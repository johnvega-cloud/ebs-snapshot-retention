# ebs-snapshot-retention

[![ci](https://github.com/johnvega-cloud/ebs-snapshot-retention/actions/workflows/ci.yml/badge.svg)](https://github.com/johnvega-cloud/ebs-snapshot-retention/actions/workflows/ci.yml)

A Bash + AWS CLI script that snapshots every EBS volume attached to running EC2
instances tagged `Backup=true`, then deletes **its own** snapshots older than
the retention period (30 days by default).

It is meant to run unattended from cron or a systemd timer: it is idempotent,
logs in text or JSON, holds a lock, bounds every network call, and returns an
exit code a scheduler can alert on.

![Architecture](docs/architecture-ebs-snapshots.svg)

## The problem

> Write a Bash + AWS CLI script that snapshots all EBS volumes attached to
> running instances tagged `Backup=true` and applies a retention policy (delete
> snapshots older than 30 days).

The interesting part is not `create-snapshot`, it is the retention: a script
that deletes "snapshots older than 30 days" can delete AMI snapshots, manual
copies, AWS Backup recovery points or the only copy of a volume that stopped
being backed up. This one is built so that it cannot.

**Minimal version.** [`basic/ebs-snapshot-basic.sh`](basic/ebs-snapshot-basic.sh)
does only what the task asks, in under 50 lines: find the volumes, snapshot
them with a `CreatedBy` tag, delete the tagged snapshots older than
`RETENTION_DAYS` (30). The tag is the one safeguard it keeps, so the retention
step never touches snapshots it did not create. It has no idempotency,
`keep-min`, dry run, multi-region or error handling beyond `set -e`; the rest
of this README is about the full tool. Diagram, authoring order and the
gaps: [build guide, section 3](docs/BUILD_GUIDE.md#3-the-minimal-version-basicebs-snapshot-basicsh).

## What it does

For each selected region:

1. **Lists this tool's snapshots**: `DescribeSnapshots --owner-ids self`
   filtered on `ebs-backup:managed-by=ebs-snapshot-backup` and the policy name.
   One call serves both the "already done today?" check and the retention plan.
2. **Finds the volumes**: `DescribeInstances` with
   `instance-state-name=running` and `tag:Backup=true`, then every
   `BlockDeviceMappings[].Ebs.VolumeId`. A multi-attach volume is snapshotted
   once. `DescribeVolumes` reads the volume tags to copy.
3. **Snapshots each volume**, unless a snapshot of it for this policy and UTC
   day already exists. Tags are applied in the same `CreateSnapshot` call
   (`--tag-specifications`), so there is never an untagged snapshot.
4. **Plans retention** in pure `jq` (no AWS calls), per volume, newest first:

   | Snapshot | Decision |
   |---|---|
   | younger than `--retention-days` | keep |
   | `pending` or `error` | keep |
   | one of the newest `--keep-min` **completed** ones (default 1) | keep |
   | carries the protect tag (`DoNotDelete`) | keep |
   | anything else | delete |

5. **Deletes** what the plan says. A snapshot used by an AMI
   (`InvalidSnapshot.InUse`) is reported as `skipped-in-use`; one that someone
   else already deleted is `already-gone`. Neither is a failure.

Snapshots are created **before** anything is pruned, so an interrupted run
never leaves a volume with fewer copies than before.

## Requirements

- bash **3.2** or newer (macOS `/bin/bash` works; CI runs on both)
- AWS CLI **v2**
- jq **1.6** or newer
- Credentials with the policy in [`iam/ebs-snapshot-backup-policy.json`](iam/ebs-snapshot-backup-policy.json)

## Usage

```bash
# Preview: AWS checks every permission (EC2 DryRun), nothing changes
bin/ebs-snapshot-backup --region us-east-1 --dry-run

# Daily run, 30 days, JSON logs, report file
bin/ebs-snapshot-backup --region us-east-1 --log-format json --report run.json

# Every enabled region, wait until the new snapshots are completed
bin/ebs-snapshot-backup --all-regions --wait

# Two schedules side by side: they never prune each other
bin/ebs-snapshot-backup --policy daily   --retention-days 7
bin/ebs-snapshot-backup --policy monthly --retention-days 365 --keep-min 3

# Another selector (several values allowed)
bin/ebs-snapshot-backup --tag Backup=true,True,yes
```

| Option | Default | Meaning |
|---|---|---|
| `-r, --region` | `AWS_REGION` / profile | Region to process (repeatable) |
| `--all-regions` | off | Every region enabled in the account |
| `-t, --tag KEY=VALUES` | `Backup=true` | Instance selector, comma-separated values |
| `-p, --policy` | `default` | Policy name: tagged on snapshots, scopes retention and the lock |
| `-d, --retention-days` | `30` | Delete managed snapshots older than this |
| `--keep-min` | `1` | Always keep the newest N completed snapshots per volume |
| `--protect-tag` | `DoNotDelete` | Snapshots carrying this tag key are never deleted |
| `--max-deletes` | `0` (off) | Abort pruning a region that would delete more than N |
| `--mode` | `all` | `all`, `snapshot` (never deletes) or `prune` (never creates) |
| `-n, --dry-run` | off | EC2 DryRun on every create/delete |
| `--no-copy-tags` | copy | Do not copy volume tags to the snapshot |
| `--wait`, `--wait-timeout` | off, `1800` | Wait for new snapshots; `error` state is a failure |
| `--report FILE` | none | JSON report: run metadata, summary, every result |
| `--lock-file` | `$TMPDIR/ebs-snapshot-backup-<policy>.lock` | Lock directory |
| `--log-format` | `text` | `text` or `json` (one object per line, on stderr) |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Everything succeeded (including `skipped-in-use`, `already-gone`) |
| `1` | Fatal: missing `aws`/`jq`, no credentials, lock held by another run |
| `2` | Usage error: nothing was called |
| `3` | Finished, but something failed: a volume, a delete, a denied permission, a region, or `--max-deletes` |

### Output

```text
2026-10-24T02:15:03Z INFO  run start version=1.0.0 identity=arn:aws:sts::123456789012:assumed-role/ebs-snapshot-backup/i-0abc regions=us-east-1 backup_date=2026-10-24 dry_run=false
2026-10-24T02:15:04Z INFO  volumes to back up region=us-east-1 count=2 selector=Backup=true
2026-10-24T02:15:04Z INFO  volume created region=us-east-1 id=vol-0e1e5ab62cb654f90 snapshot=snap-0b2c... instance=i-0456... device=/dev/sdf
2026-10-24T02:15:05Z INFO  retention region=us-east-1 managed=62 to_delete=2 retention_days=30 keep_min=1
2026-10-24T02:15:05Z INFO  snapshot deleted region=us-east-1 id=snap-07aa... volume=vol-0e1e... age_days=31
2026-10-24T02:15:06Z INFO  run finished summary={"created":2,"deleted":2}
```

## Snapshot tags

| Tag | Example | Why |
|---|---|---|
| `ebs-backup:managed-by` | `ebs-snapshot-backup` | Ownership: the only snapshots retention and IAM let it delete |
| `ebs-backup:policy` | `daily` | Separates schedules with different retention |
| `ebs-backup:volume-id` | `vol-0e1e...` | Groups copies per volume (`VolumeId` is not reliable for copied snapshots) |
| `ebs-backup:instance-id`, `ebs-backup:device` | `i-0456...`, `/dev/sdf` | Restore: where the volume was attached |
| `ebs-backup:backup-date` | `2026-10-24` | Idempotency key (UTC day) |
| `ebs-backup:run-id` | `20261024T021503Z-4242` | Ties a snapshot to a log line |
| `Name` | `web-1 /dev/sdf 2026-10-24` | Readable in the console |
| copied volume tags | `owner`, `CostCenter` | Cost allocation follows the data. `aws:*`, `Name`, the selector tag and the `ebs-backup:` namespace are not copied; at most 50 tags. |

## Security

- **Least privilege, enforced twice.** The script only deletes snapshots with
  its own tag; the IAM policy says the same thing independently:
  - `CreateSnapshot` is only allowed when the request carries
    `ebs-backup:managed-by`, so the role cannot create untagged snapshots.
  - `CreateTags` only while creating a snapshot (`ec2:CreateAction`), so the
    role cannot tag someone else's snapshot as "managed" and then delete it.
  - `DeleteSnapshot` only on snapshots tagged `ebs-backup:managed-by`.
  - An explicit `Deny` on `DeleteSnapshot` for anything tagged `DoNotDelete`.

  The e2e run proves each of these with real API calls (see below).
- **No credentials in the script.** It uses the standard AWS CLI chain:
  instance profile, SSO profile or environment.
- **Bounded network calls**: 5 s connect, 30 s read timeouts, adaptive retry
  with 8 attempts. A dead regional endpoint fails in seconds and the run goes on.
- **Reports and logs contain account and resource IDs**: they are git-ignored.
- Encrypted volumes produce encrypted snapshots with the same key; with a
  customer managed KMS key the role needs that key's grants (not covered here).

## Idempotency and concurrency

- One snapshot per volume, policy and **UTC day**: running twice, or after a
  crash, creates nothing new (`exists`). A snapshot in `error` state is retried.
- Retention is computed from the current state each run, so a missed day is
  caught up on the next one; deletes of already-deleted snapshots are
  `already-gone`.
- A lock directory per policy (`mkdir` is atomic) stops two runs of the same
  policy overlapping; a lock left by a dead process is detected by its PID and
  removed.

## Testing

```bash
bats tests/unit                 # 69 tests, fake `aws` on PATH, no network
pip install 'moto[server]'
bats tests/integration          # 14 tests (11 full tool + 3 basic), real AWS CLI against moto's EC2
shellcheck -x bin/ebs-snapshot-backup && shfmt -d bin tests
```

- **Unit** (`tests/unit`): a fake `aws` records every call and answers from
  fixture files, including API errors (`InvalidSnapshot.InUse`,
  `UnauthorizedOperation`, throttling). Covers argument validation, every
  retention rule (the `jq` plan is tested directly), dry-run, region failures,
  locks, `--wait`, report and log formats. CI runs them on Linux (bash 5) and
  macOS (bash 3.2).
- **Integration** (`tests/integration`): the real AWS CLI against moto, with a
  fake clock (`EBS_BACKUP_NOW`) to move 31 and 32 days ahead. Proves the
  filters, tag specifications and response parsing against real API shapes.
- **Mutation check**: six deliberate bugs (selecting stopped instances,
  ignoring the protect tag, `keep-min` off, treating a snapshot in `error` as
  today's backup, copying `aws:` tags, reporting denials as plain failures) were each caught by the suite.

### End-to-end in a real account

[`e2e/aws`](e2e/aws) deploys three `t4g.nano` instances (backed, unselected,
stopped), a tagged data volume, a manual snapshot and an IAM role with exactly
the policy in `iam/`, then [`run-e2e.sh`](e2e/aws/run-e2e.sh) runs the script
**as that role** and checks the results. The selector tag and policy name carry
a random suffix, so it cannot touch anything else in a shared account.

Run on 2026-10-24 in `us-east-1`: **44/44 checks passed**, including the three
IAM refusals (untagged create, deleting or re-tagging a foreign snapshot) and
the explicit `Deny` stopping a `DoNotDelete` delete even with the script's own
rule bypassed. Everything was destroyed afterwards. Full table:
[`e2e/aws/README.md`](e2e/aws/README.md).

## Deploying

- **cron**: [`examples/cron/ebs-snapshot-backup`](examples/cron/ebs-snapshot-backup)
  (daily 30 days + monthly 365 days).
- **systemd**: [`examples/systemd`](examples/systemd) service + timer
  (`Persistent=true` runs a missed backup after a reboot).
- Install: copy `bin/ebs-snapshot-backup` to `/usr/local/bin/`; it is a single
  file with no dependencies besides `aws` and `jq`.

## Limitations and alternatives

- **Crash-consistent, per volume.** Each volume is snapshotted on its own. For
  a database striped over several volumes, use `CreateSnapshots` with an
  instance specification (all volumes at the same point in time) or quiesce
  the application first. Application-consistent snapshots need VSS / fsfreeze
  hooks, which this script does not do.
- **Same region only.** No cross-region or cross-account copy for disaster
  recovery (that is exercise #42).
- **Retention is age-based.** No grandfather-father-son tiers in one policy;
  use several `--policy` schedules instead.
- **Recycle Bin**: if the account has a Recycle Bin retention rule for EBS
  snapshots, deleted snapshots go there first and keep costing until it expires.
- **Managed alternatives**: Amazon Data Lifecycle Manager (DLM) and AWS Backup
  do this natively, with cross-region copy, fast snapshot restore and
  compliance reporting. This script is for environments where a portable,
  auditable script is wanted, or as a way to understand what those services do.

## Repository layout

```text
bin/ebs-snapshot-backup        the script (single file)
basic/ebs-snapshot-basic.sh    minimal version: only what the task asks
iam/                           least-privilege IAM policy
examples/cron, examples/systemd scheduling
tests/unit                     bats + fake aws
tests/integration              bats + AWS CLI + moto
e2e/aws                        real-account harness (Terraform) + checks
docs/                          architecture diagrams (full + basic), build guide
```

## License

MIT. See [LICENSE](LICENSE).
