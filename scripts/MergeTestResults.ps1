<#
.SYNOPSIS
    Merge dotnet test .trx results and .coverage files per test category.
.DESCRIPTION
    GHA port of YAML/scripts/MergeTestResults.ps1.

    Changes from ADO original:
      - ##vso[task.setvariable variable=SkipTestPublish;isOutput=true]1
          →  "SkipTestPublish=1" >> $GITHUB_OUTPUT
      - No other ADO-specific commands; logic is identical.
#>
[CmdletBinding()]
param (
    [string]$TempDirectory = "$env:GITHUB_WORKSPACE/artifacts/testresults",
    [string]$TestCategory  = "unit"
)

$testDirectory  = Join-Path $TempDirectory "$TestCategory"
$mergedTrxFile  = Join-Path $TempDirectory "$TestCategory.trx"

Write-Output "Installing dotnet-trx-merge..."
dotnet tool install --global dotnet-trx-merge --version '2.0.1'

Write-Output "Merging TRX files from '$testDirectory' → '$mergedTrxFile'"
trx-merge --dir $testDirectory --recursive --output $mergedTrxFile

if (-not (Test-Path $mergedTrxFile)) {
    Write-Warning "No tests found in '$testDirectory'."
    # Signal to the upload step that there is nothing to publish
    "SkipTestPublish=1" >> $env:GITHUB_OUTPUT
    exit 0
}

# ── Merge .coverage files into a single file ──────────────────────────────────
$mergedCoverageFile = Join-Path $TempDirectory "$TestCategory.coverage"

Write-Output "Installing dotnet-coverage..."
dotnet tool install --global dotnet-coverage --version '17.13.1'

Write-Output "Merging coverage files → '$mergedCoverageFile'"
dotnet-coverage merge "$testDirectory/**/*.coverage" --output $mergedCoverageFile --output-format coverage

# ── Embed the merged coverage reference in the merged .trx ────────────────────
$coverageXml = @"
    <CollectorDataEntries>
      <Collector agentName="$([Environment]::MachineName)" uri="datacollector://microsoft/CodeCoverage/2.0" collectorDisplayName="Code Coverage">
        <UriAttachments>
          <UriAttachment>
            <A href="$mergedCoverageFile"></A>
          </UriAttachment>
        </UriAttachments>
      </Collector>
    </CollectorDataEntries>

"@

Write-Output "Embedding coverage reference in '$mergedTrxFile'."
(Get-Content $mergedTrxFile) -replace "(\s*)</ResultSummary>", "$coverageXml`$1</ResultSummary>" |
    Set-Content $mergedTrxFile

Write-Output "Merge complete: $mergedTrxFile"
