#!/usr/bin/env bash
# One-file Vodia MCP v0.14.9.82 Chime customer-role update.
# Contains the patcher, guarded installer, and suggested Chime policy.
set -Eeuo pipefail

MODE="${1:---explain}"
case "$MODE" in
  --explain|--dry-run|--apply|--show-policy) ;;
  *) echo "Usage: bash $0 [--explain | --dry-run | --show-policy | --apply]" >&2; exit 2 ;;
esac

explain() {
  cat <<'EXPLANATION'
Vodia MCP v0.14.9.82: Chime calls through the customer deployment role

Current flow: MCP host VodiaMCPChimeRole -> STS AssumeRole -> customer
VodiaMCPDeploymentRole. The existing Chime SDK code starts its clients with
host default credentials, so Chime operations may run under the host role.

This update routes every Chime tool through the connected customer's assumed
VodiaMCPDeploymentRole, checks STS GetCallerIdentity against the selected role
and account, rejects host fallback, and prevents a plan created for one
customer from being applied in another customer's account. It backs up the
four affected MCP files and restores them if restart/health verification fails.

The script carries all its patch files; it does not need to download anything.
It does NOT change IAM permissions, create Chime resources, buy Marketplace
products, alter subscriptions, or deploy a PBX. Attach the included Chime
permissions to VodiaMCPDeploymentRole through your authorized AWS process.

The earlier license-manager:ListReceivedLicenses error identified the caller
as assumed-role/VodiaMCPDeploymentRole. This Chime routing change does NOT
resolve that separate License Manager permission or service-role issue.

  bash this-file.sh --explain       Show this explanation; no changes.
  bash this-file.sh --show-policy   Print the suggested customer-role IAM policy.
  sudo bash this-file.sh --dry-run  Stage and validate for the live MCP; no changes.
  sudo bash this-file.sh --apply    Back up files, install, restart and health check.
EXPLANATION
}

if [[ "$MODE" == --explain ]]; then explain; exit 0; fi

BUNDLE_TMP="$(mktemp -d)"
trap 'rm -rf "$BUNDLE_TMP"' EXIT
cat >"$BUNDLE_TMP/patch-vodia-mcp-chime-deployment-credentials-v82.py" <<'PATCH_PY_V82'
#!/usr/bin/env python3
"""Stage a guarded patch of the Vodia MCP Chime credential path.

Usage: patch-vodia-mcp-chime-deployment-credentials-v82.py APP_DIR
The input directory must contain the live index.js, aws-chime.js, and
aws-marketplace-ec2-deploy-v1.js. Only the supplied directory is modified.
"""
from pathlib import Path
import re
import sys

MARKER = "VODIA_CHIME_CUSTOMER_CREDENTIALS_V82"


def one(source, old, new, label):
    if source.count(old) != 1:
        raise ValueError(f"{label}: expected one anchor; found {source.count(old)}")
    return source.replace(old, new, 1)


def patch_backend(source):
    if MARKER in source:
        return source
    anchor = "export function registerAwsMarketplaceDeployTools(server, ctx) {"
    declaration = f'''// {MARKER}: share the existing authenticated customer connection with Chime.
export let resolveAwsChimeCustomerConnection;

'''
    source = declaration + source
    return one(source, anchor, anchor + '''
  resolveAwsChimeCustomerConnection = (input, extra, roles) => {
    const connection = resolveToolConnection(input, extra, roles);
    if (!connection?.roleArn || !connection?.externalId) {
      throw new Error("AWS_CUSTOMER_CONNECTION_REQUIRED: Select and verify a customer deployment connection.");
    }
    return {
      customerId: connection.customerId || null,
      roleArn: connection.roleArn,
      credentials: customerCredentials(connection.roleArn, connection.externalId)
    };
  };
''', "Marketplace registration")


