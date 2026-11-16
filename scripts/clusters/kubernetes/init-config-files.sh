#!/bin/bash

# pipefail: a failed `aws | jq` lookup must stop the script. Otherwise an empty
# delivery_lb_vpc_origin_id is written over a good DELIVERY_LB_VPC_ORIGIN_ID.
set -eo pipefail

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
delivery_lb_vpc_origin_id=$(echo "$resources_stack" | jq -r 'first(.Outputs[]? | select(.OutputKey=="DeliveryLBVpcOriginId") | .OutputValue) // ""')
if [ -z "$delivery_lb_vpc_origin_id" ] || [ "$delivery_lb_vpc_origin_id" = "null" ]; then
  delivery_lb_vpc_origin_id="${DELIVERY_LB_VPC_ORIGIN_ID:-}"
fi

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
authoring_deployment="gitops/apps/main/craftercms/authoring-deployment.yaml"
if [ ! -f "$authoring_deployment" ]; then
  cecho "Authoring deployment not found at ${KUBER_CONFIG_HOME}/${authoring_deployment}" "error"
  exit 1
fi
sed -i "/name: DELIVERY_LB_VPC_ORIGIN_ID/{n;s~value: .*~value: \"${delivery_lb_vpc_origin_id}\"~}" "$authoring_deployment"

delivery_ingress="gitops/apps/main/craftercms/delivery-deployment.yaml"
if [ "${DELIVERY_LB_SCHEME:-internet-facing}" = "internal" ]; then
  if [ ! -f "$delivery_ingress" ]; then
    cecho "Delivery ingress not found at ${KUBER_CONFIG_HOME}/${delivery_ingress}" "error"
    exit 1
  fi
  if grep -q '{{delivery_lb_subnets_annotation}}' "$delivery_ingress"; then
    eks_stack=$(aws cloudformation describe-stacks --stack-name "eksctl-${CLUSTER_NAME}-cluster" | jq '.Stacks[0]')
    private_subnet_ids=$(echo "$eks_stack" | jq -r '.Outputs[] | select(.OutputKey=="SubnetsPrivate").OutputValue')
    if [ -z "$private_subnet_ids" ] || [ "$private_subnet_ids" = "null" ]; then
      cecho "EKS stack eksctl-${CLUSTER_NAME}-cluster has no private subnet output" "error"
      exit 1
    fi
    subnet_json=$(aws ec2 describe-subnets --subnet-ids ${private_subnet_ids//,/ } --output json)
    skipped_subnets=$(echo "$subnet_json" | jq -r --argjson bad '["use1-az3","usw1-az2","apne1-az3","cac1-az3"]' '
      [.Subnets[] | select(.AvailabilityZoneId as $az | $bad | index($az)) | "\(.SubnetId) (\(.AvailabilityZoneId))"] | join(", ")
    ')
    delivery_lb_subnet_ids=$(echo "$subnet_json" | jq -r --argjson bad '["use1-az3","usw1-az2","apne1-az3","cac1-az3"]' '
      [.Subnets[] | select(.AvailabilityZoneId as $az | ($bad | index($az)) | not) | .SubnetId] | join(",")
    ')
    if [ -n "$skipped_subnets" ]; then
      cecho "Skipping Delivery subnets in availability zones that do not support CloudFront VPC origins: ${skipped_subnets}" "warning"
    fi
    subnet_count=0
    if [ -n "$delivery_lb_subnet_ids" ]; then
      subnet_count=$(echo "$delivery_lb_subnet_ids" | awk -F, '{print NF}')
    fi
    if [ "$subnet_count" -lt 2 ]; then
      cecho "Internal Delivery needs at least two private subnets in supported availability zones" "error"
      exit 1
    fi
    sed -i "s~{{delivery_lb_subnets_annotation}}~    alb.ingress.kubernetes.io/subnets: ${delivery_lb_subnet_ids}~" "$delivery_ingress"
  elif ! grep -q 'alb.ingress.kubernetes.io/subnets:' "$delivery_ingress"; then
    cecho "Internal Delivery ingress is missing its subnet annotation" "error"
    exit 1
  fi
else
  find . -type f ! -name init-config.sh ! -name '*-target-template.yaml' -exec sed -i "/{{delivery_lb_subnets_annotation}}/d" {} \;
fi

cd $CURRENT_DIR