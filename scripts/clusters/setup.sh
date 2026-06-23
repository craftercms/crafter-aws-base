#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/set-config.sh"

CURRENT_DIR=$(pwd)

if [ ! -d "$CLUSTER_HOME" ]; then
  echo "Creating cluster folder $CLUSTER_HOME and copying templates"

  mkdir -p $CLUSTER_HOME
  cp -rp $TEMPLATES_HOME/* $CLUSTER_HOME
else
  echo "Cluster folder $CLUSTER_HOME already exists"
fi

cd $SCRIPTS_HOME

./init-config-files.sh

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

./kubernetes/init-config-files.sh

read -p "> Kubernetes config files initialized. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./kubernetes/generate-upgrade-nodegroup-jobs-config.sh

read -p "> Upgrade node group job config verified. Press enter to continue"
echo "--------------------------------------------------------------------------------"

./kubernetes/install-argocd.sh

echo "Argo CD installed"

cd $CURRENT_DIR
