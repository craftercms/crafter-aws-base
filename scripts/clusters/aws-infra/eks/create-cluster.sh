#!/bin/bash
set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

CLUSTER_CONFIG="$CLUSTER_HOME/aws-infra/eks/cluster.yaml"

cecho "Installing cluster tools..." "info"
install-cluster-tools --eksctl-version $EKSCTL_VERSION --kubectl-version $KUBECTL_VERSION --k9s-version $K9S_VERSION --skip-kube-config --aws-profile "$AWS_PROFILE" --aws-region "$AWS_DEFAULT_REGION" $CLUSTER_NAME $CLUSTER_ALIAS
switch_cluster_context

eks_stack=$(aws cloudformation describe-stacks --stack-name eksctl-${CLUSTER_NAME}-cluster | jq '.Stacks[0]')
if [ -z "$eks_stack" ] || [ "$eks_stack" == "null" ]; then
    cecho "Creating cluster $CLUSTER_NAME..." "info"
    eksctl create cluster --config-file=$CLUSTER_CONFIG --without-nodegroup --write-kubeconfig=false --timeout '1h'
else
    cecho "Cluster $CLUSTER_NAME already exists" "info"
fi

cecho "Installing initial kubeconfig..." "info"
install-cluster-tools --aws-profile "$AWS_PROFILE" --aws-region "$AWS_DEFAULT_REGION" --k8s-role admin $CLUSTER_NAME $CLUSTER_ALIAS

cecho "Creating custom ClusterRoleBindings..." "info"
kubectl apply -f $CLUSTER_HOME/kubernetes/rbac/clusterrolebindings.yaml

EKS_ADMIN_IAM_ROLE="arn:aws:iam::$AWS_ACCOUNT_ID:role/eks-admin"
EKS_CRAFTERCMS_SUPPORT_IAM_ROLE="arn:aws:iam::$AWS_ACCOUNT_ID:role/eks-craftercms-support"

cecho "Create Kubernetes group mapping for eks-admin IAM role..." "info"
eksctl create iamidentitymapping \
    --cluster $CLUSTER_NAME \
    --region=$AWS_DEFAULT_REGION \
    --arn "$EKS_ADMIN_IAM_ROLE" \
    --username "eks-admin:{{SessionName}}" \
    --group eks-admin \
    --no-duplicate-arns

cecho "Create Kubernetes group mapping for eks-craftercms-support IAM role..." "info"
eksctl create iamidentitymapping \
    --cluster $CLUSTER_NAME \
    --region=$AWS_DEFAULT_REGION \
    --arn "$EKS_CRAFTERCMS_SUPPORT_IAM_ROLE" \
    --username "eks-craftercms-support:{{SessionName}}" \
    --group eks-craftercms-support \
    --no-duplicate-arns

cecho "Installing role-based kubeconfig..." "info"
install-cluster-tools --aws-profile "$AWS_PROFILE" --aws-region "$AWS_DEFAULT_REGION" --aws-role "$EKS_ADMIN_IAM_ROLE" --k8s-role admin $CLUSTER_NAME $CLUSTER_ALIAS
install-cluster-tools --aws-profile "$AWS_PROFILE" --aws-region "$AWS_DEFAULT_REGION" --aws-role "$EKS_CRAFTERCMS_SUPPORT_IAM_ROLE" --k8s-role support $CLUSTER_NAME $CLUSTER_ALIAS

cecho "Synching up tools to S3..." "info"
sync-cluster-tools -p "$CLUSTER_TOOLS_AWS_PROFILE" -b "$CLUSTER_TOOLS_BUCKET" --up