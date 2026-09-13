#!/usr/bin/env python3
"""Analyze a 3CX backup ZIP and emit a sanitized migration-readiness report.

Stdlib-only. Does not extract the archive to disk. Secrets such as SIP auth passwords,
voicemail PINs, certificate material, and opaque DN property values are intentionally
excluded from normalized JSON output.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional

VERSION = "0.1.0"
SECRET_FIELD_NAMES = {
    "authpassword", "vmpin", "password", "secret", "token", "apikey", "api_key",
    "certificate", "privatekey", "private_key", "services_access_hash",
    "quickmeeting_key", "quickmeeting_openlink",
}


def text(el: Optional[ET.Element], name: str, default: str = "") -> str:
    if el is None:
        return default
    child = el.find(name)
    if child is None or child.text is None:
        return default
    return child.text.strip()


def boolish(v: str) -> Optional[bool]:
    if v == "":
        return None
    if v.lower() in {"true", "1", "yes"}:
        return True
    if v.lower() in {"false", "0", "no"}:
        return False
    return None


def intish(v: str) -> Any:
    try:
        return int(v)
    except (TypeError, ValueError):
        return v


def members(el: Optional[ET.Element], container: str, item: str) -> List[str]:
    if el is None:
        return []
    out: List[str] = []
    parent = el.find(container)
    if parent is None:
        return out
    for m in parent.findall(item):
        dn = (m.attrib.get("DN") or (m.text or "")).strip()
        if dn:
            out.append(dn)
    return out


def parse_destination(parent: Optional[ET.Element], tag: str = "Destination") -> Dict[str, Any]:
    if parent is None:
        return {}
    d = parent.find(tag)
    if d is None:
        return {}
    result: Dict[str, Any] = {}
    to = text(d, "To")
    if to:
        result["type"] = to
    internal = d.find("Internal")
    if internal is not None:
        target = (internal.attrib.get("DN") or (internal.text or "")).strip()
        if target:
            result["target"] = target
    external = d.find("External")
    if external is not None:
        target = (external.attrib.get("DN") or external.attrib.get("Number") or (external.text or "")).strip()
        if target:
            result["external_target"] = target
    return result


def parse_phone_devices(ext: ET.Element) -> List[Dict[str, str]]:
    out: List[Dict[str, str]] = []
    pd = ext.find("PhoneDevices")
    if pd is None:
        return out
    for dev in pd.findall("PhoneDevice"):
        item = {
            "mac": text(dev, "MAC"),
            "model": text(dev, "ProvisioningFilename2"),
            "template": text(dev, "TemplateFilename"),
            "interface": text(dev, "Interface"),
        }
        item = {k: v for k, v in item.items() if v}
        if item:
            out.append(item)
    return out


def parse_extension(ext: ET.Element) -> Dict[str, Any]:
    number = text(ext, "Number")
    first = text(ext, "FirstName")
    last = text(ext, "LastName")
    email = text(ext, "EmailAddress")
    phones = parse_phone_devices(ext)
    data: Dict[str, Any] = {
        "extension": number,
        "first_name": first,
        "last_name": last,
        "display_name": " ".join(x for x in (first, last) if x).strip(),
        "email": email,
        "outbound_caller_id": text(ext, "OutboundCallerID"),
        "enabled": boolish(text(ext, "Enabled")),
        "voicemail_enabled": boolish(text(ext, "VMEnabled")),
        "record_calls": boolish(text(ext, "RecordCalls")),
        "current_profile": text(ext, "CurrentProfile"),
        "queue_status": text(ext, "QueueStatus"),
        "phones": phones,
    }
    return {k: v for k, v in data.items() if v not in ("", None, [])}


def parse_ring_group(el: ET.Element) -> Dict[str, Any]:
    d = {
        "number": text(el, "Number"),
        "name": text(el, "Name"),
        "members": members(el, "Members", "Member"),
        "strategy": text(el, "RingStrategy"),
        "ring_time": intish(text(el, "RingTime")),
        "destination": parse_destination(el),
    }
    return {k: v for k, v in d.items() if v not in ("", None, [], {})}


def parse_queue(el: ET.Element) -> Dict[str, Any]:
    d = {
        "number": text(el, "Number"),
        "name": text(el, "Name"),
        "members": members(el, "Members", "Member"),
        "managers": members(el, "QueueManagers", "Manager"),
        "strategy": text(el, "PollingStrategy"),
        "ring_timeout": intish(text(el, "RingTimeout")),
        "master_timeout": intish(text(el, "MasterTimeout")),
        "announcement_interval": intish(text(el, "AnnouncementInterval")),
        "announce_queue_position": boolish(text(el, "AnnounceQueuePosition")),
        "intro_enabled": boolish(text(el, "EnableIntro")),
        "intro_file": os.path.basename(text(el, "IntroFile")),
        "on_hold_file": os.path.basename(text(el, "OnHoldFile")),
        "destination": parse_destination(el),
    }
    return {k: v for k, v in d.items() if v not in ("", None, [], {})}


def parse_ivr(el: ET.Element) -> Dict[str, Any]:
    forwards: List[Dict[str, Any]] = []
    fs = el.find("Forwards")
    if fs is not None:
        for f in list(fs):
            item: Dict[str, Any] = {}
            item.update({k.lower(): v for k, v in f.attrib.items() if v})
            # Include only small scalar child fields, never opaque property blobs.
            for c in list(f):
                if len(list(c)) == 0 and c.text and c.tag.lower() not in SECRET_FIELD_NAMES:
                    item[c.tag.lower()] = c.text.strip()
                elif c.tag == "Internal":
                    dn = c.attrib.get("DN")
                    if dn:
                        item["target"] = dn
            if item:
                forwards.append(item)
    d = {
        "number": text(el, "Number"),
        "name": text(el, "Name"),
        "prompt": os.path.basename(text(el, "PromptFilename")),
        "timeout": intish(text(el, "Timeout")),
        "timeout_target": text(el, "TimeoutForwardDN"),
        "timeout_type": text(el, "TimeoutForwardType"),
        "forwards": forwards,
    }
    return {k: v for k, v in d.items() if v not in ("", None, [], {})}


def parse_external_line(el: ET.Element) -> Dict[str, Any]:
    # Intentionally omit AuthID/AuthPassword and other credentials.
    d = {
        "number": text(el, "Number"),
        "gateway": text(el, "Gateway"),
        "simultaneous_calls": intish(text(el, "SimultaneousCalls")),
        "direction": text(el, "Direction"),
    }
    return {k: v for k, v in d.items() if v not in ("", None)}


def parse_gateway(el: ET.Element) -> Dict[str, Any]:
    # Gateway object is sanitized: no secrets or opaque variable values.
    d = {
        "name": text(el, "Name"),
        "host": text(el, "Host"),
        "port": intish(text(el, "Port")),
        "type": text(el, "Type"),
        "template": text(el, "TemplateFilename"),
        "srtp_mode": text(el, "SRTPMode"),
        "support_reinvite": boolish(text(el, "SupportReinvite")),
        "support_replaces": boolish(text(el, "SupportReplaces")),
    }
    return {k: v for k, v in d.items() if v not in ("", None)}


def parse_outbound_rule(el: ET.Element) -> Dict[str, Any]:
    d: Dict[str, Any] = {
        "name": text(el, "Name"),
        "prefix": text(el, "Prefix"),
        "priority": intish(text(el, "Priority")),
        "number_of_routes": intish(text(el, "NumberOfRoutes")),
    }
    extlines = el.find("ExternalLines")
    if extlines is not None:
        vals = []
        for x in extlines.iter():
            if x is extlines:
                continue
            v = (x.attrib.get("DN") or x.attrib.get("Name") or (x.text or "")).strip()
            if v:
                vals.append(v)
        if vals:
            d["external_lines"] = sorted(set(vals))
    return {k: v for k, v in d.items() if v not in ("", None, [], {})}


def parse_group(el: ET.Element) -> Dict[str, Any]:
    d = {
        "number": text(el, "Number"),
        "name": text(el, "Name"),
        "members": members(el, "Members", "Member"),
    }
    return {k: v for k, v in d.items() if v not in ("", None, [])}


def find_db_xml(z: zipfile.ZipFile) -> str:
    candidates = [n for n in z.namelist() if re.search(r"Db\.xml$", n, re.I)]
    if not candidates:
        candidates = [n for n in z.namelist() if n.lower().endswith(".xml") and "/" not in n]
    if not candidates:
        raise ValueError("No 3CX database XML file was found in the ZIP")
    # Prefer largest plausible DB XML.
    return max(candidates, key=lambda n: z.getinfo(n).file_size)


def analyze(path: Path) -> Dict[str, Any]:
    if not path.exists():
        raise ValueError(f"File does not exist: {path}")
    if not zipfile.is_zipfile(path):
        raise ValueError("Input is not a valid ZIP archive")

    with zipfile.ZipFile(path) as z:
        db_name = find_db_xml(z)
        try:
            root = ET.fromstring(z.read(db_name))
        except ET.ParseError as e:
            raise ValueError(f"Could not parse {db_name}: {e}") from e

        if root.tag != "PhoneSystem":
            raise ValueError(f"Unexpected root element '{root.tag}'; this does not look like a supported 3CX backup")

        tenant = root.find("./Tenants/Tenant")
        if tenant is None:
            raise ValueError("No Tenants/Tenant configuration found")
        dn = tenant.find("DN")
        if dn is None:
            raise ValueError("No tenant DN configuration found")

        extensions = [parse_extension(x) for x in dn.findall("Extension")]
        ring_groups = [parse_ring_group(x) for x in dn.findall("RingGroup")]
        queues = [parse_queue(x) for x in dn.findall("Queue")]
        ivrs = [parse_ivr(x) for x in dn.findall("IVR")]
        external_lines = [parse_external_line(x) for x in dn.findall("ExternalLine")]
        park_extensions = [text(x, "Number") for x in dn.findall("ParkExtension") if text(x, "Number")]
        fax_extensions = [text(x, "Number") for x in dn.findall("FaxExtension") if text(x, "Number")]
        conferences = [text(x, "Number") for x in dn.findall("ConferencePlaceExtension") if text(x, "Number")]
        groups_el = tenant.find("Groups")
        groups = [parse_group(x) for x in groups_el.findall("Group")] if groups_el is not None else []
        rules_el = tenant.find("OutboundRules")
        outbound_rules = [parse_outbound_rule(x) for x in rules_el.findall("OutboundRule")] if rules_el is not None else []
        gateways_el = root.find("Gateways")
        gateways = [parse_gateway(x) for x in gateways_el.findall("Gateway")] if gateways_el is not None else []
        holidays_el = tenant.find("OfficeHolidays")
        holidays = holidays_el.findall("OfficeHoliday") if holidays_el is not None else []

        all_phone_devices = []
        for ext in extensions:
            for dev in ext.get("phones", []):
                row = dict(dev)
                row["extension"] = ext.get("extension", "")
                all_phone_devices.append(row)

        emails_present = sum(bool(x.get("email")) for x in extensions)
        phone_assigned_users = sum(bool(x.get("phones")) for x in extensions)
        missing_email_extensions = [x.get("extension", "") for x in extensions if not x.get("email")]
        model_counts = Counter(d.get("model") or d.get("template") or "Unknown" for d in all_phone_devices)

        archive_names = z.namelist()
        ignored = {
            "call_history_files": sum(1 for n in archive_names if n.startswith("DbTables/cl_") or "callhistory" in n.lower()),
            "chat_files": sum(1 for n in archive_names if n.startswith("ChatFiles/") or "chat_" in n.lower()),
            "certificate_files": sum(1 for n in archive_names if n.startswith("Certificates/")),
            "voicemail_prompt_files": sum(1 for n in archive_names if n.startswith("vmailprompts/")),
        }

    warnings = []
    if missing_email_extensions:
        warnings.append({
            "code": "MISSING_EMAIL",
            "count": len(missing_email_extensions),
            "extensions": missing_email_extensions,
            "message": "Extensions without email require review before Vodia user creation.",
        })
    if external_lines or gateways:
        warnings.append({
            "code": "TRUNK_REVIEW_REQUIRED",
            "count": max(len(external_lines), len(gateways)),
            "message": "SIP trunks/gateways were discovered but credentials are intentionally excluded; review carrier configuration manually.",
        })
    if ivrs:
        warnings.append({
            "code": "IVR_TRANSLATION_REQUIRED",
            "count": len(ivrs),
            "message": "IVR actions should be translated and validated against Vodia auto-attendant behavior.",
        })

    result: Dict[str, Any] = {
        "analyzer": {"name": "analyze-3cx-backup", "version": VERSION},
        "source": {
            "platform": "3cx",
            "backup_file": path.name,
            "database_xml": db_name,
        },
        "summary": {
            "extensions": len(extensions),
            "extensions_with_email": emails_present,
            "extensions_missing_email": len(missing_email_extensions),
            "users_with_phone_assignments": phone_assigned_users,
            "phone_devices": len(all_phone_devices),
            "ring_groups": len(ring_groups),
            "queues": len(queues),
            "ivrs": len(ivrs),
            "external_lines": len(external_lines),
            "gateways": len(gateways),
            "outbound_rules": len(outbound_rules),
            "park_extensions": len(park_extensions),
            "groups": len(groups),
            "holidays": len(holidays),
            "fax_extensions": len(fax_extensions),
            "conference_extensions": len(conferences),
        },
        "migration_readiness": "PASS" if not warnings else "PASS_WITH_WARNINGS",
        "warnings": warnings,
        "normalized": {
            "tenant": {"source_name": text(tenant, "Name")},
            "users": extensions,
            "phones": all_phone_devices,
            "ring_groups": ring_groups,
            "queues": queues,
            "ivrs": ivrs,
            "trunks": external_lines,
            "gateways": gateways,
            "outbound_rules": outbound_rules,
            "groups": groups,
            "park_orbits": park_extensions,
            "fax_extensions": fax_extensions,
            "conference_extensions": conferences,
        },
        "phone_model_counts": dict(model_counts.most_common()),
        "ignored_sensitive_or_nonconfiguration_content": ignored,
        "security": {
            "credentials_exported": False,
            "voicemail_pins_exported": False,
            "certificate_material_exported": False,
            "note": "Normalized output intentionally excludes known credentials, voicemail PINs, certificate material, and opaque secret-bearing DN properties.",
        },
    }
    return result


def human_report(r: Dict[str, Any]) -> str:
    s = r["summary"]
    warnings = r.get("warnings", [])
    lines = [
        "========================================",
        "3CX BACKUP MIGRATION ANALYZER",
        "========================================",
        f"Source:              {r['source']['backup_file']}",
        f"Database XML:        {r['source']['database_xml']}",
        "",
        "CONFIGURATION FOUND",
        f"Extensions:          {s['extensions']}",
        f"Emails:              {s['extensions_with_email']}/{s['extensions']}",
        f"Missing email:       {s['extensions_missing_email']}",
        f"Users with phones:   {s['users_with_phone_assignments']}/{s['extensions']}",
        f"Phone devices:       {s['phone_devices']}",
        f"Ring groups:         {s['ring_groups']}",
        f"Queues:              {s['queues']}",
        f"IVRs:                {s['ivrs']}",
        f"External lines:      {s['external_lines']}",
        f"Gateways:            {s['gateways']}",
        f"Outbound rules:      {s['outbound_rules']}",
        f"Park extensions:     {s['park_extensions']}",
        f"3CX groups:          {s['groups']}",
        f"Holidays:            {s['holidays']}",
        "",
        f"Migration readiness: {r['migration_readiness']}",
    ]
    if warnings:
        lines.append("")
        lines.append("WARNINGS")
        for w in warnings:
            lines.append(f"- {w['code']}: {w['message']}")
            if w.get("extensions"):
                lines.append("  Extensions: " + ", ".join(w["extensions"]))
    models = r.get("phone_model_counts", {})
    if models:
        lines += ["", "PHONE MODELS"]
        for model, count in models.items():
            lines.append(f"- {model}: {count}")
    lines += [
        "",
        "SECURITY",
        "- SIP/auth passwords: REDACTED / NOT EXPORTED",
        "- Voicemail PINs:     REDACTED / NOT EXPORTED",
        "- Certificates:       NOT EXPORTED",
        "",
        ("PASS: Valid 3CX backup; migration-relevant configuration was parsed successfully."
         if r["migration_readiness"].startswith("PASS")
         else "FAIL: Backup could not be analyzed."),
    ]
    return "\n".join(lines)


def main() -> int:
    p = argparse.ArgumentParser(description="Analyze a 3CX backup ZIP for Vodia migration readiness")
    p.add_argument("backup", help="Path to 3CX backup ZIP")
    p.add_argument("--json", action="store_true", help="Print sanitized normalized JSON instead of human report")
    p.add_argument("--json-out", metavar="FILE", help="Write sanitized normalized JSON to FILE")
    p.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    args = p.parse_args()

    try:
        result = analyze(Path(args.backup))
    except Exception as e:
        if args.json:
            print(json.dumps({"migration_readiness": "FAIL", "error": str(e)}, indent=2))
        else:
            print(f"FAIL: {e}")
        return 1

    if args.json_out:
        out = Path(args.json_out)
        out.write_text(json.dumps(result, indent=2, sort_keys=False) + "\n", encoding="utf-8")

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=False))
    else:
        print(human_report(result))
        if args.json_out:
            print(f"\nSanitized JSON written to: {args.json_out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
