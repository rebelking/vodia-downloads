# Vodia PBX MCP v0.8 Installation and Validation Runbook

**Document status:** Operational baseline for v0.8 and design input for v0.9  
**Audience:** Vodia support engineers, system administrators, release engineers, and Codex operators  
**Deployment model:** Vodia PBX API connector on Ubuntu/EC2, Caddy HTTPS, remote MCP clients  

## 1. Purpose

This runbook defines a repeatable, security-conscious process for installing, upgrading, validating, and operating Vodia PBX MCP v0.8.

The process is deliberately divided into gates. Do not proceed to the next gate until the current gate passes:

1. Infrastructure preflight
2. Protected backup
3. Package integrity and installation
4. Service and HTTPS validation
5. Credential handling and rotation
6. Read-only MCP validation
7. Administrator MCP validation
8. Plan-only validation
9. Controlled apply validation
10. Post-change verification and audit review

The goal is not merely to make the service start. The goal is to prove that the correct release is running, the correct tools are exposed, credentials are protected, write operations are controlled, and the PBX state can be verified after every change.

## 2. v0.8 Capability Baseline

### Confirmed working

- HTTPS MCP endpoints through Caddy
- Separate read-only and administrator bearer tokens
- Read-only PBX inventory, status, diagnostics, CDR, queue, registration, and audit tools
- System-wide administrator visibility when configured with the `full` profile
- Controlled change planning with expiring, single-use change IDs
- Exact `APPLY` confirmation requirement
- Request hashing, persistent auditing, redaction, and post-change verification where supported
- Account creation planning through `plan_create_account`
- Account update/rename planning through `plan_update_account`
- Existing SIP-trunk update/rename through `plan_update_sip_trunk`
- Existing SIP-trunk enable/disable through `plan_set_sip_trunk_enabled`
- Dial-plan and tenant-settings update planning
- Controlled execution through `apply_vodia_change`

### Intentionally disabled in the current deployment

```text
VODIA_ENABLE_DESTRUCTIVE="false"
VODIA_ENABLE_CRITICAL_WRITES="false"
```

These settings should block DELETE and critical break-glass operations. They should not remove ordinary account creation, account updates, trunk updates, or tenant-setting planners.

### Known v0.8 limitations

1. `get_connector_info` may report MCP version `0.7.0` even when `package.json` reports `0.8.0`.
2. No `plan_create_sip_trunk` tool exists. v0.8 can update an existing SIP trunk but cannot create a new one.
3. Creating a plan does not prove that the target tenant exists or that the requested account number is unused.
4. A natural-language prompt can accidentally use placeholders such as `YOUR-TENANT-DOMAIN` or `REAL-TENANT-DOMAIN` literally.
5. Deferred tool discovery may omit write tools when broad search terms are used. Exact tool names produce more reliable discovery.
6. The installer prints credentials to the terminal. Any credential pasted into chat, tickets, email, logs, or screenshots must be treated as compromised and rotated.
7. A plan is not a PBX change. The PBX changes only after `apply_vodia_change` succeeds.

## 3. Architecture and Endpoints

The standard v0.8 deployment uses:

| Component | Purpose |
|---|---|
| Vodia PBX | Target PBX API |
| Vodia MCP Node.js service | Read, plan, apply, audit, and redact operations |
| Caddy | Public HTTPS and reverse proxy |
| `/mcp` | Read-only MCP endpoint |
| `/mcp-admin` | Controlled administrator MCP endpoint |
| `/admin/` | Administrative dashboard |
| `/health` | Local/public service-health check |

Example deployment:

```text
Admin dashboard: https://mcp-test.tryvodia.com/admin/
Read MCP:        https://mcp-test.tryvodia.com/mcp
Admin MCP:       https://mcp-test.tryvodia.com/mcp-admin
Local service:   http://127.0.0.1:3100
```

## 4. Gate 1 — Infrastructure Preflight

Before installation:

