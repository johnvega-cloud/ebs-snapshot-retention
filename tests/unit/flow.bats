#!/usr/bin/env bats
# End-to-end runs of the script against the fake `aws`: which calls are made,
# with which arguments, how errors are classified and which exit code results.

load ../helpers/common

setup() {
	common_setup
	TODAY=2026-10-24
	REPORT="$BATS_TEST_TMPDIR/report.json"
}

status_of() { # status_of ID -> status recorded in the report
	jq -r --arg id "$1" '.results[] | select(.id == $id) | .status' "$REPORT"
}

@test "snapshots every EBS volume of the tagged running instances" {
	instances "i-1:web:vol-a=/dev/xvda,vol-b=/dev/sdf" "i-2:db:vol-c=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 3 ]
	[ "$(status_of vol-a)" = created ]
	[ "$(status_of vol-c)" = created ]
	[ "$(jq -r '.summary.created' "$REPORT")" = 3 ]
}

@test "the instance query filters on running state and the selector tag" {
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	line=$(calls describe-instances)
	[[ "$line" == *"Name=instance-state-name,Values=running"* ]] || false
	[[ "$line" == *"Name=tag:Backup,Values=true"* ]] || false
}

@test "--tag changes the selector and accepts several values" {
	run "$SCRIPT" --tag Env=prod,staging
	[ "$status" -eq 0 ]
	[[ "$(calls describe-instances)" == *"Name=tag:Env,Values=prod,staging"* ]] || false
}

@test "a multi-attach volume is snapshotted once" {
	instances "i-1:a:vol-shared=/dev/sdf" "i-2:b:vol-shared=/dev/sdf" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 1 ]
}

@test "no tagged instances is a clean no-op" {
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ -z "$(calls create-snapshot)" ]
	[ "$(jq -c '.summary' "$REPORT")" = "{}" ]
}

@test "re-running the same day does not create a second snapshot" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	snapshot snap-today vol-a 0 completed "$TODAY" | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ -z "$(calls create-snapshot)" ]
	[ "$(status_of vol-a)" = exists ]
}

@test "a pending snapshot from today also counts as done" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	snapshot snap-today vol-a 0 pending "$TODAY" | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$(calls create-snapshot)" ]
}

@test "today's snapshot in error state is retried" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	snapshot snap-bad vol-a 0 error "$TODAY" | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 1 ]
}

@test "yesterday's snapshot does not block today's" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	snapshot snap-y vol-a 1 | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 1 ]
}

@test "managed snapshots are listed by owner=self and the tool's tags" {
	run "$SCRIPT" --policy weekly
	line=$(calls describe-snapshots)
	[[ "$line" == *"--owner-ids self"* ]] || false
	[[ "$line" == *"Name=tag:ebs-backup:managed-by,Values=ebs-snapshot-backup"* ]] || false
	[[ "$line" == *"Name=tag:ebs-backup:policy,Values=weekly"* ]] || false
}

@test "snapshot tags: own tags, copied volume tags, no aws: or selector tags" {
	instances "i-1:web:vol-a=/dev/sdf" >"$STUB_DIR/describe-instances.out"
	cat >"$STUB_DIR/describe-volumes.out" <<-'EOF'
		{"Volumes": [{"VolumeId": "vol-a", "Tags": [
		  {"Key": "owner", "Value": "team-a"},
		  {"Key": "CostCenter", "Value": "42"},
		  {"Key": "aws:cloudformation:stack-name", "Value": "x"},
		  {"Key": "Name", "Value": "data-disk"},
		  {"Key": "Backup", "Value": "true"},
		  {"Key": "ebs-backup:policy", "Value": "spoofed"}]}]}
	EOF
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	spec=$(calls create-snapshot | sed 's/.*--tag-specifications \(\[.*\]\).*/\1/')
	tags=$(jq -c '.[0].Tags | from_entries' <<<"$spec")
	[ "$(jq -r '.["ebs-backup:managed-by"]' <<<"$tags")" = ebs-snapshot-backup ]
	[ "$(jq -r '.["ebs-backup:policy"]' <<<"$tags")" = default ]
	[ "$(jq -r '.["ebs-backup:volume-id"]' <<<"$tags")" = vol-a ]
	[ "$(jq -r '.["ebs-backup:instance-id"]' <<<"$tags")" = i-1 ]
	[ "$(jq -r '.["ebs-backup:backup-date"]' <<<"$tags")" = "$TODAY" ]
	[ "$(jq -r '.Name' <<<"$tags")" = "web /dev/sdf $TODAY" ]
	[ "$(jq -r '.owner' <<<"$tags")" = team-a ]
	[ "$(jq -r '.CostCenter' <<<"$tags")" = 42 ]
	[ "$(jq -r 'has("aws:cloudformation:stack-name")' <<<"$tags")" = false ]
	[ "$(jq -r 'has("Backup")' <<<"$tags")" = false ]
}

