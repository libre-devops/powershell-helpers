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

Describe 'New-LdoHexId and trace/span/correlation ids' {
    It 'New-LdoHexId returns 2 x ByteCount lowercase hex characters' {
        $id = New-LdoHexId -ByteCount 16
        $id.Length | Should -Be 32
        $id | Should -Match '^[0-9a-f]+$'
    }
    It 'New-LdoTraceId returns 32 hex characters' {
        (New-LdoTraceId) | Should -Match '^[0-9a-f]{32}$'
    }
    It 'New-LdoSpanId returns 16 hex characters' {
        (New-LdoSpanId) | Should -Match '^[0-9a-f]{16}$'
    }
    It 'New-LdoCorrelationId returns 32 hex characters' {
        (New-LdoCorrelationId) | Should -Match '^[0-9a-f]{32}$'
    }
    It 'produces a different id each call' {
        (New-LdoTraceId) | Should -Not -Be (New-LdoTraceId)
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

Describe 'Assert-LdoLastExitCode' {
    It 'does not throw when the exit code is zero' {
        $global:LASTEXITCODE = 0
        { Assert-LdoLastExitCode -Operation 'noop' } | Should -Not -Throw
    }
    It 'throws when the exit code is non-zero' {
        $global:LASTEXITCODE = 1
        { Assert-LdoLastExitCode -Operation 'failing op' } | Should -Throw
        $global:LASTEXITCODE = 0
    }
}

Describe 'Get-LdoPublicIpAddress' {
    It 'returns the trimmed public IP' {
        InModuleScope LibreDevOpsHelpers.Utils {
            Mock Invoke-RestMethod { "203.0.113.7`n" }
            Get-LdoPublicIpAddress | Should -Be '203.0.113.7'
        }
    }
    It 'throws when no IP is returned' {
        InModuleScope LibreDevOpsHelpers.Utils {
            Mock Invoke-RestMethod { '   ' }
            { Get-LdoPublicIpAddress } | Should -Throw
        }
    }
    It 'throws when the response is not a valid IP address' {
        InModuleScope LibreDevOpsHelpers.Utils {
            Mock Invoke-RestMethod { '<html>error</html>' }
            { Get-LdoPublicIpAddress } | Should -Throw '*unexpected value*'
        }
    }
}