- Create an A/AAAA record for the public MCP hostname.
- Confirm that DNS resolves to the EC2 public address.
- Open AWS Security Group inbound TCP ports 80 and 443.
- Confirm that the Vodia PBX URL uses HTTPS.
- Create a dedicated Vodia API account; do not reuse a human administrator account.
- Decide whether the connector is system-wide or restricted to explicit tenant domains.
- Take an EC2 snapshot before upgrading an existing installation.

Run:

```bash
echo "DNS:"
getent ahostsv4 mcp-test.tryvodia.com | awk 'NR==1 {print $1}'

echo "This server:"
curl -4 -s https://checkip.amazonaws.com

echo "Ports 80/443:"
sudo ss -lntp | grep -E ':(80|443)[[:space:]]' || true
```

The DNS address and server public address must match.

### Installer input rules

| Prompt | Correct format |
|---|---|
| Public MCP domain | `mcp-test.tryvodia.com` |
| Vodia PBX URL | `https://vodiatech.audiomercy.com` |
| API username | Dedicated API account name |
| Allowed tenants | Comma-separated domains or blank for system-wide |

Do not enter `https://` in the public MCP domain field. Do include `https://` in the Vodia PBX URL field.

## 5. Gate 2 — Protected Backup

Before upgrading:

```bash
sudo test -e /etc/vodia-mcp.env.before-v0.8 || \
  sudo cp /etc/vodia-mcp.env /etc/vodia-mcp.env.before-v0.8

sudo test -e /opt/vodia-mcp.before-v0.8 || \
  sudo cp -a /opt/vodia-mcp /opt/vodia-mcp.before-v0.8
```

Backups containing credentials must remain root-readable only:

```bash
sudo chmod 600 /etc/vodia-mcp.env* /root/vodia-mcp-credentials*.txt 2>/dev/null || true
```

## 6. Gate 3 — Package Preparation and Installation

Download to a known path and discover the installer instead of assuming the ZIP layout:

```bash
cd /tmp

wget -O vodia-mcp-v0.8.0-full-admin.zip \
  https://raw.githubusercontent.com/rebelking/vodia-downloads/main/vodia-mcp-v0.8.0-full-admin.zip

mkdir -p /tmp/vodia-mcp-v0.8

unzip -q -o vodia-mcp-v0.8.0-full-admin.zip \
  -d /tmp/vodia-mcp-v0.8

find /tmp/vodia-mcp-v0.8 \
  -type f \
  -name 'install-vodia-mcp.sh'
```

Run the discovered installer path:

```bash
env \
  VODIA_MCP_PACKAGE_FILE="/tmp/vodia-mcp-v0.8.0-full-admin.zip" \
  VODIA_MCP_ROTATE_TOKENS="false" \
  VODIA_MCP_ADMIN_PROFILE="full" \
  bash /tmp/vodia-mcp-v0.8/vodia-mcp/install-vodia-mcp.sh
```

For a fresh deployment, prefer token rotation. Preserve tokens only during a controlled upgrade when existing clients cannot be updated immediately.

## 7. Gate 4 — Service, Version, and HTTPS Validation

Run immediately after installation:

```bash
curl -fsS http://127.0.0.1:3100/health

node -p "require('/opt/vodia-mcp/package.json').version"

sudo systemctl status vodia-mcp caddy --no-pager

sudo systemctl show vodia-mcp \
  --property=MainPID \
  --property=ExecStart \
  --no-pager

sudo grep -E \
'^VODIA_ADMIN_PROFILE=|^VODIA_ENABLE_DESTRUCTIVE=|^VODIA_ENABLE_CRITICAL_WRITES=' \
/etc/vodia-mcp.env
```

Expected baseline:

```text
Package version: 0.8.0
ExecStart: /usr/bin/node /opt/vodia-mcp/http.js
VODIA_ADMIN_PROFILE="full"
VODIA_ENABLE_DESTRUCTIVE="false"
VODIA_ENABLE_CRITICAL_WRITES="false"
```

