# Crafter Kubernetes Automation Scripts
This project provides scripts to setup an EKS Kubernetes cluster with Crafter CMS. In specific, these scripts:
1. Create an EKS Kubernetes cluster in a AWS region, with it's own VPC.
2. Provision necessary AWS resources external to the cluster (ES domain, AWS Secrets, IAM users, etc.).
3. Install ArgoCD for later deployment of the Crafter CMS Kubernetes resources.

## Pre-requisites

1. Install AWS CLI (https://aws.amazon.com/cli/)
2. Install the Crafter Cloud Management Tools:  https://github.com/craftersoftware/cloud-management-tools.git
5. Create a fork of this repository for the client (e.g. `crafter-aws-tpci`)

## Run the account setup script

**NOTE:** This should only be run once, after the AWS account has been created. Make sure you also have setup an AWS profile in your machine for an IAM user with administrator privileges. 

1. Under `./scripts/account`, copy the `config.sh.off` file to `config.ACC_ID.sh`, replacing `ACC_ID` with a string
representing an identifier for the account. For example, if the client has a separate account for QA resources, then you can name 
the file `config.qa.sh` (`ACC_ID` can be anything you like as long as it's different between accounts). If there's a single account, 
you can leave `ENV` empty (`config.sh`).
2. Open the config file and fill the properties appropiately. You can leave the ones that are auto-generated empty 
and they will be filled by the scripts automatically.
3. AWS_PROFILE should be the AWS profile used to access the resources of the AWS account of the client.
4. Run `./scripts/account/setup.sh` and follow the instructions. When being asked for the config.sh suffix, provide
the `ACC_ID` string mentioned aboved.
5. Navigate to the CloudFormation tab in the AWS console to ensure that your stack is being spun up.

## Run the regions setup script

**NOTE:** This should only be run once per region.

1. Under `./scripts/regions`, copy the `config.sh.off` file to `config.REGION.sh`, replacing `REGION` with a string
representing an identifier for the REGION. For example, if the client plans to create clusters in us-west-2, then you can name 
the file `config.us-west-2.sh`. If there's a single `REGION`, 
you can leave it empty (`config.sh`).
2. Open the config file and fill the properties appropiately. You can leave the ones that are auto-generated empty 
and they will be filled by the scripts automatically. `ALARMS_SLACK_CHANNEL_HOOK_URL` and `PAGER_DUTY_INTEGRATION_URL` are optional. When Slack is not configured, GuardDuty notifications are sent to `ALARMS_EMAIL_ADDRESS` instead.
3. AWS_PROFILE should be the AWS profile used to access the resources of the AWS account of the client.
4. Run `./scripts/regions/setup.sh` and follow the instructions. When being asked for the config.sh suffix, provide
the `REGION` string mentioned aboved.
5. Navigate to the CloudFormation tab and make sure `REGION` is selected on the AWS console. Ensure that your stack creates successfully.

## Run the Environment Setup Script

**NOTE:** Should only be run once per environment, when creating the first cluster for the config.

1. Under `./scripts/environments`, copy the `config.sh.off` file to `config.ENV.sh`, replacing `ENV` with a string
representing the environment specific resources. For example, if we're provisioning the resources for the Dev environment, 
then name the file `config.dev.sh`. If there's always going to be a single environment, you can leave `ENV` empty (`config.sh`).
2. Open the config.sh file and fill in the properties approriately. 
3. For the CLIENT_ID section, the first 4/5 letters of the client will be used (For example: Crafter would be either Craf or Craft)
4. Run the `./scripts/environments/setup.sh` script and enter the environment's name when prompted.
5. Navigate to the CloudFormation tab in the AWS console to ensure that your stack is being spun up.

## Create blue and green domain names 
1. Navigate to Route-53 in the AWS console and create new domain names for the client. The naming convention is $CLIENT_ID-<blue/green>.net

## Run the Clusters Setup Script

1. Under `./scripts/clusters`, copy the `config.sh.off` file to `config.ENV-(blue|green).sh`, replacing `ENV` with a string
representing the environment of this cluster, and `blue` if it's going to be the main cluster, or `green` if it's cluster that it's going to
be used for testing and will eventually transition to become the `blue` cluster. For example, if this is going to be the Prod `blue` cluster, 
then name the file `config.prod-blue.sh`. If there's always going to be a single environment, you can leave `ENV-(blue|green)` empty (`config.sh`).
2. Open the config.sh file and fill in the properties approriately. You can leave the ones that are auto-generated empty 
and they will be filled by the scripts automatically.
3. For the AWS_AZ sections, the value is $DEFAULT_REGION<a/b/c>
4. For the AWS_BACKUP_REGION, the value is the default region's closest region (us-east-1's DR would be us-east-2) OR the region the client has decided as the backup region in case of disaster recovery.
5. If you don't already have them, request the mail properties from the Cloud Ops lead.
6. `AUTHORING_DOMAIN_NAME` and `DELIVERY_DOMAIN_NAME` are the Route-53 records that point to the future Authoring and Delivery ALBs (you'll create them in a future step). Normally they 
are `ENV-authoring.CLIENT_ID-(blue|green).net` and `ENV-delivery.CLIENT_ID-(blue|green).net`.
6. `ALARMS_SLACK_CHANNEL_HOOK_URL` and `PAGER_DUTY_INTEGRATION_URL` are optional. When Slack is not configured, alarm notifications are sent to `ALARMS_EMAIL_ADDRESS` instead. Leave `PAGER_DUTY_INTEGRATION_URL` empty to skip PagerDuty notifications.
7. Run the `./scripts/clusters/setup.sh` script and enter the environment's name when prompted.

## Internal Delivery load balancer

Leave `DELIVERY_LB_SCHEME` as `internet-facing` unless this cluster's Delivery ALB must stay off the public internet. Set it to `internal` in the cluster config before `scripts/clusters/setup.sh`. Setup renders one delivery ingress with scheme `internal` and the cluster private subnets. Subnets in availability zone IDs `use1-az3`, `usw1-az2`, `apne1-az3`, and `cac1-az3` are omitted because CloudFront VPC origins do not support them.

The VPC origin talks to the ALB with `https-only` on port 443. Before the delivery ingress is synced, request an ACM certificate in the cluster region that covers `DELIVERY_DOMAIN_NAME`. In the cluster copy of `kubernetes/gitops/apps/main/craftercms/delivery-deployment.yaml`, uncomment these annotations and set the certificate ARN:

```yaml
alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS":443}]'
alb.ingress.kubernetes.io/ssl-redirect: '443'
alb.ingress.kubernetes.io/certificate-arn: <acm-certificate-arn>
```

Those three lines are commented out in the template. Without the listener and a certificate that matches `DELIVERY_DOMAIN_NAME`, CloudFront returns 502. After the ALB exists, create the Route 53 alias for `DELIVERY_DOMAIN_NAME` pointing at that internal ALB.

Run the commands below from a shell where the cluster config is loaded, so `CLUSTER_NAME` and `AWS_DEFAULT_REGION` are set. Do not pass a fresh parameter list. Every parameter other than the one being changed stays on `UsePreviousValue=true`. Dropping `BastionAmiId` replaces the bastion. Dropping `DeliveryLBArn` later sets it back to empty and deletes the VPC origin while distributions still use it.

Create the VPC origin. Leave `CloudFrontVpcOriginSecurityGroupId` unchanged. The managed security group does not exist until the origin does.

```bash
DELIVERY_LB_ARN=$(aws elbv2 describe-load-balancers \
  --region "$AWS_DEFAULT_REGION" \
  --names "${CLUSTER_NAME}-delivery" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

params=()
while read -r key; do
  case "$key" in
    DeliveryLBArn)
      params+=(ParameterKey=DeliveryLBArn,ParameterValue="$DELIVERY_LB_ARN")
      ;;
    *)
      params+=(ParameterKey="$key",UsePreviousValue=true)
      ;;
  esac
done < <(aws cloudformation describe-stacks \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources" \
  --query 'Stacks[0].Parameters[].ParameterKey' \
  --output text | tr '\t' '\n')

aws cloudformation update-stack \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources" \
  --use-previous-template \
  --parameters "${params[@]}"

aws cloudformation wait stack-update-complete \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources"
```

Wait until the VPC origin status is `Deployed`:

```bash
ORIGIN_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources" \
  --query "Stacks[0].Outputs[?OutputKey=='DeliveryLBVpcOriginId'].OutputValue" \
  --output text)

aws cloudfront get-vpc-origin \
  --id "$ORIGIN_ID" \
  --query 'VpcOrigin.Status' \
  --output text
```

Then restrict the Delivery frontend security group to the CloudFront VPC origin security group in this VPC. Filter on the VPC, because every VPC with a VPC origin has a group named `CloudFront-VPCOrigins-Service-SG`.

```bash
VPC_ID=$(aws cloudformation describe-stacks \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
  --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue" \
  --output text)

CF_VPC_ORIGIN_SG_ID=$(aws ec2 describe-security-groups \
  --region "$AWS_DEFAULT_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=group-name,Values=CloudFront-VPCOrigins-Service-SG" \
  --query 'SecurityGroups[].GroupId' \
  --output text)

params=()
while read -r key; do
  case "$key" in
    CloudFrontVpcOriginSecurityGroupId)
      params+=(ParameterKey=CloudFrontVpcOriginSecurityGroupId,ParameterValue="$CF_VPC_ORIGIN_SG_ID")
      ;;
    *)
      params+=(ParameterKey="$key",UsePreviousValue=true)
      ;;
  esac
done < <(aws cloudformation describe-stacks \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources" \
  --query 'Stacks[0].Parameters[].ParameterKey' \
  --output text | tr '\t' '\n')

aws cloudformation update-stack \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources" \
  --use-previous-template \
  --parameters "${params[@]}"

aws cloudformation wait stack-update-complete \
  --region "$AWS_DEFAULT_REGION" \
  --stack-name "${CLUSTER_NAME}-resources"
```

Re-run `scripts/clusters/kubernetes/init-config-files.sh` so the authoring deployment receives `DELIVERY_LB_VPC_ORIGIN_ID` from the stack output, and sync authoring before creating sites.

Do not change `DELIVERY_LB_SCHEME` after the Delivery ALB exists. Both clusters in a blue and green pair use the same scheme.

## Add the Crafter license (required before CrafterCMS)

**Do this after cluster setup and before you sync the `craftercms` Argo CD app.** Argo CD cannot build the CrafterCMS manifests without this file.

1. Obtain the Crafter Enterprise license from Cloud Ops / licensing (non-production license for dev/QA clusters; production license for prod clusters). The file is usually delivered as a zip renamed to `.lic` for GitHub upload — **commit the file as-is** (it remains a zip archive named `crafter.lic`; do not unzip it).
2. Copy it to:

   `./clusters/{AWS_REGION}/{CLUSTER_NAME}/kubernetes/gitops/apps/main/craftercms/resources/common/secrets/crafter.lic`

3. Commit and push the cluster config to the GitOps repository **before** continuing with the Argo CD steps below.

If `crafter.lic` is missing, syncing `craftercms` fails with a kustomize error such as `crafter.lic: no such file or directory`.

## Preview token secret (required before CrafterCMS)

`scripts/clusters/setup.sh` runs `aws-infra/resources/create-secrets.sh`. That script creates Secrets Manager secret `$CLUSTER_NAME/preview-token-key-salt` with JSON keys `key` and `salt`, the same way it creates `config-encryption-key-salt` and `system-encryption-key-salt`. Leave `PREVIEW_TOKEN_KEY` and `PREVIEW_TOKEN_SALT` empty to auto-generate. Authoring and Delivery read the same secret.

On a cluster that already ran setup, run `scripts/clusters/aws-infra/resources/create-secrets.sh` again before syncing `craftercms`. The Authoring and Delivery Tomcat containers reference Kubernetes secret `preview-token-key-salt` with a required `secretKeyRef` (`optional` is not set). Those pods do not start until External Secrets has synced the secret.

## Install Crafter CMS from ArgoCD

- Make sure you commit and push the cluster config back up to the master repository before continuing with this section (including `crafter.lic` as described above).

### Stage 1 — Bootstrap Argo CD and deploy addons

The `install-argocd.sh` script (run during cluster setup) already installs Argo CD via kustomize and prints the initial admin password.

After the script completes:

1. Register your GitOps repository:
   - SSH: `argocd repo add GITOPS_REPO_URL --ssh-private-key-path /path/to/key --name crafter-aws-CLIENT_NAME`
   - HTTPS: `argocd repo add GITOPS_REPO_URL --username GITOPS_USER --password GITOPS_PASS --name crafter-aws-CLIENT_NAME`
2. Create and sync the bootstrap app (this creates the child Argo CD apps):
   ```
   argocd app create crafter-cloud-apps \
     --project default \
     --repo GITOPS_REPO_URL \
     --revision master \
     --path clusters/CLUSTER_REGION/CLUSTER_NAME/kubernetes/gitops/apps/bootstrap \
     --dest-server https://kubernetes.default.svc
   argocd app sync crafter-cloud-apps --prune
   ```
3. Sync the `aws-load-balancer-controller` app explicitly (it is not auto-synced by bootstrap app creation):
   - `argocd app sync aws-load-balancer-controller --prune`
4. Wait for the `aws-load-balancer-controller` app to be healthy:
   - `argocd app wait aws-load-balancer-controller --health`

### Stage 2 — Access Argo CD (port-forward by default)

By default, Argo CD is installed with a `ClusterIP` service. Use **kubectl port-forward** from a machine that has cluster access (your laptop with `kubectl` configured, or a bastion with kubeconfig):

```bash
kubectl port-forward svc/argocd-server -n argocd 18080:443
```

Then open `https://localhost:18080` in your browser (ignore the certificate warning).

Login with username `admin`. The password is printed when `install-argocd.sh` completes, stored in `scripts/clusters/config.*.sh`, or in AWS Secrets Manager as `CLUSTER_NAME/argocd-credentials`.

#### Optional — Argo CD NLB (only when port-forward is not practical)

Enable the NLB patch **only** if you cannot use port-forward — for example, when installing exclusively from a bastion host with no local browser, or when multiple operators need a stable URL without keeping a port-forward session open. The NLB adds ongoing cost; for dev clusters, port-forward is usually sufficient. Do not enable the NLB and ALB options together.

Once the AWS Load Balancer Controller is healthy:

```
./scripts/clusters/kubernetes/enable-argocd-nlb.sh
```

You can then get the ArgoCD hostname:

```
kubectl -n argocd get svc argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Open `https://ARGOCD_DOMAIN` in your browser (ignore the certificate warning).

#### Optional — Argo CD ALB (custom domain + ACM certificate)

Prefer the ALB when you want a trusted HTTPS hostname (e.g. `https://argocd.example.com`) with an ACM certificate. This matches the Authoring ingress pattern: TLS terminates at the ALB and Argo CD runs with `server.insecure`. Do not enable the ALB and NLB options together.

Once the AWS Load Balancer Controller is healthy:

```
./scripts/clusters/kubernetes/enable-argocd-alb.sh
```

Get the ALB hostname:

```
kubectl -n argocd get ingress argocd-server-ingress -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Initially the ALB serves HTTP only. After the ACM certificate is issued, uncomment the `listen-ports` / `ssl-redirect` / `certificate-arn` annotations in `kubernetes/gitops/argocd/ingress-alb.yaml`, set the certificate ARN, re-apply the overlay, and point your Route 53 record at the ALB hostname.

### Stage 3 — Deploy the rest of the apps and CrafterCMS

After login to the ArgoCD UI, you can now install the rest of the apps. 

1. Go through each app that's in `OutOfSync` state and `Sync` it, starting with the `storage-addons` app. Leave the `craftercms` app last
2. Some apps might fail syncing. For those you might need to select `Server-side Apply` under the `Sync Options`.
3. After the other apps have been synced, sync the `craftercms` app (requires `crafter.lic` to already be in Git — see [Add the Crafter license](#add-the-crafter-license-required-before-craftercms)).
4. Wait for the `authoring` and `delivery` pods to become ready (`kubectl -n craftercms get pods`)
5. Get the Authoring LB from `k9s` (by entering `:ingress`), or by running `kubectl -n craftercms get ingress` 
6. Finally enter `http://AUTHORING_LB/studio` in your browser, Studio should appear. You should be able to login 
with `admin/admin` (after creating the Authoring Route-53 record and setting the SSL certificate you should be able to access Authoring through `https://AUTHORING_DOMAIN_NAME/studio`).

That's it! Crafter CMS is up and running in a Kubernetes cluster. Remember to configure the Authoring ingress at
`./clusters/{CLUSTER_NAME}/kubernetes/gitops/apps/craftercms/authoring-deployment.yaml` with and SSL certificate 
in order to allow HTTPS access.

## Requesting Certificates for the new environment

1. Navigate to the AWS console's Certificate Manager
2. Request new Certificate
3. Enter the domain name (`*.craftercloud.io`) (`*.$CLIENT_ID-blue.net`) (`*.$CLIENT_ID-green.net`) - If the client provides their own DNS name for Authoring and Delivery, use that instead of `*.craftercloud.io`
4. Click request
5. Copy the CNAME and CNAME VALUES and place them in the managed services spreadsheet.

## Adding the SSL certificates

1. Navigate to `/clusters/${cluster name}/kubernetes/gitops/apps/main/craftercms/authoring-deployment.yaml`
2. Uncomment the lines that say to uncomment after generating the SSL cert and validating it (15-17)
3. In the ARN section, paste the ARN cert in.
4. Add/Commit/Push/Merge the changes back into the main repository
5. Navigate back to the ArgoCD Application and click the "Refresh" button nuder the craftercms Application once the changes have been merged.
6. After the refresh, Synchronize. This will spin up the authoring and delivery pods
7. Search for the ingress pods in k9s and copy the Addresses for both the authoring and delivery ingresses. Paste them into the Managed Services Spreadsheet.

## Adding new DNS records
1. Navigate to the Route-53 console in the AWS console and create a new record under the Public hosted zone. Modify the Record type to CNAME.
2. In the sub domain section, add ENV-authoring, where ENV is the environment of the cluster. If it's `.craftercloud.io`, it should be `ENV-authoring-CLIENT_ID.craftercloud.io`
3. Repeat the same for Delivery. 

## Creating temporary site and publishing
1. Navigate to studio
2. Create a new empty site
3. Publish the home page

## OpenSearch backup and restore

Manual S3 snapshots before an OpenSearch upgrade. Copy
`scripts/clusters/opensearch-backup-restore.sh` to
`/opt/crafter/scripts/opensearch-backup-restore.sh` on the cluster bastion
and run `backup` / `restore` there with `curl`. CloudFormation does not
install that file. Do not run those commands from a laptop.
The snapshot bucket and IAM role live in the account stack `crafter-account-resources`
(`{CLIENT_ID}-crafter-opensearch-manual-snapshots`). See [docs/opensearch-backup-restore.md](docs/opensearch-backup-restore.md)
and `scripts/clusters/opensearch-backup-restore.sh`.