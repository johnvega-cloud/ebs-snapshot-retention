#!/usr/bin/env bats
# Integration tests: the real AWS CLI against moto's EC2 server.
# Proves the CLI arguments, filters, tag specifications and JMESPath-free
# parsing work with real API responses, not only with the unit-test stub.
#
# Uses $MOTO_URL if set, otherwise starts `moto_server` (pip install
# 'moto[server]'). Skipped when neither is available, unless REQUIRE_MOTO=1
# (CI), where a missing server is a failure instead of a silent skip.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/ebs-snapshot-backup"
DAY=86400

setup_file() {
	if [ -z "${MOTO_URL:-}" ] && command -v moto_server >/dev/null 2>&1; then
		local port=$((15000 + RANDOM % 1000))
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
		[ "${REQUIRE_MOTO:-0}" != 1 ] || { echo "REQUIRE_MOTO=1 but no moto server" >&2; return 1; }
		skip "moto_server not available"
	fi
	export AWS_ENDPOINT_URL="$MOTO_URL"
	export AWS_ACCESS_KEY_ID=testing AWS_SECRET_ACCESS_KEY=testing AWS_REGION=us-east-1
	unset AWS_PROFILE AWS_SESSION_TOKEN AWS_DEFAULT_REGION EBS_BACKUP_NOW
	export TMPDIR="$BATS_TEST_TMPDIR"
	curl -fs -X POST "$MOTO_URL/moto-api/reset" >/dev/null
	REPORT="$BATS_TEST_TMPDIR/report.json"
	AMI=$(aws ec2 describe-images --query 'Images[0].ImageId' --output text)
}

# run_instance TAGS -> instance id. TAGS in CLI shorthand, e.g. {Key=Backup,Value=true}
run_instance() {
	local spec=()
	[ -n "$1" ] && spec=(--tag-specifications "ResourceType=instance,Tags=[$1]")
	aws ec2 run-instances --image-id "$AMI" --instance-type t3.nano \
		${spec[@]+"${spec[@]}"} --query 'Instances[0].InstanceId' --output text
}

attach_data_volume() { # attach_data_volume INSTANCE DEVICE [TAGS] -> volume id
	local vol tags=()
	[ -n "${3:-}" ] && tags=(--tag-specifications "ResourceType=volume,Tags=[$3]")
	vol=$(aws ec2 create-volume --size 1 --availability-zone us-east-1a \
		${tags[@]+"${tags[@]}"} --query VolumeId --output text)
	aws ec2 attach-volume --volume-id "$vol" --instance-id "$1" --device "$2" >/dev/null
	echo "$vol"
}

managed_snapshots() { # -> "snapshot-id volume-id" lines, sorted
	aws ec2 describe-snapshots --owner-ids self \
		--filters "Name=tag:ebs-backup:managed-by,Values=ebs-snapshot-backup" \
		--query 'Snapshots[].[SnapshotId,VolumeId]' --output text | sort
}

count_managed() {
	managed_snapshots | grep -c . || true
}

@test "only volumes of running instances tagged Backup=true are snapshotted" {
	backed=$(run_instance "{Key=Backup,Value=true},{Key=Name,Value=web-1}")
	data=$(attach_data_volume "$backed" /dev/sdf "{Key=owner,Value=team-a}")
	untagged=$(run_instance "")
	other=$(run_instance "{Key=Backup,Value=false}")
	stopped=$(run_instance "{Key=Backup,Value=true}")
	aws ec2 stop-instances --instance-ids "$stopped" >/dev/null

	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	# root volume + data volume of the one matching instance
	[ "$(count_managed)" -eq 2 ]
	[ "$(jq '.summary.created' "$REPORT")" -eq 2 ]
	vols=$(aws ec2 describe-instances --instance-ids "$untagged" "$other" "$stopped" \
		--query 'Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId' --output text)
	for v in $vols; do
		if managed_snapshots | grep -q "$v"; then false; fi
	done
	managed_snapshots | grep -q "$data"
}

@test "snapshots carry the tool's tags and the copied volume tags" {
	inst=$(run_instance "{Key=Backup,Value=true},{Key=Name,Value=web-1}")
	data=$(attach_data_volume "$inst" /dev/sdf "{Key=owner,Value=team-a},{Key=Name,Value=disk}")
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	tags=$(aws ec2 describe-snapshots --owner-ids self --filters "Name=volume-id,Values=$data" \
		--query 'Snapshots[0].Tags' --output json | jq -c 'from_entries')
	[ "$(jq -r '.["ebs-backup:managed-by"]' <<<"$tags")" = ebs-snapshot-backup ]
	[ "$(jq -r '.["ebs-backup:instance-id"]' <<<"$tags")" = "$inst" ]
	[ "$(jq -r '.["ebs-backup:device"]' <<<"$tags")" = /dev/sdf ]
	[ "$(jq -r '.owner' <<<"$tags")" = team-a ]
	[[ "$(jq -r '.Name' <<<"$tags")" == "web-1 /dev/sdf "* ]] || false
}