Validate public HTTPS:

```bash
curl -fsS https://mcp-test.tryvodia.com/health
```

Review recent service logs without dumping the environment file:

```bash
sudo journalctl -u vodia-mcp -n 100 --no-pager
sudo journalctl -u caddy -n 100 --no-pager
```

## 8. Gate 5 — Credential Regime

Three different credentials exist:

| Server field | Purpose | Client use |
|---|---|---|
| `Admin token` / `ADMIN_TOKEN` | Web dashboard | Never use for MCP |
| `Read-only MCP bearer token` / `MCP_BEARER_TOKEN` | `/mcp` | Read MCP client variable |
| `Administrator MCP bearer token` / `MCP_ADMIN_BEARER_TOKEN` | `/mcp-admin` | Admin MCP client variable |

Credentials are stored in:

```text
/etc/vodia-mcp.env
/root/vodia-mcp-credentials.txt
```

Never paste credentials into documentation, chat, screenshots, tickets, or command history. Validate only their length or a one-way digest.

List credential names without revealing values:

```bash
sudo awk -F'[:=]' 'NF>1 {print $1}' /root/vodia-mcp-credentials.txt
sudo awk -F= '/TOKEN/ {print $1}' /etc/vodia-mcp.env
```

Retrieve one credential only when transferring it directly into a secure client prompt:

```bash
sudo awk -F': ' \
'$1=="Read-only MCP bearer token" {print $2}' \
/root/vodia-mcp-credentials.txt

sudo awk -F': ' \
'$1=="Administrator MCP bearer token" {print $2}' \
/root/vodia-mcp-credentials.txt
```

If any token is exposed, rotate it immediately and restart the service. Do not continue testing with a known exposed token.

## 9. Codex Client Configuration

### Windows PowerShell environment variables

Use hidden prompts rather than placing tokens directly in commands:

```powershell
$secureRead = Read-Host "Paste read MCP token" -AsSecureString
$readToken = [System.Net.NetworkCredential]::new("", $secureRead).Password

$secureAdmin = Read-Host "Paste administrator MCP token" -AsSecureString
$adminToken = [System.Net.NetworkCredential]::new("", $secureAdmin).Password

$env:VODIA_TEST_MCP_TOKEN = $readToken
$env:VODIA_TEST_MCP_ADMIN_TOKEN = $adminToken

[Environment]::SetEnvironmentVariable(
    "VODIA_TEST_MCP_TOKEN", $readToken, "User"
)

[Environment]::SetEnvironmentVariable(
    "VODIA_TEST_MCP_ADMIN_TOKEN", $adminToken, "User"
)

"Read length: $($readToken.Length)"
"Admin length: $($adminToken.Length)"

Remove-Variable secureRead, secureAdmin, readToken, adminToken
```

Both token lengths should be 64. Restart Codex Desktop and open a new PowerShell window after changing persistent environment variables.

### macOS Keychain and launch environment

Store the tokens in Keychain:

```bash
security add-generic-password \
  -a "$USER" \
  -s "vodia-test-mcp-read" \
  -w 'PASTE_READ_TOKEN_HERE' \
  -U

security add-generic-password \
  -a "$USER" \
  -s "vodia-test-mcp-admin" \
  -w 'PASTE_ADMIN_TOKEN_HERE' \
  -U
```

Load them without printing them:

```bash
export VODIA_TEST_MCP_TOKEN="$(
  security find-generic-password \
    -a "$USER" \
    -s "vodia-test-mcp-read" \
    -w
)"

export VODIA_TEST_MCP_ADMIN_TOKEN="$(
  security find-generic-password \
    -a "$USER" \
    -s "vodia-test-mcp-admin" \
    -w
)"

launchctl setenv VODIA_TEST_MCP_TOKEN "$VODIA_TEST_MCP_TOKEN"
launchctl setenv VODIA_TEST_MCP_ADMIN_TOKEN "$VODIA_TEST_MCP_ADMIN_TOKEN"

echo "Read token length: ${#VODIA_TEST_MCP_TOKEN}"
echo "Admin token length: ${#VODIA_TEST_MCP_ADMIN_TOKEN}"
```

