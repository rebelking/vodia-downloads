#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: patch-vodia-marketplace-subscription-select-v0.14.9.73.py AWS_MARKETPLACE_BACKEND")

path = Path(sys.argv[1])
s = path.read_text()

MARKER = "VODIA_MARKETPLACE_SUBSCRIPTION_SELECT_V73"
if MARKER in s:
    print("already patched")
    raise SystemExit(0)

old_import = '''  MarketplaceAgreementClient,
  SearchAgreementsCommand,
  CreateAgreementRequestCommand,
  AcceptAgreementRequestCommand
} from "@aws-sdk/client-marketplace-agreement";'''
new_import = '''  MarketplaceAgreementClient,
  SearchAgreementsCommand,
  GetAgreementTermsCommand,
  CreateAgreementRequestCommand,
  AcceptAgreementRequestCommand
} from "@aws-sdk/client-marketplace-agreement";'''
if s.count(old_import) != 1:
    raise SystemExit(f"PATCH ERROR: agreement import anchor count={s.count(old_import)}")
s = s.replace(old_import, new_import, 1)

anchor = '''async function checkSubscription(roleArn, externalId, productId) {
  const client = agreementClient(roleArn, externalId);'''
helper = r'''
const VODIA_MARKETPLACE_SUBSCRIPTION_SELECT_V73 = true;

function agreementTermDimensionView(acceptedTerms) {
  const dimensions = [];
  let currencyCode = null;
  let selectorValue = null;
  let autoRenew = null;
  for (const wrapper of acceptedTerms || []) {
    const pricing = wrapper?.configurableUpfrontPricingTerm;
    if (pricing) {
      currencyCode = pricing.currencyCode || currencyCode;
      for (const rc of pricing.rateCards || []) {
        selectorValue = rc?.selector?.value || selectorValue;
        for (const item of rc.rateCard || []) {
          if (!item?.dimensionKey) continue;
          dimensions.push({
            dimensionKey: item.dimensionKey,
            sku: item.dimensionKey,
            displayName: item.displayName || item.dimensionKey,
            description: item.description || null,
            unit: item.unit || null,
            price: item.price || null,
            quantity: item.dimensionValue ?? item.quantity ?? null,
            currencyCode: pricing.currencyCode || null,
            selectorValue: rc?.selector?.value || null
          });
        }
      }
    }
    const renewal = wrapper?.renewalTerm;
    if (renewal?.configuration?.enableAutoRenew != null) {
      autoRenew = Boolean(renewal.configuration.enableAutoRenew);
    }
  }
  return { dimensions, currencyCode, selectorValue, autoRenew };
}

async function getAgreementSelectionDetails(roleArn, externalId, agreement) {
  const agreementId = agreement?.agreementId;
  if (!agreementId) return { ...agreement, sku: null, dimensions: [], selectable: false };
  try {
    const client = agreementClient(roleArn, externalId);
    const out = await client.send(new GetAgreementTermsCommand({
      agreementId,
      maxResults: 100
    }));
    const termView = agreementTermDimensionView(out.acceptedTerms || []);
    const primary = termView.dimensions.length === 1 ? termView.dimensions[0] : null;
    return {
      ...agreement,
      sku: primary?.sku || null,
      dimensionKey: primary?.dimensionKey || null,
      planName: primary?.displayName || null,
      dimensions: termView.dimensions,
      currencyCode: termView.currencyCode,
      selectorValue: termView.selectorValue,
      autoRenew: termView.autoRenew,
      selectable: true,
      termsReadError: null
    };
  } catch (error) {
    return {
      ...agreement,
      sku: null,
      dimensionKey: null,
      planName: null,
      dimensions: [],
      selectable: true,
      termsReadError: String(error?.message || error)
    };
  }
}

async function listSelectableVodiaSubscriptions(roleArn, externalId, customerId, productId) {
  const subscription = await checkSubscription(roleArn, externalId, productId);
  if (!subscription.active) {
    return { ...subscription, agreements: [], availableAgreementCount: 0, inUseAgreementCount: 0 };
  }
  const enriched = await enrichMarketplaceSubscriptionUsage(
    roleArn, externalId, customerId || null, productId, subscription
  );
  const agreements = [];
  for (const agreement of enriched.agreements || []) {
    const detailed = await getAgreementSelectionDetails(roleArn, externalId, agreement);
    const usage = detailed.deploymentUsage || { status: "RECONCILIATION_NEEDED" };
    agreements.push({
      ...detailed,
      selectable: usage.status === "AVAILABLE",
      deploymentAllowed: usage.status === "AVAILABLE",
      deploymentBlockedReason: usage.status === "AVAILABLE" ? null : usage.status
    });
  }
  return {
    ...enriched,
    agreements,
    availableAgreementCount: agreements.filter(a => a.deploymentAllowed).length,
    inUseAgreementCount: agreements.filter(a => !a.deploymentAllowed).length
  };
}

'''
if s.count(anchor) != 1:
    raise SystemExit(f"PATCH ERROR: checkSubscription anchor count={s.count(anchor)}")
