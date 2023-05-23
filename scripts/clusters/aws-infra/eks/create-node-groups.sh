#!/bin/bash
set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

CONFIG_FOLDER="$CLUSTER_HOME/aws-infra/eks"
CURRENT_DIR=$(pwd)

cd $CONFIG_FOLDER

cecho "Creating node groups for cluster $CLUSTER_NAME..." "info"

eksctl create nodegroup --config-file cluster.yaml

cd $CURRENT_DIR