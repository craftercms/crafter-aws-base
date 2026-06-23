#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

KUBER_CONFIG_HOME="$CLUSTER_HOME/kubernetes"
CURRENT_DIR=$(pwd)

resources_stack=$(aws cloudformation describe-stacks --stack-name ${CLUSTER_NAME}-resources | jq '.Stacks[0]')
opensearch_host=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="OpenSearchDomainEndpoint").OutputValue')
opensearch_url="https://$opensearch_host"
authoring_web_acl_arn=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="AuthoringWebACLArn").OutputValue')
authoring_ng_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="AuthoringNodeGroupSecurityGroup").OutputValue')
authoring_frontend_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="AuthoringFrontendSecurityGroup").OutputValue')
authoring_backend_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="AuthoringBackendSecurityGroup").OutputValue')
delivery_ng_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DeliveryNodeGroupSecurityGroup").OutputValue')
delivery_frontend_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DeliveryFrontendSecurityGroup").OutputValue')
delivery_backend_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DeliveryBackendSecurityGroup").OutputValue')

upgrade_reports_stack_name="${CLUSTER_NAME}-upgrade-reports"
upgrade_reports_describe_err=$(mktemp)
if upgrade_reports_describe_output=$(aws cloudformation describe-stacks --region "$AWS_DEFAULT_REGION" --stack-name "$upgrade_reports_stack_name" 2>"$upgrade_reports_describe_err"); then
  upgrade_reports_stack=$(echo "$upgrade_reports_describe_output" | jq '.Stacks[0]')
  nodegroup_upgrade_sns_topic_arn=$(echo "$upgrade_reports_stack" | jq -r '.Outputs[] | select(.OutputKey=="UpgradeReportSNSTopicArn").OutputValue')
elif grep -q 'does not exist' "$upgrade_reports_describe_err"; then
  nodegroup_upgrade_sns_topic_arn=""
else
  cecho "Failed to look up upgrade-reports stack ${upgrade_reports_stack_name}: $(cat "$upgrade_reports_describe_err")" "error"
  rm -f "$upgrade_reports_describe_err"
  exit 1
fi
rm -f "$upgrade_reports_describe_err"

cd $KUBER_CONFIG_HOME

cecho "Initializing Kubernetes config files for cluster $CLUSTER_NAME..." "info"

find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{opensearch_url}}~$opensearch_url~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{authoring_web_acl_arn}}~$authoring_web_acl_arn~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s/{{authoring_frontend_sg}}/${authoring_frontend_sg}/g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{authoring_backend_sg}}~${authoring_backend_sg}~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{authoring_ng_sg}}~$authoring_ng_sg~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s/{{delivery_ng_sg}}/${delivery_ng_sg}/g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{delivery_frontend_sg}}~${delivery_frontend_sg}~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{delivery_backend_sg}}~$delivery_backend_sg~g" {} \;
find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "s~{{nodegroup_upgrade_sns_topic_arn}}~${nodegroup_upgrade_sns_topic_arn}~g" {} \;

cd $CURRENT_DIR