param(
    [switch]$RemoveRepository
)

# Both the official name and the common typo
$ModuleNames = @(
    'LibreDevOpsHelpers'
)

# ─── 1. Unload any currently-loaded instances ──────────────────────────────────
foreach ($name in $ModuleNames) {
    Get-Module -Name $name -All | Remove-Module -Force -ErrorAction SilentlyContinue
}

# ─── 2. PSResourceGet (v3) removal ────────────────────────────────────────────
if (Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet) {
    Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    foreach ($name in $ModuleNames) {
        Get-PSResource -Name $name -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Write-Host "○ Uninstalling (PSResourceGet) $($_.Name) $($_.Version)"
                    Uninstall-PSResource -Name $_.Name -Version $_.Version -ErrorAction SilentlyContinue
                }
    }
}

# ─── 3. PowerShellGet v2 removal ──────────────────────────────────────────────
if (Get-Command Get-InstalledModule -ErrorAction SilentlyContinue) {
    foreach ($name in $ModuleNames) {
        Get-InstalledModule -Name $name -AllVersions -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Write-Host "○ Uninstalling (PowerShellGet) $($_.Name) $($_.Version)"
                    Uninstall-Module -Name $_.Name -AllVersions -Force -ErrorAction SilentlyContinue
                }
    }
}

# ─── 4. Delete leftover folders on every PSModulePath entry ───────────────────
$removed = 0
$env:PSModulePath -split [System.IO.Path]::PathSeparator | ForEach-Object {
    $root = $_
    foreach ($name in $ModuleNames) {
        $dir = Join-Path $root $name
        if (Test-Path $dir) {
            Write-Host "○ Deleting folder: $dir"
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }
}
Write-Host ("✓ {0}" -f ($removed ? "Removed $removed folder(s) from PSModulePath" : 'No residual folders found.'))

# ─── 5. Clear PSResourceGet-package cache (cross-platform) ─────────────────────
$cacheRoots = @()

# Windows
if ($env:LOCALAPPDATA) {
    $cacheRoots += Join-Path $env:LOCALAPPDATA 'Microsoft\PowerShell\PSResourceGet\Cache'
}

# Linux (XDG default and legacy)
if ($env:HOME) {
    $cacheRoots += Join-Path $env:HOME '.local/share/powershell/PSResourceGet/Cache'
    $cacheRoots += Join-Path $env:HOME '.cache/powershell/PSResourceGet/Cache'
}

# macOS
if ($env:HOME) {
    $cacheRoots += Join-Path $env:HOME 'Library/Caches/powershell/PSResourceGet/Cache'
}

foreach ($cacheRoot in $cacheRoots | Where-Object { Test-Path $_ }) {
    foreach ($name in $ModuleNames) {
        Get-ChildItem -Path $cacheRoot -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like "$name*" } |
                ForEach-Object {
                    Write-Host "○ Clearing PSResourceGet cache item: $($_.FullName)"
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
    }
}

# ─── 6. Optionally unregister repositories that share the same name ───────────
if ($RemoveRepository) {
    foreach ($name in $ModuleNames) {
        if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {
            Get-PSResourceRepository -Name $name -ErrorAction SilentlyContinue |
                    ForEach-Object { Unregister-PSResourceRepository -Name $_.Name -Force }
        }
        if (Get-Command Get-PSRepository -ErrorAction SilentlyContinue) {
            Get-PSRepository -Name $name -ErrorAction SilentlyContinue |
                    ForEach-Object { Unregister-PSRepository -Name $_.Name -Force }
        }
    }
}

Write-Host "`n✅ LibreDevOpsHelpers has been fully removed. Restart PowerShell to flush auto-loaded commands."