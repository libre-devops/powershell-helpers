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
  function's return value. Control verbosity with `Set-LdoLogLevel`.

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
Levelled, timestamped logging routed to non-output streams.
- `Write-LdoLog`, `Set-LdoLogLevel`

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

### Github
GitHub Actions helpers.
- `Get-LdoGitHubActionsInput`

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
