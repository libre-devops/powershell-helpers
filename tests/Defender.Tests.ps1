BeforeAll {
    $manifest = Join-Path $PSScriptRoot '..' 'LibreDevOpsHelpers' 'LibreDevOpsHelpers.psd1'
    Import-Module $manifest -Force
}

Describe 'Defender module surface' {
    It 'exports the expected commands' -ForEach @(
        'Get-LdoDefenderSecureScore', 'Get-LdoDefenderRecommendation', 'Get-LdoDefenderPlan',
        'Set-LdoDefenderPlan', 'Get-LdoDefenderAlert', 'Invoke-LdoDefenderHuntingQuery',
        'Invoke-LdoDefenderDeviceIsolation', 'Invoke-LdoDefenderAvScan',
        'Get-LdoDefenderAvStatus', 'Start-LdoDefenderAvScan', 'Update-LdoDefenderAvSignature',
        'Add-LdoDefenderAvExclusion', 'Get-LdoMdatpHealth', 'Start-LdoMdatpScan',
        'Update-LdoMdatpDefinition', 'Add-LdoMdatpExclusion'
    ) {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
    }

    It 'does not export internal helpers' -ForEach @('Assert-LdoWindowsDefender', 'Invoke-LdoMdatpCommand') {
        Get-Command $_ -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}

Describe 'Get-LdoDefenderAlert' {
    It 'builds a filtered Graph request and returns the value collection' {
        InModuleScope LibreDevOpsHelpers.Defender {
            Mock Invoke-LdoGraphRequest {
                $script:capturedUri = $Uri
                [pscustomobject]@{ value = @([pscustomobject]@{ id = 'a1' }) }
            }
            $result = Get-LdoDefenderAlert -Severity high -Status new -Top 10
            $result.id | Should -Be 'a1'
            $script:capturedUri | Should -Match '\$top=10'
            $script:capturedUri | Should -Match 'alerts_v2'
        }
    }
}

Describe 'Invoke-LdoDefenderHuntingQuery' {
    It 'posts the query and returns the results' {
        InModuleScope LibreDevOpsHelpers.Defender {
            Mock Invoke-LdoGraphRequest {
                $script:capturedBody = $Body
                [pscustomobject]@{ results = @([pscustomobject]@{ Count = 5 }) }
            }
            $result = Invoke-LdoDefenderHuntingQuery -Query 'DeviceEvents | count'
            $result.Count | Should -Be 5
            $script:capturedBody.query | Should -Be 'DeviceEvents | count'
        }
    }
}

Describe 'Invoke-LdoDefenderDeviceIsolation' {
    It 'targets the unisolate endpoint and omits IsolationType when releasing' {
        InModuleScope LibreDevOpsHelpers.Defender {
            Mock Invoke-LdoGraphRequest {
                $script:capturedUri = $Uri
                $script:capturedBody = $Body
                [pscustomobject]@{ id = 'action1' }
            }
            Invoke-LdoDefenderDeviceIsolation -DeviceId 'dev1' -Release | Out-Null
            $script:capturedUri | Should -Match '/machines/dev1/unisolate$'
            $script:capturedBody.ContainsKey('IsolationType') | Should -BeFalse
        }
    }
}
