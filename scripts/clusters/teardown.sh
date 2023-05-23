#!/bin/bash
set -e

PRGDIR=$(cd "$( dirname "$BASH_SOURCE[0]" )" && pwd)

. "$PRGDIR/set-config.sh"

if [ "$1" = '--approve' ]; then
    read -p "Please confirm that you want to delete all resources for cluster '$CLUSTER_NAME' by typing the cluster name: " REPLY
    if [ "$REPLY" != "$CLUSTER_NAME" ]; then
        cecho "Canceling cluster '$CLUSTER_NAME' teardown" "strong"
        exit 0
    fi
else
    cecho "Doing a dry run. To perform the actual deletes, please run this script with the --approve argument" "strong"
fi

nodegroups=''

cecho "Deleting EKS nodegroups..." "info"
eksctl get nodegroups --region="$AWS_DEFAULT_REGION" --cluster "$CLUSTER_NAME"  -o json | jq -r '.[].Name' | while read name; do
    cecho "Deleting nodegroup $name"
    if [ "$1" == '--approve' ]; then
        eksctl delete nodegroup --region="$AWS_DEFAULT_REGION" --cluster="$CLUSTER_NAME" --name="$name" --drain=false --disable-eviction --wait
    fi
done

cecho "Deleting LoadBalancers..." "info"
lb_arn_list=$(aws elbv2 describe-load-balancers | jq '[.LoadBalancers[] | .LoadBalancerArn]') 
count=$(aws elbv2 describe-load-balancers | jq '.LoadBalancers | length')
for ((i=0; i<$count; i++));
do
        lb_arn=$(echo $lb_arn_list | jq '.['$i']')
        lb_arn=`sed -e 's/^"//' -e 's/"$//' <<<"$lb_arn"`
        cluster=$(aws elbv2 describe-tags --resource-arns $lb_arn --region $AWS_DEFAULT_REGION | jq '.TagDescriptions[].Tags[] | select(.Key=="elbv2.k8s.aws/cluster")')
        
        cluster_name=$(echo $cluster | jq '.Value')
        cluster_name="${cluster_name%\"}"
        cluster_name="${cluster_name#\"}"
        if [ "$1" = '--approve' ]; then    
            if [[ "$cluster_name" == "$CLUSTER_NAME" ]]; then
                cecho "deleting load-balancer from '$lb_arn'"
                aws elbv2 delete-load-balancer --load-balancer-arn $lb_arn
            fi
        fi
done

cecho "Deleting $CLUSTER_NAME-resources stack..." "info"
if [ "$1" == '--approve' ]; then
    aws cloudformation delete-stack --stack-name "$CLUSTER_NAME-resources"
    aws cloudformation wait stack-delete-complete --stack-name "$CLUSTER_NAME-resources"
fi

cecho "Deleting AWS secrets..." "info"
aws secretsmanager list-secrets --filter Key="name",Values="$CLUSTER_NAME" | jq -r '.SecretList[].Name' | while read name; do
    cecho "Deleting secret $name"
    if [ "$1" == '--approve' ]; then
        if [ ! -z "$AWS_BACKUP_REGION" ]; then
            VOID_VAR=$(aws secretsmanager remove-regions-from-replication --secret-id "$name" --remove-replica-regions "$AWS_BACKUP_REGION")
        fi
        VOID_VAR=$(aws secretsmanager delete-secret --secret-id "$name" --force-delete-without-recovery)
    fi
done

cecho "Deleting fp-kube-admin-jobs Fargate profile..." "info"
if [ "$1" == '--approve' ]; then
    eksctl delete fargateprofile --region "$AWS_DEFAULT_REGION" --cluster "$CLUSTER_NAME" --name fp-kube-admin-jobs --wait
fi

cecho "Deleting EKS cluster..." "info"
if [ "$1" == '--approve' ]; then
    eksctl delete cluster --region "$AWS_DEFAULT_REGION" --name "$CLUSTER_NAME" --wait
fi

cecho "Deleting Git config files at $CLUSTER_HOME..." "info"
if [ "$1" == '--approve' ]; then
    rm -rf $CLUSTER_HOME
fi