# Changelog

All notable changes to LibreDevOpsHelpers are recorded here.

## 2.7.0

### Added
- `Remove-LdoDetectionRuleId`: strips the server assigned id from exported detection rule files
  (YAML by precise text surgery so comments survive, JSON by rewrite; `-Backup` writes .bak
  copies). For backups and cross tenant portability, where files should re-create rules as new
  instead of aligning with existing ones.
- `Export-LdoCustomDetectionRule -ExcludeId`: the same intent at export time; the id and its
  provenance note never enter the files.

## 2.6.0

### Added
- New `LibreDevOpsHelpers.Yaml` submodule: `ConvertTo-LdoYaml`, a PowerShell native YAML emitter
  for analyst facing files (two space indent, literal block scalars for multiline strings such as
  KQL, minimal quoting, deterministic key order from `[ordered]` input, inline `{}` / `[]`).
  `ConvertFrom-LdoYaml` moved here from the Kql submodule (same export, no caller change).
- `Get-LdoCustomDetectionRule`: list or get Defender XDR custom detection rules with nextLink
  paging; a 403 logs the two unlocks (app roles, or admin consenting the delegated
  CustomDetection permissions to the Azure CLI application, since the CLI cannot request those
  scopes itself).
- `Export-LdoCustomDetectionRule`: the brownfield half of detections as code. Every rule becomes
  one file under `<OutDir>/<category>/` (category = kebab case of the first ATT&CK tactic),
  converted from Graph camelCase to the terraform-msgraph-xdr-custom-detection-rules snake_case
  authoring schema. The server assigned rule id is kept on purpose so `terraform import`
  addresses and later plans line up; legacy shape rules (category, mitreTechniques,
  impactedAssets, responseActions, period strings) convert best endeavours with anything
  unconvertible emitted as a TODO comment, never silently dropped. `-Format Json` writes the same
  spec as JSON (a conversion convenience; export notes go to the log since JSON carries no
  comments).
- New `LibreDevOpsHelpers.Terraform.GraphImport` submodule, the Graph sibling of
  `Terraform.AzureImport`: `Get-LdoTerraformGraphImportResourceId` (resolves the msgraph
  provider's `<url>/<id>?api-version=<v>` import id, matching planned body id first, then an
  unambiguous display name) and `Invoke-LdoTerraformGraphImportFromPlan` (walks a plan's managed
  msgraph_resource creations, writes a manifest CSV, imports each, `-DryRun` supported). Custom
  detection rules are the first supported collection.

## 2.5.1

### Added
- `ConvertTo-LdoCanonicalDetectionRule`: best endeavours value normalisation for analyst authored
  detection rules, mirroring the terraform-msgraph-xdr-custom-detection-rules module so the CI
  schema gate and the Terraform plan never disagree: status, severity and isolation types
  lowercase; frequencies and technique ids uppercase; tactics resolve case and separator
  insensitively to the canonical ATT&CK spelling (including British DefenceEvasion to the API's
  DefenseEvasion). `Test-LdoDetectionRuleFile` applies it before the JSON Schema check. Keys stay
  strict; unknown values still fail with the canonical list named.

## 2.5.0

