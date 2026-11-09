#!/usr/bin/env bash
# Deploy the weekly reports hub ONCE to the central ops/infra account (us-east-1).
# Do not run this against a client AWS account.
# Keep expected-producers.json outside this public repo (private clients/config).
set -euo pipefail

PRGDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$PRGDIR/../.." && pwd)

HUB_ACCOUNT_ID="${HUB_ACCOUNT_ID:-${EXPECTED_ACCOUNT:-}}"
export AWS_PROFILE="${AWS_PROFILE:-crafter-cloud-infra}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-crafter-ops-weekly-reports-hub}"
BUCKET_NAME="${BUCKET_NAME:-crafter-ops-weekly-reports}"
CODE_BUCKET="${CODE_BUCKET:-cloud-management-tools}"
CODE_KEY="${CODE_KEY:-ops/weekly-reports-hub/aggregator.zip}"
DIGEST_FROM="${DIGEST_FROM:-noreply@craftercloud.io}"
DIGEST_TO="${DIGEST_TO:-cloud-ops@craftercms.com}"
TEMPLATE="$REPO_ROOT/templates/ops/weekly-reports-hub.yaml"
AGGREGATOR_SRC="$REPO_ROOT/templates/ops/aggregator/index.py"
# Path to expected-producers.json (private inventory). Required; not shipped in this repo.
EXPECTED_SRC="${EXPECTED_SRC:-}"

cecho() {
  local color="0m"
  case "${2:-}" in
    info) color="96m" ;;
    success) color="92m" ;;
    warning) color="93m" ;;
    error) color="91m" ;;
  esac
  printf "\e[%s%b\e[0m\n" "$color" "$1"
}

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

if [[ -z "$HUB_ACCOUNT_ID" ]]; then
  cecho "Abort: set HUB_ACCOUNT_ID to the hub AWS account id (no default in this public repo)" "error"
  exit 1
fi
if [[ -z "$EXPECTED_SRC" || ! -f "$EXPECTED_SRC" ]]; then
  cecho "Abort: set EXPECTED_SRC to a readable expected-producers.json path outside this public repo" "error"
  exit 1
fi

identity=$(aws sts get-caller-identity --output json)
account=$(echo "$identity" | jq -r '.Account')
if [[ "$account" != "$HUB_ACCOUNT_ID" ]]; then
  cecho "Abort: STS Account ${account} is not hub account ${HUB_ACCOUNT_ID}" "error"
  exit 1
fi

cecho "Packaging aggregator Lambda..." "info"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$AGGREGATOR_SRC" "$work/index.py"
(
  cd "$work"
  zip -q aggregator.zip index.py
)
aws s3 cp "$work/aggregator.zip" "s3://${CODE_BUCKET}/${CODE_KEY}" --sse AES256

publish_aggregator_code() {
  set +e
  get_err=$(aws lambda get-function \
    --function-name crafter-ops-weekly-reports-aggregator 2>&1 >/dev/null)
  get_rc=$?
  set -e
  if [[ "$get_rc" -ne 0 ]]; then
    if [[ "$get_err" == *ResourceNotFoundException* ]]; then
      return 0
    fi
    cecho "Failed to check aggregator Lambda: ${get_err}" "error"
    exit 1
  fi
  cecho "Publishing aggregator Lambda code..." "info"
  aws lambda update-function-code \
    --function-name crafter-ops-weekly-reports-aggregator \
    --s3-bucket "${CODE_BUCKET}" \
    --s3-key "${CODE_KEY}" >/dev/null
  aws lambda wait function-updated-v2 --function-name crafter-ops-weekly-reports-aggregator
}

params=(
  "ParameterKey=ReportsBucketName,ParameterValue=${BUCKET_NAME}"
  "ParameterKey=DigestFromAddress,ParameterValue=${DIGEST_FROM}"
  "ParameterKey=DigestToAddress,ParameterValue=${DIGEST_TO}"
  "ParameterKey=AggregatorCodeBucket,ParameterValue=${CODE_BUCKET}"
  "ParameterKey=AggregatorCodeKey,ParameterValue=${CODE_KEY}"
)
# Optional comma-separated account IDs for the hub bucket write policy (private).
if [[ -n "${CLIENT_REPORTER_ACCOUNT_IDS:-}" ]]; then
  params+=("ParameterKey=ClientReporterAccountIds,ParameterValue=${CLIENT_REPORTER_ACCOUNT_IDS}")
fi

if aws cloudformation describe-stacks --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  cecho "Updating stack ${STACK_NAME}..." "info"
  set +e
  update_out=$(aws cloudformation update-stack \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --template-body "file://${TEMPLATE}" \
    --parameters "${params[@]}" 2>&1)
  update_rc=$?
  set -e
  if [[ "$update_rc" -eq 0 ]]; then
    aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME"
  elif grep -q 'No updates are to be performed' <<<"$update_out"; then
    cecho "No stack updates. Continuing to upload expected-producers.json." "info"
  else
    cecho "$update_out" "error"
    exit "$update_rc"
  fi
else
  cecho "Creating stack ${STACK_NAME}..." "info"
  aws cloudformation create-stack \
    --stack-name "$STACK_NAME" \
    --capabilities CAPABILITY_NAMED_IAM \
    --template-body "file://${TEMPLATE}" \
    --parameters "${params[@]}"
  aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME"
fi

publish_aggregator_code

cecho "Uploading expected-producers.json..." "info"
aws s3 cp "$EXPECTED_SRC" "s3://${BUCKET_NAME}/config/expected-producers.json" \
  --sse AES256 --content-type application/json

cecho "Hub stack ${STACK_NAME} is ready. Digest email is SES HTML (report-YYYY-MM-DD) to ${DIGEST_TO}." "success"
cecho "Presign credentials live in Secrets Manager secret crafter-ops-weekly-reports/presigner." "info"
