#!/bin/bash

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/set-config.sh"

es_linked_role=$(aws iam get-role --role-name 'AWSServiceRoleForAmazonElasticsearchService' | jq -r '.Role')
if [ -z "$es_linked_role" ] || [ "$es_linked_role" == "null" ]; then
    echo 'Creating Elastisearch service linked role...'

    aws iam create-service-linked-role --aws-service-name es.amazonaws.com
else
    echo 'Elastisearch service linked role already exists.'
fi

lifecycle_manager_role=$(aws iam get-role --role-name 'AWSDataLifecycleManagerDefaultRole' | jq -r '.Role')
if [ -z "$lifecycle_manager_role" ] || [ "$lifecycle_manager_role" == "null" ]; then
    echo "Creating default Amazon Data Lifecycle Manager IAM role..."

    aws dlm create-default-role
else
    echo 'Default Amazon Data Lifecycle Manager IAM role already exists.'
fi

RESOURCES_STACK_NAME="crafter-account-resources"
RESOURCES_STACK_CONFIG_FILE="$TEMPLATES_HOME/aws-infra/resources.yaml"
resources_stack=$(aws cloudformation describe-stacks --stack-name $RESOURCES_STACK_NAME | jq '.Stacks[0]')
if [ -z "$resources_stack" ] || [ "$resources_stack" == "null" ]; then
    aws cloudformation create-stack --stack-name $RESOURCES_STACK_NAME \
        --capabilities CAPABILITY_NAMED_IAM \
        --template-body file://$RESOURCES_STACK_CONFIG_FILE --parameters \
        ParameterKey=CloudFrontNotificationsEmailAddress,ParameterValue="$CLOUDFRONT_NOTIFICATIONS_EMAIL_ADDRESS" \
        ParameterKey=EksAdminTrustedPrincipals,ParameterValue="arn:aws:iam::$AWS_ACCOUNT_ID:root"

    echo "Waiting for account resources stack to be created..."

    aws cloudformation wait stack-create-complete --stack-name $RESOURCES_STACK_NAME
else
    echo "Account resources stack already exists."
fi