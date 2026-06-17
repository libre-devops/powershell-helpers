<#
.SYNOPSIS
    Resets LibreDevOpsHelpers and reinstalls it from the PowerShell Gallery.

.DESCRIPTION
    Uninstalls all installed versions of LibreDevOpsHelpers, removes any leftover module folders
    from PSModulePath, reinstalls the latest version from the PowerShell Gallery, patches the
    nested module filename casing for case-sensitive file systems, then imports and verifies it.
#>

Set-StrictMode -Version Latest

Write-Host 'Uninstalling existing LibreDevOpsHelpers versions...'
try {
    Uninstall-Module LibreDevOpsHelpers -AllVersions -Force -ErrorAction Stop
    Write-Host '  Uninstall-Module completed.'
}
catch {
    Write-Host '  (No existing PSGallery versions found.)'
}

Write-Host 'Removing leftover module folders from PSModulePath...'
$env:PSModulePath -split [IO.Path]::PathSeparator |
    ForEach-Object {
        $dir = Join-Path $_ 'LibreDevOpsHelpers'
        if (Test-Path $dir) {
            Write-Host "  Deleting $dir"
            Remove-Item $dir -Recurse -Force
        }
    }

Write-Host 'Installing LibreDevOpsHelpers from PSGallery...'
Install-Module LibreDevOpsHelpers -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop

Write-Host 'Patching installed module for case-sensitive file systems...'
$mod = Get-Module -ListAvailable -Name LibreDevOpsHelpers |
    Sort-Object Version -Descending | Select-Object -First 1

if (-not $mod) {
    Write-Error 'Could not find the installed module.'
    exit 1
}

$base = $mod.ModuleBase

Get-ChildItem -Path $base -Recurse -Filter 'LibreDevopsHelpers.*.psm1' |
    ForEach-Object {
        $newName = $_.Name -replace '^LibreDevopsHelpers', 'LibreDevOpsHelpers'
        Write-Host "  Renaming $($_.FullName) to $newName"
        Rename-Item $_.FullName -NewName $newName -Force
    }

$psd1 = Join-Path $base 'LibreDevOpsHelpers.psd1'
Write-Host "  Patching manifest at $psd1"
(Get-Content $psd1) -replace 'LibreDevopsHelpers\.', 'LibreDevOpsHelpers.' | Set-Content $psd1

Write-Host 'Importing LibreDevOpsHelpers...'
Import-Module LibreDevOpsHelpers -Force

Write-Host 'Verifying Write-LdoLog is available...'
if (Get-Command Write-LdoLog -ErrorAction SilentlyContinue) {
    Write-Host 'LibreDevOpsHelpers loaded successfully.'
    exit 0
}
else {
    Write-Error 'Failed to load LibreDevOpsHelpers.'
    exit 1
}
