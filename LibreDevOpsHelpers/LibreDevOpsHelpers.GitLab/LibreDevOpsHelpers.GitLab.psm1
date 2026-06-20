Set-StrictMode -Version Latest

function Invoke-LdoGlabCommand {
    # Internal. Asserts glab is present, runs it with the supplied arguments, and throws a
    # descriptive error on a non-zero exit. Centralises the shell-out so every public glab
    # function logs and error-checks identically.
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string[]]$ArgumentList,

        [string]$Operation
    )

    Assert-LdoCommand -Name 'glab'

    if (-not $Operation) {
        $Operation = "glab $($ArgumentList -join ' ')"
    }

    Write-LdoLog -Level INFO -Message "Running: glab $($ArgumentList -join ' ')"
    & glab @ArgumentList
    Assert-LdoLastExitCode -Operation $Operation
}

function Install-LdoGlab {
    <#
    .SYNOPSIS
        Installs the GitLab CLI (glab) if it is not already present.

    .DESCRIPTION
        Installs glab via Chocolatey on Windows or Homebrew on other platforms when the glab
        command is not found on PATH. Does nothing when glab is already installed.

    .EXAMPLE
        Install-LdoGlab

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param()

    if (Get-Command glab -ErrorAction SilentlyContinue) {
        Write-LdoLog -Level INFO -Message 'glab already installed.'
        return
    }

    $os = Get-LdoOperatingSystem
    if ($os -eq 'Windows') {
        Assert-LdoChocoPath
        Write-LdoLog -Level INFO -Message 'Installing glab via Chocolatey.'
        choco install glab -y
        Assert-LdoLastExitCode -Operation 'choco install glab'
    }
    else {
        Assert-LdoHomebrewPath
        Write-LdoLog -Level INFO -Message 'Installing glab via Homebrew.'
        brew install glab
        Assert-LdoLastExitCode -Operation 'brew install glab'
    }

    Write-LdoLog -Level SUCCESS -Message 'glab installed.'
}

function Test-LdoGlab {
    <#
    .SYNOPSIS
        Tests whether glab is available on PATH.

    .DESCRIPTION
        Returns $true when the glab command is found, otherwise $false.

    .EXAMPLE
        if (-not (Test-LdoGlab)) { Install-LdoGlab }

    .OUTPUTS
        System.Boolean
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $glabPath = Get-Command glab -ErrorAction SilentlyContinue
    if ($glabPath) {
        Write-LdoLog -Level INFO -Message "glab found at: $($glabPath.Source)"
        return $true
    }

    Write-LdoLog -Level WARN -Message 'glab is not installed or not in PATH.'
    return $false
}

function Connect-LdoGlab {
    <#
    .SYNOPSIS
        Authenticates glab against a GitLab instance using a token.

    .DESCRIPTION
        Logs glab in non-interactively by piping the token to 'glab auth login --stdin'. Supports
        self-managed GitLab via -Hostname. The token is supplied as a SecureString and is never
        written to the command line or logs.

    .PARAMETER Token
        A GitLab personal or project access token as a SecureString.

    .PARAMETER Hostname
        The GitLab host to authenticate against. Defaults to gitlab.com.

    .EXAMPLE
        Connect-LdoGlab -Token $secureToken -Hostname gitlab.mycorp.com

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [securestring]$Token,

        [ValidateNotNullOrEmpty()]
        [string]$Hostname = 'gitlab.com'
    )

    Assert-LdoCommand -Name 'glab'

    $plain = [System.Net.NetworkCredential]::new('', $Token).Password
    if ([string]::IsNullOrWhiteSpace($plain)) {
        throw 'The supplied GitLab token is empty.'
    }

    Write-LdoLog -Level INFO -Message "Authenticating glab against $Hostname."
    $plain | & glab auth login --hostname $Hostname --stdin
    Assert-LdoLastExitCode -Operation "glab auth login ($Hostname)"

    Write-LdoLog -Level SUCCESS -Message "glab authenticated against $Hostname."
}

