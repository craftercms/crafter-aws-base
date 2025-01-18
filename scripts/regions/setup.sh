#!/bin/bash

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/set-config.sh"

RESOURCES_STACK_NAME="crafter-region-resources"
RESOURCES_STACK_CONFIG_FILE="$TEMPLATES_HOME/aws-infra/resources.yaml"
resources_stack=$(aws cloudformation describe-stacks --stack-name $RESOURCES_STACK_NAME --region $REGION | jq '.Stacks[0]')
if [ -z "$resources_stack" ] || [ "$resources_stack" == "null" ]; then
    aws cloudformation create-stack --stack-name $RESOURCES_STACK_NAME \
        --region $REGION \
        --capabilities CAPABILITY_NAMED_IAM \
        --template-body file://$RESOURCES_STACK_CONFIG_FILE --parameters \
        ParameterKey=ClientId,ParameterValue="$CLIENT_ID" \
        ParameterKey=PagerDutyIntegrationUrl,ParameterValue="$PAGER_DUTY_INTEGRATION_URL"
    echo "Waiting for regions resources stack to be created..."

    aws cloudformation wait stack-create-complete --stack-name $RESOURCES_STACK_NAME
else
    echo "Regions resources stack already exists."
fi