@test "snapshot tags never exceed the EC2 limit of 50" {
	instances "i-1:web:vol-a=/dev/sdf" >"$STUB_DIR/describe-instances.out"
	jq -n '{Volumes: [{VolumeId: "vol-a", Tags: [range(60) | {Key: "k\(.)", Value: "v"}]}]}' >"$STUB_DIR/describe-volumes.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	spec=$(calls create-snapshot | sed 's/.*--tag-specifications \(\[.*\]\).*/\1/')
	[ "$(jq '.[0].Tags | length' <<<"$spec")" -eq 50 ]
	[ "$(jq -r '.[0].Tags[0].Key' <<<"$spec")" = "ebs-backup:managed-by" ]
}

@test "--no-copy-tags skips describe-volumes" {
	instances "i-1:web:vol-a=/dev/sdf" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT" --no-copy-tags
	[ "$status" -eq 0 ]
	[ -z "$(calls describe-volumes)" ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 1 ]
}

@test "failing to read volume tags still takes the snapshots" {
	instances "i-1:web:vol-a=/dev/sdf" >"$STUB_DIR/describe-instances.out"
	aws_err UnauthorizedOperation >"$STUB_DIR/describe-volumes.err"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 1 ]
}

@test "volume tags are read in chunks of at most 150 ids" {
	vols=$(jq -rn '[range(151) | "vol-\(.)=/dev/sd\(.)"] | join(",")')
	instances "i-1:web:$vols" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT" --mode snapshot
	[ "$status" -eq 0 ]
	[ "$(calls describe-volumes | wc -l | tr -d ' ')" -eq 2 ]
	first=$(calls describe-volumes | sed -n 1p | sed 's/.*Values=\([^ ]*\).*/\1/')
	second=$(calls describe-volumes | sed -n 2p | sed 's/.*Values=\([^ ]*\).*/\1/')
	[ "$(tr ',' '\n' <<<"$first" | wc -l | tr -d ' ')" -eq 150 ]
	[[ "$second" == vol-* && "$second" != *,* ]] || false
	[ "$(tr ',' '\n' <<<"$first,$second" | sort -u | wc -l | tr -d ' ')" -eq 151 ]
	[ "$(calls create-snapshot | wc -l | tr -d ' ')" -eq 151 ]
}

@test "one failing volume does not stop the others, exit 3" {
	instances "i-1:web:vol-a=/dev/xvda,vol-b=/dev/sdf,vol-c=/dev/sdg" >"$STUB_DIR/describe-instances.out"
	aws_err SnapshotCreationPerVolumeRateExceeded >"$STUB_DIR/create-snapshot@vol-b.err"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(status_of vol-a)" = created ]
	[ "$(status_of vol-b)" = failed ]
	[ "$(status_of vol-c)" = created ]
	[ "$(jq -r '.results[] | select(.id=="vol-b") | .error' "$REPORT")" = SnapshotCreationPerVolumeRateExceeded ]
}

@test "old managed snapshots are deleted after the new ones are taken" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	{
		snapshot s-1 vol-a 1
		snapshot s-31 vol-a 31
		snapshot s-45 vol-a 45
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of s-31)" = deleted ]
	[ "$(status_of s-45)" = deleted ]
	[ -z "$(calls delete-snapshot | grep s-1 || true)" ]
	# create before delete: a failed run never leaves a volume with fewer copies
	[ "$(grep -n -m1 create-snapshot "$STUB_LOG" | cut -d: -f1)" -lt "$(grep -n -m1 delete-snapshot "$STUB_LOG" | cut -d: -f1)" ]
}

@test "the last copy of a volume that is no longer backed up is kept" {
	{
		snapshot s-40 vol-gone 40
		snapshot s-50 vol-gone 50
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of s-40)" = kept ]
	[ "$(jq -r '.results[] | select(.id=="s-40") | .reason' "$REPORT")" = min ]
	[ "$(status_of s-50)" = deleted ]
}

@test "protected snapshots are reported as kept" {
	{
		snapshot s-1 vol-a 1
		snapshot s-p vol-a 90 completed "" DoNotDelete
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of s-p)" = kept ]
	[ -z "$(calls delete-snapshot)" ]
}

