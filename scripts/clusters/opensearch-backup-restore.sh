#!/bin/bash
# Manual OpenSearch snapshot backup/restore. Run from the cluster bastion
# (VPC access). CMS domains use AccessPolicies Principal "*" with no FGAC,
# so unsigned curl from the bastion is enough.
# Do not use this pattern on FGAC domains (CrafterQ).
#
# Bucket and IAM role come from the account stack crafter-account-resources
# (templates/account/aws-infra/resources.yaml): {CLIENT_ID}-crafter-opensearch-manual-snapshots
# and {CLIENT_ID}-crafter-opensearch-snapshot.

set -euo pipefail

WAIT_TIMEOUT_SECONDS=21600
POLL_SECONDS=15
MANUAL_REPO_NAME=manual-snapshots

usage() {
    cat <<'EOF'
Usage:
  ./opensearch-backup-restore.sh <command> [snapshot-name] [options]

Run this script on the cluster bastion (curl to the VPC endpoint).
Copy it to /opt/crafter/scripts/opensearch-backup-restore.sh.
CloudFormation does not install it. Do not run backup or restore from a laptop.

Commands:
  register-repo          PUT the manual-snapshots S3 repository (first time)
  backup [name]          Snapshot to manual-snapshots (default: pre-upgrade-YYYYMMDD-HHMMSS)
  list                   List snapshots in the selected repository
  restore <name>         Restore (destructive unless --rename-*)

Options:
  --repo <name>          Snapshot repository (default: manual-snapshots).
                         restore/list may also use cs-automated-enc.
                         backup always uses manual-snapshots.
  --wait                 Poll until backup/restore finishes (backup waits by default)
  --no-wait              Return as soon as the snapshot/restore is accepted
  --indices <list>       Comma-separated indices (default: *)
  --rename-pattern <re>  Restore indices under new names (use with --rename-replacement)
  --rename-replacement <s>
  --yes                  Required for restore onto existing index names
  -h, --help

Environment (export on the bastion):
  OPENSEARCH_ENDPOINT    Required
  REPO_NAME              Optional. Same as --repo
  SNAPSHOT_BUCKET / SNAPSHOT_ROLE_ARN / CLUSTER_NAME / AWS_REGION
                         Required for register-repo
EOF
}

cecho() {
    local msg=$1
    local level=${2:-info}
    local color=0
    case "$level" in
        info) color=96 ;;
        success) color=92 ;;
        warning) color=93 ;;
        error) color=91 ;;
    esac
    printf '\e[%sm%b\e[0m\n' "$color" "$msg"
}

die() {
    cecho "$*" error
    exit 1
}

COMMAND=
SNAPSHOT_NAME_ARG=
WAIT_MODE=default
INDICES='*'
RENAME_PATTERN=
RENAME_REPLACEMENT=
CONFIRM_RESTORE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --repo)
            REPO_NAME=${2:?--repo requires a value}
            shift 2
            ;;
        --wait)
            WAIT_MODE=on
            shift
            ;;
        --no-wait)
            WAIT_MODE=off
            shift
            ;;
        --indices)
            INDICES=${2:?--indices requires a value}
            shift 2
            ;;
        --rename-pattern)
            RENAME_PATTERN=${2:?--rename-pattern requires a value}
            shift 2
            ;;
        --rename-replacement)
            RENAME_REPLACEMENT=${2:?--rename-replacement requires a value}
            shift 2
            ;;
        --yes)
            CONFIRM_RESTORE=true
            shift
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            elif [[ -z "$SNAPSHOT_NAME_ARG" ]]; then
                SNAPSHOT_NAME_ARG=$1
            else
                die "Unexpected argument: $1"
            fi
            shift
            ;;
    esac
done

[[ -n "$COMMAND" ]] || { usage; exit 1; }

should_wait() {
    local default_mode=$1
    case "$WAIT_MODE" in
        on) return 0 ;;
        off) return 1 ;;
        *) [[ "$default_mode" == on ]] ;;
    esac
}

json_get() {
    python3 -c 'import json,sys
data=json.load(sys.stdin)
for key in sys.argv[1].split("."):
    if key.isdigit():
        data=data[int(key)]
    else:
        data=data[key]
if isinstance(data,(dict,list)):
    json.dump(data,sys.stdout,indent=2)
    print()
else:
    print(data)
' "$1"
}

