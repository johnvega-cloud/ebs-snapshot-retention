#!/usr/bin/env bash
# Runs the end-to-end checks against the harness deployed by main.tf.
# Every check prints PASS/FAIL; the script exits 1 if any check failed.
#
# The backup script runs as the e2e role (iam/ policy only). Setup steps that
# the role must NOT be able to do (tagging a snapshot DoNotDelete) run as you.
#
# Usage: cd e2e/aws && terraform apply && ./run-e2e.sh

set -o errexit -o nounset -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../../bin/ebs-snapshot-backup"
OUT="$HERE/e2e-out"
mkdir -p "$OUT"

tf() { terraform -chdir="$HERE" output -raw "$1"; }
REGION=$(tf region)
ROLE_ARN=$(tf role_arn)
SELECTOR=$(tf selector)
POLICY=$(tf policy)
DATA_VOL=$(tf data_volume_id)
MANUAL=$(tf manual_snapshot_id)
BACKED_VOLS=$(terraform -chdir="$HERE" output -json backed_volume_ids | jq -r 'join(" ")')
IGNORED_VOLS=$(terraform -chdir="$HERE" output -json ignored_volume_ids | jq -r 'join(" ")')
export AWS_REGION="$REGION"

PASS=0
FAIL=0
check() { # check NAME EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then
		PASS=$((PASS + 1))
		printf 'PASS  %-62s %s\n' "$1" "$3"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL  %-62s expected=%s actual=%s\n' "$1" "$2" "$3"
	fi
}

# --- identities -------------------------------------------------------------
# Your identity comes from the CLI profile (AWS_PROFILE or default). The role's
# temporary keys are exported as env vars, which take precedence over the
# profile; as_user drops them in a subshell to act as you again.
as_user() { (unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN && "$@"); }

assume_role() {
	local creds
	creds=$(as_user aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name ebs-e2e \
		--query Credentials --output json)
	export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds")
	AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds")
	AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds")
}

# IAM changes take a few seconds to propagate to a freshly created role.
for _ in 1 2 3 4 5 6; do
	as_user aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name probe >/dev/null 2>&1 && break
	sleep 10
done
assume_role
check "running as the e2e role" "yes" "$(aws sts get-caller-identity --query Arn --output text | grep -q 'assumed-role/.*ebs-snapshot-backup' && echo yes || echo no)"

backup() { # backup NAME [extra args...]  -> runs the script, keeps rc and report
	local name=$1
	shift
	set +o errexit
	"$SCRIPT" --region "$REGION" --tag "$SELECTOR" --policy "$POLICY" \
		--report "$OUT/$name.json" "$@" 2>"$OUT/$name.log"
	RC=$?
	set -o errexit
}
summary() { jq -r --arg k "$2" '.summary[$k] // 0' "$OUT/$1.json"; }
managed() { # managed -> "snapshot volume" lines of this policy
	aws ec2 describe-snapshots --owner-ids self \
		--filters "Name=tag:ebs-backup:managed-by,Values=ebs-snapshot-backup" "Name=tag:ebs-backup:policy,Values=$POLICY" \
		--query 'Snapshots[].[SnapshotId,VolumeId]' --output text | sort
}
managed_count() { managed | grep -c . || true; }
exists() { aws ec2 describe-snapshots --snapshot-ids "$1" >/dev/null 2>&1 && echo yes || echo no; }
err_code() { sed -n 's/.*An error occurred (\([^)]*\)).*/\1/p' | head -1; }

DAY=86400
T0=$(date +%s)

echo "== 1. dry-run: permissions checked by AWS, nothing created"
backup 01-dry-run --dry-run
check "dry-run exit code" 0 "$RC"
check "dry-run would-create (root + data volume)" 2 "$(summary 01-dry-run would-create)"
check "dry-run created nothing" 0 "$(managed_count)"

echo "== 2. first real run"
backup 02-first --wait --wait-timeout 900
check "first run exit code" 0 "$RC"
check "first run created" 2 "$(summary 02-first created)"
check "first run completed (--wait)" 2 "$(summary 02-first completed)"
check "snapshotted volumes = root + data of the backed instance" "$BACKED_VOLS" "$(managed | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
for v in $IGNORED_VOLS; do
	check "volume of unselected/stopped instance ignored ($v)" 0 "$(managed | grep -c "$v" || true)"
done
TAGS=$(aws ec2 describe-snapshots --owner-ids self --filters "Name=volume-id,Values=$DATA_VOL" \
	"Name=tag:ebs-backup:policy,Values=$POLICY" --query 'Snapshots[0].Tags' --output json | jq -c from_entries)
