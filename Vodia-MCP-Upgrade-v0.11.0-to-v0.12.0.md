# Vodia MCP Upgrade Guide: v0.11.0 to v0.12.0

This runbook upgrades an existing Vodia MCP v0.11.0 installation to v0.12.0 on Ubuntu using systemd. Version 0.12.0 adds persistent supervised learning and a separate human-approver MCP endpoint while retaining policy-controlled PBX administration.

> **Important:** The originally published v0.12.0 archive contains a defect in its upgrade script's health-response parsing and rollback handling. The procedure below patches the extracted upgrade script before running it. Do not run the unpatched v0.12.0 upgrade script.

## What v0.12.0 adds

- Persistent learned-operation state.
- Proposal, inspection, and testing of learned operations.
- Separate approval endpoint and identity.
- Execution of approved learned GET operations.
- Redaction of secrets such as SIP authorization and push tokens.
- Continued blocking of destructive learned operations.
- Continued plan, confirmation, and apply controls for supported PBX writes.

## Assumptions

- Current installation: `/opt/vodia-mcp`
- Current version: `0.11.0`
- Service: `vodia-mcp.service`
- Environment file: `/etc/vodia-mcp.env`
- Public test host: `mcp-test.tryvodia.com`
- You are logged into the EC2 instance as `root`, or can run the commands with `sudo`.
- The v0.12.0 ZIP and checksum files are published in `rebelking/vodia-downloads`.

Commands labeled **EC2** are Bash commands. Commands labeled **Windows** are PowerShell commands. Do not mix them.

## 1. Confirm v0.11.0 before upgrading

Run on **EC2**:

```bash
echo "=== Current health ==="
curl -fsS http://127.0.0.1:3100/health
echo

echo "=== Installed package ==="
node -p "require('/opt/vodia-mcp/package.json').version"

echo "=== Service ==="
systemctl is-active vodia-mcp

echo "=== Disk space ==="
df -h / /opt /tmp
```

Do not continue unless:

- Health returns `"ok": true`.
- Installed version is `0.11.0`.
- The service is `active`.
- There is enough free space for the archive, dependencies, and a retained rollback copy.

## 2. Download v0.12.0 into `/tmp`

Run on **EC2**:

```bash
cd /tmp

wget -O vodia-mcp-v0.12.0-complete-api.zip.new \
  "https://raw.githubusercontent.com/rebelking/vodia-downloads/main/vodia-mcp-v0.12.0-complete-api.zip?$(date +%s)"

sha256sum vodia-mcp-v0.12.0-complete-api.zip.new
```

The expected SHA-256 for the verified v0.12.0 archive used by this runbook is:

```text
91e5cb7806e2287a854fe601c38ba040de765dbe96d03962ccc699c583950af2
```

If the actual hash does not match exactly, stop. Do not install the archive.

After it matches, replace the previous temporary copy and create a correctly formatted checksum file:

```bash
mv \
  /tmp/vodia-mcp-v0.12.0-complete-api.zip.new \
  /tmp/vodia-mcp-v0.12.0-complete-api.zip

printf '%s  %s\n' \
  '91e5cb7806e2287a854fe601c38ba040de765dbe96d03962ccc699c583950af2' \
  'vodia-mcp-v0.12.0-complete-api.zip' \
  > /tmp/vodia-mcp-v0.12.0-complete-api.sha256

cd /tmp
sha256sum -c vodia-mcp-v0.12.0-complete-api.sha256
```

Expected result:

```text
vodia-mcp-v0.12.0-complete-api.zip: OK
```

## 3. Extract and patch the v0.12.0 upgrade script

Extract the installer from the verified archive:

```bash
cd /tmp

unzip -p \
  vodia-mcp-v0.12.0-complete-api.zip \
  vodia-mcp/upgrade-vodia-mcp-v0.12.0.sh \
  > upgrade-vodia-mcp-v0.12.0.sh

chmod 700 upgrade-vodia-mcp-v0.12.0.sh
```

Apply the three required hotfixes:

