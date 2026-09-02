# Verified Vodia REST actions and write payloads

This document records Vodia REST request shapes that have been verified from
official documentation, live PBX reads, or reviewed Vodia administrator-portal
captures. It is intended as training material for another AI or administrator.

Do not copy PBX cookies, authorization headers, API passwords, phone serial
numbers, or provisioning credentials into prompts, logs, examples, or tickets.

## Safety model used by the MCP

1. A typed planner validates the tenant, target, and required fields.
2. Planning does not change the PBX.
3. The plan returns an exact confirmation phrase.
4. `apply_vodia_change` accepts only the unchanged, unexpired, single-use plan
   and exact confirmation phrase.
5. The MCP performs a verification read after applying the action.

## Provision a tenant MAC entry

```http
POST /rest/domain/{domain}/macs
Content-Type: application/json
```

```json
{
  "mac": "000413910461",
  "vendor": "Polycom",
  "model": "VVX450",
  "siptrans": "tls",
  "prov_t38": "true",
  "refresh": "true",
  "name": "Front Desk",
  "extensions": "2009",
  "pin": ""
}
```

Notes:

- MAC addresses are normalized to twelve uppercase hexadecimal characters.
- Vendor and model strings are validated against the live tenant phone catalog.
- `siptrans`: `""`, `"tls"`, `"tcp"`, or `"udp"`.
- `prov_t38`: `""`, `"true"`, or `"false"`.
- `refresh`: `""`, `"true"`, or `"false"`.
- The full Yealink serial number is mapped to the legacy wire field `pin` and is
  always treated as secret. Do not supply a serial number for Fanvil phones.

## Provision a Fanvil phone through the portal workflow

```http
POST /rest/system/prov_phones
Content-Type: application/json
```

```json
{
  "mac": "0C383E15C577",
  "pin": "",
  "vendor": "Fanvil",
  "model": "V64",
  "ip": "",
  "extension": "2003",
  "name": "Fanvil",
  "siptrans": "",
  "prov_t38": "",
  "domain": "pbx.example.com"
}
```

Fanvil does not require a serial ID in this workflow.

## Trigger phone provisioning

Verified from the tenant MAC portal on Vodia PBX 70.5:

```http
GET /rest/domain/{domain}/check-sync?mac={MAC}&reboot=false
```

Expected JSON response:

```json
true
```

MCP planner: `plan_trigger_mac_provisioning`.

## Trigger phone reboot/resync

Verified from the tenant MAC portal and PBX logs on Vodia PBX 70.5:

```http
GET /rest/domain/{domain}/check-sync?mac={MAC}&reboot=true
```

Expected JSON response:

```json
true
```

The PBX log reported `Resync device initiated`; the phone subsequently fetched
its generated configuration. This can interrupt an active phone call.

MCP planner: `plan_trigger_mac_reboot`.

## Read provisioning history

```http
GET /rest/domain/{domain}/generated?mac={MAC}
```

Representative response shape:

```json
{
  "count": 1,
  "pairing": 0,
  "history": [
    {
      "id": 285,
      "from": "192.0.2.10",
      "header": "[REDACTED WHEN AUTHORIZATION IS PRESENT]",
      "filename": "phone.cfg",
      "transport": "https",
      "template": "vendor_common.txt",
      "encoding": "ascii",
      "size": 39784
    }
  ]
}
```

MCP reader: `get_mac_provisioning_history`.

## Clear provisioning history

Verified from the tenant MAC portal on Vodia PBX 70.5:

```http
GET /rest/domain/{domain}/generated?mac={MAC}&reset=1
```

This clears generated-file history for the selected MAC. It does not delete the
MAC entry, phone, extension, button profile, or tenant.

MCP planner: `plan_clear_mac_provisioning_history`.

## Replace an extension button profile

```http
POST /rest/user/{account}/buttons
Content-Type: application/json
```

Representative body:

```json
{
  "mac": "0004F2C785BE",
  "template": "0",
  "buttons": "{\"buttons\":[{\"number\":\"0\",\"name\":\"\",\"mode\":\"1\",\"type\":\"private\",\"sort\":1,\"group\":1,\"identity\":\"\",\"parameter\":\"\",\"label\":\"2033\",\"fixed\":false,\"pickup\":\"\"}],\"modes\":{}}"
}
```

The `buttons` field is a JSON-encoded string containing the complete replacement
profile. Every slot that must remain configured must be included.

MCP planner: `plan_set_extension_buttons` with `replace_all: true`.

## Assign a DID

```http
POST /rest/domain/{domain}/did
Content-Type: application/json
```

```json
{
  "cmd": "assign",
  "assign": "2009",
  "did": "+16175550100",
  "outbound": true
}
```

MCP planner: `plan_assign_did`. The planner reads the DID list first and blocks
assignment when the number is already assigned to a different extension.

## Not yet verified

The following portal menu actions remain intentionally unsupported until their
exact network requests are captured:

- Start Pairing—the observed `pair=read` request only reads availability/state;
  it does not prove the action that opens pairing.
- Update Cloud Provisioning (`rps`).

Never guess these request shapes from their HTML option values.
