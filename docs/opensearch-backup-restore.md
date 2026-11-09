# OpenSearch backup and restore

Manual S3 snapshots before an OpenSearch engine upgrade. Run the snapshot API
from the cluster **bastion** (VPC-only endpoint). Do not run backup or restore
from a laptop.

CMS domains use `AccessPolicies Principal "*"` and no FGAC. Unsigned `curl`
from the bastion is enough (verified on client-a prod). This is **not**
the CrafterQ FGAC / `awscurl` path.

AWS: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-snapshots.html

Script: `scripts/clusters/opensearch-backup-restore.sh`

Bucket and IAM role are created in the **account** stack
`crafter-account-resources` (`templates/account/aws-infra/resources.yaml`):

- Bucket: `{CLIENT_ID}-crafter-opensearch-manual-snapshots`
- Role: `{CLIENT_ID}-crafter-opensearch-snapshot` (trusted by `es.amazonaws.com`)

`backup` always writes to the OpenSearch repository `manual-snapshots` on that
bucket. `restore` / `list` default to the same repo, and can also use AWS
automated snapshots with `--repo cs-automated-enc`.

The S3 bucket must be in the same AWS region as the OpenSearch domain
(account stack region).

## Account stack (once per AWS account)

New accounts: set `CLIENT_ID` in `scripts/account/config.sh` and run
`scripts/account/setup.sh`. That create-stack path now passes `ClientId`.

Existing `crafter-account-resources` stacks need a **change-set** (preview,
do not execute until approved). Pass `ClientId` and `UsePreviousValue` for
every other parameter. Capabilities: `CAPABILITY_NAMED_IAM`. Expected: **Add**
the bucket and role only. No `Remove`, no `Replace` of existing resources.

After the stack is live, delete any old hand-made snapshot bucket and
`OSsnapshotrole` left from earlier manual setup. Empty the old bucket first.
Unregister old OpenSearch repos (`crafter-manual-snapshots`, `os-backup-bucket`)
on each domain after `register-repo` succeeds. Do not delete those until the
new bucket and role are in use.

## Bastion workflow

The script is not installed by CloudFormation. Bastion UserData runs only on
instance launch. A stack update does not write this file and does not run
`cfn-init`. Copy it onto the bastion each time you need a current copy.

1. SSH to the cluster bastion (EC2 Instance Connect Endpoint). Root SSH is
   disabled. Use a bastion user and `sudo`.

2. Copy `scripts/clusters/opensearch-backup-restore.sh` from this repo to
   `/opt/crafter/scripts/opensearch-backup-restore.sh` on the bastion:

```bash
sudo mkdir -p /opt/crafter/scripts
sudo tee /opt/crafter/scripts/opensearch-backup-restore.sh >/dev/null
sudo chmod 0755 /opt/crafter/scripts/opensearch-backup-restore.sh
```

Paste the script contents into `tee`, or upload the file over the SSH
session. Then run backup and restore on the bastion only.

3. On the bastion, export the OpenSearch endpoint. For a first-time
   `register-repo`, also export the account stack outputs
   `OpenSearchManualSnapshotBucket` and `OpenSearchManualSnapshotRoleArn`,
   plus `CLUSTER_NAME` and `AWS_REGION`.

```bash
export OPENSEARCH_ENDPOINT=https://vpc-....es.amazonaws.com
export SNAPSHOT_BUCKET=client-a-crafter-opensearch-manual-snapshots
export SNAPSHOT_ROLE_ARN=arn:aws:iam::111122223333:role/client-a-crafter-opensearch-snapshot
export CLUSTER_NAME=crafter-prod-v2
export AWS_REGION=us-east-1
```

4. First time on a domain, register the account bucket (idempotent):

```bash
/opt/crafter/scripts/opensearch-backup-restore.sh register-repo
```

That PUTs repository `manual-snapshots` with `base_path` = `CLUSTER_NAME` so
dev / qa / prod share one account bucket.

5. Backup:

```bash
/opt/crafter/scripts/opensearch-backup-restore.sh backup
/opt/crafter/scripts/opensearch-backup-restore.sh list
```

`backup` waits until `SUCCESS`. `FAILED` and `PARTIAL` fail the script.
Do not backup to `cs-automated-enc`.

List or restore AWS automated snapshots:

```bash
/opt/crafter/scripts/opensearch-backup-restore.sh list --repo cs-automated-enc
/opt/crafter/scripts/opensearch-backup-restore.sh restore SNAPSHOT_NAME --repo cs-automated-enc \
  --rename-pattern '(.+)' --rename-replacement 'restored-$1' --wait
```

## Restore (only if the upgrade fails)

Prefer a copy first:

```bash
/opt/crafter/scripts/opensearch-backup-restore.sh restore pre-upgrade-20260819 \
  --rename-pattern '(.+)' \
  --rename-replacement 'restored-$1' \
  --wait
```

Same-name restore is destructive and needs `--yes`. Rename restore sets
`include_aliases: false` so original aliases are not moved onto the copy.

## Test (pre-cutover record)

Example bastion dry-run before the account-stack bucket existed. Only
`classtest_v1` (empty, ~2 KB). No restore onto existing names. The script
selected the legacy repository `crafter-manual-snapshots` (S3
`os-test-backup-bucket`). That default is gone. Do not rerun these commands
as a current procedure. Current backup uses `manual-snapshots`.

```bash
export OPENSEARCH_ENDPOINT=https://vpc-crafter-prod-v2-opensearch-....es.amazonaws.com
export REPO_NAME=crafter-manual-snapshots
/opt/crafter/scripts/opensearch-backup-restore.sh backup pre-cutover-classtest --indices classtest_v1 --wait
/opt/crafter/scripts/opensearch-backup-restore.sh restore pre-cutover-classtest \
  --indices classtest_v1 \
  --rename-pattern 'classtest_v1' \
  --rename-replacement 'test-restore' \
  --wait
```

Snapshot `pre-cutover-classtest` is `SUCCESS` (5/5 shards). Restore created
`test-restore` (green, 0 docs, 2kb). Original `classtest_v1` stayed green.
Cluster stayed green, 0 relocating / unassigned.
