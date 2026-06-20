# Changelog

All notable changes to LibreDevOpsHelpers are recorded here.

## 2.1.0

### Added
- `Write-LdoLog` now emits structured JSON by default (newline-delimited JSON, one object
  per line) carrying a UTC ISO-8601 `timestamp`, `level`, `invocation` and `message`,
  ready for ingestion by log aggregators such as Splunk, Elasticsearch or Azure Monitor.
- `Get-LdoLogLevel` to read the current minimum log level (companion to `Set-LdoLogLevel`).
- `-Format Text` (per call) and `Set-LdoLogFormat` / `Get-LdoLogFormat` to switch between
  JSON and the previous human-readable coloured line format. A `JsonIndented` format is also
  available as an opt-in for local debugging (pretty-printed, not newline-delimited). The
  default can also be set via the `LDO_LOG_FORMAT` environment variable, and the minimum level
  via `LDO_LOG_LEVEL`.
- `-Data` parameter on `Write-LdoLog` for merging extra structured properties (for example
  correlation IDs or resource names) into the JSON record.
- New `LibreDevOpsHelpers.Uv` module wrapping the [uv](https://docs.astral.sh/uv/) Python package
  and version manager: `Install-LdoUv`, `Test-LdoUv`, `Install-LdoUvPython`, `Get-LdoUvPython`,
  `Set-LdoUvPythonPin`, `New-LdoUvVenv`, `Invoke-LdoUvSync`, `Invoke-LdoUvLock`, `Add-LdoUvPackage`,
  `Remove-LdoUvPackage`, `Invoke-LdoUvRun`, `Invoke-LdoUvPipInstall`, `Invoke-LdoUvPipUninstall`.

### Changed
- INFO and SUCCESS messages now route through `Write-Information` (a tagged, capturable
  information-stream record) in JSON mode instead of `Write-Host`; Text mode keeps coloured
  `Write-Host` output for interactive CLI use. WARN/ERROR/DEBUG stream routing is unchanged.
- The default log output is now JSON rather than plain text. Anything that parsed the old
  text lines should either parse JSON or opt back in with `-Format Text` / `Set-LdoLogFormat`.

## 2.0.0

### Changed (breaking)
- Every public command was renamed to use the `Ldo` prefix (for example `Invoke-TerraformPlan`
  is now `Invoke-LdoTerraformPlan`). There are no backwards-compatible aliases. Callers must
  update to the new names.
- Minimum supported PowerShell is now 7.2.
- `FunctionsToExport` in the manifest is now an explicit list of all exported commands.

### Added
- Comment-based help, `[CmdletBinding()]`, `[OutputType()]`, and parameter validation across
  every function.
- A Pester test suite covering every module, plus an analyzer-clean PSScriptAnalyzer pass run by
  `Invoke-Tests.ps1` and a GitHub Actions lint and test workflow.
- Shared `LibreDevOpsHelpers.Utils` helpers `Assert-LdoLastExitCode` and `Get-LdoPublicIpAddress`,
  now reused across the Azure resource and tooling modules.
- New and completed functionality: split temporary IP access rules into explicit add/remove
  functions for Key Vault, storage, NSG, and function apps; `Connect-LdoAzureCliManagedIdentity`;
  secure-string handling for Azure DevOps PATs and Docker registry credentials; and Pester custom
  Should operators with `Register-LdoPesterAssertion`.

### Fixed
- Numerous correctness bugs surfaced during the rewrite, including `Invoke-TerraformDestroy`
  ignoring its destroy arguments, the Trivy skip-policy arguments being concatenated into one
  token, the Azure DevOps org lookup dereferencing the response before its null check, the NSG
  rule helper ignoring port and prefix parameters, and the Pester runner referencing an undefined
  configuration variable.
- Functions no longer call `exit` or use `Invoke-Expression`; native CLI failures are detected via
  exit-code checks.

## 1.2.0

### Added
- New `LibreDevOpsHelpers.Graph` module with reusable helpers for Microsoft Graph
  and other Azure REST APIs:
  - `Invoke-WithRetry`: retry wrapper with exponential backoff, jitter, Retry-After
    support, and a configurable list of retryable status codes so non-transient
    errors fail fast.
  - `Get-GraphToken`: per-resource token cache that auto-refreshes near expiry and
    handles both plaintext and SecureString tokens across Az.Accounts versions.
  - `Get-GraphErrorDetail`: extracts the real Graph error code and message from the
    response body.
  - `Invoke-GraphRequest`: request wrapper that adds the bearer token, retries
    transient failures, and refreshes the token once on a 401.
  - `Clear-GraphTokenCache`: clears the cached token for one resource or all.

### Fixed
- `New-Password` referenced a function that did not exist, which made it throw on
  use. The random sequence generator is now a module-scope function and is called
  correctly.
- The Utils module no longer exports a function name that was never defined.

### Changed
- `Publish-ToPSGallery.ps1` now accepts `-WorkingDirectory` and `-ApiKey`, resolves
  the key from `PSGALLERY_TOKEN` or `NUGET_API_KEY`, and validates the manifest
  before publishing.

## 1.1.2

- Earlier releases. See git history for details.
