Set-StrictMode -Version Latest

function Assert-LdoGitRepository {
    <#
    .SYNOPSIS
        Asserts that a path is inside a git work tree.

    .DESCRIPTION
        Throws when git is not installed or the path is not inside a git repository.

    .PARAMETER Path
        Directory to check. Defaults to the current directory.

    .EXAMPLE
        Assert-LdoGitRepository

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Path = '.'
    )

    Assert-LdoCommand -Name @('git')
    & git -C $Path rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Not a git repository: $Path"
    }
}

function Get-LdoGitBranch {
    <#
    .SYNOPSIS
        Returns the current git branch name.

    .DESCRIPTION
        Prefers the CI-provided branch (GitHub Actions GITHUB_HEAD_REF then GITHUB_REF_NAME, Azure
        DevOps BUILD_SOURCEBRANCHNAME), because a CI checkout is usually a detached HEAD where git
        reports "HEAD". Falls back to 'git rev-parse --abbrev-ref HEAD'. Returns an empty string
        when the branch cannot be determined.

    .PARAMETER Path
        Repository directory. Defaults to the current directory.

    .EXAMPLE
        Get-LdoGitBranch

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path = '.'
    )

    foreach ($candidate in @($env:GITHUB_HEAD_REF, $env:GITHUB_REF_NAME, $env:BUILD_SOURCEBRANCHNAME)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate.Trim()
        }
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $branch = (& git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -eq 0 -and $branch -and $branch.Trim() -ne 'HEAD') {
            return $branch.Trim()
        }
    }

    return ''
}

function Get-LdoGitRepositoryUrl {
    <#
    .SYNOPSIS
        Returns the repository URL as an https web link.

    .DESCRIPTION
        Uses the GitHub Actions context (GITHUB_SERVER_URL + GITHUB_REPOSITORY) when present,
        otherwise reads remote.origin.url, normalises an SSH remote to https, and strips a trailing
        .git. Returns an empty string when no remote can be determined.

    .PARAMETER Path
        Repository directory. Defaults to the current directory.

    .EXAMPLE
        Get-LdoGitRepositoryUrl

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Path = '.'
    )

    if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY) {
        return "$($env:GITHUB_SERVER_URL.TrimEnd('/'))/$($env:GITHUB_REPOSITORY)"
    }

    if (Get-Command git -ErrorAction SilentlyContinue) {
        $url = (& git -C $Path config --get remote.origin.url 2>$null)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($url)) {
            $url = $url.Trim()
            # Normalise git@host:org/repo(.git) to https://host/org/repo.
            if ($url -match '^git@([^:]+):(.+?)(\.git)?$') {
                $url = "https://$($Matches[1])/$($Matches[2])"
            }
            return ($url -replace '\.git$', '')
        }
    }

    return ''
}

function Export-LdoGitContextToTfVar {
    <#
    .SYNOPSIS
        Exports the git branch and repository URL as TF_VAR_* environment variables.

    .DESCRIPTION
        Sets TF_VAR_<BranchVarName> and TF_VAR_<RepoVarName> from Get-LdoGitBranch and
        Get-LdoGitRepositoryUrl so a Terraform root variable of the same name is populated, for
        example to feed a DeployedBranch / DeployedRepo tag. Only sets a variable when its value is
        non-empty. The variables are visible to terraform run in the same process.

    .PARAMETER Path
        Repository directory. Defaults to the current directory.

    .PARAMETER BranchVarName
        Terraform variable name for the branch (without the TF_VAR_ prefix). Defaults to deployed_branch.

    .PARAMETER RepoVarName
        Terraform variable name for the repository URL. Defaults to deployed_repo.

    .EXAMPLE
        Export-LdoGitContextToTfVar

    .OUTPUTS
        None
    #>
    [Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Sets process environment variables; no external state changes.')]
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Path = '.',
        [string]$BranchVarName = 'deployed_branch',
        [string]$RepoVarName = 'deployed_repo'
    )

    $branch = Get-LdoGitBranch -Path $Path
    $repo = Get-LdoGitRepositoryUrl -Path $Path

    if ($branch) {
        Set-Item -Path "Env:TF_VAR_$BranchVarName" -Value $branch
        Write-LdoLog -Level INFO -Message "Exported TF_VAR_$BranchVarName=$branch"
    }
    else {
        Write-LdoLog -Level WARN -Message "Could not determine the git branch; TF_VAR_$BranchVarName not set."
    }

    if ($repo) {
        Set-Item -Path "Env:TF_VAR_$RepoVarName" -Value $repo
        Write-LdoLog -Level INFO -Message "Exported TF_VAR_$RepoVarName=$repo"
    }
    else {
        Write-LdoLog -Level WARN -Message "Could not determine the git repository URL; TF_VAR_$RepoVarName not set."
    }
}

Export-ModuleMember -Function `
    Assert-LdoGitRepository, `
    Get-LdoGitBranch, `
    Get-LdoGitRepositoryUrl, `
    Export-LdoGitContextToTfVar