check "tag managed-by" ebs-snapshot-backup "$(jq -r '.["ebs-backup:managed-by"]' <<<"$TAGS")"
check "tag device" /dev/sdf "$(jq -r '.["ebs-backup:device"]' <<<"$TAGS")"
check "copied volume tag owner" team-e2e "$(jq -r .owner <<<"$TAGS")"
check "copied volume tag CostCenter" lab-05 "$(jq -r .CostCenter <<<"$TAGS")"
check "selector tag not copied" false "$(jq -r --arg k "${SELECTOR%%=*}" 'has($k)' <<<"$TAGS")"
FIRST_SNAPS=$(managed | awk '{print $1}' | tr '\n' ' ')

echo "== 3. idempotency: same day again"
backup 03-rerun
check "rerun exit code" 0 "$RC"
check "rerun created" 0 "$(summary 03-rerun created)"
check "rerun exists" 2 "$(summary 03-rerun exists)"
check "still 2 managed snapshots" 2 "$(managed_count)"

echo "== 4. least privilege, straight API calls as the role"
code=$(aws ec2 create-snapshot --volume-id "$DATA_VOL" --description untagged 2>&1 >/dev/null | err_code || true)
check "CreateSnapshot without the managed-by tag" UnauthorizedOperation "$code"
code=$(aws ec2 delete-snapshot --snapshot-id "$MANUAL" 2>&1 >/dev/null | err_code || true)
check "DeleteSnapshot of the manual snapshot" UnauthorizedOperation "$code"
code=$(aws ec2 create-tags --resources "$MANUAL" --tags Key=ebs-backup:managed-by,Value=ebs-snapshot-backup 2>&1 >/dev/null | err_code || true)
check "re-tag a foreign snapshot as managed" UnauthorizedOperation "$code"

echo "== 5. day 31: new copy taken, old copy held by keep-min"
EBS_BACKUP_NOW=$((T0 + 31 * DAY)) backup 05-day31 --wait --wait-timeout 900
check "day 31 exit code" 0 "$RC"
check "day 31 created" 2 "$(summary 05-day31 created)"
check "day 31 kept by keep-min" 2 "$(summary 05-day31 kept)"
check "day 31 deleted" 0 "$(summary 05-day31 deleted)"

echo "== 6. day 32: the day-0 copies are past retention and not the newest"
# Day 32 is also a backup day: it takes its own copies (waited for, so the
# later steps see only completed snapshots; pending ones are never pruned).
EBS_BACKUP_NOW=$((T0 + 32 * DAY)) backup 06-day32 --wait --wait-timeout 900
check "day 32 exit code" 0 "$RC"
check "day 32 created" 2 "$(summary 06-day32 created)"
check "day 32 deleted" 2 "$(summary 06-day32 deleted)"
check "managed snapshots now: day 31 + day 32 copies" 4 "$(managed_count)"
for s in $FIRST_SNAPS; do
	check "day-0 snapshot $s is gone" no "$(exists "$s")"
done
check "manual snapshot untouched" yes "$(exists "$MANUAL")"

echo "== 7. --max-deletes brake"
EBS_BACKUP_NOW=$((T0 + 400 * DAY)) backup 07-brake --mode prune --keep-min 0 --retention-days 1 --max-deletes 1
check "brake exit code" 3 "$RC"
check "brake aborted the region" 1 "$(summary 07-brake aborted)"
check "brake deleted nothing" 4 "$(managed_count)"

echo "== 8. DoNotDelete: script rule and IAM deny"
PROTECTED=$(managed | awk 'NR==1 {print $1}')
as_user aws ec2 create-tags --resources "$PROTECTED" --tags Key=DoNotDelete,Value=e2e
EBS_BACKUP_NOW=$((T0 + 400 * DAY)) backup 08-protected --mode prune --keep-min 0 --retention-days 1
check "script keeps DoNotDelete" kept "$(jq -r --arg s "$PROTECTED" '.results[] | select(.id==$s) | .status' "$OUT/08-protected.json")"
check "the other three snapshots were deleted" 3 "$(summary 08-protected deleted)"
# Bypass the script's own rule: only the IAM Deny is left to stop the delete.
EBS_BACKUP_NOW=$((T0 + 400 * DAY)) backup 08-iam-deny --mode prune --keep-min 0 --retention-days 1 --protect-tag NoSuchTag
check "IAM deny exit code" 3 "$RC"
check "IAM deny on DoNotDelete" denied "$(jq -r --arg s "$PROTECTED" '.results[] | select(.id==$s) | .status' "$OUT/08-iam-deny.json")"
check "protected snapshot still exists" yes "$(exists "$PROTECTED")"

echo "== 9. cleanup through the script itself"
as_user aws ec2 delete-tags --resources "$PROTECTED" --tags Key=DoNotDelete
EBS_BACKUP_NOW=$((T0 + 400 * DAY)) backup 09-cleanup --mode prune --keep-min 0 --retention-days 1
check "cleanup exit code" 0 "$RC"
check "no managed snapshots left" 0 "$(managed_count)"
check "manual snapshot still untouched" yes "$(exists "$MANUAL")"

echo
echo "checks: $PASS passed, $FAIL failed (logs and reports in $OUT)"
[ "$FAIL" -eq 0 ]
