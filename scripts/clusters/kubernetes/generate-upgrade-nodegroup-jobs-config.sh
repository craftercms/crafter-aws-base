#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

UPGRADE_NODEGROUP_JOBS_CONFIG_FILE="$CLUSTER_HOME/kubernetes/gitops/apps/admin/jobs/upgrade-nodegroups.yaml"

cecho "Generating Kubernetes CronJob config to upgrade nodegroups of cluster $CLUSTER_NAME..." "info"

truncate -s 0 "$UPGRADE_NODEGROUP_JOBS_CONFIG_FILE"

eksctl get nodegroups --region="$AWS_DEFAULT_REGION" --cluster "$CLUSTER_NAME"  -o json | jq -r '.[].Name' | while read name; do
cecho "Generating upgrade CronJob config for $name..." "info"

cat <<EOF >>$UPGRADE_NODEGROUP_JOBS_CONFIG_FILE
apiVersion: batch/v1
kind: CronJob
metadata:
  name: upgrade-$name
spec:
  schedule: "$UPGRADE_NODES_CRON_UTC"
  concurrencyPolicy: Forbid
  startingDeadlineSeconds: 300
  failedJobsHistoryLimit: 1
  successfulJobsHistoryLimit: 1
  jobTemplate:
    spec:
      # Cleanup job after 8 hours
      ttlSecondsAfterFinished: 28800
      parallelism: 1
      completions: 1
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: upgrade-nodegroups
          containers:
            - name: eksctl
              image: weaveworks/eksctl:latest
              imagePullPolicy: Always
              args: ["upgrade", "nodegroup", "--cluster=$CLUSTER_NAME", "--name=$name"]
          restartPolicy: Never
---
EOF
done