```bash
sed -i \
  's/"${HEALTH:-{}}"/"$HEALTH"/' \
  upgrade-vodia-mcp-v0.12.0.sh

sed -i \
  '/^rollback() {$/a\  trap - ERR' \
  upgrade-vodia-mcp-v0.12.0.sh

sed -i \
  's/mv "$OLD_DIR" "$APP_DIR"/cp -a "$OLD_DIR" "$APP_DIR"/' \
  upgrade-vodia-mcp-v0.12.0.sh
```

Remove stale approver credential lines so the installer records the active credential once:

```bash
sed -i \
  '/^Learning approver endpoint:/d; /^Learning approver MCP bearer token:/d' \
  /root/vodia-mcp-credentials.txt
```

Validate the patched script:

```bash
bash -n /tmp/upgrade-vodia-mcp-v0.12.0.sh

echo "=== Patched lines ==="
grep -nE 'trap - ERR|cp -a "\$OLD_DIR"|RUNNING_VERSION=' \
  /tmp/upgrade-vodia-mcp-v0.12.0.sh
```

Do not continue if `bash -n` reports an error.

## 4. Run the upgrade

Run on **EC2**:

```bash
cd /tmp

env \
  VODIA_MCP_PACKAGE_FILE="/tmp/vodia-mcp-v0.12.0-complete-api.zip" \
  VODIA_MCP_CHECKSUM_FILE="/tmp/vodia-mcp-v0.12.0-complete-api.sha256" \
  bash /tmp/upgrade-vodia-mcp-v0.12.0.sh
```

The installer should complete these stages:

1. Download or select the package.
2. Verify SHA-256.
3. Extract and inspect the release.
4. Install dependencies and run audits, syntax checks, and tests.
5. Back up v0.11.0.
6. Enable persistent supervised-learning state.
7. Start v0.12.0.
8. Verify health and report success.

A single initial `curl: (7) Failed to connect` during stage 7 can be a harmless startup race if the later health check succeeds and stage 8 reports completion.

## 5. Verify the upgraded service

Run on **EC2**:

```bash
sleep 3

echo "=== Health ==="
curl -fsS http://127.0.0.1:3100/health
echo

echo "=== Package ==="
node -p "require('/opt/vodia-mcp/package.json').version"

echo "=== Service ==="
systemctl is-active vodia-mcp

echo "=== Learning components ==="
test -f /opt/vodia-mcp/learned.js && echo "learned.js: present"
test -d /var/lib/vodia-mcp && echo "learning state directory: present"
grep -q '^MCP_APPROVER_BEARER_TOKEN=' /etc/vodia-mcp.env && \
  echo "approver token: configured"
grep -q '^VODIA_LEARNING_STORE=' /etc/vodia-mcp.env && \
  echo "learning store: configured"

echo "=== Recent service log ==="
journalctl -u vodia-mcp -n 20 --no-pager
```

Expected health response:

```json
{
  "ok": true,
  "service": "vodia-mcp",
  "version": "0.12.0",
  "mode": "read-only+policy-controlled-full-admin+supervised-learning"
}
```

The journal may still contain older errors from a previous attempt. Judge the current state by the latest timestamps, current health response, installed package version, and `systemctl is-active` result.

## 6. Configure the separate approver connector

The normal admin identity must not approve its own learning proposal. Configure a separate approver MCP profile on the Windows computer running Codex.

On **EC2**, display the approver credential locally:

```bash
grep '^Learning approver MCP bearer token:' \
  /root/vodia-mcp-credentials.txt
```

Copy the token privately. Never paste it into chat, tickets, documentation, or shared logs.

On **Windows**, open the Codex configuration:

```powershell
notepad "$HOME\.codex\config.toml"
```

Add:

```toml
[mcp_servers.vodia_test_approver]
url = "https://mcp-test.tryvodia.com/mcp-approver"
bearer_token_env_var = "VODIA_MCP_APPROVER_TOKEN"
enabled = true
required = false
default_tools_approval_mode = "auto"
enabled_tools = [
  "list_learning_proposals",
  "inspect_learning_proposal",
  "approve_learned_operation"
]
```

