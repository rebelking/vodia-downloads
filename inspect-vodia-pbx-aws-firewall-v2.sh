#!/usr/bin/env bash
# Inspect one PBX's AWS security groups using either existing AWS credentials
# or a temporary session of the customer's VodiaMCPDeploymentRole.
set -Eeuo pipefail

usage() {
  echo "Usage: bash $0 --account ACCOUNT --region REGION --instance INSTANCE [--assume-deployment-role]" >&2
  exit 2
}

ACCOUNT='' REGION='' INSTANCE='' ASSUME_ROLE=0
while (($#)); do
  case "$1" in
    --account) (($# >= 2)) || usage; ACCOUNT="$2"; shift 2 ;;
    --region) (($# >= 2)) || usage; REGION="$2"; shift 2 ;;
    --instance) (($# >= 2)) || usage; INSTANCE="$2"; shift 2 ;;
    --assume-deployment-role) ASSUME_ROLE=1; shift ;;
    *) usage ;;
  esac
done
[[ "$ACCOUNT" =~ ^[0-9]{12}$ && "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ && "$INSTANCE" =~ ^i-[0-9a-f]{8,17}$ ]] || usage
command -v aws >/dev/null || { echo 'AWS CLI is required' >&2; exit 1; }

if ((ASSUME_ROLE)); then
  [[ -t 0 ]] || { echo 'An interactive terminal is required for the External ID prompt.' >&2; exit 1; }
  read -r -s -p 'Vodia deployment role External ID (input hidden): ' EXTERNAL_ID
  echo >&2
  [[ -n "$EXTERNAL_ID" ]] || { echo 'External ID must not be empty.' >&2; exit 1; }
  # The temporary credentials are held only in this script's process and its AWS CLI children.
  ROLE_CREDS="$(aws sts assume-role \
    --role-arn "arn:aws:iam::$ACCOUNT:role/VodiaMCPDeploymentRole" \
    --role-session-name vodia-firewall-inspect \
    --external-id "$EXTERNAL_ID" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)"
  unset EXTERNAL_ID
  IFS=$'\t' read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<< "$ROLE_CREDS"
  unset ROLE_CREDS
  [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" && -n "${AWS_SESSION_TOKEN:-}" ]] || {
    echo 'AssumeRole returned incomplete credentials.' >&2; exit 1;
  }
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
fi

CALLER_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
[[ "$CALLER_ACCOUNT" == "$ACCOUNT" ]] || { echo "Wrong AWS account: $CALLER_ACCOUNT (expected $ACCOUNT)" >&2; exit 1; }
if ((ASSUME_ROLE)); then
  [[ "$CALLER_ARN" == "arn:aws:sts::$ACCOUNT:assumed-role/VodiaMCPDeploymentRole/"* ]] || {
    echo 'The assumed identity was not VodiaMCPDeploymentRole.' >&2; exit 1;
  }
fi
echo "AWS identity: $CALLER_ARN"
if [[ "$CALLER_ARN" == *':assumed-role/VodiaMCPChimeRole/'* ]]; then
  echo 'This shell is using the Chime role. Re-run with --assume-deployment-role or use an authorized CloudShell session.' >&2
  exit 1
fi

echo "Target instance: $INSTANCE in $REGION (AWS account $ACCOUNT)"
aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,VpcId]' --output table

ATTACHED_GROUP_IDS="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query 'Reservations[].Instances[].NetworkInterfaces[].Groups[].GroupId' --output text)"
[[ -n "$ATTACHED_GROUP_IDS" && "$ATTACHED_GROUP_IDS" != 'None' ]] || { echo 'No attached security group found.' >&2; exit 1; }

for GROUP in $ATTACHED_GROUP_IDS; do
  [[ "$GROUP" =~ ^sg-[0-9a-f]{8,17}$ ]] || { echo "Unexpected security group ID: $GROUP" >&2; exit 1; }
  echo "Security group: $GROUP"
  # DescribeSecurityGroups includes both ingress and egress permissions.
  # No separate DescribeSecurityGroupRules permission is required.
  aws ec2 describe-security-groups --region "$REGION" --group-ids "$GROUP" \
    --query 'SecurityGroups[].[GroupId,GroupName,VpcId,Description,IpPermissions,IpPermissionsEgress]' \
    --output json
done
echo 'READ-ONLY: no AWS or operating-system firewall settings changed.'