### Added
- New `LibreDevOpsHelpers.Kql` submodule: the detections-as-code validation gate.
  - `Install-LdoKustoLanguage`: downloads and caches the Microsoft.Azure.Kusto.Language
    assembly (the library behind the product's own KQL editors) for offline parsing.
  - `Test-LdoKqlSyntax`: offline KQL syntax validation for queries or files, with labelled
    diagnostics and a `-PassThru` object mode.
  - `Test-LdoDefenderHuntingQuery`: validates a query against the tenant's real advanced
    hunting schema via `security/runHuntingQuery`; queries run verbatim by default, a trailing
    `| take 1` is opt in through `-AppendTake` (appending an operator can interact badly with a
    query that already ends in one). Needs `ThreatHunting.Read.All`.
  - `ConvertFrom-LdoYaml`: YAML parsing through yq when available, with a powershell-yaml
    fallback, so CI and local runs share one code path.
  - `Test-LdoDetectionRuleFile` and `Invoke-LdoDetectionGate`: the per-file and per-directory
    pull request gate for analyst authored custom detection YAML (parse, optional JSON Schema
    via `Test-Json`, offline KQL syntax, optional remote hunting validation), reporting through
    the findings summary and failing CI when any rule is broken.

### Changed
- `Invoke-LdoDefenderHuntingQuery` gains optional `-Timespan`, `-ApiVersion`, `-MaxRetries`
  and `-Raw` (full response with the result schema instead of just rows). Existing callers are
  unaffected.

## 2.4.3

### Changed
- The dance restore restores exactly what was captured. A null captured value means the property
  was UNSET at capture time, so the restore now applies the platform default (public network
  access Enabled, default action Allow) instead of an invented lockdown. ARM reads an
  Allow-with-no-rules Key Vault back as a null `defaultAction`, and the old fallback stamped
  Deny over vaults that were open by design (caught live: the rotation exemplar's vault lost its
  deliberate public posture after every danced run). The locked-down fallback now applies only
  to a standalone `Remove` that never had a paired `Add`.

### Added
- `-RuleOnly` on `Remove-LdoKeyVaultCurrentIpRule` and `Remove-LdoStorageCurrentIpRule`: remove
  just the runner IP rule and leave the network configuration untouched, for runs whose own
  Terraform apply changes the danced resource (restoring the pre-run capture would overwrite
  what Terraform wrote).
- `Test-LdoTerraformPlanChangesResource`: true when a plan JSON creates, updates, or deletes a
  resource of a given type and name, so the terraform-azure engine can switch to the rule-only
  removal automatically.

## 2.4.2

### Fixed
- `Add-LdoKeyVaultCurrentIpRule` crashed under `Set-StrictMode` whenever the vault existed: the
  state capture read `publicNetworkAccess` and `networkAcls` at the top level of `az keyvault show`
  output, but Key Vault nests them under `properties` (unlike the flat `az storage account show`).
  The capture now shapes the object with a JMESPath `--query`, which also guarantees every key
  exists (null when unset). Proven live against a vault that had tripped the crash in CI.
- Paired-Remove clobber after a `-SoftFail` skip, in both the Key Vault and Storage dances: when
  `Add` skipped because the target did not exist yet (the stack creates it), the `finally`-block
  `Remove` found the freshly created resource, had no cached state, and "restored" the
  locked-down fallback (public network access Disabled, default action Deny) over the network
  configuration the run's own apply had just written. `Add` now records the skip and the paired
  `Remove` skips too, leaving the resource exactly as the run applied it.

## 2.4.1

### Changed
- `Invoke-LdoTrivy` now discovers a committed ignore file (`.trivyignore.yaml`, `.trivyignore.yml`,
  or `.trivyignore`) by walking up from the code path to the enclosing git repository root, nearest
  file first, instead of looking only in the code path itself. A repo-root `.trivyignore.yaml`
  therefore covers every stack folder scanned individually (`examples/complete` and friends)
  without per-stack copies, and a stack-local file still wins. Without a git root only the code
  path is searched, so a stray ignore file outside the repository can never silently waive
  findings.
- Documented the path-scoping gotcha for waivers on findings inside downloaded modules: Trivy
  reports such paths under the module's source address plus the path relative to the scan target,
  so literal repo-relative paths never match; scope with a doublestar glob such as
  `**/.terraform/modules/key_vault/main.tf`.

## 2.4.0

### Added
- `-SoftFail` on the firewall dance functions: `Add-LdoKeyVaultCurrentIpRule`,
  `Remove-LdoKeyVaultCurrentIpRule`, `Add-LdoStorageCurrentIpRule`,
  `Remove-LdoStorageCurrentIpRule`, and `Add-LdoNspCurrentIpRule`. Opt-in (never the default):
  when the target resource does not exist the function logs a warning ("does not exist, so
  cannot append the runner IP; skipping") and returns instead of failing, so a pipeline whose
  stack creates the resource itself survives the first run and dances normally from the next
  run onward. Absence is the ONLY condition softened: authentication, network, or any other
  failure still throws, so real problems never masquerade as a first run.
- The Key Vault probe distinguishes soft-deleted vaults with its own warning: the coming apply
  resurrects them with their previous network ACLs, so the run behaves like a later run wearing
  a first-run disguise.
- Pester coverage for the Network Security Perimeter module surface (previously untested) and
  for the new `-SoftFail` parameter across all three families.

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
- New `LibreDevOpsHelpers.Defender` module spanning four Microsoft Defender surfaces: Defender for
  Cloud (`az security`: `Get-LdoDefenderSecureScore`, `Get-LdoDefenderRecommendation`,
  `Get-LdoDefenderPlan`, `Set-LdoDefenderPlan`); Defender for Endpoint / XDR via the Graph Security
  API and Defender for Endpoint API (`Get-LdoDefenderAlert`, `Invoke-LdoDefenderHuntingQuery`,
  `Invoke-LdoDefenderDeviceIsolation`, `Invoke-LdoDefenderAvScan`); Defender Antivirus on Windows
  (`Get-LdoDefenderAvStatus`, `Start-LdoDefenderAvScan`, `Update-LdoDefenderAvSignature`,
  `Add-LdoDefenderAvExclusion`); and Defender for Endpoint on Linux via `mdatp` (`Get-LdoMdatpHealth`,
  `Start-LdoMdatpScan`, `Update-LdoMdatpDefinition`, `Add-LdoMdatpExclusion`).
- New `LibreDevOpsHelpers.GitLab` module wrapping the [glab](https://gitlab.com/gitlab-org/cli) CLI
  and adding helpers for PowerShell running inside GitLab CI/CD pipelines: `Install-LdoGlab`,
  `Test-LdoGlab`, `Connect-LdoGlab`, `Invoke-LdoGlabPipeline`, `Get-LdoGlabPipeline`,
  `Wait-LdoGlabPipeline`, `New-LdoGlabMergeRequest`, `New-LdoGlabRelease`, `Set-LdoGlabCiVariable`,
  `Get-LdoGlabCiVariable`, `Get-LdoGitLabCiVariable`, `Set-LdoGitLabCiOutput`, and
  `Write-LdoGitLabCiSection` (collapsible/timed CI log sections). Tokens are passed via SecureString
  and piped through stdin so they never reach the command line or logs.

### Changed
- INFO and SUCCESS messages now route through `Write-Information` (a tagged, capturable
  information-stream record) in JSON mode instead of `Write-Host`; Text mode keeps coloured
  `Write-Host` output for interactive CLI use. WARN/ERROR/DEBUG stream routing is unchanged.
- The default log output is now JSON rather than plain text. Anything that parsed the old
  text lines should either parse JSON or opt back in with `-Format Text` / `Set-LdoLogFormat`.
- Terraform functions now assert that `terraform` is on PATH before running, so a missing CLI
  fails with a clear message. `Invoke-LdoTerraformInit` defaults to `-input=false` for
  non-interactive CI unless the caller already passes `-input`. `Convert-LdoTerraformPlanToJson`
  verifies the `terraform show` exit code before writing, so a failure no longer leaves a corrupt
  or empty JSON file.
- `Get-LdoPublicIpAddress` now accepts `-TimeoutSec` (default 15) and validates that the endpoint
  returned a real IP address, rather than passing an error page through as the result.
- Python functions now use the shared `Assert-LdoLastExitCode` for uniform native-failure handling,
  and `Invoke-LdoPytestRun` asserts its `-PythonExe` is on PATH before running.
- TerraformDocs functions now use the shared `Assert-LdoCommand` / `Assert-LdoLastExitCode` helpers
  and validate `CodePath`. `Update-LdoReadmeWithTerraformDocs` verifies the `terraform-docs` exit
  code and writes the README in a single step, so a failure no longer leaves a half-written README.
  `Set-LdoTerraformFileContent` now writes UTF-8.
- `Invoke-LdoTerraformImportFromPlan` is hardened: it asserts the Azure CLI/terraform are present
  and signed in up front, checks the exit code of every `terraform import` (a failed import is no
  longer reported as success and the run now throws if any import fails), and drops the broken `--%`
  token from the import call. `Get-LdoTerraformImportResourceId` now scopes its `az resource list`
  and Resource Graph fallbacks by resource group/subscription so a same-named resource elsewhere
  can't be matched and imported by mistake, and it validates the resolved subscription id.

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
