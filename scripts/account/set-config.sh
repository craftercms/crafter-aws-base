#!/bin/bash

set -e

export SCRIPTS_HOME=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

if [ -z "$CONFIG_FILE" ]; then
    read -p "Provide the config.sh file suffix, or press enter to use the default config.sh: " config_suffix
    if [ -z "$config_suffix" ]; then
        export CONFIG_FILE="${SCRIPTS_HOME}/config.sh"
    else
        export CONFIG_FILE="${SCRIPTS_HOME}/config.${config_suffix}.sh"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file $CONFIG_FILE doesn't exist. Exiting..."
    exit 1
fi

. "$CONFIG_FILE"

export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r '.Account')

export TEMPLATES_HOME=$(realpath "$SCRIPTS_HOME/../../templates/account")