function Invoke-LdoGlabPipeline {
    <#
    .SYNOPSIS
        Triggers a new CI/CD pipeline with glab.

    .DESCRIPTION
        Runs 'glab ci run' to create a pipeline on a branch, optionally passing CI/CD variables.
        Throws on failure.

    .PARAMETER Ref
        Branch (or tag) to run the pipeline on. Defaults to the current branch when omitted.

    .PARAMETER Variables
        Hashtable of pipeline variables to pass (key/value).

    .PARAMETER Repo
        Target project as OWNER/REPO or a full URL (passed as --repo). Optional.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to glab ci run.

    .EXAMPLE
        Invoke-LdoGlabPipeline -Ref main -Variables @{ ENVIRONMENT = 'prod' }

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [string]$Ref,
        [hashtable]$Variables = @{},
        [string]$Repo,
        [string[]]$AdditionalArgs = @()
    )

    $glabArgs = @('ci', 'run')
    if ($Ref) {
        $glabArgs += @('--branch', $Ref)
    }
    foreach ($key in $Variables.Keys) {
        $glabArgs += @('--variables', "$key`:$($Variables[$key])")
    }
    if ($Repo) {
        $glabArgs += @('--repo', $Repo)
    }
    if ($AdditionalArgs) {
        $glabArgs += $AdditionalArgs
    }

    Invoke-LdoGlabCommand -ArgumentList $glabArgs -Operation 'glab ci run'
    Write-LdoLog -Level SUCCESS -Message 'Pipeline triggered.'
}

function Get-LdoGlabPipeline {
    <#
    .SYNOPSIS
        Returns a pipeline's details from the GitLab API via glab.

    .DESCRIPTION
        Calls 'glab api projects/<ProjectId>/pipelines/<Id>' and returns the parsed JSON object,
        including the current status. ProjectId defaults to the CI_PROJECT_ID environment variable
        when running inside a pipeline.

    .PARAMETER Id
        The pipeline ID.

    .PARAMETER ProjectId
        Numeric project ID or URL-encoded path. Defaults to $env:CI_PROJECT_ID.

    .EXAMPLE
        Get-LdoGlabPipeline -Id 123

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [string]$ProjectId = $env:CI_PROJECT_ID
    )

    Assert-LdoCommand -Name 'glab'
    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw 'No project specified. Pass -ProjectId or run where CI_PROJECT_ID is set.'
    }

    $endpoint = "projects/$ProjectId/pipelines/$Id"
    Write-LdoLog -Level INFO -Message "Running: glab api $endpoint"
    $json = & glab api $endpoint
    Assert-LdoLastExitCode -Operation "glab api $endpoint"

    return ($json | ConvertFrom-Json)
}

function Wait-LdoGlabPipeline {
    <#
    .SYNOPSIS
        Waits for a GitLab pipeline to finish, throwing if it does not succeed.

    .DESCRIPTION
        Polls the pipeline status until it reaches a terminal state. Returns the final pipeline
        object on success and throws when the pipeline fails or is canceled, or when the timeout
        is exceeded.

    .PARAMETER Id
        The pipeline ID.

    .PARAMETER ProjectId
        Numeric project ID or URL-encoded path. Defaults to $env:CI_PROJECT_ID.

    .PARAMETER PollSeconds
        Seconds to wait between status checks. Defaults to 10.

    .PARAMETER TimeoutSeconds
        Maximum seconds to wait before throwing. Defaults to 1800 (30 minutes).

    .EXAMPLE
        Wait-LdoGlabPipeline -Id 123 -TimeoutSeconds 600

    .OUTPUTS
        System.Management.Automation.PSCustomObject
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Id,

        [string]$ProjectId = $env:CI_PROJECT_ID,

        [ValidateRange(1, 3600)]
        [int]$PollSeconds = 10,

        [ValidateRange(1, 86400)]
        [int]$TimeoutSeconds = 1800
    )

    $successStates = @('success')
    $failureStates = @('failed', 'canceled', 'skipped')
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while ($true) {
        $pipeline = Get-LdoGlabPipeline -Id $Id -ProjectId $ProjectId
        $status = $pipeline.status
        Write-LdoLog -Level INFO -Message "Pipeline $Id status: $status"

        if ($status -in $successStates) {
            Write-LdoLog -Level SUCCESS -Message "Pipeline $Id succeeded."
            return $pipeline
        }
        if ($status -in $failureStates) {
            throw "Pipeline $Id ended with status '$status'."
        }
        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            throw "Timed out after ${TimeoutSeconds}s waiting for pipeline $Id (last status '$status')."
        }

        Start-Sleep -Seconds $PollSeconds
    }
}