def patch_chime(source):
    if MARKER in source:
        return source
    source = one(source, 'import { randomUUID } from "node:crypto";',
                 'import { randomUUID } from "node:crypto";\nimport { AsyncLocalStorage } from "node:async_hooks";', "Chime imports")
    anchor = 'function clientOptions(region) { return { region: normalizeRegion(region), maxAttempts: 3 }; }'
    replacement = '''// VODIA_CHIME_CUSTOMER_CREDENTIALS_V82: no AWS client may use the host default chain.
const customerScope = new AsyncLocalStorage();
function chimeContext() {
  const context = customerScope.getStore();
  if (!context?.credentials) throw new Error("AWS_CUSTOMER_CONNECTION_REQUIRED: Chime requires an assumed customer deployment role.");
  return context;
}
export async function runAwsChimeWithCustomerCredentials(connection, action) {
  if (!connection?.credentials || !/^arn:aws:iam::\\d{12}:role\\/(?:[^/]+\\/)*VodiaMCPDeploymentRole$/.test(connection.roleArn || "")) {
    throw new Error("AWS_DEPLOYMENT_ROLE_REQUIRED: Select a connected VodiaMCPDeploymentRole.");
  }
  const expectedAccount = connection.roleArn.split(":")[4];
  const roleName = connection.roleArn.split("/").at(-1);
  const sts = new STSClient({region: DEFAULT_REGION, credentials: connection.credentials});
  const identity = await sts.send(new GetCallerIdentityCommand({}));
  if (identity.Account !== expectedAccount ||
      !String(identity.Arn || "").startsWith(`arn:aws:sts::${expectedAccount}:assumed-role/${roleName}/`)) {
    throw new Error("AWS_ROLE_IDENTITY_MISMATCH: Chime credentials did not assume the selected customer deployment role.");
  }
  return customerScope.run({
    credentials: connection.credentials,
    customerId: connection.customerId || null,
    roleArn: connection.roleArn,
    identity: {account: identity.Account, arn: identity.Arn}
  }, action);
}
function clientOptions(region) { return { region: normalizeRegion(region), maxAttempts: 3, credentials: chimeContext().credentials }; }'''
    source = one(source, anchor, replacement, "Chime client options")
    source = one(source, 'credentialMode:"AWS SDK v3 default provider chain"',
                 'credentialMode:"assumed customer VodiaMCPDeploymentRole"', "Chime config")
    source = re.sub(r'plans\.set\(changeId,\s*\{',
                    'plans.set(changeId, {customerRoleArn:chimeContext().roleArn, customerId:chimeContext().customerId, ', source)
    if source.count('customerRoleArn:chimeContext().roleArn') < 3:
        raise ValueError("Chime plan storage: expected at least three plans")
    anchor = 'if(p.used) throw new Error("This AWS Chime change plan has already been used.");'
    source = one(source, anchor,
                 'if (p.customerRoleArn !== chimeContext().roleArn || p.customerId !== chimeContext().customerId) '\
                 'throw new Error("AWS_CHIME_PLAN_CUSTOMER_MISMATCH: Select the customer account used to create this plan.");\n  '+anchor,
                 "Chime apply plan")
    return source


