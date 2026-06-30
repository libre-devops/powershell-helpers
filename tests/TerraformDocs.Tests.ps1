BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'TerraformDocs module surface' {
    It 'exports the expected commands' -ForEach @(
        'Format-LdoTerraform', 'Format-LdoTerraformCode',
        'Get-LdoTerraformFileContent', 'Set-LdoTerraformFileContent',
        'Format-LdoTerraformVariables', 'Format-LdoTerraformOutputs',
        'Set-LdoReadmeHeader', 'Update-LdoReadmeWithTerraformDocs'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Set-LdoReadmeHeader' {
    BeforeAll {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("ldo-readme-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $dir | Out-Null
        $readme = Join-Path $dir 'README.md'
    }
    AfterAll { Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes the header above the terraform-docs markers' {
        Set-LdoReadmeHeader -Header '# My Module' -ReadmeFile $readme
        $content = Get-Content -Raw -LiteralPath $readme
        $content        | Should -Match '# My Module'
        $content.IndexOf('# My Module') | Should -BeLessThan $content.IndexOf('<!-- BEGIN_TF_DOCS -->')
        $content        | Should -Match '<!-- BEGIN_TF_DOCS -->'
        $content        | Should -Match '<!-- END_TF_DOCS -->'
    }

    It 'writes markers only when the header is empty' {
        Set-LdoReadmeHeader -Header '' -ReadmeFile $readme
        $content = Get-Content -Raw -LiteralPath $readme
        $content.TrimStart() | Should -Match '^<!-- BEGIN_TF_DOCS -->'
    }
}

Describe 'Update-LdoReadmeWithTerraformDocs' {
    It 'throws when the code path does not exist' {
        { Update-LdoReadmeWithTerraformDocs -CodePath (Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid())) } |
            Should -Throw
    }

    It 'throws when the header file is supplied but missing' {
        { Update-LdoReadmeWithTerraformDocs -CodePath $PSScriptRoot -ReadmeHeaderFile (Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid()).md") } |
            Should -Throw
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

    It 'keeps a comment above a variable with that variable when sorting' {
        $content = @'
# zebra is the last animal alphabetically.
variable "zebra" {
  type = string
}

# alpha is the first.
variable "alpha" {
  type = string
}
'@
        $sorted = Format-LdoTerraformVariables -VariablesContent $content
        $sorted | Should -Match 'zebra is the last animal'
        $sorted | Should -Match 'alpha is the first'
        $sorted.IndexOf('alpha is the first') | Should -BeLessThan $sorted.IndexOf('variable "alpha"')
        $sorted.IndexOf('variable "alpha"')   | Should -BeLessThan $sorted.IndexOf('zebra is the last animal')
    }

    It 'does not treat the word variable inside a description string as a new block' {
        $content = @'
variable "only" {
  description = "this references variable \"trap\" in its text"
  type        = string
}
'@
        $sorted = Format-LdoTerraformVariables -VariablesContent $content
        ([regex]::Matches($sorted, '(?m)^variable\s')).Count | Should -Be 1
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

    It 'keeps a comment above an output with that output when sorting' {
        $content = @'
# second comes after first.
output "second" {
  value = 2
}

# first comes before second.
output "first" {
  value = 1
}
'@
        $sorted = Format-LdoTerraformOutputs -OutputsContent $content
        $sorted.IndexOf('first comes before second') | Should -BeLessThan $sorted.IndexOf('output "first"')
        $sorted.IndexOf('output "first"')            | Should -BeLessThan $sorted.IndexOf('second comes after first')
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
