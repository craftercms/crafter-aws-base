#!/bin/bash
set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

CONFIG_FOLDER="$CLUSTER_HOME/aws-infra/eks"
CURRENT_DIR=$(pwd)

cd $CONFIG_FOLDER

resources_stack=$(aws cloudformation describe-stacks --stack-name ${CLUSTER_NAME}-resources | jq '.Stacks[0]')
authoring_ng_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="AuthoringNodeGroupSecurityGroup").OutputValue')
delivery_ng_sg=$(echo $resources_stack | jq -r '.Outputs[] | select(.OutputKey=="DeliveryNodeGroupSecurityGroup").OutputValue')

sed -i "s/{{authoring_ng_sg}}/$authoring_ng_sg/g" cluster.yaml
sed -i "s/{{delivery_ng_sg}}/$delivery_ng_sg/g" cluster.yaml

cecho "Creating node groups for cluster $CLUSTER_NAME..." "info"

eksctl create nodegroup --config-file cluster.yaml

cd $CURRENT_DIR