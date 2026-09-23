# Validation

Tested September 23, 2026 against a local cumulative fixture assembled from the preserved .73 regional-key source plus the repository's .72 one-click, .73 wiring, .74 scope, and .75 inventory/capacity scripts at commit `c0805913f0265016fe71a29d755f57dce4a75b47`.

- 11 behavioral regression tests passed, including the actual extracted UI quote handler, MCP error envelopes, stale quote/customer handling, failed refresh, license pagination/permissions, agreement pagination, and partial inventory blocking.
- 2 patch tests passed: repeat application is byte-for-byte stable; unknown source layout is rejected before writing source.
- Backend, guided resource module, version module, inline browser script, helper module, and shell installer syntax checks passed.
- Installer dry run passed, including `npm ci` with the supplied lockfile and loading the actual License Manager SDK. No shared application dependencies were modified.

No test called AWS, accepted a purchase, launched/terminated an instance, changed IAM, or restarted the live MCP. Deployment on the user's server and an authenticated AWS refresh remain to be validated.

Run tests against an unpatched local fixture:

```bash
python3 test-patch.py /path/to/fixture
python3 patch.py /path/to/fixture
node test.mjs /path/to/fixture
VODIA_MCP_DRY_RUN=1 VODIA_MCP_APP_DIR=/path/to/fixture bash install.sh
```

Run patch.py only against staging/test files. Use install.sh for a live server because it performs backup, restart, health verification, and rollback.
