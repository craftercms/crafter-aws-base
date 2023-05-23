#!/bin/bash

set -e

PRGDIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)

. "$PRGDIR/../set-config.sh"

KUBER_CONFIG_HOME="$CLUSTER_HOME/kubernetes"
CURRENT_DIR=$(pwd)
resources_stack=$(aws cloudformation describe-stacks --stack-name ${CLUSTER_NAME}-resources | jq '.Stacks[0]')

if [ -z "$CRAFTER_MANAGEMENT_TOKEN" ]; then
    CRAFTER_MANAGEMENT_TOKEN=$(gen_random_pswd_only_alphanumeric 40)
    update_var 'CRAFTER_MANAGEMENT_TOKEN' "$CRAFTER_MANAGEMENT_TOKEN"

    cecho "Crafter management token generated: $CRAFTER_MANAGEMENT_TOKEN" "info"
fi

if [ -z "$CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX" ]; then
    CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX=$(gen_random_pswd_only_alphanumeric_no_uppercase 10)
    update_var 'CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX' "$CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX"

    cecho "CloudFront secret header name suffix generated: $CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX" "info"
fi

if [ -z "$CLOUDFRONT_SECRET_HEADER_VALUE" ]; then
    CLOUDFRONT_SECRET_HEADER_VALUE=$(gen_random_pswd_only_alphanumeric_no_uppercase 40)
    update_var 'CLOUDFRONT_SECRET_HEADER_VALUE' "$CLOUDFRONT_SECRET_HEADER_VALUE"

    cecho "CloudFront secret header value generated: $CLOUDFRONT_SECRET_HEADER_VALUE" "info"
fi

cd $KUBER_CONFIG_HOME

cecho "Initializing Kubernetes config files for cluster $CLUSTER_NAME..." "info"

find . -type f ! -name init-config.sh -exec sed -i "s/{{craftercms_namespace}}/$CRAFTERCMS_NAMESPACE/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{crafter_management_token}}/${CRAFTER_MANAGEMENT_TOKEN}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{cloudfront_secret_header_name_suffix}}/${CLOUDFRONT_SECRET_HEADER_NAME_SUFFIX}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{cloudfront_secret_header_value}}/${CLOUDFRONT_SECRET_HEADER_VALUE}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s~{{gitops_repo_url}}~${GITOPS_REPO_URL}~g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{gitops_repo_revision}}/${GITOPS_REPO_REVISION}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s~{{mail_host}}~${MAIL_HOST}~g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{mail_port}}/${MAIL_PORT}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s~{{mail_address}}~${MAIL_ADDRESS}~g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{mail_smtp_auth}}/${MAIL_SMTP_AUTH}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{mail_smtp_starttls}}/${MAIL_SMTP_STARTTLS}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s~{{alarms_email_address}}~${ALARMS_EMAIL_ADDRESS}~g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s/{{argocd_project}}/${ARGOCD_PROJECT}/g" {} \;
find . -type f ! -name init-config.sh -exec sed -i "s~{{delivery_domain_name}}~${DELIVERY_DOMAIN_NAME}~g" {} \;

cd $CURRENT_DIR