@{
    # The default rule set runs automatically. IncludeDefaultRules is intentionally not set:
    # enabling it without a CustomRulePath triggers a NullReferenceException in some
    # PSScriptAnalyzer versions. The formatting rules below are configured explicitly.

    # Rules that do not fit this repo:
    #  - PSAvoidUsingWriteHost: the logger intentionally uses Write-Host for the
    #    information stream so CLI output is coloured and visible.
    #  - PSUseShouldProcessForStateChangingFunctions: many helpers are thin wrappers
    #    around external CLIs where ShouldProcess adds noise without value.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseShouldProcessForStateChangingFunctions'
    )

    Rules = @{
        PSUseConsistentIndentation = @{
            Enable          = $true
            Kind            = 'space'
            IndentationSize = 4
        }
        PSUseConsistentWhitespace = @{
            Enable = $true
        }
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
        PSPlaceCloseBrace = @{
            Enable = $true
        }
    }
}
