#!/usr/bin/env bats
# shellcheck disable=SC2034 # globals read by the sourced script
# Retention rules, tested on the pure jq function: no AWS calls involved.

load ../helpers/common

setup() {
	common_setup
	# shellcheck source=/dev/null
	source "$SCRIPT"
	NOW_EPOCH=$NOW
	RETENTION_DAYS=30
	KEEP_MIN=1
	MANAGED="$BATS_TEST_TMPDIR/managed.json"
}

# managed ID:VOL:AGE_DAYS[:STATE[:protected]] ... -> normalised managed list
managed() {
	jq -n --argjson now "$NOW" '$ARGS.positional
	  | map(split(":") as [$id, $vol, $age, $state, $prot]
	        | {snapshot_id: $id, volume_id: $vol, backup_date: "",
	           state: ($state // "completed"),
	           start_epoch: ($now - ($age | tonumber) * 86400),
	           protected: ($prot == "protected")})' --args "$@" >"$MANAGED"
}

decision() { # decision SNAPSHOT_ID
	prune_plan "$MANAGED" | jq -r --arg id "$1" 'select(.snapshot_id == $id) | .decision'
}

@test "snapshots younger than retention are kept, older ones deleted" {
	managed s-new:v1:1 s-mid:v1:29 s-old:v1:31 s-older:v1:90
	[ "$(decision s-new)" = keep-young ]
	[ "$(decision s-mid)" = keep-young ]
	[ "$(decision s-old)" = delete ]
	[ "$(decision s-older)" = delete ]
}

@test "exactly retention days old is deleted (older than or equal to the cutoff)" {
	managed s-30:v1:30 s-new:v1:0
	[ "$(decision s-30)" = delete ]
}

@test "keep-min keeps the newest completed snapshot even when it is past retention" {
	managed s-a:v1:40 s-b:v1:50 s-c:v1:60
	[ "$(decision s-a)" = keep-min ]
	[ "$(decision s-b)" = delete ]
	[ "$(decision s-c)" = delete ]
}

@test "keep-min counts per volume" {
	managed a1:v1:40 a2:v1:50 b1:v2:45 b2:v2:55
	[ "$(decision a1)" = keep-min ]
	[ "$(decision b1)" = keep-min ]
	[ "$(decision a2)" = delete ]
	[ "$(decision b2)" = delete ]
}

@test "a pending or failed snapshot does not count towards keep-min" {
	# Today's snapshot is still pending: it is not a backup yet, so the newest
	# completed one is kept.
	managed new:v1:0:pending err:v1:5:error old:v1:31
	[ "$(decision old)" = keep-min ]
}

@test "keep-min 2 keeps the two newest completed" {
	KEEP_MIN=2
	managed s1:v1:40 s2:v1:41 s3:v1:42
	[ "$(decision s1)" = keep-min ]
	[ "$(decision s2)" = keep-min ]
	[ "$(decision s3)" = delete ]
}

@test "keep-min 0 deletes every snapshot past retention" {
	KEEP_MIN=0
	managed s1:v1:40 s2:v1:41
	[ "$(decision s1)" = delete ]
	[ "$(decision s2)" = delete ]
}

@test "protected snapshots are never deleted" {
	managed new:v1:1 p:v1:100:completed:protected
	[ "$(decision p)" = keep-protected ]
}

@test "old snapshots still pending (or in error) are not deleted" {
	KEEP_MIN=0
	managed stuck:v1:40:pending broken:v1:40:error
	[ "$(decision stuck)" = keep-not-completed ]
	[ "$(decision broken)" = keep-not-completed ]
}

@test "the retention period follows --retention-days" {
	RETENTION_DAYS=7
	managed s6:v1:6 s8:v1:8 s0:v1:0
	[ "$(decision s6)" = keep-young ]
	[ "$(decision s8)" = delete ]
}

@test "age_days is reported for every snapshot" {
	managed s:v1:45 n:v1:0
	run bash -c "source '$SCRIPT'; NOW_EPOCH=$NOW RETENTION_DAYS=30 KEEP_MIN=1 prune_plan '$MANAGED' | jq -r 'select(.snapshot_id==\"s\") | .age_days'"
	[ "$output" = 45 ]
}

@test "an empty list produces no decisions" {
	echo '[]' >"$MANAGED"
	[ -z "$(prune_plan "$MANAGED")" ]
}
