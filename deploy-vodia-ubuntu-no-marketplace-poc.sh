#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Use from AWS CloudShell or another AWS CLI session in YOUR AWS account:
  AWS_REGION=us-east-2 SUBNET_ID=subnet-... SECURITY_GROUP_ID=sg-... \
  KEY_NAME=your-existing-key INSTANCE_NAME=vodia-manual-poc \
  bash deploy-vodia-ubuntu.sh --plan

Review the account, region, selected Ubuntu AMI, key, subnet, SG and estimated EC2 resources.
Then run the same environment variables with --apply to launch and install Vodia.

Optional: INSTANCE_TYPE=t3.medium (default t3.medium), DISK_GIB=30 (min 20).
Apply also requires INSTALLER_SHA256 from the plan output.
This launcher makes no Marketplace purchase. It does create billable EC2/EBS resources on --apply.
The official Vodia installer may require a Vodia license after installation.
HELP
}
MODE=${1:---plan}
[[ "$MODE" == --plan || "$MODE" == --apply ]] || { usage; exit 2; }
for binary in aws python3; do command -v "$binary" >/dev/null || { echo "Missing $binary" >&2; exit 2; }; done
for variable in AWS_REGION SUBNET_ID SECURITY_GROUP_ID KEY_NAME INSTANCE_NAME; do
  [[ -n "${!variable:-}" ]] || { echo "Set $variable first." >&2; usage; exit 2; }