normalize_endpoint() {
    [[ -n "${OPENSEARCH_ENDPOINT:-}" ]] || return 0
    OPENSEARCH_ENDPOINT="https://${OPENSEARCH_ENDPOINT#https://}"
    OPENSEARCH_ENDPOINT=${OPENSEARCH_ENDPOINT%/}
}

require_endpoint() {
    normalize_endpoint
    [[ -n "${OPENSEARCH_ENDPOINT:-}" ]] || die "OPENSEARCH_ENDPOINT is required. Export it on the bastion."
}

os_curl() {
    local method=$1
    local path=$2
    local body=${3:-}
    command -v curl >/dev/null 2>&1 || die "curl is required on the bastion."
    local url="${OPENSEARCH_ENDPOINT}${path}"
    local tmp code
    tmp=$(mktemp)
    if [[ -n "$body" ]]; then
        code=$(curl -sS -m 60 -o "$tmp" -w '%{http_code}' -X "$method" \
            -H 'Content-Type: application/json' -d "$body" "$url")
    else
        code=$(curl -sS -m 60 -o "$tmp" -w '%{http_code}' -X "$method" "$url")
    fi
    cat "$tmp"
    echo
    rm -f "$tmp"
    [[ "$code" =~ ^2 ]] || die "OpenSearch ${method} ${path} HTTP ${code}."
}

use_manual_repo() {
    if [[ -n "${REPO_NAME:-}" && "$REPO_NAME" != "$MANUAL_REPO_NAME" ]]; then
        die "backup and register-repo use ${MANUAL_REPO_NAME} only. Use --repo only with restore or list."
    fi
    REPO_NAME=$MANUAL_REPO_NAME
}

resolve_repo() {
    require_endpoint
    REPO_NAME=${REPO_NAME:-$MANUAL_REPO_NAME}
    cecho "Using snapshot repository ${REPO_NAME}" info
}

cmd_register_repo() {
    require_endpoint
    use_manual_repo
    [[ -n "${SNAPSHOT_BUCKET:-}" ]] || die "SNAPSHOT_BUCKET is required. Export it on the bastion after the account stack has the snapshot bucket."
    [[ -n "${SNAPSHOT_ROLE_ARN:-}" ]] || die "SNAPSHOT_ROLE_ARN is required. Export it on the bastion after the account stack has the snapshot role."
    [[ -n "${AWS_REGION:-${AWS_DEFAULT_REGION:-}}" ]] || die "AWS_REGION is required to register the repository."
    [[ -n "${CLUSTER_NAME:-}" ]] || die "CLUSTER_NAME is required (S3 base_path so clusters share one account bucket)."
    AWS_REGION=${AWS_REGION:-$AWS_DEFAULT_REGION}
    local body
    body=$(python3 -c 'import json,sys
print(json.dumps({
  "type": "s3",
  "settings": {
    "bucket": sys.argv[1],
    "region": sys.argv[2],
    "role_arn": sys.argv[3],
    "base_path": sys.argv[4],
  },
}))' "$SNAPSHOT_BUCKET" "$AWS_REGION" "$SNAPSHOT_ROLE_ARN" "$CLUSTER_NAME")
    os_curl PUT "/_snapshot/${REPO_NAME}" "$body"
    os_curl GET '/_snapshot?pretty'
}

default_snapshot_name() {
    echo "pre-upgrade-$(date -u +%Y%m%d-%H%M%S)"
}

wait_for_snapshot() {
    local name=$1
    local started payload state
    started=$(date +%s)
    while true; do
        payload=$(os_curl GET "/_snapshot/${REPO_NAME}/${name}")
        state=$(printf '%s' "$payload" | json_get snapshots.0.state)
        cecho "Snapshot ${name}: ${state}" info
        case "$state" in
            SUCCESS) return 0 ;;
            FAILED | PARTIAL)
                printf '%s\n' "$payload"
                die "Snapshot ${name} ended as ${state}."
                ;;
        esac
        if (( $(date +%s) - started >= WAIT_TIMEOUT_SECONDS )); then
            die "Timed out waiting for snapshot ${name}."
        fi
        sleep "$POLL_SECONDS"
    done
}

cmd_backup() {
    use_manual_repo
    resolve_repo
    local name=${SNAPSHOT_NAME_ARG:-${SNAPSHOT_NAME:-$(default_snapshot_name)}}
    local body
    body=$(printf '{"indices":"%s","ignore_unavailable":true,"include_global_state":true}' "$INDICES")
    os_curl PUT "/_snapshot/${REPO_NAME}/${name}" "$body"
    cecho "Snapshot ${name} started in ${REPO_NAME}." success
    if should_wait on; then
        wait_for_snapshot "$name"
    fi
}

