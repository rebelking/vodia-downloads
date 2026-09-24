#!/usr/bin/env bash
# Upload the four-file MCP code archive from its EC2 host to vodia-downloads.
# Requires a GitHub fine-grained token with Contents: Read and write on this repo.
set -Eeuo pipefail

MODE=--check
ARCHIVE=/tmp/vodia-mcp-firewall-code-20260924-203445.tar.gz
usage(){ echo "Usage: bash $0 [--check|--upload] [--archive /tmp/vodia-mcp-firewall-code-YYYYMMDD-HHMMSS.tar.gz]" >&2; exit 2; }
while (($#)); do
  case "$1" in
    --check|--upload) MODE="$1"; shift ;;
    --archive) (($#>=2)) || usage; ARCHIVE="$2"; shift 2 ;;
    *) usage ;;
  esac
done

python3 - "$MODE" "$ARCHIVE" <<'PY'
import base64
import getpass
import hashlib
import json
import re
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

mode, archive_name = sys.argv[1:]
path = Path(archive_name)
if not re.fullmatch(r'vodia-mcp-firewall-code-\d{8}-\d{6}\.tar\.gz', path.name):
    raise SystemExit('Expected a timestamped vodia-mcp-firewall-code archive.')
if not path.is_file() or path.is_symlink():
    raise SystemExit('Archive not found or is a symlink: ' + str(path))
data = path.read_bytes()
if not 0 < len(data) <= 10 * 1024 * 1024:
    raise SystemExit('Archive is empty or exceeds the 10 MiB upload limit.')

expected = {
    'aws-marketplace-ec2-deploy-v1.js',
    'ui/msp-guided-app.html',
    'msp-guided-app-v1.js',
    'version.js',
}
try:
    with tarfile.open(path, 'r:gz') as bundle:
        members = bundle.getmembers()
        if len(members) != 4 or {m.name for m in members} != expected or not all(m.isfile() for m in members):
            raise SystemExit('Unexpected archive members; expected exactly the four MCP code files.')
        for member in members:
            contents = bundle.extractfile(member).read()
            if len(contents) > 5 * 1024 * 1024:
                raise SystemExit('A code file is unexpectedly large: ' + member.name)
            if re.search(rb'AKIA[0-9A-Z]{16}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|gh[opusr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}', contents):
                raise SystemExit('Possible hardcoded credential found in ' + member.name + '; upload stopped.')
except tarfile.TarError as exc:
    raise SystemExit('Invalid gzip/tar archive: ' + str(exc))

digest = hashlib.sha256(data).hexdigest()
repo = 'rebelking/vodia-downloads'
repo_path = 'source-bundles/' + path.name
print('PASS: four expected code files; no database or environment file.')
print('SHA256:', digest)
print('Target: https://github.com/' + repo + '/blob/main/' + repo_path)
if mode == '--check':
    print('CHECK ONLY: nothing uploaded. Run with --upload to publish to the public repository.')
    raise SystemExit(0)

token = getpass.getpass('GitHub token for rebelking/vodia-downloads (input hidden): ').strip()
if not token:
    raise SystemExit('No GitHub token entered. Nothing uploaded.')
payload = json.dumps({
    'message': 'Add code-only MCP firewall source bundle ' + path.name,
    'content': base64.b64encode(data).decode('ascii'),
}).encode('utf-8')
url = 'https://api.github.com/repos/' + repo + '/contents/' + repo_path
request = urllib.request.Request(url, data=payload, method='PUT', headers={
    'Accept': 'application/vnd.github+json',
    'Authorization': 'Bearer ' + token,
    'X-GitHub-Api-Version': '2022-11-28',
    'Content-Type': 'application/json',
    'User-Agent': 'vodia-mcp-firewall-source-upload-v1',
})
try:
    with urllib.request.urlopen(request, timeout=45) as response:
        result = json.load(response)
except urllib.error.HTTPError as exc:
    try:
        message = json.load(exc).get('message', 'GitHub rejected the upload.')
    except (ValueError, OSError):
        message = 'GitHub rejected the upload.'
    raise SystemExit('Upload failed (HTTP ' + str(exc.code) + '): ' + str(message))
except urllib.error.URLError as exc:
    raise SystemExit('Upload failed: could not reach GitHub (' + str(exc.reason) + ').')
finally:
    token = ''

commit = result.get('commit', {}).get('sha', '')
if not re.fullmatch(r'[0-9a-f]{40}', commit):
    raise SystemExit('GitHub returned no commit SHA; check the repository before retrying.')
print('UPLOAD PASS: https://github.com/' + repo + '/blob/' + commit + '/' + repo_path)
print('Commit: ' + commit)
print('Pinned download: https://raw.githubusercontent.com/' + repo + '/' + commit + '/' + repo_path)
print('Send the pinned download URL here so I can build the firewall patch.')
PY
