BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Trivy module surface' {
    It 'exports the expected commands' -ForEach @(
        'Install-LdoTrivy', 'Invoke-LdoTrivy'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-LdoTrivy' {
    It 'throws when the code path does not exist' {
        { Invoke-LdoTrivy -CodePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }

    It 'throws when an explicit IgnoreFile is supplied but missing' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldotrivy-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            { Invoke-LdoTrivy -CodePath $dir -IgnoreFile (Join-Path $dir 'nope.yaml') } | Should -Throw '*ignore file not found*'
        }
        finally { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Context 'with the trivy CLI available' -Skip:($null -eq (Get-Command trivy -ErrorAction SilentlyContinue)) {
        BeforeAll {
            $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldotrivy-" + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            # A storage account with no network rules trips AVD-AZU-0012 (CRITICAL).
            @'
resource "azurerm_storage_account" "this" {
  name                     = "examplestorageacct"
  resource_group_name      = "example"
  location                 = "uksouth"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}
'@ | Set-Content -LiteralPath (Join-Path $dir 'main.tf')
            $waiver = @'
misconfigurations:
  - id: AVD-AZU-0012
    statement: "Test waiver."
'@
        }
        AfterAll { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }

        It 'fails on a HIGH/CRITICAL finding with no waiver' {
            { Invoke-LdoTrivy -CodePath $dir } | Should -Throw
        }

        It 'passes when a committed .trivyignore.yaml waives the finding' {
            $f = Join-Path $dir '.trivyignore.yaml'
            Set-Content -LiteralPath $f -Value $waiver
            try { { Invoke-LdoTrivy -CodePath $dir } | Should -Not -Throw }
            finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }

        It 'passes when an explicit IgnoreFile waives the finding' {
            $f = Join-Path $dir 'custom.yaml'
            Set-Content -LiteralPath $f -Value $waiver
            try { { Invoke-LdoTrivy -CodePath $dir -IgnoreFile $f } | Should -Not -Throw }
            finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
