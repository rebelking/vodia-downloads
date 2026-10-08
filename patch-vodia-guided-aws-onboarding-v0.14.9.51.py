#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-vodia-guided-aws-onboarding-v0.14.9.51.py BACKEND")
p=Path(sys.argv[1]); s=p.read_text()
if 'VODIA_AWS_AUTO_REUSE_V51' in s:
    raise SystemExit(0)
if 'VODIA_AWS_ONBOARDING_V50' not in s:
    raise SystemExit('PATCH ERROR: v0.14.9.50 backend marker missing')

anchor='''export function registerMspCustomerConnectionTools(server, ctx) {'''
helper='''function isAssumeRoleDenied(error) {
  const text=String(error?.message || error || "");
  return error?.name === "AccessDenied" || /AccessDenied|not authorized to perform:\\s*sts:AssumeRole/i.test(text);
}

async function reuseAccessibleAwsConnectionForAccount(targetCustomerId, accountId, extra) {
  // VODIA_AWS_AUTO_REUSE_V51: only reuse an exact-account connection that
  // this OAuth identity can access, and always re-test it with STS first.
  const data=readAll();
  const candidates=Object.entries(data.customers || {})
    .filter(([id,record]) => id !== targetCustomerId && record?.aws?.account === accountId)
    .sort((a,b) => String(b[1]?.aws?.savedAt || "").localeCompare(String(a[1]?.aws?.savedAt || "")));
  for (const [sourceCustomerId] of candidates) {
    try {
      requireCustomerAccess(extra, sourceCustomerId, ["MSP_ADMIN","CUSTOMER_ADMIN"]);
    } catch {
      continue;
    }
    try {
      const result=await reuseScopedAwsConnection(sourceCustomerId,targetCustomerId);
      return { ...result, reusedFromCustomerId: sourceCustomerId };
    } catch {
      // A stored source can be stale after an IAM trust-policy change. Try the
      // next accessible connection for the same account without exposing data.
    }
  }
  return null;
}

'''
if s.count(anchor)!=1:
    raise SystemExit(f'PATCH ERROR: tool registration anchor count={s.count(anchor)}')
s=s.replace(anchor,helper+anchor,1)

old='''      const result = await completeScopedAwsOnboarding(customerId, accountId);
      scopedAudit("msp_complete_customer_aws_onboarding", { customerId, subject: access.identity.subject, account: result.identity.account });
      return scopedSuccess({ customerId, connection: result.connection, identity: result.identity, changesMade: true },
        { operation: "MSP_CUSTOMER_AWS_ONBOARDING_COMPLETE", readOnly: false },
        "Customer AWS account verified and connected.");'''
new='''      let result;
      let reusedFromCustomerId=null;
      try {
        result = await completeScopedAwsOnboarding(customerId, accountId);
      } catch (error) {
        if (!isAssumeRoleDenied(error)) throw error;
        const reused = await reuseAccessibleAwsConnectionForAccount(customerId, accountId, extra);
        if (!reused) throw error;
        result = reused;
        reusedFromCustomerId = reused.reusedFromCustomerId;
      }
      scopedAudit("msp_complete_customer_aws_onboarding", {
        customerId, subject: access.identity.subject, account: result.identity.account,
        reusedExistingConnection: Boolean(reusedFromCustomerId), reusedFromCustomerId
      });
      return scopedSuccess({
          customerId, connection: result.connection, identity: result.identity,
          reusedExistingConnection: Boolean(reusedFromCustomerId), changesMade: true
        },
        { operation: "MSP_CUSTOMER_AWS_ONBOARDING_COMPLETE", readOnly: false },
        reusedFromCustomerId
          ? "Existing verified AWS account connection retested and reused securely."
          : "Customer AWS account verified and connected.");'''
if s.count(old)!=1:
    raise SystemExit(f'PATCH ERROR: completion handler anchor count={s.count(old)}')
s=s.replace(old,new,1)
p.write_text(s)