def patch_index(source):
    if MARKER in source:
        return source
    anchor = '} from "./aws-chime.js";'
    if source.count(anchor) != 1:
        raise ValueError("Chime import anchor missing")
    source = source.replace('  applyAwsChimeChange,\n'+anchor,
                            '  applyAwsChimeChange,\n  runAwsChimeWithCustomerCredentials,\n'+anchor, 1)
    source = source.replace(anchor, anchor+'\nimport { resolveAwsChimeCustomerConnection } from "./aws-marketplace-ec2-deploy-v1.js";', 1)
    # Alter only the registration calls for aws_chime_*; their handler bodies remain intact.
    source, count = re.subn(r'server\.registerTool\((\s*"aws_chime_[^"]+")',
                            r'registerChimeCustomerTool(\1', source)
    if count < 10 or 'server.registerTool(\n  "aws_chime_' in source:
        raise ValueError(f"Expected Chime tool registrations; found {count}")
    first = re.search(r'registerChimeCustomerTool\(\s*"aws_chime_', source)
    helper = '''// VODIA_CHIME_CUSTOMER_CREDENTIALS_V82
function registerChimeCustomerTool(name, definition, handler) {
  server.registerTool(name, {
    ...definition,
    description: definition.description + " Uses the selected customer's VodiaMCPDeploymentRole.",
    inputSchema: {
      ...definition.inputSchema,
      customerId: z.string().uuid().optional().describe("Connected customer ID. Required when several customers are available.")
    }
  }, async (input, extra) => {
    try {
      if (typeof resolveAwsChimeCustomerConnection !== "function") {
        throw new Error("AWS_CUSTOMER_CONNECTION_REQUIRED: AWS customer connector is unavailable.");
      }
      const roles = definition.annotations?.readOnlyHint
        ? ["MSP_ADMIN", "CUSTOMER_ADMIN", "OPERATOR", "READ_ONLY"]
        : ["MSP_ADMIN", "CUSTOMER_ADMIN"];
      const connection = resolveAwsChimeCustomerConnection(input, extra, roles);
      return await runAwsChimeWithCustomerCredentials(connection, () => handler(input, extra));
    } catch (error) {
      return failure(error, "AWS customer deployment role");
    }
  });
}

'''
    source = source[:first.start()] + helper + source[first.start():]
    old = '"Verify the AWS identity available to this MCP host and confirm read access to Amazon Chime SDK Voice. Uses the AWS SDK default credential provider chain; on EC2 this can use the instance IAM role without stored access keys."'
    if old in source:
        source = source.replace(old, '"Verify the connected customer deployment role identity and confirm read access to Amazon Chime SDK Voice."', 1)
    return source


def main():
    app = Path(sys.argv[1])
    patches = {
        "aws-marketplace-ec2-deploy-v1.js": patch_backend,
        "aws-chime.js": patch_chime,
        "index.js": patch_index,
    }
    # Compute every edit before touching any file.
    results = {}
    for filename, patch in patches.items():
        path = app / filename
        results[path] = patch(path.read_text())
    for path, value in results.items():
        path.write_text(value)
        print(f"PATCHED {path.name}")


if __name__ == "__main__":
    main()
PATCH_PY_V82
cat >"$BUNDLE_TMP/upgrade-vodia-mcp-v0.14.9.82-chime-customer-role.sh" <<'UPGRADE_SH_V82'
#!/usr/bin/env bash
# Route every Chime SDK Voice operation through the selected customer deployment role.
set -Eeuo pipefail

APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"
SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
PATCHER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/patch-vodia-mcp-chime-deployment-credentials-v82.py"
BACKUP_ROOT="${VODIA_MCP_BACKUP_ROOT:-/var/backups}"
VERSION="$APP/version.js"
STAGE="$(mktemp -d)"
BACKUP=""
INSTALLED=0
cleanup() {
  result=$?
  if [[ $result -ne 0 && $INSTALLED -eq 1 && -n $BACKUP ]]; then
    for filename in index.js aws-chime.js aws-marketplace-ec2-deploy-v1.js version.js; do
      cp -a "$BACKUP/$filename" "$APP/$filename" || true
    done
    systemctl restart "$SERVICE" || true
    echo "ROLLBACK: restored original MCP files from $BACKUP" >&2
  fi
  rm -rf "$STAGE"
  exit "$result"
}
trap cleanup EXIT

[[ $(id -u) == 0 ]] || { echo "Run as root" >&2; exit 1; }
for tool in node python3 install systemctl curl rg; do command -v "$tool" >/dev/null || exit 1; done
[[ -f $PATCHER ]] || { echo "Missing patcher: $PATCHER" >&2; exit 1; }
for filename in index.js aws-chime.js aws-marketplace-ec2-deploy-v1.js version.js; do
  [[ -f $APP/$filename ]] || { echo "Missing $APP/$filename" >&2; exit 1; }
  cp -a "$APP/$filename" "$STAGE/$filename"
done

