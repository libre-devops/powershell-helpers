# LibreDevOps Helpers

Enterprise grade PowerShell helper modules for Azure, Terraform, Microsoft Graph, and the
surrounding DevOps tooling. The toolkit wraps common CLIs (Terraform, Azure CLI, Checkov, Trivy,
Packer, Docker, and more) with idempotent, testable functions, and ships a consistent logging
framework.

Every command uses the `Ldo` prefix (for example `Invoke-LdoTerraformPlan`) so the helpers never
clash with built-in cmdlets or other modules.

## Requirements

- PowerShell 7.2 or later.
- The external CLIs used by a given function must be on `PATH` (for example `terraform`, `az`,
  `checkov`, `trivy`, `packer`, `docker`). Use `Assert-LdoChocoPath` / `Assert-LdoHomebrewPath`
  to bootstrap a package manager, or `Assert-LdoCommand` to fail fast when a tool is missing.

## Installation

```powershell
Install-Module -Name LibreDevOpsHelpers -Scope CurrentUser
Import-Module LibreDevOpsHelpers
```

Nested modules auto-load with the root module. You can also import a single nested module:

```powershell
Import-Module LibreDevOpsHelpers.Terraform
```

## Conventions

- All public commands are prefixed with `Ldo` and use approved PowerShell verbs.
- Every command has comment-based help. Use `Get-Help <Command> -Full` for parameters and
  examples.
- Functions validate their input, throw on failure (they never call `exit`), and check the exit
  code of any native CLI they invoke.
- Logging goes through `Write-LdoLog`, which writes to the correct stream and never pollutes a
  function's return value. It emits the OpenTelemetry wire format by default (one OTLP/JSON
  export request per line, which a collector ingests directly); switch to a human-readable line
  with `Set-LdoLogFormat -Format Text`, or to the older flat record with
  `Set-LdoLogFormat -Format Json`. Control verbosity with `Set-LdoLogLevel`. Both default to the
  `LDO_LOG_FORMAT` / `LDO_LOG_LEVEL` environment variables when set.

## Quick start

```powershell
# Plan Terraform and scan the plan with Checkov
$code = './terraform'
Invoke-LdoTerraformInit -CodePath $code -InitArgs '-input=false'
Invoke-LdoTerraformPlan -CodePath $code
Convert-LdoTerraformPlanToJson -CodePath $code
Invoke-LdoCheckov -CodePath $code

# Sign in to Azure with a service principal (secret as a SecureString)
$secret = Read-Host -AsSecureString
Connect-LdoAzureCli -Method ClientSecret -ClientId $id -ClientSecret $secret -TenantId $tenant
```

## Modules and commands

### Logger
Levelled, timestamped logging routed to non-output streams. The OpenTelemetry wire format by
default, with an optional flat JSON record and a human-readable text format.
- `Write-LdoLog`, `Set-LdoLogLevel`, `Get-LdoLogLevel`, `Set-LdoLogFormat`, `Get-LdoLogFormat`

Five formats, selected per call with `-Format` or globally with `Set-LdoLogFormat` /
`LDO_LOG_FORMAT`:

| Format | What it emits |
| --- | --- |
| `Otlp` | **Default.** One complete OTLP/JSON `ExportLogsServiceRequest` per line, carrying one record. The collector-contrib `otlpjsonfile` receiver reads it directly, with no parser stack, no severity mapping and no timestamp layout to configure. |
| `OtlpIndented` | The same payload, pretty-printed. Not newline-delimited, so local debugging only. |
| `Json` | One compact flat object per line. Borrows OpenTelemetry's vocabulary (the severity numbers, the `service.*` semantic conventions) but is NOT OTLP: ingesting it needs a parser stack, typically a `filelog` receiver with `json_parser` and `severity_parser`. Roughly a third of the bytes, and easier to query in a backend that is not OTel-aware, such as Azure Monitor via KQL. |
| `JsonIndented` | The same record, pretty-printed. Local debugging only. |
| `Text` | Human-readable coloured line for interactive CLI use. |