Restart the Codex application after changing `launchctl` variables.

### `config.toml`

```toml
[mcp_servers.vodia]
url = "https://mcp.tryvodia.com/mcp"
bearer_token_env_var = "VODIA_MCP_TOKEN"
enabled = false
required = false
default_tools_approval_mode = "auto"
tool_timeout_sec = 60

[mcp_servers.vodia_test]
url = "https://mcp-test.tryvodia.com/mcp"
bearer_token_env_var = "VODIA_TEST_MCP_TOKEN"
enabled = true
required = true
default_tools_approval_mode = "auto"
tool_timeout_sec = 60

[mcp_servers.vodia_test_admin]
url = "https://mcp-test.tryvodia.com/mcp-admin"
bearer_token_env_var = "VODIA_TEST_MCP_ADMIN_TOKEN"
enabled = true
required = false
default_tools_approval_mode = "writes"
tool_timeout_sec = 60
```

Keep the admin endpoint `required = false` during initial setup so a bad administrator token does not prevent read-only work. After the full acceptance test passes, production policy may choose `required = true`.

Validate configuration:

```powershell
codex mcp list
```

Expected:

```text
vodia              disabled
vodia_test         enabled   Bearer token
vodia_test_admin   enabled   Bearer token
```

## 10. Gate 6 — Read-Only Acceptance Test

```powershell
codex exec --skip-git-repo-check --sandbox read-only "Using only the vodia_test MCP server, call get_connector_info and get_system_status. Return the MCP version, PBX version, build date, redaction status, persistent-audit status, and connector health."
```

Pass conditions:

- No HTTP 401 from `/mcp`
- PBX version and build date returned
- Redaction enabled
- Persistent audit enabled
- No administrator tool invoked

An HTTP 401 mentioning an administrator token can originate from the separately enabled admin server while the read call still succeeds. Fix the admin token before proceeding.

## 11. Gate 7 — Administrator Acceptance Test

First confirm authentication without writing:

```powershell
codex exec --skip-git-repo-check --sandbox read-only "Connect only to the vodia_test_admin MCP server. Report the PBX version, visible tenant count, and available read-only administrator tools. Do not perform any write operation."
```

Then force exact discovery of the v0.8 write surface:

```powershell
codex exec --skip-git-repo-check --sandbox read-only "Inspect only the vodia_test_admin MCP definitions. Do not invoke them. Confirm whether these exact tools are available: plan_create_account, plan_update_account, plan_update_sip_trunk, plan_set_sip_trunk_enabled, plan_update_dial_plan, plan_update_tenant_settings, plan_delete_account, plan_delete_sip_trunk, and apply_vodia_change."
```

All named definitions must be visible in the `full` profile. Delete planners may be defined while their execution remains blocked by policy.

## 12. Gate 8 — Plan-Only Validation

### Mandatory preflight rule

The tenant used for the existence check must be exactly the same tenant used in the plan. Never mix a placeholder tenant in the read step with a real tenant in the plan step.

Run the read separately:

```powershell
codex exec --skip-git-repo-check --sandbox read-only "Using only vodia_test_admin, call list_extensions with domain EXAMPLE-TENANT and account 2040. Report whether extension 2040 exists. Do not call any plan or apply tool."
```

Only after confirming the account is unused, create a plan:

```powershell
codex exec --skip-git-repo-check --sandbox read-only "Using only vodia_test_admin, call plan_create_account with domain EXAMPLE-TENANT, type extensions, accounts 2040, and reason 'Controlled acceptance test'. Return the complete plan, change_id, target tenant, request body, expiration, and required confirmation. Do not call apply_vodia_change."
```

Review all of the following before approval:

