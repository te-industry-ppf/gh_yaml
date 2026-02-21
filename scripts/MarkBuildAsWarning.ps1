<#
.SYNOPSIS
    Analyse a build binlog and emit GitHub Actions warning annotations for real warnings.
.DESCRIPTION
    GHA port of YAML/scripts/MarkBuildAsWarning.ps1.

    Changes from ADO original:
      - ##vso[task.logissue type=warning;]  →  Write-Host "::warning::..."  (GHA annotation)
      - ##vso[task.complete result=SucceededWithIssues;]
            →  "has_warnings=true" >> $GITHUB_OUTPUT  (caller decides how to handle)
      - ##vso[task.complete result=Succeeded;]
            →  "has_warnings=false" >> $GITHUB_OUTPUT
      - ##[group] / ##[endgroup]  →  ::group:: / ::endgroup::
#>
param (
    [string]  $BinlogPath          = "$env:ARTIFACT_BASE_DIR/binlog/build.binlog",
    [string]  $SourceRoot          = "$env:GITHUB_WORKSPACE/",
    [string[]]$IgnoreList          = @("CS1030","CS0618","MSB3026","S1135","S5693","S4275","SA1000","SA1008","SA1316","SA1414"),
    [string[]]$SpecificIgnoreList  = @("System.Net.Http, Version=4.2.0.0, Culture=neutral,")
)

Write-Host "Replaying binlog: $BinlogPath"
Write-Host "dotnet build $BinlogPath --nologo -clp:`"WarningsOnly;NoSummary`" -tl:off"

$originalContent  = dotnet build $BinlogPath --nologo -clp:"WarningsOnly;NoSummary" -tl:off
$ignoredItems     = @()
$summaryItems     = @()
$validWarnings    = @()

if ($originalContent) {
    foreach ($line in $originalContent) {
        $wasIgnored = $false

        if (-not $line.Trim()) {
            $summaryItems += "[cont] $line"; $wasIgnored = $true
        }
        if ($line.StartsWith("Build ") -or $line -match "Time Elapsed|Warning\(s\)|Error\(s\)") {
            $summaryItems += "[cont] $line"; $wasIgnored = $true
        }
        if ($line.Contains("sonarsource")) {
            $ignoredItems += "[sonar]  $line"; $wasIgnored = $true
        }
        if (-not $wasIgnored) {
            foreach ($code in $IgnoreList) {
                if ($line.Contains("warning $code`:")) { $ignoredItems += "[ignore] $line"; $wasIgnored = $true; break }
            }
        }
        if (-not $wasIgnored) {
            foreach ($frag in $SpecificIgnoreList) {
                if ($line.Contains($frag)) { $ignoredItems += "[speci]  $line"; $wasIgnored = $true; break }
            }
        }
        if (-not $wasIgnored) { $validWarnings += $line }
    }

    $validCount   = $validWarnings.Count
    $ignoredCount = $ignoredItems.Count

    Write-Host "[INFO] Valid warnings: $validCount  |  Ignored: $ignoredCount"

    if ($ignoredCount -gt 0) {
        Write-Host "::group::Ignored warnings ($ignoredCount)"
        $ignoredItems | ForEach-Object { Write-Host ($_.Replace($SourceRoot, "")) }
        Write-Host "::endgroup::"
    }

    if ($summaryItems.Count -gt 0) {
        Write-Host "::group::Ignored summary lines ($($summaryItems.Count))"
        $summaryItems | ForEach-Object { Write-Host ($_.Replace($SourceRoot, "")) }
        Write-Host "::endgroup::"
    }

    if ($validCount -gt 0) {
        $validWarnings | ForEach-Object { Write-Host "::warning::$($_.Replace($SourceRoot,''))" }
        Write-Host "::warning::Build contains $validCount warning(s). See annotations above."
        "has_warnings=true" >> $env:GITHUB_OUTPUT
    } else {
        Write-Host "No actionable warnings found."
        "has_warnings=false" >> $env:GITHUB_OUTPUT
    }
}
