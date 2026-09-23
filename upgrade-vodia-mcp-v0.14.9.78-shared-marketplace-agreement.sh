#!/usr/bin/env bash
set -Eeuo pipefail
APP="${VODIA_MCP_APP_DIR:-/opt/vodia-mcp}"; SERVICE="${VODIA_MCP_SERVICE:-vodia-mcp}"
B="$APP/aws-marketplace-ec2-deploy-v1.js"; U="$APP/ui/msp-guided-app.html"; G="$APP/msp-guided-app-v1.js"; V="$APP/version.js"
TMP="$(mktemp -d)"; DRY="${VODIA_MCP_DRY_RUN:-0}"; STAMP="$(date -u +%Y%m%d-%H%M%S)"; BK="/var/backups/vodia-mcp-v0.14.9.78-shared-agreement-$STAMP"
trap 'rm -rf "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
for f in "$B" "$U" "$G" "$V"; do [[ -f "$f" ]] || fail "missing $f"; done
CUR="$(grep -oE 'CONNECTOR_VERSION[^0-9]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$V" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
case "$CUR" in 0.14.9.76|0.14.9.77|0.14.9.78) ;; *) fail "expected .76/.77/.78; found ${CUR:-unknown}";; esac
mkdir -p "$TMP/s"; cp -a "$B" "$TMP/s/b.js"; cp -a "$U" "$TMP/s/u.html"; cp -a "$G" "$TMP/s/g.js"; cp -a "$V" "$TMP/s/v.js"
echo "=== Vodia MCP v0.14.9.78 — shared active Marketplace agreement ==="
echo "[1/6] Stage backend — NO LIVE CHANGES"
python3 - "$TMP/s/b.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_SHARED_MARKETPLACE_AGREEMENT_V78' not in s:
    a='const VODIA_AWS_PRODUCT_INVENTORY_V72 = true;'; i=s.find(a)
    if i<0: raise SystemExit('PATCH ERROR: inventory marker missing')
    e=s.find('\n',i); s=s[:e+1]+'const VODIA_SHARED_MARKETPLACE_AGREEMENT_V78 = true;\n'+s[e+1:]
# Planner: same active agreement may already have deployments.
s=s.replace('        if(planningMatches.length) throw agreementInUseError(selectedAgreement.agreementId,planningMatches);\n','',1)
s=re.sub(r'''\n        const selectedUsage = await reconcileMarketplaceAgreementUsage\(.*?\n        \}\n\n        const client = ec2Client''','''\n\n        const client = ec2Client''',s,count=1,flags=re.S)
# Apply: same active agreement may already have deployments; PBX-name duplicate guard remains.
s=s.replace('          if(launchMatches.length) throw agreementInUseError(plan.agreementId,launchMatches);\n','',1)
# Subscription summary no longer says an agreement is unavailable because it has an instance.
s=s.replace('''        const summary = enriched.active
          ? ("Active Marketplace agreement(s) found: " + enriched.availableAgreementCount + " available, " + enriched.inUseAgreementCount + " already assigned.")
          : "No active Marketplace agreement found.";''','''        const summary = enriched.active
          ? ("Active Marketplace agreement(s) found: " + (enriched.agreements?.length ?? 0) + ". Existing EC2 deployments do not lock an ACTIVE agreement from another Vodia AMI launch.")
          : "No active Marketplace agreement found.";''',1)
# Termination applies to the EC2 instance, not an exclusive agreement slot.
s=s.replace('title: "Terminate Vodia PBX and release deployment slot",','title: "Terminate Vodia PBX instance",',1)
s=s.replace('releaseAgreementOnTermination:true,','releaseAgreementOnTermination:false,',1)
s=s.replace('agreementReleasePending:true,','agreementReleasePending:false,\n          agreementRemainsReusable:true,',1)
s=s.replace('The Vodia deployment slot will be released only after AWS confirms terminated.','The EC2 instance will terminate; the active Marketplace agreement remains reusable.',1)
p.write_text(s)
PY

echo "[2/6] Stage UI"
python3 - "$TMP/s/u.html" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_SHARED_MARKETPLACE_AGREEMENT_UI_V78' not in s:
    a='const VODIA_MARKETPLACE_PRODUCT_ID='; i=s.find(a)
    if i<0: raise SystemExit('PATCH ERROR: product constant missing')
    e=s.find('\n',i); s=s[:e+1]+'  const VODIA_SHARED_MARKETPLACE_AGREEMENT_UI_V78 = true;\n'+s[e+1:]