- Correct target tenant
- Correct account type
- Correct account number
- Correct Vodia operation ID
- Expected request body
- `risk: write`
- `adminTier: standard`
- Expiration has not passed
- `confirmationRequired: APPLY`
- No secrets in the plan

A plan can create an audit entry and server-side pending-plan state, but it does not change the PBX.

## 13. Gate 9 — Controlled Apply Validation

Use a disposable test tenant and an unused test account. Never perform the first apply test on a production tenant.

Approval must name the exact `change_id` and request a single apply:

```text
Using only vodia_test_admin, call apply_vodia_change exactly once with:

change_id: REVIEWED-CHANGE-ID
confirmation: APPLY

Do not perform any additional plan or write operation. Return the HTTP result and verification result.
```

Do not reuse a change ID. Do not approve an expired plan. Do not approve a plan when the live PBX state has changed since planning.

## 14. Gate 10 — Verification and Audit

After applying an account creation:

1. Read the account from the same tenant.
2. Confirm the exact account number and expected defaults.
3. Confirm the operation appears in the MCP audit log.
4. Confirm secrets are redacted.
5. Confirm replaying the change ID is rejected.
6. Document rollback or cleanup separately.

Example verification prompt:

```text
Using only vodia_test_admin, call list_extensions for the exact tenant and account just created. Return its basic properties and confirm it exists. Then read the relevant MCP audit entry. Do not modify the PBX.
```

## 15. Troubleshooting Decision Table

| Symptom | Likely cause | Action |
|---|---|---|
| `codex` not found | Codex binary directory absent from PATH | Run the full executable path, then add its directory to PATH |
| `HTTP 401` read token | Wrong or stale read bearer token | Replace `VODIA_TEST_MCP_TOKEN`, restart client |
| `HTTP 401` administrator token | Dashboard token or stale admin MCP token used | Use `Administrator MCP bearer token`, restart client |
| Read works but admin fails | Independent endpoint credentials | Fix only the admin variable; do not replace TOML with literal tokens |
| Only read tools discovered | Deferred discovery ranking/cache | Restart service/client and query exact v0.8 tool names |
| Package says 0.8, metadata says 0.7 | Hard-coded/stale connector version field | Verify `package.json`, running path, and source; fix in v0.9 |
| Installer rejects MCP domain | Scheme included in hostname | Enter hostname only, without `https://` |
| Installer path not found | ZIP contains nested directory | Discover it with `find`; do not guess |
| Plan targets placeholder | Prompt copied without replacement | Abandon the plan; repeat preflight and planning with one exact tenant |
| Plan exists but PBX unchanged | Expected plan/apply separation | Review and explicitly apply, or allow plan to expire |
| Cannot create SIP trunk | v0.8 limitation | Add `plan_create_sip_trunk` in v0.9 |

## 16. v0.9 Required Improvements

### Installer and upgrade behavior

- Provide explicit `install`, `upgrade`, `repair`, `rotate-tokens`, `validate`, and `uninstall` modes.
- Support noninteractive arguments while retaining an interactive mode.
- Discover and validate package layout internally.
- Validate DNS, public IP, ports 80/443, PBX HTTPS, credentials, and permissions before copying files.
- Stop before mutation when any mandatory preflight fails.
- Back up application, environment, Caddy, and systemd files with a timestamped manifest.
- Preserve existing secrets during upgrade unless rotation is explicitly requested.
- Provide automatic rollback when health or self-tests fail.
- Emit a machine-readable installation report with no secrets.
- Never print bearer tokens by default. Store them in a root-only credentials file and require an explicit local command to reveal one token.
- Keep service descriptions and version strings synchronized with the package version.

### Version integrity

- Define the version in one source of truth.
- Return the same version from `package.json`, `/health`, `get_connector_info`, logs, dashboard, and release report.
- Fail CI when any hard-coded old version remains.

### SIP-trunk creation

Add `plan_create_sip_trunk` with:

