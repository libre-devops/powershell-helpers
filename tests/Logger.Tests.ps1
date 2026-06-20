BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Write-LdoLog (JSON, default format)' {

    It 'is exported from the module' {
        Get-Command Write-LdoLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'emits a single parseable JSON object with the expected fields' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.level | Should -Be 'WARN'
        $obj.invocation | Should -Be 'test'
        $obj.message | Should -Be 'careful'
    }

    It 'stamps a UTC ISO-8601 timestamp' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        # Inspect the raw JSON: ConvertFrom-Json would coerce the string to a DateTime
        # and drop the literal UTC marker we want to assert on.
        $warning.Message | Should -Match '"timestamp":"\d{4}-\d{2}-\d{2}T[\d:.]+Z"'
    }

    It 'merges -Data properties into the record' {
        $warning = Write-LdoLog -Level WARN -Message 'm' -InvocationName 'test' -Data @{ resourceGroup = 'rg-prod' } 3>&1
        $obj = $warning.Message | ConvertFrom-Json
        $obj.resourceGroup | Should -Be 'rg-prod'
    }

    It 'routes ERROR to the error stream without terminating' {
        $err = Write-LdoLog -Level ERROR -Message 'broke' -InvocationName 'test' 2>&1
        ($err.ToString() | ConvertFrom-Json).message | Should -Be 'broke'
    }

    It 'derives the invocation name from the caller when not supplied' {
        function Invoke-Caller { Write-LdoLog -Level WARN -Message 'auto' 3>&1 }
        $warning = Invoke-Caller
        ($warning.Message | ConvertFrom-Json).invocation | Should -Be 'Invoke-Caller'
    }

    It 'routes INFO to the information stream, not the success stream' {
        $output = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>$null
        $output | Should -BeNullOrEmpty
    }

    It 'writes INFO as JSON on the information stream' {
        $info = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>&1
        ($info.MessageData | ConvertFrom-Json).message | Should -Be 'hello'
    }

    It 'emits compact single-line JSON by default' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'test' 3>&1
        $warning.Message | Should -Not -Match "`n"
    }
}

Describe 'Write-LdoLog (JsonIndented format)' {

    It 'pretty-prints across multiple lines but stays valid JSON' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' -Format JsonIndented 3>&1
        $warning.Message | Should -Match "`n"
        ($warning.Message | ConvertFrom-Json).message | Should -Be 'careful'
    }
}

Describe 'Write-LdoLog (Text format)' {

    It 'renders a human-readable prefixed line with -Format Text' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'MyCaller' -Format Text 3>&1
        $warning | Should -Match 'careful'
        $warning | Should -Match '\[WARN\]'
        $warning | Should -Match '\[MyCaller\]'
    }

    It 'honours Set-LdoLogFormat as the default' {
        Set-LdoLogFormat -Format Text
        try {
            Get-LdoLogFormat | Should -Be 'Text'
            $warning = Write-LdoLog -Level WARN -Message 'plain' -InvocationName 'test' 3>&1
            $warning | Should -Match '\[WARN\]'
        } finally {
            Set-LdoLogFormat -Format Json
        }
    }
}

Describe 'Set-LdoLogLevel' {

    AfterEach {
        Set-LdoLogLevel -Level DEBUG
    }

    It 'suppresses messages below the configured level' {
        Set-LdoLogLevel -Level ERROR
        $warning = Write-LdoLog -Level WARN -Message 'hidden' -InvocationName 'test' 3>&1
        $warning | Should -BeNullOrEmpty
    }

    It 'still emits messages at or above the configured level' {
        Set-LdoLogLevel -Level WARN
        $warning = Write-LdoLog -Level WARN -Message 'shown' -InvocationName 'test' 3>&1
        ($warning.Message | ConvertFrom-Json).message | Should -Be 'shown'
    }

    It 'Get-LdoLogLevel returns the configured level' {
        Set-LdoLogLevel -Level WARN
        Get-LdoLogLevel | Should -Be 'WARN'
    }
}
