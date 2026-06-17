# Changelog

All notable changes to LibreDevOpsHelpers are recorded here.

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
