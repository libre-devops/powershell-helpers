BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'TerraformDocs module surface' {
    It 'exports the expected commands' -ForEach @(
        'Format-LdoTerraform', 'Format-LdoTerraformCode',
        'Get-LdoTerraformFileContent', 'Set-LdoTerraformFileContent',
        'Format-LdoTerraformVariables', 'Format-LdoTerraformOutputs',
        'Update-LdoReadmeWithTerraformDocs'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Format-LdoTerraformVariables' {
    It 'sorts variable blocks alphabetically' {
        $content = @'
variable "zebra" {
  type = string
}

variable "alpha" {
  type = string
}
'@
        $sorted = Format-LdoTerraformVariables -VariablesContent $content
        $sorted.IndexOf('"alpha"') | Should -BeLessThan $sorted.IndexOf('"zebra"')
    }
}

Describe 'Format-LdoTerraformOutputs' {
    It 'sorts output blocks alphabetically' {
        $content = @'
output "second" {
  value = 2
}

output "first" {
  value = 1
}
'@
        $sorted = Format-LdoTerraformOutputs -OutputsContent $content
        $sorted.IndexOf('"first"') | Should -BeLessThan $sorted.IndexOf('"second"')
    }
}

Describe 'Get/Set-LdoTerraformFileContent' {
    BeforeAll {
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-tf-" + [guid]::NewGuid() + ".tf")
    }
    AfterAll { Remove-Item $file -Force -ErrorAction SilentlyContinue }

    It 'round-trips content' {
        Set-LdoTerraformFileContent -Filename $file -Content 'hello world'
        (Get-LdoTerraformFileContent -Filename $file).Trim() | Should -Be 'hello world'
    }

    It 'throws when reading a missing file' {
        { Get-LdoTerraformFileContent -Filename (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }
}
