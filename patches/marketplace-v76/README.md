# Vodia MCP 0.14.9.76 — Marketplace purchase feedback

Patches installed 0.14.9.73–0.14.9.75 source in a staging directory. An unknown layout fails before any live change. Reapplying .76 is supported. Existing one-click, inventory, SSH-key, and capacity-failover changes are preserved.

Changes:

- Marketplace tool error envelopes are checked before unwrapping data. Original AWS errors are visible beside the quote control, with operation/error/request-ID details for CreateAgreementRequest failures.
- Adds an ordinary AWS Marketplace subscriptions link and a selectable URL, independent of clipboard permission.
- Refresh reads all agreement pages, EC2 inventory, and License Manager entitlements/usage using the customer's scoped credentials. Partial inventory blocks new deployment plans and launches. Failed refresh clears stale approval state.
- Old quotes are cleared before retrying or changing purchase controls. Purchase acceptance and deployment still require their existing exact confirmations.
- License Manager results are informational. **This patch does not unlock a second PBX on an assigned agreement.** A license dimension may represent extensions or channels, not PBXs. The agreement/license association and Vodia allocation rules must be verified before implementing that behavior. An unused active agreement continues through the existing plan/approve/deploy flow.
- No purchase, cancellation, termination, or PBX launch is performed by installation or refresh.

## Install

Extract the delivered archive, enter its `marketplace-v76` directory, then:

```bash
sudo env VODIA_MCP_DRY_RUN=1 bash install.sh
sudo bash install.sh
```

Requires Node 20+, Python 3, npm, and network access to the npm registry. The locked License Manager SDK is installed in its own directory; existing application dependencies are untouched. The installer backs up source, verifies health on port 3100, and restores source if installation/restart/health verification fails. Save the printed backup path.

Reconnect the MCP client and open a fresh **Vodia Setup** card to load the new UI URI.

## License read access

`license-read-policy.json` is an additive read-only policy for the **customer's VodiaMCPDeploymentRole**. Have the account's IAM administrator add it if refresh returns AccessDenied. The installer does not change IAM policies. Existing deployment/purchase permissions must remain.

License lookup uses exact ProductSKU equality to the configured product identifier/code and follows HomeRegion for usage. If the listing exposes a different SKU or requires a different licensing integration, the UI reports `NO_EXACT_SKU_MATCH`; it does not guess a license, infer zero consumption, or unlock an assigned agreement. An empty, missing, denied, or partial license read is not proof of spare capacity.

## Live verification

1. Trigger the previously failing quote. The actual error must appear beside the button, and the button must re-enable. No acceptance occurs.
2. Open the AWS link, or manually copy the displayed URL. Select Vodia under the same customer account. Review contract/quantity options and pricing in AWS.
3. Return and click **Refresh subscriptions and licenses**. Allow up to ten minutes after a purchase. Confirm agreement state, exact SKU, units and consumed quantity, or a clear read failure.
4. PBXM's existing allocation must remain unchanged. A newly available agreement can be selected and planned. Reusing PBXM's assigned agreement remains blocked pending verified allocation rules.
5. Select region and SSH key, then validate the deployment plan. Stop at review until you explicitly approve deployment.

Rollback: stop the service, restore the four backed-up source files (including `ui/msp-guided-app.html`) and any previous `marketplace-v76` module directory from the printed backup, then restart. Preserve the backup for investigation.
