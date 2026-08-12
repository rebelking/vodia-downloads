# Vodia MCP 0.9 full-admin installation and validation

This procedure installs v0.9 on the Linux connector host and connects Codex on
Windows or macOS without placing bearer tokens in `config.toml`.

## 1. Back up the connector

On the Linux connector server:

```bash
sudo cp /etc/vodia-mcp.env /etc/vodia-mcp.env.before-v0.9
sudo cp -a /opt/vodia-mcp /opt/vodia-mcp.before-v0.9
```

Verify both backup paths before continuing.

## 2. Install the v0.9 ZIP

Copy `vodia-mcp-v0.9.0-full-admin.zip` to the connector server, then run from
the directory containing the ZIP:

```bash
unzip -q vodia-mcp-v0.9.0-full-admin.zip -d /tmp/vodia-mcp-v0.9
sudo env \
  VODIA_MCP_PACKAGE_FILE="$PWD/vodia-mcp-v0.9.0-full-admin.zip" \
  VODIA_MCP_ROTATE_TOKENS="false" \
  VODIA_MCP_ADMIN_PROFILE="full" \
  bash /tmp/vodia-mcp-v0.9/vodia-mcp/install-vodia-mcp.sh
```

Use `VODIA_MCP_ROTATE_TOKENS="true"` only when you intentionally want new MCP
tokens. The installer prompts for the connector DNS name, PBX URL, dedicated
PBX administrator username/password, and optional tenant allowlist.

The safe full-admin defaults are:

```text
VODIA_ADMIN_PROFILE="full"
VODIA_ENABLE_DESTRUCTIVE="false"
VODIA_ENABLE_CRITICAL_WRITES="false"
```

The three generated secrets are stored with mode 0600 in:

```text
/root/vodia-mcp-credentials.txt
```

## 3. Validate the Linux service

```bash
sudo systemctl status vodia-mcp caddy --no-pager
curl -fsS http://127.0.0.1:3100/health
curl -fsS https://YOUR-MCP-DOMAIN/health
node -p "require('/opt/vodia-mcp/package.json').version"
sudo stat -c '%A %U:%G %n' /var/log/vodia-mcp/audit.jsonl
```

Expected version: `0.9.0`. Port 3100 must listen only on `127.0.0.1`.

The installer hides token values from terminal output by default. Retrieve them
only from `/root/vodia-mcp-credentials.txt`. Set
`VODIA_MCP_SHOW_TOKENS=true` only for an isolated installation terminal where
screen capture and scrollback exposure are acceptable.

## 4A. Store both bearer tokens on Windows

In PowerShell, paste each token only into the hidden prompt:

```powershell
$secureRead = Read-Host "Paste read-only MCP token" -AsSecureString
$readToken = [System.Net.NetworkCredential]::new("", $secureRead).Password
$secureAdmin = Read-Host "Paste administrator MCP token" -AsSecureString
$adminToken = [System.Net.NetworkCredential]::new("", $secureAdmin).Password

[Environment]::SetEnvironmentVariable("VODIA_MCP_TOKEN", $readToken, "User")
[Environment]::SetEnvironmentVariable("VODIA_MCP_ADMIN_TOKEN", $adminToken, "User")
$env:VODIA_MCP_TOKEN = $readToken
$env:VODIA_MCP_ADMIN_TOKEN = $adminToken

"Read token length: $($env:VODIA_MCP_TOKEN.Length)"
"Admin token length: $($env:VODIA_MCP_ADMIN_TOKEN.Length)"
```

Both generated tokens should be 64 characters. Completely exit and restart
Codex Desktop after changing user environment variables. Do not place the raw
tokens in `config.toml`.

## 4B. Store both bearer tokens in macOS Keychain

On the Mac, enter each command separately. When prompted, paste only the raw
token—do not include `Bearer`, quotes, brackets, or the variable name.

```bash
read -s "READ_TOKEN?Paste read-only token: "; echo
security add-generic-password -U -a "$USER" -s "vodia-mcp-read" -w "$READ_TOKEN"
unset READ_TOKEN

read -s "ADMIN_TOKEN_VALUE?Paste administrator token: "; echo
security add-generic-password -U -a "$USER" -s "vodia-mcp-admin" -w "$ADMIN_TOKEN_VALUE"
unset ADMIN_TOKEN_VALUE
```

Load them into the current shell and the macOS GUI environment:

```bash
export VODIA_MCP_TOKEN="$(security find-generic-password -a "$USER" -s "vodia-mcp-read" -w)"
export VODIA_MCP_ADMIN_TOKEN="$(security find-generic-password -a "$USER" -s "vodia-mcp-admin" -w)"

launchctl setenv VODIA_MCP_TOKEN "$VODIA_MCP_TOKEN"
launchctl setenv VODIA_MCP_ADMIN_TOKEN "$VODIA_MCP_ADMIN_TOKEN"

echo "Read token length: ${#VODIA_MCP_TOKEN}"
echo "Admin token length: ${#VODIA_MCP_ADMIN_TOKEN}"
```

Both lengths must be nonzero. Do not use `echo "$VODIA_MCP_ADMIN_TOKEN"`,
because that displays the secret. Run the four load commands again after a Mac
restart, before launching Codex.

## 5. Configure Codex

