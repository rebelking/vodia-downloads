#!/usr/bin/env bash
set -Eeuo pipefail

# Vodia MCP v0.14.9.6
# Corrects the v0.14.9.5 static validator false-positive, then applies the
# automatic PBX-public-IP + DNS-FIRST workflow from the v0.14.9.5 installer.
#
# v0.14.9.5 did not alter live files when its static validation failed.
# This bootstrap downloads the reviewed v0.14.9.5 installer, rewrites only the
# faulty validation boundary plus version labels, syntax-checks it, and executes it.

SRC_URL="https://raw.githubusercontent.com/rebelking/vodia-downloads/main/upgrade-vodia-mcp-v0.14.9.5-auto-pbx-ip-dns-first.sh"
TMP="$(mktemp /tmp/vodia-mcp-v01496.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
[[ ${EUID} -eq 0 ]] || fail "run as root"
for c in wget python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "$c is required"; done

printf '%s\n' "=== Vodia MCP v0.14.9.6 — automatic PBX IP + DNS-FIRST validator fix ==="
echo "[1/4] Download v0.14.9.5 base installer"
wget -qO "$TMP" "$SRC_URL" || fail "could not download v0.14.9.5 base installer"
[[ -s "$TMP" ]] || fail "downloaded installer is empty"
echo PASS

echo "[2/4] Correct false-positive validator + version labels"
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

old='''plan_start=s.index('async function planCreateTenantWithDns')
apply_start=s.index('async function applyCreateTenantWithDns', plan_start)
plan_block=s[plan_start:apply_start]
# Planner may query Cloudflare API for name conflicts, but must not resolve the new
# tenant hostname through waitForPublicDnsA before a record exists.
if 'waitForPublicDnsA(' in plan_block:
    raise SystemExit('VALIDATION ERROR: planner is attempting public DNS propagation before Cloudflare creation')
'''
new='''plan_start=s.index('async function planCreateTenantWithDns')
# The DNS helper declaration is intentionally located between the planner and the
# apply function in v0.14.9.4. Stop at that helper declaration, not at APPLY,
# otherwise the validator mistakes the helper definition for a planner invocation.
helper_start=s.index('async function waitForPublicDnsA', plan_start)
apply_start=s.index('async function applyCreateTenantWithDns', helper_start)
plan_block=s[plan_start:helper_start]
# Planner may query Cloudflare API for exact-name conflicts, but it must never
# invoke public-DNS propagation for a brand-new hostname before Cloudflare creates it.
if 'await waitForPublicDnsA(' in plan_block:
    raise SystemExit('VALIDATION ERROR: planner invokes public DNS propagation before Cloudflare creation')
'''
if s.count(old) != 1:
    raise SystemExit(f'PATCH ERROR: expected one faulty validator block, found {s.count(old)}')
s=s.replace(old,new,1)

# Promote the installer/runtime version to 0.14.9.6 without changing the feature marker
# used by the underlying patch logic until after its own preflight.
s=s.replace('Vodia MCP v0.14.9.5 — automatic PBX public IPv4 + DNS-FIRST tenant creation',
            'Vodia MCP v0.14.9.6 — automatic PBX public IPv4 + DNS-FIRST tenant creation',1)
s=s.replace('=== Vodia MCP v0.14.9.5 — automatic PBX IP + DNS-FIRST tenant creation ===',
            '=== Vodia MCP v0.14.9.6 — automatic PBX IP + DNS-FIRST tenant creation ===',1)
s=s.replace('v0.14.9.5-auto-pbx-ip-$STAMP','v0.14.9.6-auto-pbx-ip-$STAMP',1)
# Only change the connector version assignment target in the embedded version patch.
s=s.replace("r'\\g<1>0.14.9.5\\2'", "r'\\g<1>0.14.9.6\\2'", 1)

p.write_text(s)
PY
bash -n "$TMP" || fail "corrected installer shell syntax invalid"
grep -q "helper_start=s.index('async function waitForPublicDnsA'" "$TMP" || fail "validator boundary correction missing"
grep -q "if 'await waitForPublicDnsA(' in plan_block" "$TMP" || fail "planner invocation-only validation missing"
echo PASS

echo "[3/4] Execute corrected installer"
chmod +x "$TMP"
"$TMP"

echo "[4/4] v0.14.9.6 complete"
echo "PASS: corrected validator distinguishes helper declaration from planner invocation"
echo "PASS: planner allows brand-new tenant hostname to be unresolved"
echo "PASS: PBX public IPv4 is derived from configured Vodia endpoint"
echo "PASS: APPLY remains Cloudflare create -> public DNS propagation -> Vodia tenant create"
