# Vodia Pharmacy AI Installation Guide

This guide explains how to install the Vodia Pharmacy AI demo portal and connect it to a Vodia PBX Audio AI agent.

The setup uses:

- NPM package: `vodia-pharmacy-ai@0.2.3`
- Git/Cloudflare Pages for installer, docs, and full Audio AI script
- Public installer URL: `https://get.tryvodia.com/pharmacy-ai/install-ubuntu.sh`

---

## 1. DNS Must Be Ready First

For HTTPS setup, the domain must point to the server before the installer continues.

Example:

```text
pharmacytest.audiomercy.com


## DNS Preflight Wizard

For HTTPS installs, use a real public hostname/FQDN that you or the customer controls.

Examples:
- ai.customer-domain.com
- refills.mypharmacy.com
- pharmacy.company.org

The hostname does not need to be tryvodia.com.

If DNS does not point to the server yet, the installer will show the required A record.

If you misspell the hostname during the wizard, choose:

3) Re-enter hostname/FQDN

To rerun only the DNS wizard without reinstalling the app:

curl -fsSL https://raw.githubusercontent.com/rebelking/vodia-downloads/feature/pharmacy-installer-polish/pharmacy-ai/install-ubuntu.sh -o /tmp/install-pharmacy-ai-polish.sh
chmod +x /tmp/install-pharmacy-ai-polish.sh
sudo DNS_ONLY=true ENABLE_HTTPS=true bash /tmp/install-pharmacy-ai-polish.sh

Or pass the corrected hostname directly:

sudo DNS_ONLY=true ENABLE_HTTPS=true DOMAIN=ai.customer-domain.com bash /tmp/install-pharmacy-ai-polish.sh

