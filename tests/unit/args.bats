#!/usr/bin/env bats
# Argument parsing and preflight: every bad input exits 2 before any AWS call.

load ../helpers/common

setup() { common_setup; }

@test "--help prints usage and exits 0" {
	run "$SCRIPT" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"Usage: ebs-snapshot-backup"* ]] || false
	[[ "$output" == *"--retention-days"* ]] || false
}

@test "--version prints the version" {
	run "$SCRIPT" --version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^ebs-snapshot-backup\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || false
}

@test "unknown option exits 2" {
	run "$SCRIPT" --bogus
	[ "$status" -eq 2 ]
	[[ "$output" == *"unknown option: --bogus"* ]] || false
}

@test "option without value exits 2" {
	run "$SCRIPT" --region
	[ "$status" -eq 2 ]
	[[ "$output" == *"--region needs a value"* ]] || false
}

@test "--retention-days rejects 0 and non-numbers" {
	run "$SCRIPT" --retention-days 0
	[ "$status" -eq 2 ]
	run "$SCRIPT" --retention-days 30d
	[ "$status" -eq 2 ]
	run "$SCRIPT" --retention-days -1
	[ "$status" -eq 2 ]
}

@test "--keep-min and --max-deletes accept 0 but not negatives" {
	run "$SCRIPT" --keep-min -1
	[ "$status" -eq 2 ]
	run "$SCRIPT" --max-deletes x
	[ "$status" -eq 2 ]
}

@test "--tag needs KEY=VALUE" {
	run "$SCRIPT" --tag Backup
	[ "$status" -eq 2 ]
	run "$SCRIPT" --tag =true
	[ "$status" -eq 2 ]
	run "$SCRIPT" --tag Backup=
	[ "$status" -eq 2 ]
}

@test "--policy rejects characters that would break tag filters" {
	run "$SCRIPT" --policy 'daily,monthly'
	[ "$status" -eq 2 ]
	run "$SCRIPT" --policy 'a b'
	[ "$status" -eq 2 ]
}

@test "--mode and --log-format only accept known values" {
	run "$SCRIPT" --mode delete
	[ "$status" -eq 2 ]
	run "$SCRIPT" --log-format yaml
	[ "$status" -eq 2 ]
}

@test "--region and --all-regions are mutually exclusive" {
	run "$SCRIPT" --region us-east-1 --all-regions
	[ "$status" -eq 2 ]
}

@test "no region anywhere exits 2 without touching EC2" {
	unset AWS_REGION
	run "$SCRIPT"
	[ "$status" -eq 2 ]
	[[ "$output" == *"no region"* ]] || false
	[ -z "$(calls ec2)" ]
}

@test "the profile region is used when no region is given" {
	unset AWS_REGION
	echo eu-west-1 >"$STUB_DIR/configure-region"
	run "$SCRIPT"
	[ "$status" -eq 0 ]
	[[ "$(calls describe-instances)" == *"--region eu-west-1"* ]] || false
}

@test "invalid EBS_BACKUP_NOW is fatal" {
	EBS_BACKUP_NOW=yesterday run "$SCRIPT"
	[ "$status" -eq 1 ]
}

@test "missing credentials exit 1 before any EC2 call" {
	aws_err ExpiredToken >"$STUB_DIR/get-caller-identity.err"
	run "$SCRIPT"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no valid AWS credentials"* ]] || false
	[ -z "$(calls describe-instances)" ]
}

@test "sourcing the script defines functions without running main" {
	run bash -c "source '$SCRIPT' && type prune_plan >/dev/null && echo sourced"
	[ "$status" -eq 0 ]
	[ "$output" = "sourced" ]
	[ ! -s "$STUB_LOG" ]
}
