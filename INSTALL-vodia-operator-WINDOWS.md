# Install Vodia Operator on Windows

## 1. Download

Download `vodia-operator-skill-v0.1.0.zip` into your Windows Downloads folder.

## 2. Install

Open PowerShell and run:

```powershell
$Zip = "$env:USERPROFILE\Downloads\vodia-operator-skill-v0.1.0.zip"
$Skills = "$env:USERPROFILE\.codex\skills"
$Destination = "$Skills\vodia-operator"
$Temporary = Join-Path $env:TEMP "vodia-operator-install"

if (-not (Test-Path $Zip)) {
    throw "Download not found: $Zip"
}

if (Test-Path $Destination) {
    $Backup = "$Destination.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Move-Item $Destination $Backup
    Write-Host "Existing skill backed up to $Backup"
}

if (Test-Path $Temporary) {
    Remove-Item $Temporary -Recurse -Force
}

New-Item -ItemType Directory -Force $Skills | Out-Null
Expand-Archive -Path $Zip -DestinationPath $Temporary -Force
Move-Item "$Temporary\vodia-operator" $Destination
Remove-Item $Temporary -Recurse -Force

if (-not (Test-Path "$Destination\SKILL.md")) {
    throw "Installation failed: SKILL.md is missing."
}

Write-Host "Vodia Operator installed at $Destination"
Write-Host "Completely restart Codex before testing."
```

The installer preserves an existing installation as a timestamped backup.

## 3. Restart Codex

Completely exit Codex, end any remaining Codex process in Task Manager, and reopen it.

## 4. Test

Start with a read-only request:

```text
$vodia-operator registrations 2035
```

Expected: all current registrations for extension 2035, not only the latest history event.

Then prepare a reboot without applying it:

```text
$vodia-operator reboot 2035 T57W. Prepare the plan only and wait for approval.
```

Expected target:

- Device: Yealink SIP-T57W
- MAC: `805EC03C36F6`
- Tenant: `vodiatech.audiomercy.com`

It must not target the T73U or Grandstream device registered to extension 2035.
