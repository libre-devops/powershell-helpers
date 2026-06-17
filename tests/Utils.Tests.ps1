BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Test-LdoPath' {
    It 'returns true when all paths exist' {
        Test-LdoPath -Path $PSScriptRoot | Should -BeTrue
    }
    It 'returns false when any path is missing' {
        Test-LdoPath -Path $PSScriptRoot, (Join-Path $PSScriptRoot 'does-not-exist-xyz') | Should -BeFalse
    }
}

Describe 'Assert-LdoCommand' {
    It 'does not throw for a command that exists' {
        { Assert-LdoCommand -Name 'Get-Command' } | Should -Not -Throw
    }
    It 'throws for a command that does not exist' {
        { Assert-LdoCommand -Name 'definitely-not-a-real-command-xyz' } | Should -Throw
    }
}

Describe 'Assert-LdoEnvironmentVariable' {
    It 'does not throw when the variable is set' {
        $env:LDO_TEST_VAR = 'value'
        { Assert-LdoEnvironmentVariable -Name 'LDO_TEST_VAR' } | Should -Not -Throw
        Remove-Item Env:LDO_TEST_VAR
    }
    It 'throws when the variable is missing' {
        { Assert-LdoEnvironmentVariable -Name 'LDO_MISSING_VAR_XYZ' } | Should -Throw
    }
}

Describe 'New-LdoRandomSequence' {
    It 'produces a string of the requested length' {
        (New-LdoRandomSequence -Length 20 -Alphabet 'abc').Length | Should -Be 20
    }
    It 'only uses characters from the alphabet' {
        $seq = New-LdoRandomSequence -Length 100 -Alphabet 'xy'
        $seq | Should -Match '^[xy]+$'
    }
}

Describe 'New-LdoPassword' {
    It 'produces a password of the requested length' {
        (New-LdoPassword -Length 32).Length | Should -Be 32
    }
    It 'contains at least one of each character class' {
        $p = New-LdoPassword -Length 16
        $p | Should -Match '[A-Z]'
        $p | Should -Match '[a-z]'
        $p | Should -Match '[0-9]'
        $p | Should -Match '[^A-Za-z0-9]'
    }
    It 'returns a SecureString when requested' {
        New-LdoPassword -AsSecureString | Should -BeOfType [System.Security.SecureString]
    }
    It 'produces a different password each call' {
        (New-LdoPassword) | Should -Not -Be (New-LdoPassword)
    }
}

Describe 'ConvertTo-LdoBoolean' {
    It 'maps truthy strings to true' -ForEach @('true', 'TRUE', '1', 'yes', 'Y') {
        ConvertTo-LdoBoolean -Value $_ | Should -BeTrue
    }
    It 'maps falsy strings to false' -ForEach @('false', '0', 'no', 'N') {
        ConvertTo-LdoBoolean -Value $_ | Should -BeFalse
    }
    It 'treats empty as false' {
        ConvertTo-LdoBoolean -Value '' | Should -BeFalse
    }
    It 'throws on an invalid value' {
        { ConvertTo-LdoBoolean -Value 'maybe' } | Should -Throw
    }
}

Describe 'ConvertTo-LdoNull' {
    It 'returns null for empty and quote-only strings' -ForEach @('', '  ', "''", '""') {
        ConvertTo-LdoNull -Value $_ | Should -BeNullOrEmpty
    }
    It 'returns the original value otherwise' {
        ConvertTo-LdoNull -Value 'hello' | Should -Be 'hello'
    }
}

Describe 'Get-LdoOperatingSystem' {
    It 'returns a known operating system family' {
        Get-LdoOperatingSystem | Should -BeIn @('Linux', 'Windows', 'macOS')
    }
}
