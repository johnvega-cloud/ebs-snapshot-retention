# End-to-end test (real AWS)

Deploys a minimal fleet and an IAM role with exactly the policy in
[`iam/`](../../iam/ebs-snapshot-backup-policy.json), runs the script **as that
role**, checks every rule against the real API, and cleans up after itself.

Unit tests (fake `aws`) and integration tests (moto) prove the logic and the
CLI arguments; moto does not enforce IAM. This proves AWS agrees, including the
tag conditions and the explicit `Deny`.

| Resource | Role in the test |
|---|---|
| `backed`: running, selector `=true`, root + 1 GiB data volume (`owner`, `CostCenter` tags) | the two volumes that must be snapshotted |
| `unselected`: running, selector `=false` | must be ignored |
| `stopped`: stopped, selector `=true` | must be ignored (not running) |
| `manual`: a snapshot of the data volume made by Terraform | must survive every retention run |
| IAM role, trusted by the caller, policy from `iam/` | the identity the script runs as |

The selector tag key (`E2EBackup-<random>`) and the policy name
(`e2e-<random>`) carry a random suffix, so the run cannot select or prune
anything else in the account. **Cost:** three `t4g.nano` for ~20 minutes and a
few GiB of snapshots for minutes: a few cents.

## Run

```bash
cd e2e/aws
terraform init
# Accounts that only allow IAM names matching a pattern: -var name_prefix=<prefix>
terraform plan -out=tfplan
terraform apply tfplan
./run-e2e.sh            # ~15 min: waits for real snapshots to complete
```

`run-e2e.sh` moves the clock with `EBS_BACKUP_NOW` to simulate day 31, 32 and
400, so rotation is tested without waiting a month. Reports and logs of every
step land in `e2e-out/` (git-ignored: they contain resource IDs).

## Checks

| # | Step | Expected | Proves |
|---|---|---|---|
| 1 | `--dry-run` as the role | `would-create` ×2, nothing created | the role may create **tagged** snapshots (AWS evaluated the tag condition) |
| 2 | first run, `--wait` | `created` ×2, `completed` ×2; exactly the backed instance's root + data volume; the other two instances' volumes untouched; `owner`/`CostCenter` copied, selector tag not copied | discovery, tags at creation |
| 3 | same day again | `exists` ×2, nothing created | idempotency |
| 4 | direct API calls as the role: untagged `create-snapshot`, `delete-snapshot` of the manual snapshot, `create-tags` to mark the manual snapshot as managed | `UnauthorizedOperation` ×3 | least privilege: the role cannot create untagged snapshots, delete or adopt foreign ones |
| 5 | day 31 | `created` ×2, `kept` ×2 (`keep-min`), nothing deleted | a `pending` snapshot is not a backup yet: the last completed copy is held |
| 6 | day 32, `--wait` | `created` ×2, `deleted` ×2 (the day-0 copies), manual snapshot intact | rotation |
| 7 | day 400, `--max-deletes 1` | exit 3, region `aborted`, nothing deleted | the safety brake |
| 8a | one snapshot tagged `DoNotDelete`, prune | that one `kept`, the other three `deleted` | the script's protect rule |
| 8b | same, with `--protect-tag NoSuchTag` (script rule bypassed) | exit 3, `denied`, snapshot still exists | the IAM `Deny` stops it on its own |
| 9 | tag removed, prune with `--keep-min 0` | no managed snapshots left, manual snapshot intact | cleanup through the script; nothing to delete by hand |

## Result (2026-10-24, us-east-1)

**44 checks passed, 0 failed.** The script ran as the role
`cloudbatch818-ebs-e2e-ebs-snapshot-backup-<suffix>`, policy from `iam/` only.
Infrastructure destroyed afterwards: 0 resources in state, no snapshots,
instances, volumes or role left.

| Check | Actual | |
|---|---|---|
| running as the e2e role | `yes` | PASS |
| **1. dry-run: permissions checked by AWS, nothing created** | | |
| dry-run exit code | `0` | PASS |
| dry-run would-create (root + data volume) | `2` | PASS |
| dry-run created nothing | `0` | PASS |
| **2. first real run** | | |
| first run exit code | `0` | PASS |
| first run created | `2` | PASS |
| first run completed (--wait) | `2` | PASS |
| snapshotted volumes = root + data of the backed instance | `vol-… vol-…` | PASS |
| volume of unselected/stopped instance ignored (vol-…) | `0` | PASS |
| volume of unselected/stopped instance ignored (vol-…) | `0` | PASS |
| tag managed-by | `ebs-snapshot-backup` | PASS |
| tag device | `/dev/sdf` | PASS |
| copied volume tag owner | `team-e2e` | PASS |
| copied volume tag CostCenter | `lab-05` | PASS |
| selector tag not copied | `false` | PASS |
| **3. idempotency: same day again** | | |
| rerun exit code | `0` | PASS |
| rerun created | `0` | PASS |
| rerun exists | `2` | PASS |
| still 2 managed snapshots | `2` | PASS |
| **4. least privilege, straight API calls as the role** | | |
| CreateSnapshot without the managed-by tag | `UnauthorizedOperation` | PASS |
| DeleteSnapshot of the manual snapshot | `UnauthorizedOperation` | PASS |
| re-tag a foreign snapshot as managed | `UnauthorizedOperation` | PASS |
| **5. day 31: new copy taken, old copy held by keep-min** | | |
| day 31 exit code | `0` | PASS |
| day 31 created | `2` | PASS |
| day 31 kept by keep-min | `2` | PASS |
| day 31 deleted | `0` | PASS |
| **6. day 32: the day-0 copies are past retention and not the newest** | | |
| day 32 exit code | `0` | PASS |
| day 32 created | `2` | PASS |
| day 32 deleted | `2` | PASS |
| managed snapshots now: day 31 + day 32 copies | `4` | PASS |
| day-0 snapshot snap-… is gone | `no` | PASS |
| day-0 snapshot snap-… is gone | `no` | PASS |
| manual snapshot untouched | `yes` | PASS |
| **7. --max-deletes brake** | | |
| brake exit code | `3` | PASS |
| brake aborted the region | `1` | PASS |
| brake deleted nothing | `4` | PASS |
| **8. DoNotDelete: script rule and IAM deny** | | |
| script keeps DoNotDelete | `kept` | PASS |
| the other three snapshots were deleted | `3` | PASS |
| IAM deny exit code | `3` | PASS |
| IAM deny on DoNotDelete | `denied` | PASS |
| protected snapshot still exists | `yes` | PASS |
| **9. cleanup through the script itself** | | |
| cleanup exit code | `0` | PASS |
| no managed snapshots left | `0` | PASS |
| manual snapshot still untouched | `yes` | PASS |

A first run (same day) had 6 failures, all in the test's expectations, not in
the script: the day-32 run also takes that day's backups, and without `--wait`
those snapshots were still `pending`, which the script correctly never prunes.
The checks after it counted only the older copies. Fixed by waiting on day 32
and expecting the day-32 copies; the second run is the one above.

## Destroy

```bash
terraform plan -destroy -out=tfdestroy
terraform apply tfdestroy
rm -rf e2e-out
```

Step 9 already deleted every snapshot the script created; `terraform destroy`
removes the instances, the volume, the manual snapshot and the role.
