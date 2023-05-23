#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

ARGOCD_CONFIG_HOME="$CLUSTER_HOME/kubernetes/gitops/argocd"
CURRENT_DIR=$(pwd)

cd $ARGOCD_CONFIG_HOME

cecho "Installing ArgoCD in cluster $CLUSTER_NAME..." "info"

kubectl apply -k .

cecho "Sleeping 30 seconds to wait for ArgoCD to be installed..."
sleep 30

initial_argocd_pswd=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

cecho "Run 'kubectl port-forward svc/argocd-server -n argocd 18080:443' to access Argo CD" "strong"
cecho "Argo CD username: admin" "strong"
cecho "Argo CD initial password: $initial_argocd_pswd" "strong"

argocd_password=$(aws secretsmanager get-secret-value --secret-id "${CLUSTER_NAME}/argocd-credentials" | \
    jq -r '.SecretString' | jq -r '.password')

cecho "Login from the CLI with 'argocd login localhost:18080', and then run 'argocd account update-password' to: $argocd_password" "strong"

cd $CURRENT_DIR