# Treat every AWS ACTIVE agreement as selectable, regardless of deploymentUsage.
s=s.replace('const availableAgreements=agreements.filter(a=>a?.deploymentUsage?.status==="AVAILABLE");','const availableAgreements=agreements.filter(a=>String(a?.status||"ACTIVE").toUpperCase()==="ACTIVE");',1)
s=s.replace('const available=usage.status==="AVAILABLE";','const available=String(agreement?.status||"ACTIVE").toUpperCase()==="ACTIVE";',1)
s=s.replace('"Available for deployment: "+availableAgreements.length,','"ACTIVE agreement(s) selectable: "+availableAgreements.length,',1)
s=s.replace('"Already assigned / used: "+usedCount,','"Agreement(s) with existing deployments: "+usedCount,',1)
s=s.replace('"Selected AVAILABLE agreement: "+selectedId','"Selected ACTIVE agreement: "+selectedId',1)
s=s.replace('WARNING: duplicate active EC2 instances use the same Marketplace agreement.','Shared Marketplace agreement has multiple active EC2 instances.',1)
s=s.replace('Duplicate agreement(s): ','Shared agreement(s): ',1)
s=s.replace('(machine.duplicateAgreement?"DUPLICATE · ":"")','(machine.duplicateAgreement?"SHARED AGREEMENT · ":"")',1)
s=s.replace('Duplicate count on this agreement: ','Deployments using this agreement: ',1)
s=s.replace('"Choose an AVAILABLE subscription for this deployment. Agreements already assigned to a PBX are locked."','"Choose an ACTIVE Marketplace agreement. Existing Vodia EC2 deployments do not lock the agreement."',1)
s=s.replace('"All active subscriptions are already assigned. Start another subscription before deploying another PBX."','"Choose an ACTIVE Marketplace agreement. Existing Vodia EC2 deployments do not lock the agreement."',1)
s=s.replace('return Boolean(r.active && (r.availableAgreementCount??0)>0);','return Boolean(r.active && (r.agreements?.length??0)>0);',1)
s=s.replace('Terminate & release','Terminate instance')
s=s.replace('The Vodia deployment slot has been released.','The EC2 instance is terminated. The Marketplace agreement remains active and reusable.')
s=re.sub(r'uiVersion:"0\.14\.9\.\d+"','uiVersion:"0.14.9.78"',s)
p.write_text(s)
PY
python3 - "$TMP/s/g.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); n,c=re.subn(r'ui://vodia/msp-guided/v0\.14\.9\.\d+/mcp-app\.html','ui://vodia/msp-guided/v0.14.9.78/mcp-app.html',s,count=1)
if c!=1: raise SystemExit('PATCH ERROR: URI anchor missing')
p.write_text(n)
PY
python3 - "$TMP/s/v.js" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); n,c=re.subn(r'(CONNECTOR_VERSION\s*=\s*["\'])[^"\']+(["\'])',r'\g<1>0.14.9.78\2',s,count=1)
if c!=1: raise SystemExit('PATCH ERROR: version anchor missing')
p.write_text(n)
PY

echo "[3/6] Validate staged patch"
node --check "$TMP/s/b.js" >/dev/null || fail "backend JS invalid"
python3 - "$TMP/s/u.html" "$TMP/s/inline.js" <<'PY'
from pathlib import Path
import re,sys
h=Path(sys.argv[1]).read_text(); x=re.findall(r'<script(?:\s[^>]*)?>(.*?)</script>',h,re.S|re.I)
Path(sys.argv[2]).write_text('\n'.join(x))
PY
node --check "$TMP/s/inline.js" >/dev/null || fail "UI JS invalid"
grep -Fq 'VODIA_SHARED_MARKETPLACE_AGREEMENT_V78' "$TMP/s/b.js" || fail "backend marker missing"
grep -Fq 'VODIA_SHARED_MARKETPLACE_AGREEMENT_UI_V78' "$TMP/s/u.html" || fail "UI marker missing"
! grep -Fq 'if(planningMatches.length) throw agreementInUseError' "$TMP/s/b.js" || fail "planner still blocks reuse"
! grep -Fq 'if(launchMatches.length) throw agreementInUseError' "$TMP/s/b.js" || fail "apply still blocks reuse"
echo "PASS: ACTIVE agreement reuse staged; duplicate PBX-name protection remains"
if [[ "$DRY" == 1 ]]; then echo; echo "DRY RUN PASS: v0.14.9.78 staged patch validated successfully."; echo "DRY RUN: no live files changed, no service restarted, no AWS resources changed."; exit 0; fi

echo "[4/6] Backup + install"
mkdir -p "$BK"; cp -a "$B" "$BK/b.js"; cp -a "$U" "$BK/u.html"; cp -a "$G" "$BK/g.js"; cp -a "$V" "$BK/v.js"
rollback(){ cp -a "$BK/b.js" "$B" || true; cp -a "$BK/u.html" "$U" || true; cp -a "$BK/g.js" "$G" || true; cp -a "$BK/v.js" "$V" || true; systemctl restart "$SERVICE" || true; }
trap 'rc=$?; if [[ $rc -ne 0 ]]; then rollback; fi; rm -rf "$TMP"; exit $rc' EXIT
install -m 0644 "$TMP/s/b.js" "$B"; install -m 0644 "$TMP/s/u.html" "$U"; install -m 0644 "$TMP/s/g.js" "$G"; install -m 0644 "$TMP/s/v.js" "$V"; systemctl restart "$SERVICE"
echo "[5/6] Health"
for _ in {1..30}; do H="$(curl -fsS http://127.0.0.1:3100/health 2>/dev/null || true)"; [[ -n "$H" ]] && break; sleep 1; done
[[ "$H" == *'"version":"0.14.9.78"'* ]] || fail "health does not report .78: $H"; echo "$H"
echo "[6/6] Complete"
echo "PASS: v0.14.9.78 installed — ACTIVE Marketplace agreement reuse enabled; duplicate PBX names still blocked."
echo "Backup: $BK"