In `Otlp` mode `service.name`, `service.version` and `deployment.environment` become resource
attributes rather than record fields, because that is where the OTel data model puts them, and the
ambient trace context becomes `traceId` / `spanId`. An id that is not valid hex of the right width
is dropped rather than emitted, since one bad id makes a collector reject the whole payload; when
no trace id is set, a correlation id that is a GUID seeds one, so a run is one trace for free.

### Utils
General purpose helpers shared across the toolkit.
- `Test-LdoPath`, `Assert-LdoCommand`, `Assert-LdoEnvironmentVariable`, `Assert-LdoLastExitCode`
- `Get-LdoPublicIpAddress`, `Get-LdoOperatingSystem`
- `New-LdoPassword`, `New-LdoRandomSequence`
- `ConvertTo-LdoBoolean`, `ConvertTo-LdoNull`

### Graph
Resilient Microsoft Graph and Azure REST helpers.
- `Invoke-LdoWithRetry`, `Invoke-LdoGraphRequest`, `Get-LdoGraphToken`, `Clear-LdoGraphTokenCache`,
  `Get-LdoGraphErrorDetail`

### AzurePowerShell
Az PowerShell authentication.
- `Connect-LdoAzurePowerShell`, `Connect-LdoAzurePowerShellClientSecret`,
  `Connect-LdoAzurePowerShellManagedIdentity`, `Connect-LdoAzurePowerShellDeviceCode`,
  `Test-LdoAzurePowerShellConnection`, `Disconnect-LdoAzurePowerShell`

### AzureCli
Azure CLI install and authentication.
- `Install-LdoAzureCli`, `Connect-LdoAzureCli`, `Connect-LdoAzureCliClientSecret`,
  `Connect-LdoAzureCliOidc`, `Connect-LdoAzureCliManagedIdentity`, `Connect-LdoAzureCliDeviceCode`,
  `Test-LdoAzureCliConnection`, `Disconnect-LdoAzureCli`

### AzureKeyVault
Temporary network access rules for Key Vaults.
- `Add-LdoKeyVaultCurrentIpRule`, `Remove-LdoKeyVaultCurrentIpRule`

### AzureStorage
Temporary network access rules for storage accounts.
- `Add-LdoStorageCurrentIpRule`, `Remove-LdoStorageCurrentIpRule`

### AzureNsg
Network security group rule management.
- `Add-LdoNsgCurrentIpRule`, `Remove-LdoNsgRule`

### AzureFunctionApps
Function app packaging, deployment, settings, and access rules.
- `Compress-LdoFunctionAppSource`, `Invoke-LdoFunctionAppZipDeploy`,
  `Get-LdoFunctionAppDefaultUrl`, `Set-LdoFunctionAppSetting`,
  `Add-LdoFunctionAppCurrentIpRule`, `Remove-LdoFunctionAppCurrentIpRule`

### AzureDevOps
Azure DevOps organization lookup and Terraform module token injection.
- `Get-LdoAzureDevOpsOrgId`, `Invoke-LdoAzureDevOpsTokenReplacement`,
  `Invoke-LdoAzureDevOpsTokenReplacementRevert`

### Terraform
End to end Terraform workflow helpers.
- `Invoke-LdoTerraformValidate`, `Invoke-LdoTerraformFmtCheck`, `Invoke-LdoTerraformInit`,
  `Invoke-LdoTerraformWorkspaceSelect`, `Invoke-LdoTerraformPlan`, `Invoke-LdoTerraformPlanDestroy`,
  `Invoke-LdoTerraformApply`, `Invoke-LdoTerraformDestroy`, `Convert-LdoTerraformPlanToJson`,
  `Get-LdoTerraformStackFolders`

### Terraform.AzureImport
Import existing Azure resources into Terraform state from a plan.
- `Get-LdoTerraformImportResourceId`, `Invoke-LdoTerraformImportFromPlan`

