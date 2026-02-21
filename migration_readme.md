# TIX Build – Azure DevOps → GitHub Actions Migration

This repository (`gh_yaml`) is the GitHub Actions equivalent of the Azure DevOps `SWS/YAML`
templates repository. It provides reusable workflows and composite actions that replicate the
full TIX build pipeline.

---

## Repository structure

```
gh_yaml/
├── .github/
│   └── workflows/
│       └── build.yml                  ← Main reusable workflow (call this from your repo)
└── actions/
    ├── setup-dotnet/action.yml        ← Install .NET 8, 9, 10 SDKs
    ├── dotnet-restore/action.yml      ← Authenticate Azure Artifacts + dotnet restore
    └── run-test/action.yml            ← dotnet test + collect coverage + upload results
```

Build definitions live in the consuming repository (e.g. `tix`) under `.github/workflows/`:

```
tix/.github/workflows/
├── netcore-ci.yml       ← push to develop/main
├── netcore-branch.yml   ← pull_request (PR builds)
├── netcore-nightly.yml  ← cron schedule (daily)
└── netcore-sprint.yml   ← push to sprint_g_* branches
```

---

## ADO → GitHub Actions mapping

### Concepts

| Azure DevOps concept | GitHub Actions equivalent |
|---|---|
| Pipeline template (`template:`) | Reusable workflow (`uses: org/repo/.github/workflows/file.yml@ref`) |
| Step template | Composite action (`uses: org/repo/actions/name@ref`) |
| Stage | Job (with `needs:` for ordering) |
| Variable group (`NET8 Build Variables`) | Repository / organisation secrets & variables |
| Agent pool (`TietoDocker-01`) | Self-hosted runner label (`runs-on: TietoDocker-01`) |
| `$(System.AccessToken)` | `secrets.AZURE_DEVOPS_PAT` |
| `counter()` for build numbers | `github.run_number` (unique, always increasing) |
| `pipeline.startTime` | `github.run_started_at` / `[datetime]::UtcNow` in PowerShell |
| Agentless manual-gate job | GitHub Environment protection rule |
| `PublishPipelineArtifact` | `actions/upload-artifact@v4` |
| `DownloadPipelineArtifact` | `actions/download-artifact@v4` |
| `PublishTestResults@2` | `actions/upload-artifact@v4` (`.trx` files) |
| `UseDotNet@2` | `actions/setup-dotnet@v4` |

### Files

| ADO file | GitHub Actions equivalent |
|---|---|
| `templates/build.yml` | `.github/workflows/build.yml` (reusable workflow) |
| `templates/stages.yml` | Merged into `.github/workflows/build.yml` |
| `templates/variables.yml` | `prepare` job step — version numbers written to `$GITHUB_OUTPUT` |
| `templates/jobs/job_prepare.yml` | `prepare` job in `build.yml` |
| `templates/jobs/job_build.yml` | `build` job in `build.yml` |
| `templates/jobs/job_test.yml` | `unit-test`, `integration-test`, `mssql-test` jobs in `build.yml` |
| `templates/jobs/job_publish_gitops.yml` | `publish-gitops` job in `build.yml` |
| `templates/stages/stage_publish_nuget.yml` | `publish-nuget` job in `build.yml` |
| `templates/steps/step_use_dotnet.yml` | `actions/setup-dotnet/action.yml` |
| `templates/steps/step_dotnet_restore.yml` | `actions/dotnet-restore/action.yml` |
| `templates/steps/step_run_test.yml` | `actions/run-test/action.yml` |
| `common/netcore.build.yml` (ADO definition) | Four workflow files in `tix/.github/workflows/` |

---

## Build type detection

In ADO the build type was inferred from the pipeline **definition name** (e.g. a definition
containing the word `Nightly` triggered nightly behaviour). In GitHub Actions the build type
is an **explicit input** to the reusable workflow, set by each workflow file:

| Workflow file | `build-type` input | Trigger |
|---|---|---|
| `netcore-ci.yml` | `CI` | `push` to `develop` / `main` |
| `netcore-branch.yml` | `Branch` | `pull_request` targeting `develop`, `main`, `sprint_g_*` |
| `netcore-nightly.yml` | `Nightly` | `schedule` cron (default 02:00 UTC) |
| `netcore-sprint.yml` | `Sprint` | `push` to `sprint_g_*` branches |

---

## Version numbering

ADO used `counter()` which resets per prefix (i.e. per branch). GitHub Actions uses
`github.run_number` which is global per workflow file and never resets — the counter
is monotonically increasing across all branches. This is functionally equivalent for
CI/Nightly/Sprint purposes.

| Build type | Build number format | Package version format |
|---|---|---|
| Branch | `0.0.0-{safe-branch}-{NN}` | `{safe-branch}-{NN}` |
| CI | `1.0.0.{run_number}` | `{YYYY-MM-DD}-{run_number}` |
| Nightly | `{YYYY.MM.DD}.{run_number}` | `{YYYY-MM-DD}-{run_number}` |
| Sprint | `1.0.{sprint}.{run_number}` | `1.0.{sprint}.{run_number}` |
| Sprint (hotfix) | `1.0.{sprint}-HTFX.{run_number}` | `1.0.{sprint}-HTFX.{run_number}` |

The safe branch name replaces `/` and `#` with `-` and strips `_`
(mirrors `Tix.BuildSafeSourceBranchName`).

---

## Secrets and variables

Add the following to your GitHub repository (or organisation) **Secrets**:

| Secret name | ADO equivalent | Used by |
|---|---|---|
| `AZURE_DEVOPS_PAT` | `System.AccessToken` | All builds — NuGet auth, feed push |
| `ORACLE_INTEGRATION_TEST_CONNECTION_STRING` | `OracleIntegrationTestConnectionString_CI` / `_Nightly` | Integration tests |
| `MSSQL_INTEGRATION_TEST_CONNECTION_STRING` | `MssqlIntegrationTestConnectionString` | MS SQL tests |
| `MSSQL_INTEGRATION_TEST_PASSWORD` | `MssqlIntegrationTestPassword` | MS SQL tests |
| `SONAR_TOKEN` | SonarQube token from variable group | Nightly (Sonar) |
| `GITHUB_PRIVATE_KEY` | `GITHUB_PRIVATE_KEY` | GitOps job |
| `GITHUB_APP_ID` | `GITHUB_APP_ID` | GitOps job |
| `GITHUB_INSTALLATION_ID` | `GITHUB_INSTALLATION_ID` | GitOps job |

Add the following **Variables** (Settings → Secrets and variables → Actions → Variables):

| Variable name | ADO equivalent |
|---|---|
| `TIX_CORE_VERSION` | `TixCoreVersion` from variable group `NET8 Build Variables` |

---

## Manual NuGet publish gate

In ADO the `TriggerNuGet` stage was an agentless job that paused the pipeline — operators
had to re-run that stage to proceed with publishing. The GitHub Actions equivalent is an
**Environment protection rule**:

1. Go to **Settings → Environments → New environment** and create `nuget-gate`.
2. Add **Required reviewers** (the people who approve NuGet publishes).
3. The `publish-nuget` job in `build.yml` targets this environment when
   `publish-nuget-on-first-attempt: false` (Branch and CI builds).

For Nightly and Sprint builds `publish-nuget-on-first-attempt: true` is set, so no gate
is applied and packages are pushed immediately.

---

## NuGet feed authentication

ADO injected `System.AccessToken` automatically. In GitHub Actions a PAT is used instead:

```yaml
# nuget.config must contain a source named "TIPS":
# <add key="TIPS" value="https://pkgs.dev.azure.com/tieto-pe/_packaging/TIPS/nuget/v3/index.json" />

dotnet nuget update source "TIPS" \
  --configfile nuget.config \
  --username az \
  --password "$AZURE_DEVOPS_PAT" \
  --store-password-in-clear-text
```

The PAT needs **Packaging (read)** scope for restore and **Packaging (read & write)** scope
for the push step.

---

## SonarQube (Nightly builds)

Set `run-sonar: true` in `netcore-nightly.yml`. When enabled:

- Tests run **inline in the build job** (same as ADO Nightly pattern) so SonarQube can
  collect coverage during the analysis.
- The separate `unit-test`, `integration-test` and `mssql-test` jobs are **skipped**
  (their `if: ${{ !inputs.run-sonar }}` condition is false).

The SonarQube Prepare / Finish steps from `step_prepare_sonar.yml` and `step_finish_sonar.yml`
still need to be ported into the `run-test` composite action or inlined in the `build` job.
Pass `secrets.SONAR_TOKEN` via `secrets: inherit`.

---

## Migration status

All scripts and composite actions have been ported. No outstanding items remain.

| ADO artifact | GHA equivalent | Status |
|---|---|---|
| `scripts/SetupBuildVariables.ps1` | `gh_yaml/scripts/SetupBuildVariables.ps1` | ✅ Done |
| `scripts/GetNugetPackageVersions.ps1` | `gh_yaml/scripts/GetNugetPackageVersions.ps1` | ✅ Done |
| `scripts/ReplaceProjectReferences.ps1` | `gh_yaml/scripts/ReplaceProjectReferences.ps1` | ✅ Done |
| `scripts/ReplaceImageTags.ps1` | `gh_yaml/scripts/ReplaceImageTags.ps1` | ✅ Done |
| `scripts/MergeTestResults.ps1` | `gh_yaml/scripts/MergeTestResults.ps1` | ✅ Done |
| `scripts/MarkBuildAsWarning.ps1` | `gh_yaml/scripts/MarkBuildAsWarning.ps1` | ✅ Done |
| `scripts/VerifyBuildAttempt.ps1` | Inline step in `build.yml` build job | ✅ Done |
| `steps/step_setup_nugets.yml` | `gh_yaml/actions/setup-nugets/action.yml` | ✅ Done |
| `steps/step_prepare_sonar.yml` | `gh_yaml/actions/sonar-prepare/action.yml` | ✅ Done |
| `steps/step_finish_sonar.yml` | `gh_yaml/actions/sonar-finish/action.yml` | ✅ Done |

> **Note:** The `gh_yaml` scripts repo is checked out at `.gh_yaml` inside the build job so the reusable
> workflow can call scripts directly. No further porting is required.

---

## One-time setup checklist

- [ ] Push `gh_yaml` to GitHub and note the org/repo path.
- [ ] Replace every occurrence of `TIPS-ORG/gh_yaml` in all workflow and action files with `your-org/gh_yaml`.
- [ ] Register the self-hosted runner(s) under the label `TietoDocker-01`
      (Settings → Actions → Runners), or update the `runner` input default.
- [ ] Add all secrets listed above to the repository or organisation.
- [ ] Create the `nuget-gate` environment with required reviewers.
- [ ] Validate a Branch build by opening a PR to `develop`.
- [ ] Validate a CI build by merging to `develop`.
- [ ] Validate a Nightly build via `workflow_dispatch` on `netcore-nightly.yml`.
- [ ] Validate a Sprint build by pushing to a `sprint_g_NNN` branch.