Edit `~/.codex/config.toml`. On Windows the default path is
`$HOME\.codex\config.toml`. Add:

```toml
[mcp_servers.vodia]
url = "https://YOUR-MCP-DOMAIN/mcp"
bearer_token_env_var = "VODIA_MCP_TOKEN"
enabled = true
required = true
default_tools_approval_mode = "auto"
tool_timeout_sec = 60

[mcp_servers.vodia_admin]
url = "https://YOUR-MCP-DOMAIN/mcp-admin"
bearer_token_env_var = "VODIA_MCP_ADMIN_TOKEN"
enabled = true
required = false
default_tools_approval_mode = "writes"
tool_timeout_sec = 60
```

Do not put either token value in TOML. Quit and reopen Codex after setting the
`launchctl` environment.

## 6. Verify read and administrator access

Ask Codex:

```text
Using Vodia MCP, call get_connector_info and list_domains. Return the connector
version, access mode, tenant count and tenant names. Do not display secrets.
```

Then:

```text
Using Vodia administrator MCP, report the admin profile and write-policy flags.
Find account-create and SIP-trunk update capabilities. Make no changes.
```

Expected profile: `full`. Destructive and critical flags should both be false.

## 7. Validate normal full-admin changes

Account creation, account renaming/settings, SIP-trunk renaming/settings,
trunk enable/disable, dial-plan update and tenant settings are available through
typed planners. Always request a plan first. Example:

```text
Using Vodia administrator MCP, plan creating extension 2201 in tenant
TENANT-DOMAIN for ticket TEST-001. Do not apply it. Show the proposed request,
expiration, request hash and required confirmation without exposing secrets.
```

After reviewing it:

```text
Apply that unchanged change ID using the exact confirmation requested by the
plan. Read the account afterward and report whether the change succeeded.
```

For an existing trunk:

```text
Using Vodia administrator MCP, plan renaming SIP trunk TRUNK-ID in tenant
TENANT-DOMAIN to NEW-NAME for ticket TEST-002. Do not apply it.
```

The current API schema has no documented create-SIP-trunk operation. Create a
new trunk in the Vodia web interface; MCP can then manage the existing trunk.

Create a dial plan through a typed planner:

```text
Using Vodia administrator MCP, plan creating dial plan Emergency in tenant
TENANT-DOMAIN for ticket TEST-003. Do not apply it. Show the exact request and
required confirmation.
```

## 8. Validate live-call control

Use only a disposable test call. First ask Codex to read active calls and return
the exact call ID. Then request a plan:

```text
Using Vodia administrator MCP, plan hanging up CALL-ID for account
EXTENSION@TENANT-DOMAIN because of test ticket TEST-004. Do not apply it.
```

Review both call parties. Apply with the exact dynamic confirmation shown by
the plan, for example `HANGUP CALL-ID`. The apply must succeed even when the
PBX `now` field changes, but it must fail if the call ID disappears first.

## 9. Download a retained PCAP

The binary endpoint uses the dashboard administrator token. From the connector
host or another trusted machine:

```bash
curl -fsS \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -o call.pcap \
  "https://YOUR-MCP-DOMAIN/api/pcap/CALL-ID?domain=TENANT-DOMAIN"
```

Confirm the downloaded file opens in Wireshark. The endpoint validates tenant
ownership and enforces `VODIA_PCAP_LIMIT_BYTES`.

## 10. Enable deletion only when required

Deletion is deliberately off even in the full profile. On the connector server:

```bash
sudoedit /etc/vodia-mcp.env
```

Set:

```text
VODIA_ENABLE_DESTRUCTIVE="true"
```

Then restart and check health:

```bash
sudo systemctl restart vodia-mcp
curl -fsS http://127.0.0.1:3100/health
```

Delete plans require the exact confirmation `DELETE`. Return the switch to
`false` and restart after the maintenance window.

## 11. Critical break-glass writes

Critical system operations include administrator, access-control, certificate,
license, software-update, login/session, global configuration and similar
system-level changes. Enable them only for a reviewed maintenance operation:

```text
VODIA_ENABLE_CRITICAL_WRITES="true"
```

Restart the service. Critical plans require `APPLY-CRITICAL`; critical DELETE
plans also require the destructive switch and `DELETE-CRITICAL`. Prefer
`VODIA_ALLOWED_WRITE_OPERATIONS` to restrict the maintenance window to named
operation IDs. Disable the switch and restart immediately afterward.

## 12. Verify audit redaction

```bash
sudo tail -n 50 /var/log/vodia-mcp/audit.jsonl
sudo stat -c '%A %U:%G %n' /var/log/vodia-mcp/audit.jsonl
```

The audit file must remain `vodiamcp:vodiamcp`, mode 0600. Passwords, tokens and
SIP Authorization values must not appear.

## 13. Roll back

```bash
sudo systemctl stop vodia-mcp
sudo find /opt/vodia-mcp -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
sudo cp -a /opt/vodia-mcp.before-v0.9/. /opt/vodia-mcp/
sudo cp /etc/vodia-mcp.env.before-v0.9 /etc/vodia-mcp.env
sudo systemctl daemon-reload
sudo systemctl restart vodia-mcp
curl -fsS http://127.0.0.1:3100/health
```

The deletion command targets only `/opt/vodia-mcp`. Verify both backup paths
before running it.
