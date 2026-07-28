#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

function gen_random_pswd() {
    aws secretsmanager --output json get-random-password --exclude-characters "\"'/\\[]=:,{}@&" \
        --password-length $1 | jq -r '.RandomPassword'
}

ALARMS_STACK_NAME="${CLUSTER_NAME}-alarms"
RESOURCES_STACK_NAME="${CLUSTER_NAME}-resources"
HEALTHCHECKS_STACK_NAME="${CLUSTER_NAME}-${AWS_DEFAULT_REGION}-healthchecks"
NOTIFICATIONS_STACK_NAME="${CLUSTER_NAME}-notifications"
UPGRADE_REPORTS_STACK_NAME="${CLUSTER_NAME}-upgrade-reports"
VOLUME_BACKUP_REPORTS_STACK_NAME="${CLUSTER_NAME}-volume-backup-reports"
ALARMS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/alarms.yaml"
RESOURCES_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/resources.yaml"
HEALTHCHECKS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/healthchecks.yaml"
NOTIFICATIONS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/notifications.yaml"
UPGRADE_REPORTS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/upgrade-reports.yaml"
VOLUME_BACKUP_REPORTS_STACK_CONFIG_FILE="$CLUSTER_HOME/aws-infra/resources/volume-backup-reports.yaml"