s = s.replace(anchor, helper + anchor, 1)

tool_anchor = '''  server.registerTool(
    "aws_marketplace_check_subscription",'''
tool = r'''  server.registerTool(
    "aws_marketplace_list_vodia_subscriptions",
    {
      title: "List selectable Vodia Marketplace subscriptions",
      description: "Lists ACTIVE Vodia AWS Marketplace agreements, accepted contract dimensions/SKU, and whether each agreement is available or already assigned to a PBX. Read-only. Use the selected agreementId with aws_marketplace_plan_vodia_pbx_deployment.",
      inputSchema: {
        customerId: z.string().uuid().optional(),
        roleArn: z.string().min(20).optional(),
        externalId: z.string().min(8).optional(),
        productId: z.string().min(3)
      },
      outputSchema: toolOutputSchema,
      annotations: { readOnlyHint: true, destructiveHint: false, openWorldHint: true }
    },
    async ({ customerId, roleArn, externalId, productId }, extra) => {
      scopedAudit("aws_marketplace_list_vodia_subscriptions", { customerId: customerId || null, roleArn, productId });
      try {
        const c = resolveToolConnection({ customerId, roleArn, externalId }, extra);
        const result = await listSelectableVodiaSubscriptions(
          c.roleArn, c.externalId, c.customerId || null, productId
        );
        return scopedSuccess(
          { ...result, changesMade: false },
          { operation: "AWS_MARKETPLACE_LIST_VODIA_SUBSCRIPTIONS", readOnly: true },
          result.active
            ? `Vodia Marketplace subscriptions loaded: ${result.availableAgreementCount} available, ${result.inUseAgreementCount} already assigned.`
            : "No active Vodia Marketplace subscription found."
        );
      } catch (error) {
        return failure(error, "AWS Marketplace Vodia subscription selection");
      }
    }
  );

'''
if s.count(tool_anchor) != 1:
    raise SystemExit(f"PATCH ERROR: subscription tool anchor count={s.count(tool_anchor)}")
s = s.replace(tool_anchor, tool + tool_anchor, 1)

# Make the planner contract explicit: agreementId is the selected Marketplace subscription.
old_desc = 'description: "Creates a short-lived deployment plan only after an ACTIVE AWS Marketplace agreement is verified. Performs EC2 RunInstances DryRun to validate IAM, Marketplace entitlement, AMI, network, instance profile, and launch parameters. Makes no EC2 changes.",'
new_desc = 'description: "Creates a short-lived deployment plan for the selected ACTIVE Vodia Marketplace agreement. Pass agreementId from aws_marketplace_list_vodia_subscriptions. Resolves the regional AWS Marketplace AMI by Vodia product code and performs EC2 RunInstances DryRun. Makes no EC2 changes.",'
if s.count(old_desc) != 1:
    raise SystemExit(f"PATCH ERROR: planner description anchor count={s.count(old_desc)}")
s = s.replace(old_desc, new_desc, 1)

path.write_text(s)
print("PASS: installed selectable Marketplace subscription/SKU flow")
