#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

ARGOCD_CONFIG_HOME="$CLUSTER_HOME/kubernetes/gitops/argocd"
KUSTOMIZATION_FILE="$ARGOCD_CONFIG_HOME/kustomization.yaml"
CURRENT_DIR=$(pwd)
LB_WAIT_TIMEOUT_SECONDS=${LB_WAIT_TIMEOUT_SECONDS:-300}
LB_WAIT_INTERVAL_SECONDS=${LB_WAIT_INTERVAL_SECONDS:-10}

if [ ! -f "$KUSTOMIZATION_FILE" ]; then
  cecho "Could not find $KUSTOMIZATION_FILE" "error"
  exit 1
fi

cd "$ARGOCD_CONFIG_HOME"

cecho "Enabling Argo CD NLB patch in $KUSTOMIZATION_FILE..." "info"

if grep -qE '^[[:space:]]*#[[:space:]]*- path: patches-nlb.yaml' "$KUSTOMIZATION_FILE"; then
  sed -i -E 's/^([[:space:]]*)#[[:space:]]*- path: patches-nlb.yaml/\1- path: patches-nlb.yaml/' "$KUSTOMIZATION_FILE"
elif grep -qE '^[[:space:]]*- path: patches-nlb.yaml' "$KUSTOMIZATION_FILE"; then
  cecho "patches-nlb.yaml is already enabled in kustomization.yaml" "info"
else
  cecho "Could not find commented patches-nlb.yaml entry in kustomization.yaml" "error"
  exit 1
fi

cecho "Applying Argo CD kustomize overlay..." "info"
kubectl apply --server-side --force-conflicts -k .

cecho "Waiting for argocd-server LoadBalancer hostname..." "info"
elapsed_seconds=0
argocd_hostname=""

while [ "$elapsed_seconds" -lt "$LB_WAIT_TIMEOUT_SECONDS" ]; do
  argocd_hostname=$(kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

  if [ -n "$argocd_hostname" ]; then
    cecho "argocd-server LoadBalancer hostname: $argocd_hostname" "strong"
    break
  fi

  cecho "Waiting for hostname... ${elapsed_seconds}s/${LB_WAIT_TIMEOUT_SECONDS}s" "info"
  sleep "$LB_WAIT_INTERVAL_SECONDS"
  elapsed_seconds=$((elapsed_seconds + LB_WAIT_INTERVAL_SECONDS))
done

if [ -z "$argocd_hostname" ]; then
  cecho "Timed out waiting for argocd-server LoadBalancer hostname after ${LB_WAIT_TIMEOUT_SECONDS}s" "error"
  exit 1
fi

cd "$CURRENT_DIR"
