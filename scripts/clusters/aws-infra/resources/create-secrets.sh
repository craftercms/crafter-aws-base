#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../../set-config.sh"

CURRENT_DIR=$(pwd)

cecho "Creating secrets for cluster $CLUSTER_NAME..." "info"

if [ -z "$CONFIG_ENCRYPTION_KEY" ]; then
    CONFIG_ENCRYPTION_KEY=$(gen_random_pswd 16)
    update_var 'CONFIG_ENCRYPTION_KEY' "$CONFIG_ENCRYPTION_KEY"

    cecho "Configuration encryption key generated: $CONFIG_ENCRYPTION_KEY"
fi

if [ -z "$CONFIG_ENCRYPTION_SALT" ]; then
    CONFIG_ENCRYPTION_SALT=$(gen_random_pswd 16)
    update_var 'CONFIG_ENCRYPTION_SALT' "$CONFIG_ENCRYPTION_SALT"

    cecho "Configuration encryption salt generated: $CONFIG_ENCRYPTION_SALT"
fi

if [ -z "$SYSTEM_ENCRYPTION_KEY" ]; then
    SYSTEM_ENCRYPTION_KEY=$(gen_random_pswd 16)
    update_var 'SYSTEM_ENCRYPTION_KEY' "$SYSTEM_ENCRYPTION_KEY"

    cecho "System encryption key generated: $SYSTEM_ENCRYPTION_KEY"
fi

if [ -z "$SYSTEM_ENCRYPTION_SALT" ]; then
    SYSTEM_ENCRYPTION_SALT=$(gen_random_pswd 16)
    update_var 'SYSTEM_ENCRYPTION_SALT' "$SYSTEM_ENCRYPTION_SALT"

    cecho "System encryption salt generated: $SYSTEM_ENCRYPTION_SALT"
fi

if [ -z "$ARGOCD_PASSWORD" ]; then
    ARGOCD_PASSWORD=$(gen_random_pswd 16)
    update_var 'ARGOCD_PASSWORD' "$ARGOCD_PASSWORD"

    cecho "ArgoCD password generated: $ARGOCD_PASSWORD"
fi

if [ "$GENERATE_GIT_HTTPS_SERVER_SECRETS" == "true" ]; then
    if [ -z "$GIT_HTTPS_SERVER_SSL_CERT" ]; then
        temp_dir=$(mktemp -d)
        # Remove the temp dir on script exit signal (0: Exit shell, 2: Interrupt, 3: Quit, 15: Terminate)
        trap "rm -rf $temp_dir" 0 2 3 15

        cecho "Generating Git HTTPS Server SSL cert..."

        # Generate certs for 5 years
        openssl req -x509 -nodes -days 1825 -newkey rsa:2048 -keyout "$temp_dir/tls.key" -out "$temp_dir/tls.crt"

        GIT_HTTPS_SERVER_SSL_CERT=`cat "$temp_dir/tls.crt"`
        update_var_with_file_content 'GIT_HTTPS_SERVER_SSL_CERT' "$temp_dir/tls.crt"

        GIT_HTTPS_SERVER_SSL_KEY=`cat "$temp_dir/tls.key"`
        update_var_with_file_content 'GIT_HTTPS_SERVER_SSL_KEY' "$temp_dir/tls.key" 
    fi

    if [ -z "$GIT_HTTPS_SERVER_USERNAME" ]; then
        username_suffix=$(gen_random_pswd_only_alphanumeric_no_uppercase 10)
        GIT_HTTPS_SERVER_USERNAME="git-$username_suffix"
        update_var 'GIT_HTTPS_SERVER_USERNAME' "$GIT_HTTPS_SERVER_USERNAME"

        cecho "Git HTTPS Server username generated: $GIT_HTTPS_SERVER_USERNAME"
    fi

    if [ -z "$GIT_HTTPS_SERVER_PASSWORD" ]; then
        GIT_HTTPS_SERVER_PASSWORD=$(gen_random_pswd 16)
        update_var 'GIT_HTTPS_SERVER_PASSWORD' "$GIT_HTTPS_SERVER_PASSWORD"

        cecho "Git HTTPS Server password generated: $GIT_HTTPS_SERVER_PASSWORD"
    fi
fi

cecho "Saving mail user credentials secret..." "info"
save_secret_string "mail-user-credentials" \
    "$CLUSTER_NAME mail user credentials" \
    "{\"username\": \"$MAIL_USERNAME\", \"password\": \"$MAIL_PASSWORD\"}"

cecho "Saving config encryption key and salt secret..." "info"
save_secret_string "config-encryption-key-salt" \
    "$CLUSTER_NAME config encryption key and salt" \
    "{\"key\": \"$CONFIG_ENCRYPTION_KEY\", \"salt\": \"$CONFIG_ENCRYPTION_SALT\"}"

cecho "Saving system encryption key and salt secret..." "info"
save_secret_string "system-encryption-key-salt" \
    "$CLUSTER_NAME system encryption key and salt" \
    "{\"key\": \"$SYSTEM_ENCRYPTION_KEY\", \"salt\": \"$SYSTEM_ENCRYPTION_SALT\"}"

cecho "Saving ArgoCD credentials secret..." "info"
save_secret_string "argocd-credentials" \
    "$CLUSTER_NAME ArgoCD credentials" \
    "{\"username\": \"admin\", \"password\": \"$ARGOCD_PASSWORD\"}"

if [ "$GENERATE_GIT_HTTPS_SERVER_SECRETS" == "true" ]; then
    cecho 'Saving Git HTTPS Server SSL certificate...' "info"
    save_secret_string "git-https-server-ssl-cert" \
        "$CLUSTER_NAME Git HTTPS Server SSL certificate" \
        "$GIT_HTTPS_SERVER_SSL_CERT"

    cecho 'Saving Git HTTPS Server SSL key...' "info"
    save_secret_string "git-https-server-ssl-key" \
        "$CLUSTER_NAME Git HTTPS Server SSL key" \
        "$GIT_HTTPS_SERVER_SSL_KEY"

    cecho "Saving Git HTTPS Server credentials secret..." "info"
    save_secret_string "git-https-server-credentials" \
        "$CLUSTER_NAME Git HTTPS Server credentials" \
        "{\"username\": \"$GIT_HTTPS_SERVER_USERNAME\", \"password\": \"$GIT_HTTPS_SERVER_PASSWORD\"}"
fi