- Exact tenant validation
- Supported provider/template selection
- Required name and destination fields
- Registrar, proxy, transport, authentication, codec, routing, header, failover, and PCAP schemas
- Secret input fields that are never echoed in plans, logs, hashes, or audit output
- Collision detection for trunk names and identifiers
- Plan/apply separation
- Post-create readback verification
- Safe cleanup procedure for failed partial creation

### Strong preflight validation

Every planner must validate before issuing a change ID:

- Tenant exists and is within allowed scope
- Target account/trunk/dial plan exists for updates
- Target does not exist for creates
- Requested field names are supported
- Current state is captured when available
- User input contains no unresolved placeholders
- Plan tenant matches the preflight tenant
- API operation exists in the callable catalog

Reject obvious placeholders including:

```text
YOUR-TENANT-DOMAIN
REAL-TENANT-DOMAIN
EXAMPLE-TENANT
example.com
CHANGEME
```

### Safer plans and applies

- Bind each plan to actor, endpoint role, tenant, request hash, preimage hash, expiration, and reason.
- Make every plan single-use.
- Reject stale plans when the live preimage differs.
- Require exact confirmation appropriate to risk tier.
- Keep destructive and critical operations disabled by default.
- Return structured verification after every apply.
- Provide a dry-run validator that performs all checks without creating a pending plan.

### Tool discovery and documentation

- Add an administrator capability tool that reports profile, feature flags, and exact planner names without exposing secrets.
- Add generated tool-reference documentation from live schemas.
- Include examples for read, plan, review, apply, verify, and audit.
- Ensure broad discovery searches find the write planners reliably.

### Release testing

The v0.9 CI and installer self-test must prove:

- Unauthorized read token rejected
- Unauthorized admin token rejected
- Read token cannot access admin tools
- Admin token can access all enabled admin tools
- Full profile contains every documented planner
- Account creation plan/apply/verify works
- Account update/rename plan/apply/verify works
- SIP-trunk creation plan/apply/verify works
- SIP-trunk update/rename plan/apply/verify works
- Enable/disable plan/apply/verify works
- Wrong confirmation rejected
- Expired plan rejected
- Replayed plan rejected
- Stale plan rejected
- Destructive operations blocked by default
- Critical operations blocked by default
- Secrets redacted from responses, plans, hashes, logs, and audits
- Package, health, connector, and dashboard versions match
- Failed upgrade rolls back cleanly

## 17. v0.9 Release Acceptance Checklist

- [ ] Fresh install succeeds on supported Ubuntu LTS release
- [ ] Upgrade from v0.8 preserves configuration and data
- [ ] Automated rollback tested
- [ ] DNS and HTTPS preflight tested
- [ ] Package integrity verified
- [ ] All version surfaces match
- [ ] Credentials are never printed by default
- [ ] Token rotation command tested
- [ ] Read and admin authentication tested separately
- [ ] Tenant restrictions tested
- [ ] Exact admin tool catalog documented
- [ ] `plan_create_sip_trunk` implemented
- [ ] All planners perform tenant/object preflight
- [ ] Placeholder rejection implemented
- [ ] Plan/apply/verify lifecycle tested
- [ ] Persistent audit and redaction tested
- [ ] Destructive and critical defaults remain disabled
- [ ] Windows Codex instructions tested
- [ ] macOS Codex instructions tested
- [ ] Installer emits a redacted validation report
- [ ] Release ZIP contains README, release notes, checksums, installer, rollback instructions, and this runbook

## 18. Operational Rule

For every PBX write, use this sequence:

```text
READ → VALIDATE → PLAN → REVIEW → APPLY ONCE → VERIFY → AUDIT
```

Never combine the existence check and apply approval into a vague prompt. Use exact tenant names, exact object identifiers, exact tool names, and explicit stopping conditions.

---

This document is the v0.8 operational baseline. v0.9 should not be released until every mandatory improvement and release acceptance item has an owner, a test, and a recorded result.
