#!/usr/bin/env python3
"""
Stage 2 bulk migration: 3CX users -> Vodia extensions.

Scope: users/extensions ONLY. This script never touches phones, MACs,
ring groups, queues, IVRs, park orbits, trunks, dial plans, fax,
conference accounts, DIDs or inbound routing.

Idempotent: safe to rerun. Existing extensions are detected and skipped
for creation; profile updates converge on the same target state.

Usage:
    export VODIA_BASE_URL=https://pbx.example.com
    export VODIA_USER=apiuser
    export VODIA_PASS=...

    # dry run (default, no writes)
    python3 stage2_migrate_users.py \
        --source /var/lib/vodia-mcp/imports/3cx-test-fixture-sanitized-normalized.json \
        --domain allisonmackenzie-migration.tryvodia.com

    # live
    python3 stage2_migrate_users.py --source ... --domain ... --apply
"""

import argparse
import json
import os
import sys
import urllib.parse
import urllib.request
import base64
from typing import Any, Dict, List, Optional, Tuple

# --- field mapping ----------------------------------------------------------
# 3CX source key -> Vodia user_settings key
#
# Verified by direct read-back against live accounts: Vodia has no
# last_name field. display_name holds the surname; the full label is
# composed by the PBX as "<display_name> <first_name>". The 3CX
# display_name is therefore derived and must NOT be written.

PROFILE_FIELDS = ("first_name", "display_name", "email_address", "ani", "mb_enable")


class ApiError(RuntimeError):
    """Unexpected API response. Halts the run."""


class VodiaClient:
    def __init__(self, base_url: str, user: str, password: str, dry_run: bool = True):
        self.base_url = base_url.rstrip("/")
        self.dry_run = dry_run
        token = base64.b64encode(f"{user}:{password}".encode()).decode()
        self._auth = f"Basic {token}"

    def _request(self, method: str, path: str, body: Optional[dict] = None) -> Any:
        url = f"{self.base_url}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", self._auth)
        req.add_header("Accept", "application/json")
        if data:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode().strip()
                if resp.status not in (200, 201, 204):
                    raise ApiError(f"{method} {path} returned HTTP {resp.status}")
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise ApiError(f"{method} {path} returned HTTP {e.code}: {e.read().decode()[:300]}")
        except urllib.error.URLError as e:
            raise ApiError(f"{method} {path} failed: {e.reason}")

    # --- reads (always real, even in dry run) ---
    def list_accounts(self, domain: str) -> List[dict]:
        d = urllib.parse.quote(domain, safe="")
        res = self._request("GET", f"/rest/domain/{d}/users")
        if isinstance(res, dict):
            return list(res.values())
        return res or []

    def get_account(self, domain: str, ext: str) -> dict:
        d = urllib.parse.quote(domain, safe="")
        e = urllib.parse.quote(ext, safe="")
        return self._request("GET", f"/rest/domain/{d}/user_settings/{e}")

    # --- writes (suppressed in dry run) ---
    def create_extension(self, domain: str, ext: str) -> bool:
        """Proven format: POST /rest/domain/{domain}/addacc
        body {"type": "extensions", "account_ext": "<ext>"}"""
        if self.dry_run:
            return False
        d = urllib.parse.quote(domain, safe="")
        self._request("POST", f"/rest/domain/{d}/addacc",
                      {"type": "extensions", "account_ext": ext})
        return True

    def update_profile(self, domain: str, ext: str, changes: Dict[str, str]) -> bool:
        """POST /rest/domain/{domain}/user_settings/{ext}, flat body, changed fields only."""
        if self.dry_run or not changes:
            return False
        d = urllib.parse.quote(domain, safe="")
        e = urllib.parse.quote(ext, safe="")
        self._request("POST", f"/rest/domain/{d}/user_settings/{e}", changes)
        return True


# --- mapping ---------------------------------------------------------------

def map_user(src: dict) -> Tuple[str, Dict[str, str]]:
    """Translate one 3CX user into the Vodia target profile state."""
    ext = str(src.get("extension", "")).strip()
    if not ext:
        raise ApiError(f"source user has no extension: {src!r}")

    last = src.get("last_name")
    email = src.get("email")
    ani = src.get("outbound_caller_id")
    vm = src.get("voicemail_enabled")

    return ext, {
        "first_name": (src.get("first_name") or ""),
        "display_name": (last or ""),          # null last name -> empty
        "email_address": (email or ""),        # missing email -> empty
        "ani": (ani or ""),
        # explicit string, never empty: empty means "inherit tenant default"
        "mb_enable": "true" if vm else "false",
    }


def diff_profile(current: dict, target: Dict[str, str]) -> Dict[str, str]:
    """Only the fields that actually differ."""
    return {k: v for k, v in target.items() if str(current.get(k, "")) != str(v)}


# --- main ------------------------------------------------------------------

def load_source(path: str) -> List[dict]:
    with open(path) as fh:
        doc = json.load(fh)
    users = doc.get("users")
    if not isinstance(users, list):
        raise ApiError(f"source has no 'users' array (keys: {sorted(doc)[:15]})")
    return users


def run(source: str, domain: str, client: VodiaClient) -> Dict[str, Any]:
    users = load_source(source)

    existing_ids = {str(a.get("name")) for a in client.list_accounts(domain)}

    summary = {
        "source_count": len(users),
        "existing": 0, "created": 0, "updated": 0,
        "verified": 0, "failed": 0, "skipped_create": [],
        "mismatches": [],
    }

    for src in users:
        ext, target = map_user(src)

        if ext in existing_ids:
            summary["existing"] += 1
            summary["skipped_create"].append(ext)
        else:
            if client.create_extension(domain, ext):
                summary["created"] += 1
            existing_ids.add(ext)

        # In dry run the account may not exist yet; treat as blank current state.
        try:
            current = client.get_account(domain, ext)
        except ApiError:
            if not client.dry_run:
                raise
            current = {}

        changes = diff_profile(current, target)
        if client.update_profile(domain, ext, changes):
            summary["updated"] += 1
        elif client.dry_run and changes:
            summary["updated"] += 1  # would update

        # independent read-back verification
        if client.dry_run:
            continue
        readback = client.get_account(domain, ext)
        bad = {k: (readback.get(k, ""), target[k])
               for k in PROFILE_FIELDS if str(readback.get(k, "")) != str(target[k])}
        if bad:
            summary["failed"] += 1
            summary["mismatches"].append({"extension": ext, "fields": bad})
        else:
            summary["verified"] += 1

    return summary


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--source", required=True)
    p.add_argument("--domain", required=True)
    p.add_argument("--apply", action="store_true", help="perform writes (default: dry run)")
    args = p.parse_args()

    base = os.environ.get("VODIA_BASE_URL") or os.environ.get("PBX_URL")
    user = os.environ.get("VODIA_USER") or os.environ.get("PBX_USER")
    pw = os.environ.get("VODIA_PASS") or os.environ.get("PBX_PASS")
    if not all((base, user, pw)):
        print(
            "Set VODIA_BASE_URL/VODIA_USER/VODIA_PASS or PBX_URL/PBX_USER/PBX_PASS",
            file=sys.stderr,
        )
        return 2

    client = VodiaClient(base, user, pw, dry_run=not args.apply)
    mode = "APPLY" if args.apply else "DRY RUN"
    print(f"=== Stage 2 users/extensions — {mode} — {args.domain} ===")

    try:
        summary = run(args.source, args.domain, client)
    except ApiError as e:
        print(f"HALTED on unexpected API error: {e}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2))
    return 1 if summary["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
