
# LibreDevOps Helpers

A collection of **PowerShell helper modules** that make day-to-day DevOps tasks less tedious and more repeatable.  

The toolkit wraps common CLI utilities (Terraform, Checkov, Azure CLI, Chocolatey, Homebrew …) with idempotent, test-friendly PowerShell functions and includes a lightweight logging framework.

---

## Available Modules

| Module                                        | Purpose                                                                           |
|-----------------------------------------------|-----------------------------------------------------------------------------------|
| **AzureCliLogin**                             | Unified Azure CLI authentication (service-principal, OIDC, device-code, MSI)      |
| **Checkov**                                   | Safe wrapper for `checkov` scans with skip-lists, soft-fail, and structured logging |
| **Choco**                                     | Assert that Chocolatey exists and install packages idempotently                   |
| **Homebrew**                                  | Same as above but for Linux & macOS Homebrew                                     |
| **Logger**                                    | Opinionated logging (`INFO`, `WARN`, `DEBUG`, `ERROR`) with timestamps and invocation names |
| **Pester**                                    | Thin helpers for writing module / pipeline tests                                 |
| **Terraform**                                 | End-to-end helpers: `Invoke-TerraformInit/Plan/Apply/Destroy`, workspace selection, plan → JSON, etc. |
| **TerraformDocs**                             | Sort `variables.tf`, `outputs.tf` & auto-generate **README.md** via `terraform-docs` |
| **Utils**                                     | Generic helpers (type conversions, OS detection, program discovery, …)           |

---

## Installation

```powershell
# Install from the PowerShell Gallery
Install-Module -Name LibreDevOpsHelpers -Scope CurrentUser

# Import the root module (nested modules auto-load)
Import-Module LibreDevOpsHelpers
```

### Prerequisites

Some functions call external CLIs (`terraform`, `checkov`, `az`, etc.).  
Ensure those are available in your `$Env:PATH` or install them with the included `Assert-ChocoPath` / `Assert-HomebrewPath` helpers.

---

## Quick Start

```powershell
# Initialize Terraform and run a plan
$code = "C:\src\infra\terraform"
Invoke-TerraformInit  -CodePath $code -InitArgs '-input=false'
Invoke-TerraformPlan  -CodePath $code
Convert-TerraformPlanToJson -CodePath $code -PassThru | Invoke-Checkov

# Log in to Azure with a service-principal
Connect-AzureCli -UseClientSecret
```

---

## Using Individual Modules

```powershell
# Import everything
Import-Module LibreDevOpsHelpers

# Or cherry-pick only what you need:
Import-Module LibreDevOpsHelpers.Terraform
Import-Module LibreDevOpsHelpers.Logger
```

Each nested module is independent and exports only approved-verb cmdlets.

---

## Contributing

1. Fork the repo & create a feature branch
2. Follow the style guide:
   ```powershell
   Get-Command -Module LibreDevOpsHelpers | Sort-Object Verb, Noun
   ```  
3. Add Pester tests where applicable
4. Open a PR — GitHub Actions will lint, test, and publish preview packages

---

## License

This project is licensed under the [MIT License](https://raw.githubusercontent.com/libre-devops/powershell-helpers/main/LICENSE).

___

Made with ❤️ by **Libre DevOps**.
