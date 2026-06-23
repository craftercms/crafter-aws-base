#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

UPGRADE_NODEGROUP_JOBS_CONFIG_FILE="$CLUSTER_HOME/kubernetes/gitops/apps/admin/jobs/upgrade-nodegroups.yaml"

cecho "Checking nodegroup upgrade CronJob config for cluster $CLUSTER_NAME..." "info"

if [ ! -f "$UPGRADE_NODEGROUP_JOBS_CONFIG_FILE" ]; then
  cecho "Upgrade nodegroups config not found at $UPGRADE_NODEGROUP_JOBS_CONFIG_FILE" "error"
  exit 1
fi

if grep -q '{{[^}]\+}}' "$UPGRADE_NODEGROUP_JOBS_CONFIG_FILE"; then
  cecho "Upgrade nodegroups config still contains unresolved template placeholders" "error"
  exit 1
fi

cecho "Nodegroup upgrade CronJob config is present (dynamic nodegroup discovery at runtime)." "info"
