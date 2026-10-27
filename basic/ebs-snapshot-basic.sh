#!/usr/bin/env bash
# Minimal version of the exercise: snapshot every EBS volume attached to a
# running instance tagged Backup=true, then delete the snapshots this script
# created that are older than RETENTION_DAYS (default 30).
#
# Usage: AWS_REGION=us-east-1 ./ebs-snapshot-basic.sh
# Needs: AWS CLI v2 and credentials. The full tool is bin/ebs-snapshot-backup.
set -euo pipefail

RETENTION_DAYS="${RETENTION_DAYS:-30}"
TAG_KEY="CreatedBy"
TAG_VALUE="ebs-snapshot-basic"

# Cutoff taken before any snapshot is created, so this run's own snapshots
# are never older than it. GNU date (Linux) uses -d, BSD date (macOS) uses -v.
cutoff=$(date -u -d "$RETENTION_DAYS days ago" +%Y-%m-%dT%H:%M:%S 2>/dev/null ||
	date -u -v-"${RETENTION_DAYS}"d +%Y-%m-%dT%H:%M:%S)

# 1. Volumes attached to running instances tagged Backup=true.
volumes=$(aws ec2 describe-instances \
	--filters "Name=tag:Backup,Values=true" "Name=instance-state-name,Values=running" \
	--query "Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId" \
	--output text)

# 2. One snapshot per volume, tagged so step 3 only deletes our own snapshots.
for volume in $volumes; do
	snapshot=$(aws ec2 create-snapshot \
		--volume-id "$volume" \
		--description "Backup of $volume" \
		--tag-specifications "ResourceType=snapshot,Tags=[{Key=$TAG_KEY,Value=$TAG_VALUE}]" \
		--query SnapshotId --output text)
	echo "created $snapshot from $volume"
done

# 3. Retention: delete our snapshots that started before the cutoff.
aws ec2 describe-snapshots \
	--owner-ids self \
	--filters "Name=tag:$TAG_KEY,Values=$TAG_VALUE" \
	--query "Snapshots[].[SnapshotId,StartTime]" \
	--output text |
	while read -r snapshot started; do
		# ISO-8601 timestamps sort as text, so a string comparison is enough.
		if [[ "$started" < "$cutoff" ]]; then
			aws ec2 delete-snapshot --snapshot-id "$snapshot"
			echo "deleted $snapshot (started $started)"
		fi
	done
