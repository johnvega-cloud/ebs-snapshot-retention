#!/usr/bin/env bats
# Integration tests for basic/ebs-snapshot-basic.sh, the minimal version:
# the real AWS CLI against moto's EC2 server. Same server rules as moto.bats.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/basic/ebs-snapshot-basic.sh"

setup_file() {
	if [ -z "${MOTO_URL:-}" ] && command -v moto_server >/dev/null 2>&1; then
		local port=$((16000 + RANDOM % 1000))
		moto_server -p "$port" >"$BATS_FILE_TMPDIR/moto.log" 2>&1 &
		echo $! >"$BATS_FILE_TMPDIR/moto.pid"
		export MOTO_URL="http://127.0.0.1:$port"
		for _ in $(seq 1 50); do
			curl -fs "$MOTO_URL/moto-api/" >/dev/null 2>&1 && break
			sleep 0.2
		done
	fi
}

teardown_file() {
	if [ -f "$BATS_FILE_TMPDIR/moto.pid" ]; then
		kill "$(cat "$BATS_FILE_TMPDIR/moto.pid")" 2>/dev/null || true
	fi
}

setup() {
	if [ -z "${MOTO_URL:-}" ]; then
		[ "${REQUIRE_MOTO:-0}" != 1 ] || {
			echo "REQUIRE_MOTO=1 but no moto server" >&2
			return 1
		}
		skip "moto_server not available"
	fi
	export AWS_ENDPOINT_URL="$MOTO_URL"
	export AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing AWS_REGION=us-east-1
	unset AWS_PROFILE AWS_SESSION_TOKEN AWS_DEFAULT_REGION RETENTION_DAYS
	curl -fs -X POST "$MOTO_URL/moto-api/reset" >/dev/null
	AMI=$(aws ec2 describe-images --query 'Images[0].ImageId' --output text)
}

run_instance() { # run_instance BACKUP_VALUE -> instance id
	aws ec2 run-instances --image-id "$AMI" --instance-type t3.nano \
		--placement AvailabilityZone=us-east-1a \
		--tag-specifications "ResourceType=instance,Tags=[{Key=Backup,Value=$1}]" \
		--query 'Instances[0].InstanceId' --output text
}

volumes_of() {
	aws ec2 describe-instances --instance-ids "$@" \
		--query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text
}

ours() { # -> number of snapshots carrying the basic script's tag
	aws ec2 describe-snapshots --owner-ids self \
		--filters "Name=tag:CreatedBy,Values=ebs-snapshot-basic" --query 'length(Snapshots)'
}

@test "basic: only volumes of running instances tagged Backup=true are snapshotted" {
	backed=$(run_instance true)
	other=$(run_instance false)
	stopped=$(run_instance true)
	aws ec2 stop-instances --instance-ids "$stopped" >/dev/null
	data=$(aws ec2 create-volume --size 1 --availability-zone us-east-1a --query VolumeId --output text)
	aws ec2 attach-volume --volume-id "$data" --instance-id "$backed" --device /dev/sdf >/dev/null

	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(ours)" -eq 2 ]
	want=$(volumes_of "$backed" | tr '\t' '\n' | sort)
	got=$(aws ec2 describe-snapshots --owner-ids self \
		--filters "Name=tag:CreatedBy,Values=ebs-snapshot-basic" \
		--query 'Snapshots[].VolumeId' --output text | tr '\t' '\n' | sort)
	[ "$got" = "$want" ]
	for v in $(volumes_of "$other" "$stopped"); do
		[ "$(aws ec2 describe-snapshots --filters "Name=volume-id,Values=$v" --query 'length(Snapshots)')" -eq 0 ]
	done
}

@test "basic: snapshots younger than the retention period are kept" {
	run_instance true >/dev/null
	"$SCRIPT" >/dev/null
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" != *deleted* ]] || false
	[ "$(ours)" -eq 2 ]
}

@test "basic: old snapshots of its own are deleted, this run's and foreign ones are not" {
	backed=$(run_instance true)
	root=$(volumes_of "$backed")
	manual=$(aws ec2 create-snapshot --volume-id "$root" --query SnapshotId --output text)
	"$SCRIPT" >/dev/null
	sleep 2
	# RETENTION_DAYS=0 puts the cutoff at the start of this run: the previous
	# run's snapshot is past it, the one this run takes is not.
	RETENTION_DAYS=0 run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(grep -c '^deleted' <<<"$output")" -eq 1 ]
	[ "$(ours)" -eq 1 ]
	[ "$(aws ec2 describe-snapshots --snapshot-ids "$manual" --query 'Snapshots[0].SnapshotId' --output text)" = "$manual" ]
}