cmd_list() {
    resolve_repo
    os_curl GET "/_snapshot/${REPO_NAME}/_all?pretty"
}

wait_for_restore() {
    local started seen=false hidden=0 recovery count
    started=$(date +%s)
    while true; do
        recovery=$(os_curl GET '/_cat/recovery?format=json&active_only=true')
        count=$(printf '%s' "$recovery" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
        if [[ "$count" != 0 ]]; then
            seen=true
            hidden=0
            cecho "Restore in progress: ${count} active shard recoveries." info
        elif [[ "$seen" == true ]]; then
            cecho "Restore recoveries finished. Check _cluster/health." success
            os_curl GET '/_cluster/health?pretty'
            return 0
        else
            hidden=$((hidden + 1))
            if (( hidden >= 3 )); then
                cecho "No active recoveries observed. Checking cluster health; confirm indices manually." warning
                os_curl GET '/_cluster/health?pretty'
                return 0
            fi
            cecho "Waiting for restore recoveries to appear..." info
        fi
        if (( $(date +%s) - started >= WAIT_TIMEOUT_SECONDS )); then
            die "Timed out waiting for restore."
        fi
        sleep "$POLL_SECONDS"
    done
}

restore_target_names() {
    python3 -c 'import json,re,sys
snap=json.load(sys.stdin)
indices=snap["snapshots"][0].get("indices") or []
want=sys.argv[1]
pat=sys.argv[2]
repl=sys.argv[3]
if want != "*":
    wanted=set(want.split(","))
    indices=[i for i in indices if i in wanted]
if pat:
    indices=[re.sub(pat, repl, i, count=1) for i in indices]
for name in indices:
    print(name)
' "$INDICES" "$RENAME_PATTERN" "$RENAME_REPLACEMENT"
}

index_exists() {
    local name=$1
    local code
    code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "${OPENSEARCH_ENDPOINT}/${name}")
    [[ "$code" == 200 ]]
}

cmd_restore() {
    resolve_repo
    [[ -n "$SNAPSHOT_NAME_ARG" ]] || die "restore requires a snapshot name."
    if [[ -n "$RENAME_PATTERN" || -n "$RENAME_REPLACEMENT" ]]; then
        [[ -n "$RENAME_PATTERN" && -n "$RENAME_REPLACEMENT" ]] \
            || die "Use --rename-pattern and --rename-replacement together."
    elif [[ "$CONFIRM_RESTORE" != true ]]; then
        die "Restore onto existing names is destructive. Re-run with --yes, or restore as a copy with --rename-pattern '(.+)' --rename-replacement 'restored-\$1'."
    fi
    local snap_json target existing_targets
    snap_json=$(os_curl GET "/_snapshot/${REPO_NAME}/${SNAPSHOT_NAME_ARG}")
    existing_targets=()
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        if index_exists "$target"; then
            existing_targets+=("$target")
        fi
    done < <(printf '%s' "$snap_json" | restore_target_names)
    if [[ ${#existing_targets[@]} -gt 0 && "$CONFIRM_RESTORE" != true ]]; then
        die "Restore would replace existing index(es): ${existing_targets[*]}. Re-run with --yes."
    fi
    local body
    body=$(python3 -c 'import json,sys
payload={
  "indices": sys.argv[1],
  "ignore_unavailable": True,
  "include_global_state": False,
}
if sys.argv[2]:
    payload["rename_pattern"]=sys.argv[2]
    payload["rename_replacement"]=sys.argv[3]
    payload["include_aliases"]=False
print(json.dumps(payload))
' "$INDICES" "$RENAME_PATTERN" "$RENAME_REPLACEMENT")
    os_curl POST "/_snapshot/${REPO_NAME}/${SNAPSHOT_NAME_ARG}/_restore" "$body"
    cecho "Restore of ${SNAPSHOT_NAME_ARG} started from ${REPO_NAME}." success
    if should_wait off; then
        wait_for_restore
    fi
}

case "$COMMAND" in
    register-repo | backup | list | restore)
        require_endpoint
        "cmd_${COMMAND//-/_}"
        ;;
    *)
        die "Unknown command: $COMMAND. Use register-repo, backup, list, or restore on the bastion."
        ;;
esac
