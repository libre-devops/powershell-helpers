BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Findings module surface' {
    It 'exports the expected commands' -ForEach @(
        'Add-LdoFinding', 'Get-LdoFinding', 'Clear-LdoFinding', 'Show-LdoFindingsSummary'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }
}

Describe 'Add/Get/Clear-LdoFinding' {
    BeforeEach { Clear-LdoFinding }

    It 'records and returns findings' {
        Add-LdoFinding -Tool 'trivy' -Target './x' -Status 'PASS' -Summary 'clean'
        Add-LdoFinding -Tool 'conftest' -Target './x' -Status 'WARN' -Summary 'naming' -Detail 'WARN - ...'
        $f = Get-LdoFinding
        $f.Count | Should -Be 2
        $f[0].Tool | Should -Be 'trivy'
        $f[1].Status | Should -Be 'WARN'
    }

    It 'clears findings' {
        Add-LdoFinding -Tool 'tflint' -Target './x' -Status 'PASS'
        Clear-LdoFinding
        (Get-LdoFinding).Count | Should -Be 0
    }

    It 'rejects an invalid status' {
        { Add-LdoFinding -Tool 'trivy' -Target './x' -Status 'BROKEN' } | Should -Throw
    }
}

Describe 'Show-LdoFindingsSummary' {
    BeforeEach { Clear-LdoFinding }

    It 'does not throw with no findings' {
        { Show-LdoFindingsSummary } | Should -Not -Throw
    }

    It 'does not throw and renders recorded findings' {
        Add-LdoFinding -Tool 'conftest' -Target './examples/minimal' -Status 'WARN' -Summary '1 warning' -Detail 'WARN - naming (info): ...'
        { Show-LdoFindingsSummary } | Should -Not -Throw
    }
}
