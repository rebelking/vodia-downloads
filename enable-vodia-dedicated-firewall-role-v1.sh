#!/usr/bin/env bash
# Run in customer AWS CloudShell as an IAM administrator.
set -Eeuo pipefail
MODE=${1:---dry-run}
[[ $MODE == --dry-run || $MODE == --apply ]] || { echo 'Usage: bash script [--dry-run|--apply]' >&2; exit 2; }
ROLE=VodiaMCPDeploymentRole
POLICY=VodiaMCPDeploymentRolePolicy
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ $ACCOUNT =~ ^[0-9]{12}$ ]] || { echo 'AWS account unavailable' >&2; exit 1; }
[[ $ACCOUNT == 963966408518 ]] || { echo "Wrong AWS account: $ACCOUNT (expected 963966408518)" >&2; exit 1; }
echo "AWS account: $ACCOUNT; role: $ROLE; policy: $POLICY"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
chmod 700 "$WORK"
aws iam get-role-policy --role-name "$ROLE" --policy-name "$POLICY" --output json > "$WORK/current.json"
python3 - "$WORK/current.json" "$WORK/updated.json" "$ACCOUNT" <<'PY'
import json,sys
from pathlib import Path
current=Path(sys.argv[1]); target=Path(sys.argv[2]); account=sys.argv[3]
data=json.loads(current.read_text()); p=data['PolicyDocument']
assert data['RoleName']=='VodiaMCPDeploymentRole' and data['PolicyName']=='VodiaMCPDeploymentRolePolicy'
assert p['Version']=='2012-10-17' and isinstance(p['Statement'],list)
statements=[
 {'Sid':'VodiaFirewallCreateTaggedGroup','Effect':'Allow','Action':'ec2:CreateSecurityGroup',
  'Resource':f'arn:aws:ec2:*:{account}:security-group/*',
  'Condition':{'StringEquals':{'aws:RequestTag/ManagedBy':'VodiaMCP'}}},
 {'Sid':'VodiaFirewallCreateInVpc','Effect':'Allow','Action':'ec2:CreateSecurityGroup',
  'Resource':f'arn:aws:ec2:*:{account}:vpc/*'},
 {'Sid':'VodiaFirewallRulesAndCleanup','Effect':'Allow',
  'Action':['ec2:AuthorizeSecurityGroupIngress','ec2:DeleteSecurityGroup'],
  'Resource':f'arn:aws:ec2:*:{account}:security-group/*',
  'Condition':{'StringEquals':{'ec2:ResourceTag/ManagedBy':'VodiaMCP'}}}
]
by_sid={x.get('Sid'):x for x in p['Statement']}
for statement in statements:
  prior=by_sid.get(statement['Sid'])
  if prior and prior!=statement: raise SystemExit('ERROR: conflicting existing IAM Sid '+statement['Sid'])
  if not prior: p['Statement'].append(statement)
target.write_text(json.dumps(p,indent=2)+'\n')
print('New permissions: create a tagged security group in a VPC; add ingress and clean up Vodia-tagged groups.')
print('All existing statements preserved. Current statement count:',len(data['PolicyDocument']['Statement']))
PY
if [[ $MODE == --dry-run ]]; then
  echo 'DRY RUN: no IAM changes made. Run --apply from this account when ready.'
  exit 0
fi
BACKUP="$HOME/vodia-deployment-role-policy-before-firewall-$(date -u +%Y%m%d-%H%M%S).json"
install -m 600 "$WORK/current.json" "$BACKUP"
aws iam put-role-policy --role-name "$ROLE" --policy-name "$POLICY" --policy-document "file://$WORK/updated.json"
aws iam get-role-policy --role-name "$ROLE" --policy-name "$POLICY" --query 'PolicyDocument.Statement[].Sid' --output text
echo "PASS: deployment role permissions updated; IAM backup: $BACKUP"