The approver hostname must match the environment used by `vodia_test_admin`. A proposal created on `mcp-test.tryvodia.com` cannot be approved through a different production server and learning store.

Store the token without echoing it:

```powershell
$secureToken = Read-Host "Paste the approver token" -AsSecureString
$pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)

try {
    $plainToken = (
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    ).Trim()

    if ($plainToken.Length -ne 64) {
        throw "Token length is $($plainToken.Length); expected 64."
    }

    $env:VODIA_MCP_APPROVER_TOKEN = $plainToken

    [Environment]::SetEnvironmentVariable(
        "VODIA_MCP_APPROVER_TOKEN",
        $plainToken,
        "User"
    )
}
finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    Remove-Variable plainToken, pointer, secureToken -ErrorAction SilentlyContinue
}
```

Locate the installed Codex executable. For the OpenAI desktop installation, it is commonly beneath:

```text
C:\Users\<user>\AppData\Local\OpenAI\Codex\bin\<build-id>\codex.exe
```

If necessary, search for it:

```powershell
Get-ChildItem `
  "$HOME\Downloads",
  "$HOME\.codex",
  "$env:LOCALAPPDATA",
  "$env:ProgramFiles" `
  -Include "codex.exe","codex.cmd","codex.ps1" `
  -File -Recurse -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty FullName
```

Use the normal installation under `AppData\Local\OpenAI\Codex\bin`; do not use the `.sandbox-bin` or `.plugin-appserver` helper copies.

Set the discovered path and verify the MCP profiles:

```powershell
$codexPath = "C:\path\to\OpenAI\Codex\bin\build-id\codex.exe"

& $codexPath --version
& $codexPath mcp list
```

The list should include:

- `vodia_test_admin` at `https://mcp-test.tryvodia.com/mcp-admin`
- `vodia_test_approver` at `https://mcp-test.tryvodia.com/mcp-approver`

Completely restart Codex after changing `config.toml` or persistent environment variables.

## 7. Validate supervised learning

### Confirm the learning subsystem

Run through `vodia_test_admin`:

```text
Using only vodia_test_admin, call get_connector_info and
list_learned_operations. Return the connector version, learning status,
number of proposed, approved, and disabled operations, and whether
destructive learning is permitted. Do not perform any PBX write.
```

Expected baseline:

- Connector version `0.12.0`
- Learning enabled
- Destructive learning disabled

### Safe learning workflow

Use this order:

1. Admin proposes a read-only operation.
2. Admin tests the proposed GET operation.
3. Separate approver inspects and approves it using the exact confirmation phrase.
4. Admin executes the approved learned read.

The proposing/admin identity must not be able to approve its own proposal.

### Example approval prompt

```text
Using only vodia_test_approver, inspect and approve proposal
<proposal-id>.

Confirm it is GET-only, tenant-scoped, classified as read-only,
successfully tested, contains no credentials, and has no destructive behavior.

Return the approved learned-operation ID, final tool name, approver identity,
and approval timestamp. Do not perform any PBX operation.
```

### Example execution prompt

```text
Using only vodia_test_admin, run the approved learned operation
<learned-operation-id> for domain vodiatech.audiomercy.com.

Return the HTTP status and requested records. Confirm that sensitive fields
are redacted. Do not perform any PBX write.
```

## 8. Rollback procedure

The upgrade retains the previous installation in a timestamped directory similar to:

```text
/opt/vodia-mcp.previous-YYYYMMDD-HHMMSS
```

To identify available installations:

```bash
find /opt -maxdepth 1 -type d -name 'vodia-mcp*' \
  -printf '%TY-%Tm-%Td %TH:%TM:%TS  %p\n' | sort

for directory in /opt/vodia-mcp*; do
  if [[ -f "$directory/package.json" ]]; then
    version="$(node -p "require('$directory/package.json').version" 2>/dev/null)"
    printf '%s  version=%s\n' "$directory" "$version"
  fi
done
```