function New-LdoGlabMergeRequest {
    <#
    .SYNOPSIS
        Creates a merge request with glab.

    .DESCRIPTION
        Runs 'glab mr create' non-interactively. Either supply -Title (with optional -Description)
        or use -Fill to derive the title and description from the commits. Throws on failure.

    .PARAMETER Source
        Source branch.

    .PARAMETER Target
        Target branch.

    .PARAMETER Title
        Merge request title. Required unless -Fill is set.

    .PARAMETER Description
        Merge request description.

    .PARAMETER Fill
        When set, passes --fill to populate the title and description from the commits.

    .PARAMETER RemoveSourceBranch
        When set, passes --remove-source-branch.

    .PARAMETER Squash
        When set, passes --squash-before-merge.

    .PARAMETER Repo
        Target project as OWNER/REPO or a full URL (passed as --repo). Optional.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to glab mr create.

    .EXAMPLE
        New-LdoGlabMergeRequest -Source feature/x -Target main -Title 'Add x' -RemoveSourceBranch

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Target,
        [string]$Title,
        [string]$Description,
        [switch]$Fill,
        [switch]$RemoveSourceBranch,
        [switch]$Squash,
        [string]$Repo,
        [string[]]$AdditionalArgs = @()
    )

    if (-not $Title -and -not $Fill) {
        throw 'Specify -Title, or use -Fill to derive it from the commits.'
    }

    $glabArgs = @('mr', 'create', '--source-branch', $Source, '--target-branch', $Target, '--yes')
    if ($Fill) {
        $glabArgs += '--fill'
    }
    if ($Title) {
        $glabArgs += @('--title', $Title)
    }
    if ($Description) {
        $glabArgs += @('--description', $Description)
    }
    if ($RemoveSourceBranch) {
        $glabArgs += '--remove-source-branch'
    }
    if ($Squash) {
        $glabArgs += '--squash-before-merge'
    }
    if ($Repo) {
        $glabArgs += @('--repo', $Repo)
    }
    if ($AdditionalArgs) {
        $glabArgs += $AdditionalArgs
    }

    Invoke-LdoGlabCommand -ArgumentList $glabArgs -Operation 'glab mr create'
    Write-LdoLog -Level SUCCESS -Message "Merge request created ($Source -> $Target)."
}

function New-LdoGlabRelease {
    <#
    .SYNOPSIS
        Creates a release with glab.

    .DESCRIPTION
        Runs 'glab release create' for a tag, optionally attaching notes and asset files. Throws
        on failure.

    .PARAMETER Tag
        The release tag (for example v1.2.0).

    .PARAMETER Name
        Release name. Defaults to the tag when omitted.

    .PARAMETER Notes
        Release notes text. Mutually exclusive with -NotesFile.

    .PARAMETER NotesFile
        Path to a file containing the release notes.

    .PARAMETER Ref
        Commit SHA or branch the tag should be created from, if it does not already exist.

    .PARAMETER AssetFiles
        One or more files to attach to the release.

    .PARAMETER Repo
        Target project as OWNER/REPO or a full URL (passed as --repo). Optional.

    .PARAMETER AdditionalArgs
        Additional arguments passed through to glab release create.

    .EXAMPLE
        New-LdoGlabRelease -Tag v1.2.0 -Name 'v1.2.0' -NotesFile CHANGELOG.md

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Tag,
        [string]$Name,
        [string]$Notes,
        [string]$NotesFile,
        [string]$Ref,
        [string[]]$AssetFiles = @(),
        [string]$Repo,
        [string[]]$AdditionalArgs = @()
    )

    if ($Notes -and $NotesFile) {
        throw 'Specify only one of -Notes or -NotesFile.'
    }
    if ($NotesFile -and -not (Test-Path $NotesFile)) {
        throw "Notes file not found: $NotesFile"
    }

    $glabArgs = @('release', 'create', $Tag)
    if ($Name) {
        $glabArgs += @('--name', $Name)
    }
    if ($Notes) {
        $glabArgs += @('--notes', $Notes)
    }
    if ($NotesFile) {
        $glabArgs += @('--notes-file', $NotesFile)
    }
    if ($Ref) {
        $glabArgs += @('--ref', $Ref)
    }
    foreach ($asset in $AssetFiles) {
        if (-not (Test-Path $asset)) {
            throw "Asset file not found: $asset"
        }
        $glabArgs += $asset
    }
    if ($Repo) {
        $glabArgs += @('--repo', $Repo)
    }
    if ($AdditionalArgs) {
        $glabArgs += $AdditionalArgs
    }

    Invoke-LdoGlabCommand -ArgumentList $glabArgs -Operation "glab release create $Tag"
    Write-LdoLog -Level SUCCESS -Message "Release $Tag created."
}