### TerraformDocs
Formatting and README generation for Terraform code.
- `Format-LdoTerraform`, `Format-LdoTerraformCode`, `Format-LdoTerraformVariables`,
  `Format-LdoTerraformOutputs`, `Get-LdoTerraformFileContent`, `Set-LdoTerraformFileContent`,
  `Update-LdoReadmeWithTerraformDocs`

### Tenv
Terraform version management via tenv.
- `Install-LdoTenv`, `Test-LdoTenv`, `Invoke-LdoTenvTerraformInstall`

### Packer
Packer build workflow.
- `Invoke-LdoPackerInit`, `Invoke-LdoPackerValidate`, `Invoke-LdoPackerBuild`,
  `Invoke-LdoPackerWorkflow`

### Checkov
Checkov install and scanning.
- `Install-LdoCheckov`, `Invoke-LdoCheckov`

### Trivy
Trivy install and configuration scanning.
- `Install-LdoTrivy`, `Invoke-LdoTrivy`

### Docker
Docker build and push.
- `Assert-LdoDockerExists`, `Build-LdoDockerImage`, `Push-LdoDockerImage`

### Choco / Homebrew
Package manager bootstrapping.
- `Assert-LdoChocoPath`, `Assert-LdoHomebrewPath`

### Python
Virtual environments, dependency install, and pytest.
- `New-LdoVenv`, `Initialize-LdoVenv`, `Use-LdoVenv`, `Clear-LdoVenv`, `Remove-LdoVenv`,
  `Invoke-LdoPythonInstallRequirements`, `Remove-LdoPythonPackages`, `Invoke-LdoPytestRun`

