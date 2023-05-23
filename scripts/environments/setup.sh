#!/bin/bash

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/set-config.sh"

RESOURCES_STACK_NAME="crafter-$ENVIRONMENT-resources"
RESOURCES_STACK_CONFIG_FILE="$TEMPLATES_HOME/aws-infra/resources.yaml"
resources_stack=$(aws cloudformation describe-stacks --stack-name $RESOURCES_STACK_NAME | jq '.Stacks[0]')
if [ -z "$resources_stack" ] || [ "$resources_stack" == "null" ]; then
    aws cloudformation create-stack --stack-name $RESOURCES_STACK_NAME \
        --capabilities CAPABILITY_NAMED_IAM \
        --template-body file://$RESOURCES_STACK_CONFIG_FILE --parameters \
        ParameterKey=Environment,ParameterValue="$ENVIRONMENT" \
        ParameterKey=S3BucketNamePrefix,ParameterValue="$S3_BUCKET_NAME_PREFIX" \
        ParameterKey=CloudFrontLoggingS3BucketName,ParameterValue="$CLOUDFRONT_LOGGING_S3_BUCKET_NAME" 

    echo "Waiting for environment resources stack to be created..."

    aws cloudformation wait stack-create-complete --stack-name $RESOURCES_STACK_NAME
else
    echo "Environment resources stack already exists."
fi