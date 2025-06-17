<#
.SYNOPSIS
  Completely reset LibreDevOpsHelpers and patch the Linux casing bug.
#>

# 1) Uninstall all existing versions
Write-Host "→ Uninstalling existing LibreDevOpsHelpers versions..."
try {
    Uninstall-Module LibreDevOpsHelpers -AllVersions -Force -ErrorAction Stop
    Write-Host "   Uninstall-Module completed."
} catch {
    Write-Host "   (No existing PSGallery versions found.)"
}

# 2) Remove any leftover module folders
Write-Host "→ Removing leftover module folders from PSModulePath..."
$env:PSModulePath -split [IO.Path]::PathSeparator |
        ForEach-Object {
            $dir = Join-Path $_ 'LibreDevOpsHelpers'
            if (Test-Path $dir) {
                Write-Host "   Deleting $dir"
                Remove-Item $dir -Recurse -Force
            }
        }

# 3) Install fresh from PSGallery
Write-Host "→ Installing LibreDevOpsHelpers from PSGallery..."
Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop

# 4) Patch the installed module for Linux case sensitivity
Write-Host "→ Patching installed module for Linux case-sensitivity..."
$mod = Get-Module -ListAvailable -Name LibreDevOpsHelpers |
        Sort-Object Version -Descending | Select-Object -First 1

if (-not $mod) {
    Write-Host "❌ Could not find the installed module!"
    exit 1
}

$base = $mod.ModuleBase

# 4a) Rename any nested .psm1 whose filename has 'LibreDevopsHelpers' → 'LibreDevOpsHelpers'
Get-ChildItem -Path $base -Recurse -Filter 'LibreDevopsHelpers.*.psm1' |
        ForEach-Object {
            $old = $_.FullName
            $newName = $_.Name -replace '^LibreDevopsHelpers','LibreDevOpsHelpers'
            $new = Join-Path $_.DirectoryName $newName
            Write-Host "   Renaming $old → $new"
            Rename-Item $old -NewName $newName -Force
        }

# 4b) Fix the manifest’s NestedModules entries
$psd1 = Join-Path $base 'LibreDevOpsHelpers.psd1'
Write-Host "   Patching manifest at $psd1"
(Get-Content $psd1) `
  -replace 'LibreDevopsHelpers\.', 'LibreDevOpsHelpers.' |
        Set-Content $psd1

# 5) Import and verify
Write-Host "→ Importing LibreDevOpsHelpers..."
Import-Module LibreDevOpsHelpers -Force -Verbose

Write-Host "→ Verifying _LogMessage…"
if (Get-Command _LogMessage -ErrorAction SilentlyContinue) {
    Write-Host "✅ LibreDevOpsHelpers loaded successfully!"
    exit 0
}
else {
    Write-Host "❌ Failed to load LibreDevOpsHelpers."
    exit 1
}