### Uv
The [uv](https://docs.astral.sh/uv/) Python package and version manager: install/detect, Python
version management, project and dependency workflow, and the pip interface.
- `Install-LdoUv`, `Test-LdoUv`
- `Install-LdoUvPython`, `Get-LdoUvPython`, `Set-LdoUvPythonPin`
- `New-LdoUvVenv`, `Invoke-LdoUvSync`, `Invoke-LdoUvLock`, `Add-LdoUvPackage`, `Remove-LdoUvPackage`
- `Invoke-LdoUvRun`, `Invoke-LdoUvPipInstall`, `Invoke-LdoUvPipUninstall`

### Defender
Microsoft Defender across four surfaces: Defender for Cloud (`az security`), Defender for
Endpoint / XDR (Graph Security API + Defender for Endpoint API), Defender Antivirus (Windows), and
Defender for Endpoint on Linux (`mdatp`).
- Cloud: `Get-LdoDefenderSecureScore`, `Get-LdoDefenderRecommendation`, `Get-LdoDefenderPlan`, `Set-LdoDefenderPlan`
- Endpoint/XDR: `Get-LdoDefenderAlert`, `Invoke-LdoDefenderHuntingQuery`, `Invoke-LdoDefenderDeviceIsolation`, `Invoke-LdoDefenderAvScan`
- Windows AV: `Get-LdoDefenderAvStatus`, `Start-LdoDefenderAvScan`, `Update-LdoDefenderAvSignature`, `Add-LdoDefenderAvExclusion`
- Linux (mdatp): `Get-LdoMdatpHealth`, `Start-LdoMdatpScan`, `Update-LdoMdatpDefinition`, `Add-LdoMdatpExclusion`

### LogicApps
Consumption Logic App workflow tooling. The offline half checks a definition against the contract
the platform enforces, with no network access and nothing deployed; the online half asks the
resource provider to validate it without creating anything.

The contract is not taste, it is what Azure rejects: a definition arrives in one of three shapes, a
wrapper's `parameters` block holds VALUES while a bare definition's holds DECLARATIONS, every
declared parameter needs a value by deploy time or the engine returns `InvalidTemplate`, and a
native `Workflow` dispatch action's target is checked at PUT time (`NestedWorkflowNotFound`).
- Shape: `ConvertFrom-LdoLogicAppExport` unwraps the designer code view, an ARM resource GET or a
  bare definition, keeping values and declarations separate so the round-trip trap cannot bite
- Offline gate: `Get-LdoLogicAppParameterStatus`, `Test-LdoLogicAppDefinition`,
  `Assert-LdoLogicAppDefinition`
- Provider verdict, nothing deployed: `Test-LdoLogicAppDeployment`
- Round trip: `Export-LdoLogicAppDefinition`, `Compare-LdoLogicAppDefinition`
- Lifting between estates: `Add-LdoLogicAppParameterDefault`, `Update-LdoLogicAppReference`
- Estate reads: `Get-LdoLogicAppConnection`, `Get-LdoLogicAppConnectionReference`,
  `Get-LdoLogicAppDeployOrder`

`Get-LdoLogicAppConnectionReference` answers the question a definition can be audited on alone:
which `$connections` keys does it USE, and does each resolve against what was wired? A definition
names its connections by an arbitrary key, that key has to match the one supplied at deploy time,
and nothing checks it, so a mismatch saves, deploys, and only fails when the workflow runs.

```powershell
# Fail the build naming every parameter that will not have a value at deploy time.
Get-ChildItem ./templates/*.json.tftpl | Assert-LdoLogicAppDefinition

# Every definition in an estate that reaches for a connection key nobody wired.
Get-ChildItem ./dist/*.json | Get-LdoLogicAppConnectionReference | Where-Object { $_.Wired -eq $false }

# The estate's distinct connection keys, and how many workflows use each. A key used once is
# usually a typo or a leftover from a designer session.
Get-ChildItem ./dist/*.json | Get-LdoLogicAppConnectionReference |
    Group-Object Name | Select-Object Name, Count

# Ask Azure whether it would accept this, without deploying it.
Test-LdoLogicAppDeployment -Path ./export.json -ResourceGroupName rg-soc-uks-dev-01
```

### Github
GitHub Actions helpers.
- `Get-LdoGitHubActionsInput`

### GitLab
The [glab](https://gitlab.com/gitlab-org/cli) CLI plus helpers for PowerShell running inside GitLab
CI/CD pipelines: install/detect/auth, pipelines, merge requests, releases, CI/CD variables, and
pipeline runtime helpers.
- `Install-LdoGlab`, `Test-LdoGlab`, `Connect-LdoGlab`
- `Invoke-LdoGlabPipeline`, `Get-LdoGlabPipeline`, `Wait-LdoGlabPipeline`
- `New-LdoGlabMergeRequest`, `New-LdoGlabRelease`, `Set-LdoGlabCiVariable`, `Get-LdoGlabCiVariable`
- `Get-LdoGitLabCiVariable`, `Set-LdoGitLabCiOutput`, `Write-LdoGitLabCiSection`

### Pester
Custom Pester operators and a test runner.
- `Register-LdoPesterAssertion`, `Invoke-LdoPesterTest`, `Test-LdoZeroExitCode`,
  `Test-LdoCommandOutputMatch`

## Helper scripts

The repository root contains orchestration scripts that import the module and call its functions:

- `Run-Docker.ps1` builds and optionally pushes a Docker image.
- `Terraform-Import.ps1` plans, converts to JSON, and imports existing Azure resources.
- `Terraform-Release.ps1` formats code, sorts variables and outputs, regenerates the README, and
  optionally tags a release.
- `Delete-Modules.ps1` resets and reinstalls the module from the PowerShell Gallery.
- `Publish-ToPSGallery.ps1` and `Publish-ToGitHubPackages.ps1` publish the module.

## Development

```powershell
# Lint and test (installs PSScriptAnalyzer and Pester if missing)
./Invoke-Tests.ps1
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the module coding standards.

## License

Licensed under the [MIT License](https://raw.githubusercontent.com/libre-devops/powershell-helpers/main/LICENSE).

Made by Libre DevOps.