@test "--protect-tag changes the protection key" {
	{
		snapshot s-1 vol-a 1
		snapshot s-p vol-a 90 completed "" Legal-Hold
		snapshot s-d vol-a 90 completed "" DoNotDelete
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --protect-tag Legal-Hold --report "$REPORT"
	[ "$(status_of s-p)" = kept ]
	[ "$(status_of s-d)" = deleted ]
}

@test "a snapshot used by an AMI is skipped, not a failure" {
	{
		snapshot s-1 vol-a 1
		snapshot s-ami vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	aws_err InvalidSnapshot.InUse >"$STUB_DIR/delete-snapshot@s-ami.err"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of s-ami)" = skipped-in-use ]
}

@test "a snapshot deleted by someone else meanwhile is already-gone" {
	{
		snapshot s-1 vol-a 1
		snapshot s-x vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	aws_err InvalidSnapshot.NotFound >"$STUB_DIR/delete-snapshot@s-x.err"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of s-x)" = already-gone ]
}

@test "a denied delete is reported as denied, exit 3" {
	{
		snapshot s-1 vol-a 1
		snapshot s-x vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	aws_err UnauthorizedOperation >"$STUB_DIR/delete-snapshot@s-x.err"
	run "$SCRIPT" --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(status_of s-x)" = denied ]
}

@test "--dry-run sends DryRun on every create and delete and changes nothing" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	{
		snapshot s-1 vol-a 1
		snapshot s-60 vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --dry-run --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(status_of vol-a)" = would-create ]
	[ "$(status_of s-60)" = would-delete ]
	[[ "$(calls create-snapshot)" == *"--dry-run"* ]] || false
	[[ "$(calls delete-snapshot)" == *"--dry-run"* ]] || false
	[ "$(jq -r '.dry_run' "$REPORT")" = true ]
}

@test "--dry-run reports missing permissions as denied, exit 3" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	aws_err UnauthorizedOperation >"$STUB_DIR/create-snapshot.dryrun.err"
	run "$SCRIPT" --dry-run --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(status_of vol-a)" = denied ]
}

@test "--mode snapshot never deletes" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	snapshot s-60 vol-a 60 | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --mode snapshot --keep-min 0
	[ "$status" -eq 0 ]
	[ -n "$(calls create-snapshot)" ]
	[ -z "$(calls delete-snapshot)" ]
}

@test "--mode prune never looks at instances or creates snapshots" {
	{
		snapshot s-1 vol-a 1
		snapshot s-60 vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --mode prune
	[ "$status" -eq 0 ]
	[ -z "$(calls describe-instances)" ]
	[ -z "$(calls create-snapshot)" ]
	[ -n "$(calls delete-snapshot)" ]
}

@test "--max-deletes aborts pruning of that region, exit 3" {
	{
		snapshot s-1 vol-a 1
		snapshot s-40 vol-a 40
		snapshot s-50 vol-a 50
		snapshot s-60 vol-a 60
	} | snapshots >"$STUB_DIR/describe-snapshots.out"
	run "$SCRIPT" --max-deletes 2 --report "$REPORT"
	[ "$status" -eq 3 ]
	[ -z "$(calls delete-snapshot)" ]
	[ "$(status_of us-east-1)" = aborted ]
}

@test "a failing region is reported and the next region still runs, exit 3" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	aws_err AuthFailure >"$STUB_DIR/describe-snapshots@eu-west-1.err"
	run "$SCRIPT" -r eu-west-1 -r us-east-1 --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(status_of eu-west-1)" = region-error ]
	[ "$(jq -r '.results[] | select(.id=="eu-west-1") | .step' "$REPORT")" = describe-snapshots ]
	[ "$(jq -r '.results[] | select(.id=="vol-a") | .region' "$REPORT")" = us-east-1 ]
	[ "$(status_of vol-a)" = created ]
}

@test "a failing instance query skips only that region" {
	aws_err RequestLimitExceeded >"$STUB_DIR/describe-instances@eu-west-1.err"
	run "$SCRIPT" -r eu-west-1 -r us-east-1 --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(jq -r '.results[] | select(.id=="eu-west-1") | .step' "$REPORT")" = describe-instances ]
	[ "$(calls describe-instances | wc -l | tr -d ' ')" -eq 2 ]
}

@test "regions are processed in the given order" {
	run "$SCRIPT" -r eu-west-1 -r ap-south-1
	[ "$status" -eq 0 ]
	[[ "$(calls describe-instances | head -1)" == *"--region eu-west-1"* ]] || false
	[[ "$(calls describe-instances | tail -1)" == *"--region ap-south-1"* ]] || false
}