@test "a second run the same day creates nothing" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	attach_data_volume "$inst" /dev/sdf >/dev/null
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(count_managed)" -eq 2 ]
	[ "$(jq '.summary.exists' "$REPORT")" -eq 2 ]
	[ "$(jq '.summary.created // 0' "$REPORT")" -eq 0 ]
}

@test "rotation over time: the old snapshot goes once a newer one has completed" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	now=$(date +%s)
	run "$SCRIPT" --no-copy-tags
	[ "$status" -eq 0 ]
	first=$(managed_snapshots)
	[ "$(count_managed)" -eq 1 ]

	# Day 31: a new snapshot is taken. The old one is the newest *completed*
	# copy when the run starts, so keep-min holds it for one more day.
	EBS_BACKUP_NOW=$((now + 31 * DAY)) run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(count_managed)" -eq 2 ]
	[ "$(jq '.summary.kept' "$REPORT")" -eq 1 ]

	# Day 32: the day-31 copy exists and is completed, the day-0 copy goes.
	EBS_BACKUP_NOW=$((now + 32 * DAY)) run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq '.summary.deleted' "$REPORT")" -eq 1 ]
	[ "$(count_managed)" -eq 2 ]
	if managed_snapshots | grep -qx "$first"; then false; fi
	[ -n "$inst" ]
}

@test "snapshots not created by the tool are never deleted" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	vol=$(aws ec2 describe-instances --instance-ids "$inst" \
		--query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
	manual=$(aws ec2 create-snapshot --volume-id "$vol" --description manual --query SnapshotId --output text)
	EBS_BACKUP_NOW=$(($(date +%s) + 400 * DAY)) run "$SCRIPT" --keep-min 0 --retention-days 1
	[ "$status" -eq 0 ]
	aws ec2 describe-snapshots --snapshot-ids "$manual" >/dev/null
}

@test "DoNotDelete snapshots survive retention" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	run "$SCRIPT"
	snap=$(managed_snapshots | awk '{print $1}')
	aws ec2 create-tags --resources "$snap" --tags Key=DoNotDelete,Value=legal
	EBS_BACKUP_NOW=$(($(date +%s) + 100 * DAY)) run "$SCRIPT" --mode prune --keep-min 0 --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.results[0].status' "$REPORT")" = kept ]
	aws ec2 describe-snapshots --snapshot-ids "$snap" >/dev/null
	[ -n "$inst" ]
}

@test "policies are isolated: pruning daily never touches monthly" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	run "$SCRIPT" --policy monthly
	run "$SCRIPT" --policy daily
	[ "$(count_managed)" -eq 2 ]
	EBS_BACKUP_NOW=$(($(date +%s) + 60 * DAY)) run "$SCRIPT" --policy daily --mode prune --keep-min 0
	[ "$status" -eq 0 ]
	[ "$(count_managed)" -eq 1 ]
	aws ec2 describe-snapshots --owner-ids self --filters "Name=tag:ebs-backup:policy,Values=monthly" \
		--query 'length(Snapshots)' --output text | grep -qx 1
	[ -n "$inst" ]
}

@test "--dry-run changes nothing (moto answers DryRunOperation)" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	run "$SCRIPT" --dry-run --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq '.summary["would-create"]' "$REPORT")" -eq 1 ]
	[ "$(count_managed)" -eq 0 ]
	[ -n "$inst" ]
}

@test "--dry-run of retention reports would-delete and keeps the snapshot" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	run "$SCRIPT"
	EBS_BACKUP_NOW=$(($(date +%s) + 60 * DAY)) run "$SCRIPT" --mode prune --keep-min 0 --dry-run --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.results[0].status' "$REPORT")" = would-delete ]
	[ "$(count_managed)" -eq 1 ]
	[ -n "$inst" ]
}

@test "--wait reports the new snapshots as completed" {
	inst=$(run_instance "{Key=Backup,Value=true}")
	EBS_BACKUP_POLL_SECONDS=0 run "$SCRIPT" --wait --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq '.summary.completed' "$REPORT")" -eq 1 ]
	[ -n "$inst" ]
}

@test "--all-regions walks every region moto exposes" {
	run "$SCRIPT" --all-regions --report "$REPORT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"region start region=eu-west-1"* ]] || false
	[[ "$output" == *"region start region=us-east-1"* ]] || false
}