function Set-LdoGlabCiVariable {
    <#
    .SYNOPSIS
        Creates or updates a project CI/CD variable with glab.

    .DESCRIPTION
        Runs 'glab variable set' to create or update a CI/CD variable. The value is piped via
        stdin so it never appears on the command line or in logs. Throws on failure.

    .PARAMETER Key
        The variable key.

    .PARAMETER Value
        The variable value. Piped to glab via stdin.

    .PARAMETER Masked
        When set, passes --masked so the value is masked in job logs.

    .PARAMETER Protected
        When set, passes --protected so the variable is only exposed to protected refs.

    .PARAMETER Scope
        Environment scope for the variable (passed as --scope). Optional.

    .PARAMETER Group
        Set the variable at group level instead of project level (passed as --group).

    .PARAMETER Repo
        Target project as OWNER/REPO or a full URL (passed as --repo). Optional.

    .EXAMPLE
        Set-LdoGlabCiVariable -Key DEPLOY_TOKEN -Value $token -Masked -Protected

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,
        [switch]$Masked,
        [switch]$Protected,
        [string]$Scope,
        [string]$Group,
        [string]$Repo
    )

    Assert-LdoCommand -Name 'glab'

    $glabArgs = @('variable', 'set', $Key)
    if ($Masked) {
        $glabArgs += '--masked'
    }
    if ($Protected) {
        $glabArgs += '--protected'
    }
    if ($Scope) {
        $glabArgs += @('--scope', $Scope)
    }
    if ($Group) {
        $glabArgs += @('--group', $Group)
    }
    if ($Repo) {
        $glabArgs += @('--repo', $Repo)
    }

    # Pipe the value via stdin so it is never exposed on the command line or in logs.
    Write-LdoLog -Level INFO -Message "Setting CI/CD variable '$Key'."
    $Value | & glab @glabArgs
    Assert-LdoLastExitCode -Operation "glab variable set $Key"

    Write-LdoLog -Level SUCCESS -Message "CI/CD variable '$Key' set."
}

function Get-LdoGlabCiVariable {
    <#
    .SYNOPSIS
        Returns the value of a project CI/CD variable via glab.

    .DESCRIPTION
        Runs 'glab variable get' and returns the variable's value. Throws on failure.

    .PARAMETER Key
        The variable key.

    .PARAMETER Scope
        Environment scope to read (passed as --scope). Optional.

    .PARAMETER Group
        Read the variable at group level instead of project level (passed as --group).

    .PARAMETER Repo
        Target project as OWNER/REPO or a full URL (passed as --repo). Optional.

    .EXAMPLE
        Get-LdoGlabCiVariable -Key DEPLOY_TOKEN

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Key,
        [string]$Scope,
        [string]$Group,
        [string]$Repo
    )

    Assert-LdoCommand -Name 'glab'

    $glabArgs = @('variable', 'get', $Key)
    if ($Scope) {
        $glabArgs += @('--scope', $Scope)
    }
    if ($Group) {
        $glabArgs += @('--group', $Group)
    }
    if ($Repo) {
        $glabArgs += @('--repo', $Repo)
    }

    Write-LdoLog -Level INFO -Message "Getting CI/CD variable '$Key'."
    $value = & glab @glabArgs
    Assert-LdoLastExitCode -Operation "glab variable get $Key"

    return $value
}

