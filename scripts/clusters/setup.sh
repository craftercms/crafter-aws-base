#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/set-config.sh"

CURRENT_DIR=$(pwd)

function create_cidr_list() {
  IFS=','
  read -ra strarr <<< "$CLUSTER_PUBLIC_ACCESS_CIDRS"
  printf -v cluster_public_access_cidr_list '"%s",' "${strarr[@]}"
  cluster_public_access_cidr_list="[${cluster_public_access_cidr_list%,}]"
  echo $cluster_public_access_cidr_list | sed 's/ /,/g'
}
cluster_public_access_cidr_list=$(create_cidr_list)

if [ ! -d "$CLUSTER_HOME" ]; then
  echo "Creating cluster folder $CLUSTER_HOME and copying templates"

  mkdir -p $CLUSTER_HOME
  cp -rp $TEMPLATES_HOME/* $CLUSTER_HOME
else
  echo "Cluster folder $CLUSTER_HOME already exists"
fi

cd $CLUSTER_HOME

acct_resources_stack=$(aws cloudformation describe-stacks --region $ACCOUNT_RESOURCES_REGION --stack-name crafter-account-resources | jq '.Stacks[0]')
default_delivery_cloudfront_caching_policy_id=$(echo $acct_resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DefaultDeliveryCloudFrontCachingPolicy").OutputValue')
default_delivery_cloudfront_origin_request_policy_id=$(echo $acct_resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DefaultDeliveryCloudFrontOriginRequestPolicy").OutputValue')
env_resources_stack=$(aws cloudformation describe-stacks --region $ENVIRONMENT_RESOURCES_REGION --stack-name crafter-$ENVIRONMENT-resources | jq '.Stacks[0]')
cloudfront_oai_id=$(echo $env_resources_stack | jq -r '.Outputs[] | select(.OutputKey=="CloudFrontOriginAccessIdentityId").OutputValue')
s3_replication_role_arn=$(echo $env_resources_stack | jq -r '.Outputs[] | select(.OutputKey=="S3ReplicationRoleArn").OutputValue')

find . -type f ! -name setup.sh -exec sed -i "s/{{client_id}}/$CLIENT_ID/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{eks_version}}/$EKS_VERSION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_account_id}}/$AWS_ACCOUNT_ID/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_region}}/$AWS_DEFAULT_REGION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_az_1}}/$AWS_AZ_1/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_az_2}}/$AWS_AZ_2/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_az_3}}/$AWS_AZ_3/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{aws_backup_region}}/$AWS_BACKUP_REGION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_worker_instance_type}}/$AUTHORING_WORKER_INSTANCE_TYPE/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_worker_instance_type}}/$DELIVERY_WORKER_INSTANCE_TYPE/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_instance_count}}/$DELIVERY_INSTANCE_COUNT/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{enable_blobs_buckets_creation}}/$ENABLE_BLOBS_BUCKETS_CREATION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{enable_backup_buckets_creation}}/$ENABLE_BACKUP_BUCKETS_CREATION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{enable_s3_origin_failover}}/$ENABLE_S3_ORIGIN_FAILOVER/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{disable_bucket_clear_on_target_deletion}}/$DISABLE_BUCKET_CLEAR_ON_TARGET_DELETION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{disable_cloudformation_deletion_on_target_deletion}}/$DISABLE_CLOUDFORMATION_DELETION_ON_TARGET_DELETION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s~{{vpc_cidr}}~$VPC_CIDR~g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{nat_gateway_mode}}/$NAT_GATEWAY_MODE/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s~{{cluster_public_access_cidrs}}~$cluster_public_access_cidr_list~g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{cluster_name}}/$CLUSTER_NAME/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{site_cloudformation_stack_name_prefix}}/$SITE_CLOUDFORMATION_STACK_NAME_PREFIX/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{s3_bucket_name_base_prefix}}/$S3_BUCKET_NAME_BASE_PREFIX/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{s3_current_region_bucket_name_prefix}}/$S3_CURRENT_REGION_BUCKET_NAME_PREFIX/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{s3_backup_region_bucket_name_prefix}}/$S3_BACKUP_REGION_BUCKET_NAME_PREFIX/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{cloudfront_logging_s3_bucket_name}}/$CLOUDFRONT_LOGGING_S3_BUCKET_NAME/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{cloudfront_oai_id}}/$cloudfront_oai_id/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{es_auto_snapshot_start_hour_utc}}/$ES_AUTO_SNAPSHOT_START_HOUR_UTC/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{kuber_volume_daily_backup_time_utc}}/$KUBER_VOLUME_DAILY_BACKUP_TIME_UTC/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{environment}}/$ENVIRONMENT/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{environment_version}}/$ENVIRONMENT_VERSION/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s~{{s3_replication_role_arn}}~$s3_replication_role_arn~g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{default_delivery_cloudfront_caching_policy_id}}/$default_delivery_cloudfront_caching_policy_id/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{default_delivery_cloudfront_origin_request_policy_id}}/$default_delivery_cloudfront_origin_request_policy_id/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{default_static_assets_cloudfront_response_headers_policy_id}}/$default_static_assets_cloudfront_response_headers_policy_id/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_tomcat_container_min_cpu}}/$DELIVERY_TOMCAT_CONTAINER_MIN_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_tomcat_container_max_cpu}}/$DELIVERY_TOMCAT_CONTAINER_MAX_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_tomcat_container_min_memory}}/$DELIVERY_TOMCAT_CONTAINER_MIN_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{delivery_tomcat_container_max_memory}}/$DELIVERY_TOMCAT_CONTAINER_MAX_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_tomcat_container_min_cpu}}/$AUTHORING_TOMCAT_CONTAINER_MIN_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_tomcat_container_max_cpu}}/$AUTHORING_TOMCAT_CONTAINER_MAX_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_tomcat_container_min_memory}}/$AUTHORING_TOMCAT_CONTAINER_MIN_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_tomcat_container_max_memory}}/$AUTHORING_TOMCAT_CONTAINER_MAX_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_deployer_container_min_cpu}}/$AUTHORING_DEPLOYER_CONTAINER_MIN_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_deployer_container_max_cpu}}/$AUTHORING_DEPLOYER_CONTAINER_MAX_CPU/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_deployer_container_min_memory}}/$AUTHORING_DEPLOYER_CONTAINER_MIN_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{authoring_deployer_container_max_memory}}/$AUTHORING_DEPLOYER_CONTAINER_MAX_MEMORY/g" {} \;
find . -type f ! -name setup.sh -exec sed -i "s/{{deployer_notification_email_addresses}}/$DEPLOYER_NOTIFICATION_EMAIL_ADDRESSES/g" {} \;

cd $SCRIPTS_HOME

read -p "> Cluster config files initialized. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./aws-infra/eks/create-cluster.sh

read -p "> EKS cluster created. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./aws-infra/resources/create-resources-stack.sh

read -p "> Resources CloudFormation stack created. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./aws-infra/resources/create-secrets.sh

read -p "> Secrets created. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./aws-infra/eks/create-node-groups.sh

read -p "> EKS node groups created. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./kubernetes/init-config.sh

read -p "> Kubernetes config files initialized. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./kubernetes/generate-upgrade-nodegroup-jobs-config.sh

read -p "> Upgrade node group jobs config generated. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./kubernetes/install-argocd.sh

echo "Argo CD installed"

cd $CURRENT_DIR