If v0.12.0 fails and `/opt/vodia-mcp` is missing, restore the exact v0.11.0 backup:

```bash
systemctl stop vodia-mcp

test ! -e /opt/vodia-mcp || {
  echo "STOP: /opt/vodia-mcp already exists"
  exit 1
}

mv \
  /opt/vodia-mcp.previous-YYYYMMDD-HHMMSS \
  /opt/vodia-mcp

systemctl daemon-reload
systemctl reset-failed vodia-mcp
systemctl start vodia-mcp

sleep 3
curl -fsS http://127.0.0.1:3100/health
echo
node -p "require('/opt/vodia-mcp/package.json').version"
systemctl is-active vodia-mcp
```

Replace the placeholder with the verified directory whose `package.json` reports `0.11.0`. Never guess which backup directory to restore.

## 9. Common problems

| Symptom | Cause | Resolution |
| --- | --- | --- |
| `~cd: command not found` | `~cd` is not a command. | Run `cd /tmp`. |
| `no properly formatted checksum lines found` | The checksum file is malformed or stale. | Download it again or construct it only from the trusted release checksum. |
| ZIP checksum mismatch | Stale, cached, incomplete, or wrong ZIP. | Stop, download to a `.new` filename with a cache-busting query, verify, then move it into place. |
| First health `curl` cannot connect | Node has not started listening yet. | Wait several seconds and retry; continue only if health, version, and service state succeed. |
| JSON parse shows an extra `}` | Original v0.12.0 installer used the faulty `${HEALTH:-{}}` expression. | Patch it to pass `"$HEALTH"` exactly before running the installer. |
| systemd reports `status=200/CHDIR` | `/opt/vodia-mcp` is missing, often after a failed rollback. | Stop the service and restore the verified v0.11.0 backup directory. |
| Approver returns HTTP `401` | Windows token does not match the server token, or the wrong hostname is configured. | Compare token lengths and SHA-256 fingerprints; use the same test hostname as the admin connector. |
| Approver tools do not appear | Approver connector failed initialization, often because of `401`. | Fix authentication first, confirm it with `codex mcp list`, then restart Codex. |
| Approval fails once with confirmation error | Exact confirmation enforcement is active. | Retry using the exact phrase returned by the approver service. |

## 10. Security rules

- Never paste bearer tokens into chat, email, tickets, or documentation.
- If a token is exposed, rotate it immediately in `/etc/vodia-mcp.env`, update the credential record, restart the service, and replace the Windows environment variable.
- Keep the admin and approver identities separate.
- Never enable dynamically learned destructive operations.
- Learned writes must remain subject to supported planning, policy, confirmation, and application controls.
- Do not interpret approval of a learned definition as permission to execute a PBX write.

## Upgrade completion checklist

- [ ] Original v0.11.0 health confirmed.
- [ ] v0.12.0 archive checksum matched exactly.
- [ ] Extracted upgrade script received all three hotfixes.
- [ ] Dependency audit, syntax checks, and tests passed.
- [ ] Health reports v0.12.0 and supervised learning.
- [ ] `vodia-mcp.service` is active.
- [ ] Persistent learning directory exists.
- [ ] Approver token and learning-store variables are configured.
- [ ] Previous v0.11.0 installation is retained for rollback.
- [ ] Admin and approver profiles use the same environment hostname.
- [ ] Codex sees both `vodia_test_admin` and `vodia_test_approver`.
- [ ] A read-only proposal can be tested, separately approved, and executed.
- [ ] Sensitive response fields are redacted.
- [ ] No PBX write occurred during validation.

## Release maintenance note

The v0.12.0 service is functional after applying the documented installer hotfixes. A subsequent v0.12.1 release should permanently include:

- Safe health JSON parsing using `"$HEALTH"`.
- Rollback recursion prevention with `trap - ERR` inside the rollback function.
- Rollback restoration that retains a recoverable backup copy.
- Automated regression coverage for upgrade failure and rollback paths.
