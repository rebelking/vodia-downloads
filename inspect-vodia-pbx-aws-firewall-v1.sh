#!/usr/bin/env bash
# Read-only inventory of the AWS security groups attached to ONE EC2 instance.
# Run in the customer's AWS CloudShell with permission to describe EC2 resources.
set -Eeuo pipefail

usage() {
  echo "Usage: bash $0 --account 963966408518 --region us-west-1 --instance i-03e1cc4e6bcf8f61d" >&2
  exit 2
}

ACCOUNT='' REGION='' INSTANCE=''
while (($#)); do
  case "$1" in
    --account) (($# >= 2)) || usage; ACCOUNT="$2"; shift 2 ;;
    --region) (($# >= 2)) || usage; REGION="$2"; shift 2 ;;
    --instance) (($# >= 2)) || usage; INSTANCE="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[[ "$ACCOUNT" =~ ^[0-9]{12}$ && "$REGION" =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ && "$INSTANCE" =~ ^i-[0-9a-f]{8,17}$ ]] || usage
command -v aws >/dev/null || { echo 'AWS CLI is required' >&2; exit 1; }

CALLER="$(aws sts get-caller-identity --query Account --output text)"
[[ "$CALLER" == "$ACCOUNT" ]] || { echo "Wrong AWS account: $CALLER (expected $ACCOUNT)" >&2; exit 1; }

echo "Target instance: $INSTANCE in $REGION (AWS account $ACCOUNT)"
aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,VpcId]' --output table

GROUPS="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE" \
  --query 'Reservations[].Instances[].NetworkInterfaces[].Groups[].GroupId' --output text)"
[[ -n "$GROUPS" && "$GROUPS" != 'None' ]] || { echo 'No attached security group found' >&2; exit 1; }

for GROUP in $GROUPS; do
  [[ "$GROUP" =~ ^sg-[0-9a-f]{8,17}$ ]] || { echo "Unexpected security group ID: $GROUP" >&2; exit 1; }
  echo "Security group: $GROUP"
  aws ec2 describe-security-groups --region "$REGION" --group-ids "$GROUP" \
    --query 'SecurityGroups[].[GroupId,GroupName,VpcId,Description]' --output table
  echo 'Network interfaces using this group (changes affect ALL of them):'
  aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=group-id,Values=$GROUP" \
    --query 'NetworkInterfaces[].[NetworkInterfaceId,Attachment.InstanceId,Status]' --output table
  echo 'Current inbound and outbound rules:'
  aws ec2 describe-security-group-rules --region "$REGION" \
    --filters "Name=group-id,Values=$GROUP" \
    --query 'SecurityGroupRules[].[SecurityGroupRuleId,IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4,CidrIpv6,ReferencedGroupInfo.GroupId,Description]' \
    --output table
done
echo 'READ-ONLY: no security group or operating-system firewall settings changed.'