done
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.medium}
DISK_GIB=${DISK_GIB:-30}
[[ $DISK_GIB =~ ^[0-9]+$ && $DISK_GIB -ge 20 && $DISK_GIB -le 1024 ]] || { echo 'DISK_GIB must be 20-1024' >&2; exit 2; }
[[ $AWS_REGION =~ ^[a-z]{2}(-[a-z]+)+-[0-9]+$ && $SUBNET_ID =~ ^subnet-[a-f0-9]{8,17}$ && $SECURITY_GROUP_ID =~ ^sg-[a-f0-9]{8,17}$ ]] || { echo 'Invalid region, subnet or SG.' >&2; exit 2; }
[[ $KEY_NAME =~ ^[A-Za-z0-9_.@+-]{1,255}$ && $INSTANCE_NAME =~ ^[A-Za-z0-9_.-]{1,120}$ && $INSTANCE_TYPE =~ ^[a-z][a-z0-9]*[0-9][a-z0-9]*\.[a-z0-9]+$ ]] || { echo 'Invalid key, name or instance type.' >&2; exit 2; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ $ACCOUNT =~ ^[0-9]{12}$ ]] || { echo 'AWS identity unavailable' >&2; exit 1; }
AMI=$(aws ec2 describe-images --region "$AWS_REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' 'Name=state,Values=available' \
  --query 'reverse(sort_by(Images,&CreationDate))[0].ImageId' --output text)
[[ $AMI =~ ^ami-[a-f0-9]{8,17}$ ]] || { echo 'Canonical Ubuntu 24.04 AMI not found in region' >&2; exit 1; }
AMI_INFO=$(aws ec2 describe-images --region "$AWS_REGION" --image-ids "$AMI" --output json)
ROOT_DEVICE=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Images"][0]["RootDeviceName"])' <<< "$AMI_INFO")
[[ $ROOT_DEVICE == /dev/* ]] || { echo "AMI root device unavailable" >&2; exit 1; }
python3 -c 'import json,sys; i=json.load(sys.stdin)["Images"][0]; assert i["OwnerId"]=="099720109477" and i["Architecture"]=="x86_64" and i["VirtualizationType"]=="hvm" and not i.get("ProductCodes"), "AMI is not plain Canonical Ubuntu"' <<< "$AMI_INFO"
SUBNET_INFO=$(aws ec2 describe-subnets --region "$AWS_REGION" --subnet-ids "$SUBNET_ID" --output json)
SG_INFO=$(aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$SECURITY_GROUP_ID" --output json)
aws ec2 describe-key-pairs --region "$AWS_REGION" --key-names "$KEY_NAME" --query 'KeyPairs[0].KeyName' --output text >/dev/null
aws ec2 describe-instance-types --region "$AWS_REGION" --instance-types "$INSTANCE_TYPE" \
  --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' --output json | python3 -c 'import json,sys; assert "x86_64" in json.load(sys.stdin), "Instance type does not support x86_64"'
export SUBNET_INFO SG_INFO
python3 - <<'PY'
import json,os
s=json.loads(os.environ['SUBNET_INFO'])['Subnets'][0]
g=json.loads(os.environ['SG_INFO'])['SecurityGroups'][0]
if s['VpcId']!=g['VpcId']:raise SystemExit('Subnet and SG are in different VPCs.')
if s.get('State')!='available':raise SystemExit('Subnet is not available.')
if not s.get('MapPublicIpOnLaunch'):print('INFO: Subnet does not assign public IP by default; this launch explicitly requests one.')
if s.get('AvailableIpAddressCount',0)<1:raise SystemExit('Subnet has no available IPs.')
ports={22:False,80:False,443:False}
for p in g.get('IpPermissions',[]):
 if p.get('IpProtocol') not in ('tcp','-1'):continue
 for port in ports:
  if p.get('IpProtocol')=='-1' or p.get('FromPort',65536)<=port<=p.get('ToPort',-1):
   ports[port]|=bool(p.get('IpRanges'))
print('VPC:',s['VpcId'],'Subnet AZ:',s['AvailabilityZone'])
print('Inbound TCP ports 22/80/443:',ports)
if not all(ports.values()):raise SystemExit('Security group must permit IPv4 TCP 22, 80 and 443 before launch (limit SSH 22 to your admin IP).')
print('Check Vodia SIP/RTP ports separately before testing calls.')
PY

cat <<SUMMARY
Account: $ACCOUNT
Region: $AWS_REGION
Image: $AMI (Canonical Ubuntu 24.04 amd64, no Marketplace product code)
Instance type: $INSTANCE_TYPE
Subnet: $SUBNET_ID
Security group: $SECURITY_GROUP_ID
SSH key: $KEY_NAME
Name: $INSTANCE_NAME
Root EBS: ${DISK_GIB} GiB encrypted gp3 ($ROOT_DEVICE), delete on termination
Public IP: requested
Software installation: official https://cdn.vodia.net/builds/install-linux.sh
SUMMARY
INSTALLER_STAGE=$(mktemp -d)
trap 'rm -rf "$INSTALLER_STAGE"' EXIT
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 \
  https://cdn.vodia.net/builds/install-linux.sh -o "$INSTALLER_STAGE/install-linux.sh"
DOWNLOADED_SHA256=$(sha256sum "$INSTALLER_STAGE/install-linux.sh" | cut -d' ' -f1)
[[ $DOWNLOADED_SHA256 =~ ^[a-f0-9]{64}$ ]] || { echo 'Could not hash Vodia installer.' >&2; exit 1; }
echo "Official installer SHA256: $DOWNLOADED_SHA256"
if [[ "$MODE" == --plan ]]; then
  echo 'PLAN ONLY: no AWS resources created. Review the official installer and rerun --apply with INSTALLER_SHA256 set to this value.'
  exit 0
fi
[[ ${INSTALLER_SHA256:-} == "$DOWNLOADED_SHA256" ]] || { echo 'Installer hash changed or INSTALLER_SHA256 was not supplied. Review and plan again.' >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE" "$INSTALLER_STAGE"' EXIT
cat > "$STAGE/user-data.sh" <<'USERDATA'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
exec > /var/log/vodia-install.log 2>&1
trap 'echo "Vodia install failed at line $LINENO" >&2' ERR
if [[ -e /usr/local/pbx/pbxctrl ]]; then
  echo 'PBX already installed; refusing to run installer again.' >&2
  exit 1
fi
apt-get update
apt-get install -y ca-certificates curl
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
  https://cdn.vodia.net/builds/install-linux.sh -o /root/install-vodia-linux.sh
chmod 0700 /root/install-vodia-linux.sh
sha256sum -c /root/vodia-installer.sha256
bash /root/install-vodia-linux.sh
systemctl is-active --quiet pbx
printf 'Vodia installation complete at %s\n' "$(date -u +%FT%TZ)"
USERDATA
chmod 0600 "$STAGE/user-data.sh"
# Embed only a digest; no credential is passed in EC2 user data.
# The digest is placed into user data for verification on the instance.
python3 - "$STAGE/user-data.sh" "$INSTALLER_SHA256" <<'PYHASH'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); marker='sha256sum -c /root/vodia-installer.sha256'
s=s.replace(marker, 'echo "'+sys.argv[2]+'  /root/install-vodia-linux.sh" | sha256sum -c -')
p.write_text(s)
PYHASH
cat > "$STAGE/storage.json" <<STORAGE
[{"DeviceName":"$ROOT_DEVICE","Ebs":{"VolumeSize":$DISK_GIB,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]
STORAGE
cat > "$STAGE/network.json" <<NETWORK
[{"DeviceIndex":0,"SubnetId":"$SUBNET_ID","Groups":["$SECURITY_GROUP_ID"],"AssociatePublicIpAddress":true}]
NETWORK
cat > "$STAGE/tags.json" <<TAGS
[{"ResourceType":"instance","Tags":[{"Key":"Name","Value":"$INSTANCE_NAME"},{"Key":"ManagedBy","Value":"VodiaMCP"},{"Key":"VodiaDeploymentMode","Value":"ManualInstallPOC"}]},{"ResourceType":"volume","Tags":[{"Key":"Name","Value":"$INSTANCE_NAME-root"},{"Key":"ManagedBy","Value":"VodiaMCP"}]}]
TAGS
INSTANCE_ID=$(aws ec2 run-instances --region "$AWS_REGION" --image-id "$AMI" \
  --instance-type "$INSTANCE_TYPE" --key-name "$KEY_NAME" --count 1 \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
  --block-device-mappings "file://$STAGE/storage.json" \
  --network-interfaces "file://$STAGE/network.json" \
  --tag-specifications "file://$STAGE/tags.json" \
  --user-data "file://$STAGE/user-data.sh" \
  --query 'Instances[0].InstanceId' --output text)
[[ $INSTANCE_ID =~ ^i-[a-f0-9]{8,17}$ ]] || { echo 'AWS returned an unexpected launch result; inspect EC2 before retrying.' >&2; exit 1; }
echo "LAUNCHED: $INSTANCE_ID in $AWS_REGION. EC2/EBS charges now apply."
echo "Check state: aws ec2 describe-instances --region $AWS_REGION --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].[State.Name,PublicIpAddress]' --output text"
echo 'The official Vodia installer runs through EC2 user data. Inspect /var/log/vodia-install.log on the instance as root for the installer result and initial credentials.'
echo 'Change the default PBX password before enabling API access. A Vodia license is a separate requirement.'
