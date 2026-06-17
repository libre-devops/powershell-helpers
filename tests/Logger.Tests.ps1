BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Write-LdoLog' {

    It 'is exported from the module' {
        Get-Command Write-LdoLog -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'routes WARN to the warning stream' {
        $warning = Write-LdoLog -Level WARN -Message 'careful' -InvocationName 'test' 3>&1
        $warning | Should -Match 'careful'
        $warning | Should -Match '\[WARN\]'
    }

    It 'routes ERROR to the error stream without terminating' {
        $err = Write-LdoLog -Level ERROR -Message 'broke' -InvocationName 'test' 2>&1
        $err | Should -Match 'broke'
    }

    It 'includes the invocation name in the prefix' {
        $warning = Write-LdoLog -Level WARN -Message 'x' -InvocationName 'MyCaller' 3>&1
        $warning | Should -Match '\[MyCaller\]'
    }

    It 'does not write to the success stream' {
        $output = Write-LdoLog -Level INFO -Message 'hello' -InvocationName 'test' 6>$null
        $output | Should -BeNullOrEmpty
    }

    It 'derives the invocation name from the caller when not supplied' {
        function Invoke-Caller { Write-LdoLog -Level WARN -Message 'auto' 3>&1 }
        $warning = Invoke-Caller
        $warning | Should -Match '\[Invoke-Caller\]'
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
        $warning | Should -Match 'shown'
    }
}
