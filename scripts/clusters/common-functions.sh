#!/bin/bash

cecho () {
    if [ "$2" == "info" ] ; then
        color="96m";
    elif [ "$2" == "strong" ] ; then
        color="94m";
    elif [ "$2" == "success" ] ; then
        color="92m";
    elif [ "$2" == "warning" ] ; then
        color="93m";
    elif [ "$2" == "error" ] ; then
        color="91m";
    else #default color
        color="0m";
    fi

    startcolor="\e[$color";
    endcolor="\e[0m";

    printf "$startcolor%b$endcolor\n" "$1";
}

function update_var() {
    var_name=$1
    var_value=$2

    sed -E -i "s/${var_name}=(.*)$/${var_name}='${var_value}'/g" $CONFIG_FILE
}

function update_var_with_file_content {
    var_name=$1
    file=$2

    perl -pi -e "s~${var_name}=(.)*\$~${var_name}='`cat ${file}`'~g;" $CONFIG_FILE
}

function gen_random_pswd() {
    aws secretsmanager --output json get-random-password \
        --exclude-characters "\"'/\\[]=:,{}@&|" --password-length $1 | jq -r '.RandomPassword'
}

function gen_random_pswd_only_alphanumeric() {
    aws secretsmanager --output json get-random-password \
        --exclude-punctuation --password-length $1 | jq -r '.RandomPassword'
}

function gen_random_pswd_only_alphanumeric_no_uppercase() {
    aws secretsmanager --output json get-random-password \
        --exclude-punctuation --exclude-uppercase --password-length $1 | jq -r '.RandomPassword'
}

function save_secret_string() {
    local name=$1
    local desc=$2
    local str=$3
    local final_name="$CLUSTER_NAME/$name"

    local secret=$(aws secretsmanager list-secrets --output json --filters Key=name,Values=$final_name | \
        jq -r '.SecretList[0]')

    if [ "$REPLICATE_SECRETS" == "true" ] && [ ! -z "$AWS_BACKUP_REGION" ]; then
        if [ -z "$secret" ] || [ "$secret" == "null" ]; then
            aws secretsmanager create-secret --output json --name "$final_name" --description "$desc" --secret-string "$str" --add-replica-regions Region="$AWS_BACKUP_REGION"
        else
            aws secretsmanager put-secret-value --output json --secret-id "$final_name" --secret-string "$str"

        fi
    else 
        if [ -z "$secret" ] || [ "$secret" == "null" ]; then
            aws secretsmanager create-secret --output json --name "$final_name" --description "$desc" --secret-string "$str"
        else
            aws secretsmanager put-secret-value --output json --secret-id "$final_name" --secret-string "$str"

        fi
    fi
}

function switch_cluster_context() {
    cluster_tools_installed=$(cluster-context --list | { grep "$CLUSTER_ALIAS" || true; })
    if [ ! -z "$cluster_tools_installed" ]; then
        current=$(cluster-context --show)
        if [ "$current" != "$CLUSTER_ALIAS" ]; then
            cecho "Switching to cluster context for '$CLUSTER_ALIAS'"
            cluster-context "$CLUSTER_ALIAS"
        fi
    fi  
}