#!/bin/bash
set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

CLUSTER_CONFIG="$CLUSTER_HOME/aws-infra/eks/cluster.yaml"

cecho "Installing cluster tools..." "info"
install-cluster-tools --eksctl-version $EKSCTL_VERSION --kubectl-version $KUBECTL_VERSION --k9s-version $K9S_VERSION --skip-kube-config --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" $CLUSTER_NAME $CLUSTER_ALIAS
switch_cluster_context

eks_stack=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster | jq '.Stacks[0]')
if [ -z "$eks_stack" ] || [ "$eks_stack" == "null" ]; then
    cecho "Creating cluster $CLUSTER_NAME..." "info"
    eksctl create cluster --config-file=$CLUSTER_CONFIG --without-nodegroup --write-kubeconfig=false
else
    cecho "Cluster $CLUSTER_NAME already exists" "info"
fi

cecho "Installing initial kubeconfig..." "info"
install-cluster-tools --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" $CLUSTER_NAME $CLUSTER_ALIAS

cecho "Creating custom ClusterRoleBindings..." "info"
kubectl apply -f $CLUSTER_HOME/kubernetes/rbac/clusterrolebindings.yaml

EKS_ADMIN_IAM_ROLE="arn:aws:iam::$AWS_ACCOUNT_ID:role/eks-admin"

cecho "Create Kubernetes group mapping for cluster-admin IAM role..." "info"
eksctl create iamidentitymapping \
    --cluster $CLUSTER_NAME \
    --region=$AWS_DEFAULT_REGION \
    --arn "$EKS_ADMIN_IAM_ROLE" \
    --username "eks-admin:{{SessionName}}" \
    --group eks-admin \
    --no-duplicate-arns

cecho "Installing role-based kubeconfig..." "info"
install-cluster-tools --profile "$AWS_PROFILE" --region "$AWS_DEFAULT_REGION" --role "$EKS_ADMIN_IAM_ROLE" $CLUSTER_NAME $CLUSTER_ALIAS

cecho "Synching up tools to S3..." "info"
sync-cluster-tools --up