CURRENT="$(python3 - "$VERSION" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
m=re.search(r'CONNECTOR_VERSION\s*=\s*["\']([^"\']+)',s)
print(m.group(1) if m else '')
PY
)"
case "$CURRENT" in
  0.14.9.79|0.14.9.80|0.14.9.81|0.14.9.82) ;;
  *) echo "Unsupported MCP version: ${CURRENT:-unknown}; expected .79 through .82" >&2; exit 1 ;;
esac
rg -q 'registerAwsMarketplaceDeployTools\(server, ctx\)' "$APP/aws-marketplace-ec2-deploy-v1.js" || {
  echo "Marketplace customer connection registration missing" >&2; exit 1;
}

python3 "$PATCHER" "$STAGE"
python3 - "$STAGE/version.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
n,count=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.82\2',s,count=1)
assert count==1
p.write_text(n)
PY
for filename in index.js aws-chime.js aws-marketplace-ec2-deploy-v1.js version.js; do
  node --check "$STAGE/$filename"
done
echo "PASS: staged v0.14.9.82; all JavaScript parses. No AWS changes made."
if [[ ${VODIA_MCP_DRY_RUN:-0} == 1 ]]; then
  echo "DRY RUN PASS: service and live files unchanged."
  exit 0
fi

BACKUP="$BACKUP_ROOT/vodia-mcp-v0.14.9.82-chime-customer-role-$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
for filename in index.js aws-chime.js aws-marketplace-ec2-deploy-v1.js version.js; do
  cp -a "$APP/$filename" "$BACKUP/$filename"
done
INSTALLED=1
for filename in index.js aws-chime.js aws-marketplace-ec2-deploy-v1.js version.js; do
  install -m 0644 "$STAGE/$filename" "$APP/$filename"
done
systemctl restart "$SERVICE"
HEALTH=""
for ((attempt=0;attempt<20;attempt++)); do
  if HEALTH="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null)"; then break; fi
  sleep 1
done
[[ $HEALTH == *'"version":"0.14.9.82"'* ]] || {
  echo "Health check failed or version mismatch: $HEALTH" >&2; exit 1;
}
echo "PASS: MCP $HEALTH"
echo "Backup: $BACKUP"
UPGRADE_SH_V82
cat >"$BUNDLE_TMP/aws-chime-customer-deployment-role-policy-v82.json" <<'CHIME_POLICY_V82'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "VodiaCustomerChimeVoice",
      "Effect": "Allow",
      "Action": [
        "chime:ListVoiceConnectors",
        "chime:GetVoiceConnector",
        "chime:GetVoiceConnectorTermination",
        "chime:GetVoiceConnectorOrigination",
        "chime:ListVoiceConnectorTerminationCredentials",
        "chime:GetVoiceConnectorTerminationHealth",
        "chime:ListAvailableVoiceConnectorRegions",
        "chime:CreateVoiceConnector",
        "chime:SearchAvailablePhoneNumbers",
        "chime:ListPhoneNumbers",
        "chime:GetPhoneNumber",
        "chime:CreatePhoneNumberOrder",
        "chime:GetPhoneNumberOrder",
        "chime:ListPhoneNumberOrders",
        "chime:AssociatePhoneNumbersWithVoiceConnector",
        "chime:PutVoiceConnectorTerminationCredentials",
        "chime:PutVoiceConnectorTermination",
        "chime:PutVoiceConnectorOrigination"
      ],
      "Resource": "*"
    }
  ]
}
CHIME_POLICY_V82

if [[ "$MODE" == --show-policy ]]; then
  cat "$BUNDLE_TMP/aws-chime-customer-deployment-role-policy-v82.json"
  exit 0
fi
if [[ "$MODE" == --dry-run ]]; then
  VODIA_MCP_DRY_RUN=1 bash "$BUNDLE_TMP/upgrade-vodia-mcp-v0.14.9.82-chime-customer-role.sh"
  exit 0
fi
explain
bash "$BUNDLE_TMP/upgrade-vodia-mcp-v0.14.9.82-chime-customer-role.sh"
