BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Terraform.AzureImport module surface' {
    It 'exports the expected commands' -ForEach @(
        'Get-LdoTerraformImportResourceId', 'Invoke-LdoTerraformImportFromPlan'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-LdoTerraformImportResourceId' {
    It 'builds a resource group id from the type map' {
        $after = [pscustomobject]@{ name = 'rg-test' }
        $id = Get-LdoTerraformImportResourceId -TfType azurerm_resource_group -After $after -SubscriptionId '00000000-0000-0000-0000-000000000000'
        $id | Should -Be '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-test'
    }

    It 'builds a storage account id from the type map' {
        $after = [pscustomobject]@{ name = 'sttest'; resource_group_name = 'rg-test' }
        $id = Get-LdoTerraformImportResourceId -TfType azurerm_storage_account -After $after -SubscriptionId 'sub'
        $id | Should -Be '/subscriptions/sub/resourceGroups/rg-test/providers/Microsoft.Storage/storageAccounts/sttest'
    }
}
