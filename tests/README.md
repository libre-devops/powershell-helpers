# Tests

Pester tests for LibreDevOpsHelpers. One `*.Tests.ps1` file per module, named after
the module it covers.

## Running

From the repository root:

```powershell
./Invoke-Tests.ps1
```

This runs PSScriptAnalyzer across the module source and then the full Pester suite.
To run a single module's tests:

```powershell
Invoke-Pester ./tests/Logger.Tests.ps1
```

## Conventions

- Tests must not require network access, an Azure context, or installed external
  CLIs. Mock those boundaries with `Mock`.
- Import the module once in a `BeforeAll` block from the manifest so the prefixed
  command names resolve exactly as a consumer would see them.
