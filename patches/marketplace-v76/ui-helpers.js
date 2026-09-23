  // VODIA_MARKETPLACE_FEEDBACK_V76
  const marketplaceToolsV76 = new Set([
    "aws_marketplace_present_vodia_offer", "aws_marketplace_prepare_vodia_purchase",
    "aws_marketplace_accept_vodia_purchase", "aws_marketplace_check_subscription"
  ]);
  function marketplaceResultErrorV76(result) {
    const candidates = [result, result?.structuredContent];
    const texts = (result?.content || []).filter(x=>x?.type === "text").map(x=>x.text);
    for (const text of texts) { try { candidates.push(JSON.parse(text)); } catch {} }
    for (const item of [...candidates]) {
      if (item?.data) candidates.push(item.data);
      if (item?.result) candidates.push(item.result);
    }
    const failed = candidates.find(x=>x && (x.isError === true || x.ok === false || x.success === false || x.error || x.status === "error" || x.status === "failed"));
    if (!failed) return "";
    for (const item of [failed, ...candidates]) {
      const msg = item?.error?.message || (typeof item?.error === "string" ? item.error : null) || item?.message;
      if (msg) return String(msg);
    }
    return texts.join("\n") || "AWS Marketplace request failed without error details.";
  }
  function clearMarketplaceQuoteV76() {
    currentMarketplaceQuote = null;
    $("marketplaceApproval").value = "";
    $("acceptMarketplaceQuote").disabled = true;
    $("marketplaceQuoteBox").classList.add("hidden");
  }
  function showMarketplaceFailureV76(message) {
    const node = $("marketplaceErrorV76");
    node.textContent = String(message || "AWS Marketplace request failed.");
    node.classList.remove("hidden");
    // Place feedback beside the quote button, independently of the step-level message.
    node.scrollIntoView?.({block:"nearest"});
    reportSize();
  }
  function renderLicenseEvidenceV76(subscription) {
    const evidence = subscription?.licenseEvidence;
    const lines = ["License check: " + (evidence?.status || "UNKNOWN"),
      "Checked: " + (evidence?.checkedAt || "Not completed")];
    for (const license of evidence?.licenses || []) {
      lines.push("", "License: " + license.licenseArn, "SKU: " + license.productSKU,
        "Status: " + license.status + " / " + (license.receivedStatus || "unknown"));
      for (const unit of license.entitlements || []) {
        const usage = license.usage?.find(x=>x.Name === unit.Name && x.Unit === unit.Unit);
        lines.push(unit.Name + " (" + unit.Unit + "): purchased " + (unit.MaxCount ?? unit.Value ?? "unknown") +
          "; consumed " + (usage?.ConsumedValue ?? "unknown"));
      }
    }
    for (const error of evidence?.errors || []) lines.push("Read failed: " + error);
    lines.push("", evidence?.explanation || "Capacity is unverified. Refresh before deployment.");
    $("marketplaceLicenseEvidenceV76").textContent = lines.join("\n");
  }
  $("refreshMarketplaceLicensesV76").addEventListener("click",()=>checkMarketplaceSubscription());
  ["marketplacePlanSelect", "marketplaceQuantity", "marketplaceAutoRenew", "marketplaceOfferSelect"].forEach(id=>{
    $(id).addEventListener("change",clearMarketplaceQuoteV76);
    $(id).addEventListener("input",clearMarketplaceQuoteV76);
  });
