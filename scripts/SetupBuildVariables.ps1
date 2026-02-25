<#
.SYNOPSIS
    Read Directory.Build.props and set build variables for GitHub Actions.
.DESCRIPTION
    GHA port of YAML/scripts/SetupBuildVariables.ps1.

    Changes from ADO original:
      - ##vso[task.setvariable variable=NAME]VALUE  →  "NAME=VALUE" >> $GITHUB_ENV
      - ArtifactBaseDir is NOT set here; it is fixed to $GITHUB_WORKSPACE/artifacts in the workflow.
      - PackageVersion comes from the prepare job (already in GITHUB_ENV as PACKAGE_VERSION).
      - ContainerImageVersion is derived from PACKAGE_VERSION + BUILD_TYPE.
#>
param (
    [string]$SolutionPath = "",
    [string]$BuildType    = ""          # Branch | CI | Nightly | Sprint
)

$ErrorActionPreference = "Stop"

Write-Output "=================== SetupBuildVariables (GHA) ==================="
Write-Output "SolutionPath : $SolutionPath"
Write-Output "BuildType    : $BuildType"
Write-Output "CurrentDir   : $PWD"
Write-Output "Workspace    : $env:GITHUB_WORKSPACE"

# SolutionPath is relative to the repository root, which is the default working directory in GHA. If provided, make it absolute.
if ($SolutionPath) {
    $SolutionPath = Join-Path $env:GITHUB_WORKSPACE $SolutionPath
    Write-Output "Resolved SolutionPath: $SolutionPath"
}

# ── 1. Find Directory.Build.props walking up from the solution directory ──────
function Find-FirstParentPath {
    param([string]$Path, [string]$FileName)
    $test = Join-Path $Path $FileName
    if (Test-Path $test) { return $Path }
    $parent = Split-Path $Path -Parent
    if ($parent -and (Test-Path $parent)) { return Find-FirstParentPath $parent $FileName }
}

$solutionDir        = if ($SolutionPath) { Split-Path $SolutionPath -Parent } else { $PWD.Path }
$dbPropsDir         = Find-FirstParentPath -Path $solutionDir -FileName "Directory.Build.props"

if ($dbPropsDir) {
    Write-Output "Found Directory.Build.props in: $dbPropsDir"
    [xml]$dbProps = Get-Content (Join-Path $dbPropsDir "Directory.Build.props")

    $tfmNode = $dbProps.SelectNodes("//NetCorePublishVersion")
    if ($tfmNode.Count -gt 0) {
        $tfm = $tfmNode[0].InnerText
        Write-Output "NetCorePublishVersion from Directory.Build.props: $tfm"
        # Override workflow-level DOTNET_PUBLISH_TFM and DOTNET_TEST_TFM
        "DOTNET_PUBLISH_TFM=$tfm" >> $env:GITHUB_ENV
        "DOTNET_TEST_TFM=$tfm"    >> $env:GITHUB_ENV
    } else {
        Write-Output "NetCorePublishVersion not found in Directory.Build.props; using workflow default."
    }
} else {
    Write-Output "::error::Directory.Build.props not found above '$solutionDir'."
    exit 1
}
