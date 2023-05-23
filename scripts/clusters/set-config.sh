#!/bin/bash

set -e

export SCRIPTS_HOME=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

if [ -z "$CONFIG_FILE" ]; then
    read -p "Provide the config.sh file suffix, or press enter to use the default config.sh: " config_suffix
    if [ -z "$config_suffix" ]; then
        export CONFIG_FILE="${SCRIPTS_HOME}/config.sh"
        export ENV_ALIAS=''
    else
        export CONFIG_FILE="${SCRIPTS_HOME}/config.${config_suffix}.sh"
        export ENV_ALIAS="$config_suffix"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file $CONFIG_FILE doesn't exist. Exiting..."
    exit 1
fi

. "$CONFIG_FILE"

export CLUSTER_ALIAS="$CLIENT_ID-$ENV_ALIAS"

# Check if it's the old cluster path. If it doesn't exist, use the new path
export CLUSTER_HOME=$(realpath -m "$SCRIPTS_HOME/../../clusters/$CLUSTER_NAME")
if [ ! -d "$CLUSTER_HOME" ]; then
    export CLUSTER_HOME=$(realpath -m "$SCRIPTS_HOME/../../clusters/$AWS_DEFAULT_REGION/$CLUSTER_NAME")
fi

export TEMPLATES_HOME=$(realpath "$SCRIPTS_HOME/../../templates/clusters")
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')

. "$SCRIPTS_HOME/common-functions.sh"

switch_cluster_context