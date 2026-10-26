# shellcheck shell=bash disable=SC2034 # variables used by the .bats files
# Shared setup for the unit tests: a fake `aws` on PATH, a fixture directory
# and helpers that build EC2 API responses.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
SCRIPT="$REPO_ROOT/bin/ebs-snapshot-backup"

# Fixed clock: 2026-10-24T12:00:00Z
NOW=1792843200
DAY=86400

common_setup() {
	STUB_DIR="$BATS_TEST_TMPDIR/stub"
	STUB_LOG="$BATS_TEST_TMPDIR/aws.log"
	mkdir -p "$STUB_DIR"
	: >"$STUB_LOG"
	export STUB_DIR STUB_LOG
	export PATH="$REPO_ROOT/tests/helpers/bin:$PATH"
	export TMPDIR="$BATS_TEST_TMPDIR"
	export EBS_BACKUP_NOW="$NOW"
	export EBS_BACKUP_POLL_SECONDS=0
	export AWS_REGION=us-east-1
	unset AWS_DEFAULT_REGION AWS_PROFILE
}

# iso EPOCH -> 2026-10-24T12:00:00.000Z (the CLI's default timestamp format)
iso() {
	jq -rn --argjson e "$1" '$e | strftime("%Y-%m-%dT%H:%M:%S.000Z")'
}

# instances ID:NAME:VOL=DEV[,VOL=DEV...] ...  -> describe-instances response
instances() {
	jq -n '$ARGS.positional
	  | map(split(":") as [$id, $name, $vols]
	        | {InstanceId: $id,
	           Tags: (if $name == "" then [] else [{Key: "Name", Value: $name}, {Key: "Backup", Value: "true"}] end),
	           BlockDeviceMappings: ($vols | split(",") | map(split("=") as [$v, $d] | {DeviceName: $d, Ebs: {VolumeId: $v}}))})
	  | {Reservations: [{Instances: .}]}' --args "$@"
}

# snapshot ID VOLUME AGE_DAYS [STATE] [BACKUP_DATE] [EXTRA_TAG_KEY] -> one Snapshot object
snapshot() {
	local id=$1 vol=$2 age=$3 state=${4:-completed} date=${5:-} extra=${6:-}
	[ -n "$date" ] || date=$(jq -rn --argjson e "$((NOW - age * DAY))" '$e | strftime("%Y-%m-%d")')
	jq -n --arg id "$id" --arg vol "$vol" --arg state "$state" --arg date "$date" \
		--arg start "$(iso $((NOW - age * DAY)))" --arg extra "$extra" '
	  {SnapshotId: $id, VolumeId: $vol, State: $state, StartTime: $start,
	   Tags: ([{Key: "ebs-backup:managed-by", Value: "ebs-snapshot-backup"},
	           {Key: "ebs-backup:policy", Value: "default"},
	           {Key: "ebs-backup:volume-id", Value: $vol},
	           {Key: "ebs-backup:backup-date", Value: $date}]
	          + (if $extra == "" then [] else [{Key: $extra, Value: "yes"}] end))}'
}

# snapshots OBJ... -> describe-snapshots response
snapshots() {
	jq -s '{Snapshots: .}'
}

aws_err() { # aws_err CODE -> CLI-style error message
	echo "An error occurred ($1) when calling the operation: simulated $1"
}

calls() { # calls OP -> lines of the stub log for that operation
	grep -E -- "(^| )$1( |\$)" "$STUB_LOG" || true
}