@test "--all-regions processes every enabled region" {
	echo '{"Regions": [{"RegionName": "us-west-2"}, {"RegionName": "eu-central-1"}]}' >"$STUB_DIR/describe-regions.out"
	run "$SCRIPT" --all-regions
	[ "$status" -eq 0 ]
	[ "$(calls describe-instances | wc -l | tr -d ' ')" -eq 2 ]
	[[ "$(calls describe-instances)" == *"--region eu-central-1"* ]] || false
	[[ "$(calls describe-instances)" == *"--region us-west-2"* ]] || false
}

@test "every EC2 call carries bounded timeouts and JSON output" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT"
	while IFS= read -r line; do
		[[ "$line" == *"--cli-connect-timeout 5"* ]] || false
		[[ "$line" == *"--cli-read-timeout 30"* ]] || false
		[[ "$line" == *"--output json"* ]] || false
	done < <(grep '^ec2 ' "$STUB_LOG")
}

@test "--wait reports completed snapshots" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	echo '{"Snapshots": [{"SnapshotId": "snap-new-a", "State": "completed"}]}' >"$STUB_DIR/describe-snapshots@snap-new-a.out"
	run "$SCRIPT" --wait --report "$REPORT"
	[ "$status" -eq 0 ]
	[ "$(jq -r '.results[] | select(.kind=="snapshot" and .id=="snap-new-a") | .status' "$REPORT")" = completed ]
}

@test "--wait turns a snapshot in error state into a failure, exit 3" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	echo '{"Snapshots": [{"SnapshotId": "snap-new-a", "State": "error", "StateMessage": "KMS key disabled"}]}' >"$STUB_DIR/describe-snapshots@snap-new-a.out"
	run "$SCRIPT" --wait --report "$REPORT"
	[ "$status" -eq 3 ]
	[ "$(jq -r '.results[] | select(.id=="snap-new-a") | .message' "$REPORT")" = "KMS key disabled" ]
}

@test "--wait gives up after the timeout without failing" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	echo '{"Snapshots": [{"SnapshotId": "snap-new-a", "State": "pending"}]}' >"$STUB_DIR/describe-snapshots@snap-new-a.out"
	run "$SCRIPT" --wait --wait-timeout 0
	[ "$status" -eq 0 ]
	[[ "$output" == *"wait timeout"* ]] || false
}

@test "a live lock stops a second run, exit 1" {
	mkdir "$TMPDIR/ebs-snapshot-backup-default.lock"
	echo $$ >"$TMPDIR/ebs-snapshot-backup-default.lock/pid"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"another run holds the lock"* ]] || false
	[ -z "$(calls describe-instances)" ]
}

@test "a stale lock is removed and the run proceeds; the lock is released" {
	mkdir "$TMPDIR/ebs-snapshot-backup-default.lock"
	echo 999999 >"$TMPDIR/ebs-snapshot-backup-default.lock/pid"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$output" == *"removing stale lock"* ]] || false
	[ ! -e "$TMPDIR/ebs-snapshot-backup-default.lock" ]
}

@test "different policies use different locks" {
	mkdir "$TMPDIR/ebs-snapshot-backup-default.lock"
	echo $$ >"$TMPDIR/ebs-snapshot-backup-default.lock/pid"
	run "$SCRIPT" --policy monthly
	[ "$status" -eq 0 ]
}

@test "--log-format json emits one JSON object per line" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT" --log-format json
	[ "$status" -eq 0 ]
	while IFS= read -r line; do
		jq -e '.ts and .level and .msg and .run_id' <<<"$line" >/dev/null
	done <<<"$output"
	[[ "$output" == *'"msg":"volume created"'* ]] || false
}

@test "the report holds run metadata and a status summary" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT" --report "$REPORT" --retention-days 14 --policy daily
	[ "$status" -eq 0 ]
	[ "$(jq -r '.policy' "$REPORT")" = daily ]
	[ "$(jq -r '.retention_days' "$REPORT")" = 14 ]
	[ "$(jq -r '.backup_date' "$REPORT")" = "$TODAY" ]
	[ "$(jq -r '.selector' "$REPORT")" = "Backup=true" ]
	[ "$(jq -r '.summary.created' "$REPORT")" = 1 ]
}

@test "no temporary files are left behind" {
	instances "i-1:web:vol-a=/dev/xvda" >"$STUB_DIR/describe-instances.out"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[ -z "$(find "$TMPDIR" -maxdepth 1 -name 'ebs-snapshot-backup*')" ]
}