function Get-LdoGitLabCiVariable {
    <#
    .SYNOPSIS
        Reads a GitLab CI/CD variable from the environment.

    .DESCRIPTION
        Returns the value of a GitLab CI variable (a predefined variable such as
        CI_COMMIT_REF_NAME, or any variable exposed to the job) from the environment. Returns the
        default value when the variable is unset or empty. Intended for PowerShell running inside a
        GitLab pipeline.

    .PARAMETER Name
        The CI variable name, for example CI_COMMIT_REF_NAME.

    .PARAMETER Default
        Value to return when the variable is not set. Defaults to $null.

    .EXAMPLE
        Get-LdoGitLabCiVariable -Name CI_COMMIT_REF_NAME -Default main

    .OUTPUTS
        System.String
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        $Default = $null
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if (-not [string]::IsNullOrEmpty($value)) {
        return $value
    }

    return $Default
}

function Set-LdoGitLabCiOutput {
    <#
    .SYNOPSIS
        Writes a variable to a dotenv file for passing values to later GitLab CI jobs.

    .DESCRIPTION
        Appends a KEY=value line to a dotenv file. Expose it to downstream jobs by declaring the
        file as a dotenv report artifact in .gitlab-ci.yml:

            artifacts:
              reports:
                dotenv: build.env

        Subsequent jobs then receive the value as an environment variable.

    .PARAMETER Name
        The variable name. Must be a valid environment variable identifier.

    .PARAMETER Value
        The variable value.

    .PARAMETER Path
        The dotenv file to append to. Defaults to build.env.

    .EXAMPLE
        Set-LdoGitLabCiOutput -Name imageTag -Value $tag

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z_][A-Za-z0-9_]*$')]
        [string]$Name,

        [Parameter(Mandatory)][AllowEmptyString()][string]$Value,

        [ValidateNotNullOrEmpty()]
        [string]$Path = 'build.env'
    )

    Add-Content -Path $Path -Value "$Name=$Value"
    Write-LdoLog -Level INFO -Message "Wrote '$Name' to dotenv file '$Path' (declare it as artifacts:reports:dotenv to pass downstream)."
}

function Write-LdoGitLabCiSection {
    <#
    .SYNOPSIS
        Runs a script block inside a collapsible, timed GitLab CI log section.

    .DESCRIPTION
        Emits the GitLab CI section_start/section_end markers around the supplied script block so
        its output is grouped (and optionally collapsed) in the job log, with a duration shown. The
        section is always closed, even when the script block throws.

    .PARAMETER Name
        Section identifier. Letters, numbers and underscores only.

    .PARAMETER ScriptBlock
        The script block to run inside the section.

    .PARAMETER Header
        Human-readable header shown on the section. Defaults to the section name.

    .PARAMETER Collapsed
        When set, the section is collapsed by default in the job log.

    .EXAMPLE
        Write-LdoGitLabCiSection -Name build -Header 'Building image' -ScriptBlock { docker build . }

    .OUTPUTS
        None
    #>
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9_]+$')]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$Header,

        [switch]$Collapsed
    )

    if (-not $Header) {
        $Header = $Name
    }

    $esc = [char]27
    $collapsedTag = if ($Collapsed) { '[collapsed=true]' } else { '' }

    $start = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Write-Host ("{0}[0Ksection_start:{1}:{2}{3}`r{0}[0K{4}" -f $esc, $start, $Name, $collapsedTag, $Header)
    try {
        & $ScriptBlock
    }
    finally {
        $end = [System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        Write-Host ("{0}[0Ksection_end:{1}:{2}`r{0}[0K" -f $esc, $end, $Name)
    }
}

Export-ModuleMember -Function `
    Install-LdoGlab, `
    Test-LdoGlab, `
    Connect-LdoGlab, `
    Invoke-LdoGlabPipeline, `
    Get-LdoGlabPipeline, `
    Wait-LdoGlabPipeline, `
    New-LdoGlabMergeRequest, `
    New-LdoGlabRelease, `
    Set-LdoGlabCiVariable, `
    Get-LdoGlabCiVariable, `
    Get-LdoGitLabCiVariable, `
    Set-LdoGitLabCiOutput, `
    Write-LdoGitLabCiSection
