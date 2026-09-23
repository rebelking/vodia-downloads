// Read-only evidence. License units must not be interpreted as PBX instances.
export function purchaseError(error, operation = "CreateAgreementRequest") {
  const code = error?.code || error?.Code || error?.name || "AWS_ERROR";
  const requestId = error?.$metadata?.requestId;
  const message = String(error?.message || error);
  const unsupported = /UNSUPPORTED_ACTION|not supported/i.test(code + " " + message);
  const detail = [operation, code, requestId ? "request " + requestId : null,
    error?.$metadata?.httpStatusCode ? "HTTP " + error.$metadata.httpStatusCode : null].filter(Boolean).join("; ");
  const out = new Error(message + " [" + detail + "]" + (unsupported
    ? " Review the purchase or amendment in AWS Marketplace. This error alone does not establish that all AMI-contract purchases are unsupported."
    : ""));
  out.name = String(code);
  return out;
}

export async function readLicenseEvidence({credentials, productId, productCode, region = "us-east-1", sdk}) {
  const checkedAt = new Date().toISOString();
  const result = {status:"UNKNOWN", checkedAt, region, licenses:[], errors:[],
    deploymentCapacityVerified:false,
    explanation:"License units are evidence, not a count of deployable PBXs. Agreement-to-license mapping and Vodia consumption rules must be verified before reusing an assigned agreement."};
  try {
    sdk ||= await import("@aws-sdk/client-license-manager");
    const client = new sdk.LicenseManagerClient({region, credentials});
    // Exact identifiers only; never match by product name or choose an arbitrary license.
    const skus = [...new Set([productId, productCode].filter(Boolean))];
    const licenses = new Map();
    for (const sku of skus) {
      let NextToken;
      const seen = new Set();
      do {
        const page = await client.send(new sdk.ListReceivedLicensesCommand({
          Filters:[{Name:"ProductSKU", Values:[sku]}], MaxResults:100, ...(NextToken ? {NextToken} : {})
        }));
        for (const item of page.Licenses || []) {
          if (item.LicenseArn && skus.includes(item.ProductSKU)) licenses.set(item.LicenseArn, item);
        }
        NextToken = page.NextToken;
        if (NextToken && seen.has(NextToken)) throw new Error("Repeated License Manager pagination token");
        seen.add(NextToken);
      } while (NextToken);
    }
    for (const item of licenses.values()) {
      const view = {licenseArn:item.LicenseArn, productSKU:item.ProductSKU, status:item.Status,
        receivedStatus:item.ReceivedMetadata?.ReceivedStatus || null, validity:item.Validity || null,
        homeRegion:item.HomeRegion || region, entitlements:item.Entitlements || [], usage:null};
      result.licenses.push(view);
      try {
        const usageClient = item.HomeRegion && item.HomeRegion !== region
          ? new sdk.LicenseManagerClient({region:item.HomeRegion, credentials}) : client;
        const out = await usageClient.send(new sdk.GetLicenseUsageCommand({LicenseArn:item.LicenseArn}));
        view.usage = out.LicenseUsage?.EntitlementUsages || [];
      } catch (error) {
        view.error = purchaseError(error, "GetLicenseUsage").message;
        result.errors.push(view.error);
      }
    }
    result.status = result.errors.length ? "PARTIAL" : result.licenses.length ? "READ" : "NO_EXACT_SKU_MATCH";
  } catch (error) {
    result.errors.push(purchaseError(error, "ListReceivedLicenses").message);
  }
  return result;
}