resources_stack=$(aws cloudformation describe-stacks --stack-name $RESOURCES_STACK_NAME | jq '.Stacks[0]')
if [ -z "$resources_stack" ] || [ "$resources_stack" == "null" ]; then
    eks_stack=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster | jq '.Stacks[0]')
    vpc_id=$(echo $eks_stack | jq -r '.Outputs[] | select(.OutputKey=="VPC").OutputValue')
    private_subnet_ids=$(echo $eks_stack | jq -r '.Outputs[] | select(.OutputKey=="SubnetsPrivate").OutputValue')
    private_route_table_ids=$(aws ec2 describe-route-tables --region $AWS_DEFAULT_REGION --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=eksctl-${CLUSTER_NAME}-cluster/Private*" | jq -r '.RouteTables[].RouteTableId' | paste -s -d, -)

    aws cloudformation create-stack --stack-name $RESOURCES_STACK_NAME --capabilities CAPABILITY_NAMED_IAM \
        --template-body file://$RESOURCES_STACK_CONFIG_FILE --parameters \
        ParameterKey=VpcId,ParameterValue=$vpc_id \
        ParameterKey=PrivateSubnetIds,ParameterValue=${private_subnet_ids//,/\\,} \
        ParameterKey=PrivateRouteTableIds,ParameterValue=${private_route_table_ids//,/\\,} \
        ParameterKey=BackupRegion,ParameterValue=$AWS_BACKUP_REGION \
        ParameterKey=BackupRegionBucketNamePrefix,ParameterValue=$S3_BACKUP_REGION_BUCKET_NAME_PREFIX \
        ParameterKey=DeliveryInstanceCount,ParameterValue=$DELIVERY_INSTANCE_COUNT \
        ParameterKey=OpenSearchSingleNodeCluster,ParameterValue=$OPEN_SEARCH_SINGLE_NODE_CLUSTER \
        ParameterKey=OpenSearchInstanceType,ParameterValue=$OPEN_SEARCH_INSTANCE_TYPE \
        ParameterKey=OpenSearchVolumeSize,ParameterValue=$OPEN_SEARCH_VOLUME_SIZE

    cecho "Waiting for resources stack to be created..." "info"

    aws cloudformation wait stack-create-complete --stack-name $RESOURCES_STACK_NAME
else
    cecho "Resources stack $RESOURCES_STACK_NAME already exists" "info"
fi

healthchecks_stack=$(aws cloudformation describe-stacks --region 'us-east-1' --stack-name $HEALTHCHECKS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$healthchecks_stack" ] || [ "$healthchecks_stack" == "null" ]; then
    if [ "$AWS_DEFAULT_REGION" == "us-east-1" ]; then
        aws cloudformation create-stack --stack-name $HEALTHCHECKS_STACK_NAME --capabilities CAPABILITY_NAMED_IAM \
            --template-body file://$HEALTHCHECKS_STACK_CONFIG_FILE --parameters \
            ParameterKey=AuthoringHealthcheckHostname,ParameterValue=$AUTHORING_DOMAIN_NAME \
            ParameterKey=AuthoringHealthcheckPath,ParameterValue=${AUTHORING_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=DeliveryHealthcheckHostname,ParameterValue=$DELIVERY_DOMAIN_NAME \
            ParameterKey=DeliveryHealthcheckPath,ParameterValue=${DELIVERY_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=${ALARMS_SLACK_CHANNEL_HOOK_URL:-} \
            ParameterKey=AlarmsEmailAddress,ParameterValue=$ALARMS_EMAIL_ADDRESS \
            ParameterKey=PagerDutyIntegrationUrl,ParameterValue=${PAGER_DUTY_INTEGRATION_URL:-}

    else
        aws cloudformation create-stack --region 'us-east-1' --stack-name $HEALTHCHECKS_STACK_NAME \
            --capabilities CAPABILITY_NAMED_IAM --template-body file://$HEALTHCHECKS_STACK_CONFIG_FILE --parameters \
            ParameterKey=AuthoringHealthcheckHostname,ParameterValue=$AUTHORING_DOMAIN_NAME \
            ParameterKey=AuthoringHealthcheckPath,ParameterValue=${AUTHORING_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=DeliveryHealthcheckHostname,ParameterValue=$DELIVERY_DOMAIN_NAME \
            ParameterKey=DeliveryHealthcheckPath,ParameterValue=${DELIVERY_HEALTHCHECK_PATH/token=/"token=$CRAFTER_MANAGEMENT_TOKEN"} \
            ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=${ALARMS_SLACK_CHANNEL_HOOK_URL:-} \
            ParameterKey=AlarmsEmailAddress,ParameterValue=$ALARMS_EMAIL_ADDRESS \
            ParameterKey=PagerDutyIntegrationUrl,ParameterValue=${PAGER_DUTY_INTEGRATION_URL:-}
    fi

    cecho "Waiting for resources stack to be created..." "info"
else
    cecho "Resources stack $HEALTHCHECKS_STACK_NAME already exists" "info"
fi

alarms_stack=$(aws cloudformation describe-stacks --region $AWS_DEFAULT_REGION --stack-name $ALARMS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$alarms_stack" ] || [ "$alarms_stack" == "null" ]; then
    aws cloudformation create-stack --region $AWS_DEFAULT_REGION --stack-name $ALARMS_STACK_NAME \
        --capabilities CAPABILITY_NAMED_IAM --template-body file://$ALARMS_STACK_CONFIG_FILE --parameters \
        ParameterKey=CloudWatchAlarmsEnabled,ParameterValue=$ENABLE_CLOUDWATCH_ALARMS \
        ParameterKey=AlarmsSlackChannelHookUrl,ParameterValue=${ALARMS_SLACK_CHANNEL_HOOK_URL:-} \
        ParameterKey=AlarmsEmailAddress,ParameterValue=$ALARMS_EMAIL_ADDRESS \
        ParameterKey=PagerDutyIntegrationUrl,ParameterValue=${PAGER_DUTY_INTEGRATION_URL:-} \
        ParameterKey=DeliveryInstanceCount,ParameterValue=$DELIVERY_INSTANCE_COUNT

    cecho "Waiting for alarms stack to be created..." "info"
else
    cecho "Resources stack $ALARMS_STACK_NAME already exists" "info"
fi

notifications_stack=$(aws cloudformation describe-stacks --region $AWS_DEFAULT_REGION --stack-name $NOTIFICATIONS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$notifications_stack" ] || [ "$notifications_stack" == "null" ]; then
    aws cloudformation create-stack --region $AWS_DEFAULT_REGION --stack-name $NOTIFICATIONS_STACK_NAME \
        --capabilities CAPABILITY_NAMED_IAM --template-body file://$NOTIFICATIONS_STACK_CONFIG_FILE --parameters \
        ParameterKey=NotificationsEmailAddress,ParameterValue=${NOTIFICATIONS_EMAIL_ADDRESS:-cloud-ops@craftercms.com}

    cecho "Waiting for notifications stack to be created..." "info"

    aws cloudformation wait stack-create-complete --region $AWS_DEFAULT_REGION --stack-name $NOTIFICATIONS_STACK_NAME
else
    cecho "Notifications stack $NOTIFICATIONS_STACK_NAME already exists" "info"
fi

upgrade_reports_stack=$(aws cloudformation describe-stacks --region $AWS_DEFAULT_REGION --stack-name $UPGRADE_REPORTS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$upgrade_reports_stack" ] || [ "$upgrade_reports_stack" == "null" ]; then
    aws cloudformation create-stack --region $AWS_DEFAULT_REGION --stack-name $UPGRADE_REPORTS_STACK_NAME \
        --capabilities CAPABILITY_NAMED_IAM --template-body file://$UPGRADE_REPORTS_STACK_CONFIG_FILE --parameters \
        ParameterKey=UpgradeReportsEnabled,ParameterValue=${ENABLE_UPGRADE_REPORTS:-true} \
        ParameterKey=AlarmsEmailAddress,ParameterValue=$ALARMS_EMAIL_ADDRESS

    cecho "Waiting for upgrade reports stack to be created..." "info"

    aws cloudformation wait stack-create-complete --region $AWS_DEFAULT_REGION --stack-name $UPGRADE_REPORTS_STACK_NAME
else
    cecho "Upgrade reports stack $UPGRADE_REPORTS_STACK_NAME already exists" "info"
fi

volume_backup_reports_stack=$(aws cloudformation describe-stacks --region $AWS_DEFAULT_REGION --stack-name $VOLUME_BACKUP_REPORTS_STACK_NAME | jq '.Stacks[0]')
if [ -z "$volume_backup_reports_stack" ] || [ "$volume_backup_reports_stack" == "null" ]; then
    if [ "${ENABLE_VOLUME_BACKUP_REPORTS:-true}" != "true" ]; then
        cecho "Volume backup reports disabled (ENABLE_VOLUME_BACKUP_REPORTS=false). Skipping stack creation." "info"
    else
        notifications_export=$(aws cloudformation list-exports --region $AWS_DEFAULT_REGION \
            --query "Exports[?Name=='${CLUSTER_NAME}-NotificationsSNSTopicArn'].Value" --output text)
        if [ -z "$notifications_export" ] || [ "$notifications_export" == "None" ]; then
            cecho "Volume backup reports require the notifications stack export ${CLUSTER_NAME}-NotificationsSNSTopicArn. Deploy notifications first." "error"
            exit 1
        fi

        aws cloudformation create-stack --region $AWS_DEFAULT_REGION --stack-name $VOLUME_BACKUP_REPORTS_STACK_NAME \
            --capabilities CAPABILITY_NAMED_IAM --template-body file://$VOLUME_BACKUP_REPORTS_STACK_CONFIG_FILE --parameters \
            ParameterKey=VolumeBackupReportsEnabled,ParameterValue=true

        cecho "Waiting for volume backup reports stack to be created..." "info"

        aws cloudformation wait stack-create-complete --region $AWS_DEFAULT_REGION --stack-name $VOLUME_BACKUP_REPORTS_STACK_NAME
    fi
else
    cecho "Volume backup reports stack $VOLUME_BACKUP_REPORTS_STACK_NAME already exists" "info"
fi
