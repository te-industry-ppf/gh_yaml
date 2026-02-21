<#
.SYNOPSIS
    Resolve shared NuGet package versions from Azure Artifacts feeds and update nuget.config.
.DESCRIPTION
    GHA port of YAML/scripts/GetNugetPackageVersions.ps1.

    Changes from ADO original:
      - $env:SYSTEM_ACCESSTOKEN  →  $env:AZURE_DEVOPS_PAT
      - ##vso[task.setvariable variable=NAME]VALUE  →  "NAME=VALUE" >> $env:GITHUB_ENV
      - ##vso[task.uploadsummary]path  →  Append content to $env:GITHUB_STEP_SUMMARY
      - ##[group] / ##[endgroup]  →  ::group:: / ::endgroup::
      - $env:TF_BUILD / $env:AGENT_JOBNAME checks removed (not needed in GHA context).
      - $env:AGENT_WORKFOLDER  →  $env:RUNNER_TEMP
#>
param (
    [string]$BuildType              = "Sprint",
    [string]$BuildSafeSourceBranchName = "sprint-g-285-htfx"
)

Set-StrictMode -Version 3.0

Write-Output "GetNugetPackageVersions: BuildType=$BuildType  SafeBranch=$BuildSafeSourceBranchName"

$useBranch  = $BuildType -eq "Branch"
$useCI      = ($BuildType -eq "Branch") -or ($BuildType -eq "CI")
$useNightly = ($BuildType -eq "Branch") -or ($BuildType -eq "CI") -or ($BuildType -eq "Nightly")
$useSprint  = $true  # always check sprint feed (fixed deps may live there, e.g. EUDR)

$nugetConfigFile = (Get-ChildItem -Filter "*.config" | Where-Object { $_.BaseName -ieq "nuget" }).Name
if (-not $nugetConfigFile) { Write-Error "nuget.config not found in $PWD"; exit 1 }

Write-Output "UseBranch=$useBranch  UseCI=$useCI  UseNightly=$useNightly  UseSprint=$useSprint"

if ($useSprint) {
    $sprint = $BuildSafeSourceBranchName -replace "sprint-g-", "" -replace "-htfx", ""
    Write-Output "Sprint number: $sprint"
}

# Use a temp NuGet HTTP cache to avoid poisoning the shared cache
$tempNugetCache = Join-Path $env:RUNNER_TEMP (".nuget/v3-cache/" + [Guid]::NewGuid().ToString("N"))
$oldNugetCache  = $env:NUGET_HTTP_CACHE_PATH
$env:NUGET_HTTP_CACHE_PATH = $tempNugetCache

$TixDependenciesFile = if ($env:TixDependenciesFile) { $env:TixDependenciesFile } else { "Tix.Dependencies.props" }

$packageVersionsTable = [System.Collections.ArrayList]::new()
$packageVersionsTable.Add("| SubSystem                     | PackageVersion            | Feed                 |") | Out-Null
$packageVersionsTable.Add("|-------------------------------|---------------------------|----------------------|") | Out-Null

if (-not (Test-Path $TixDependenciesFile)) {
    Write-Output "Cannot find '$TixDependenciesFile', skipping nuget version resolution."
    exit 0
}

# ── Helper: create a temporary nuget.config for a single feed ────────────────
function Write-NugetConfig {
    param([bool]$Condition, [string]$FeedName, [string]$PackageSourceUrl)
    if (-not $Condition) { return }
    $file = "test.$FeedName.nuget.config"
    Set-Content $file "<configuration></configuration>"
    # GHA: use AZURE_DEVOPS_PAT instead of SYSTEM_ACCESSTOKEN
    $pat  = $env:AZURE_DEVOPS_PAT
    if ($pat) {
        dotnet nuget add source -n $FeedName $PackageSourceUrl --configfile $file          -u anonymous -p $pat --store-password-in-clear-text | Out-Null
        dotnet nuget add source -n $FeedName $PackageSourceUrl --configfile $global:nugetConfigFile `
               -u anonymous -p $pat --store-password-in-clear-text | Out-Null
    } else {
        dotnet nuget add source -n $FeedName $PackageSourceUrl --configfile $file | Out-Null
        dotnet nuget add source -n $FeedName $PackageSourceUrl --configfile $global:nugetConfigFile | Out-Null
    }
    # Warmup
    dotnet package search "Tix.Runtime" --verbosity minimal --prerelease --exact-match `
           --source $FeedName --format json --configfile $file | Out-Null
}

function Remove-NugetConfig {
    param([bool]$Condition, [string]$FeedName)
    if (-not $Condition) { return }
    $file = "test.$FeedName.nuget.config"
    if (Test-Path $file) { Remove-Item $file }
}

function Get-VersionForCi {
    param([string]$ciVersion, [string]$niVersion)
    if (-not $niVersion) { return $ciVersion }
    $ciDate = $ciVersion -replace "1\.0\.3-ci-", "" -replace "-", ""
    $niDate = $niVersion -replace "1\.0\.1-ni-", "" -replace "-", ""
    if ($ciDate.Substring(0, [Math]::Min(8,$ciDate.Length)) -gt $niDate.Substring(0, [Math]::Min(8,$niDate.Length))) { return $ciVersion }
    return $niVersion
}

function Get-PackageVersionFromSource {
    param([string]$PackageName, [string]$FeedName, [string]$SearchString)
    $result = dotnet package search $PackageName --verbosity minimal --prerelease --exact-match `
                  --source $FeedName --format json --configfile "test.$FeedName.nuget.config" 2>&1
    try {
        $json     = $result | ConvertFrom-Json
        $packages = $json.searchResult[0].packages
        if (-not $packages -or $packages.Count -eq 0) { return $null }
        $versions = $packages | ForEach-Object {
            ($_.psobject.Properties['latestVersion'] ?? $_.psobject.Properties['version']).Value
        } | Where-Object { $_.Contains($SearchString) }
        if (-not $versions -or $versions.Count -eq 0) { return $null }
        return $versions[0]
    } catch { return $null }
}

function Set-PackageVersion {
    param([string]$SubSystem, [string]$FoundVersion)
    $varName = "${SubSystem}Version"
    Write-Output "  $varName = $FoundVersion"
    # GHA: write to GITHUB_ENV instead of ##vso[task.setvariable]
    "$varName=$FoundVersion"          >> $env:GITHUB_ENV
    "DOTNET_$varName=$FoundVersion"   >> $env:GITHUB_ENV
    Set-Item "Env:\$varName"          $FoundVersion
    Set-Item "Env:\DOTNET_$varName"   $FoundVersion
}

function Get-PackageVersion {
    param([string]$SubSystem, [string]$PackageName)
    if ($useBranch) {
        $v = Get-PackageVersionFromSource $PackageName "TIX-BRANCH" $BuildSafeSourceBranchName
        if ($v) { Set-PackageVersion $SubSystem $v; $packageVersionsTable.Add("| $($SubSystem.PadRight(30))| $($v.PadRight(25)) | TIX-BRANCH           |") | Out-Null; return }
    }
    if ($useCI) {
        $vci = Get-PackageVersionFromSource $PackageName "TIX-CI"      "-ci-"
        $vni = Get-PackageVersionFromSource $PackageName "TIX-NIGHTLY" "-ni-"
        if ($vci) {
            $v    = Get-VersionForCi $vci $vni
            $feed = if ($v -eq $vni) { "TIX-NIGHTLY" } else { "TIX-CI" }
            Set-PackageVersion $SubSystem $v
            $packageVersionsTable.Add("| $($SubSystem.PadRight(30))| $($v.PadRight(25)) | $($feed.PadRight(20)) |") | Out-Null
            return
        }
    }
    if ($useNightly) {
        $v = Get-PackageVersionFromSource $PackageName "TIX-NIGHTLY" "-ni-"
        if ($v) { Set-PackageVersion $SubSystem $v; $packageVersionsTable.Add("| $($SubSystem.PadRight(30))| $($v.PadRight(25)) | TIX-NIGHTLY          |") | Out-Null; return }
    }
    if ($useSprint) {
        $v = Get-PackageVersionFromSource $PackageName "TIX-SPRINT" "1.0.$sprint"
        if (-not $v) { $v = "0.0.0" }
        Set-PackageVersion $SubSystem $v
        $packageVersionsTable.Add("| $($SubSystem.PadRight(30))| $($v.PadRight(25)) | TIX-SPRINT           |") | Out-Null
    }
}

function Update-PackageSourceMapping {
    param([xml]$NugetConfig)
    $mapping = $NugetConfig.configuration.packageSourceMapping
    if (-not $mapping) { return }
    $tipsSource = $mapping.packageSource | Where-Object { $_.key -eq "TIPS" }
    if (-not $tipsSource) { return }
    foreach ($feedName in @("TIX-BRANCH","TIX-CI","TIX-NIGHTLY","TIX-SPRINT") | Where-Object {
        ($_ -eq "TIX-BRANCH"  -and $useBranch)  -or
        ($_ -eq "TIX-CI"      -and $useCI)       -or
        ($_ -eq "TIX-NIGHTLY" -and $useNightly)  -or
        ($_ -eq "TIX-SPRINT"  -and $useSprint)
    }) {
        if (-not ($mapping.packageSource | Where-Object { $_.key -eq $feedName })) {
            $newSrc = $NugetConfig.CreateElement("packageSource"); $newSrc.SetAttribute("key", $feedName)
            $tipsSource.package | ForEach-Object { $p = $NugetConfig.CreateElement("package"); $p.SetAttribute("pattern",$_.pattern); $newSrc.AppendChild($p) | Out-Null }
            $mapping.AppendChild($newSrc) | Out-Null
            Write-Output "Added packageSourceMapping for $feedName"
        }
    }
}

# ── Set up feed configs ───────────────────────────────────────────────────────
Copy-Item $nugetConfigFile "$nugetConfigFile.original" -Force
dotnet nuget remove source "TIPS" --configfile $nugetConfigFile | Out-Null

Write-NugetConfig -Condition $useBranch  -FeedName "TIX-BRANCH"  -PackageSourceUrl "https://pkgs.dev.azure.com/tieto-pe/_packaging/TIX-BRANCH/nuget/v3/index.json"
Write-NugetConfig -Condition $useCI      -FeedName "TIX-CI"      -PackageSourceUrl "https://pkgs.dev.azure.com/tieto-pe/_packaging/TIX-CI/nuget/v3/index.json"
Write-NugetConfig -Condition $useNightly -FeedName "TIX-NIGHTLY" -PackageSourceUrl "https://pkgs.dev.azure.com/tieto-pe/_packaging/TIX-NIGHTLY/nuget/v3/index.json"
Write-NugetConfig -Condition $useSprint  -FeedName "TIX-SPRINT"  -PackageSourceUrl "https://pkgs.dev.azure.com/tieto-pe/_packaging/TIX-SPRINT/nuget/v3/index.json"
Write-NugetConfig -Condition $true       -FeedName "TIPS"        -PackageSourceUrl "https://pkgs.dev.azure.com/tieto-pe/_packaging/TIX-NUGETPE/nuget/v3/index.json"

[xml]$cfg = Get-Content $nugetConfigFile
Update-PackageSourceMapping $cfg
$cfg.Save($nugetConfigFile)

# ── Resolve versions for each dependency ─────────────────────────────────────
$dependencies = Select-Xml -Path $TixDependenciesFile -XPath "//ModuleReference" | Select-Object -ExpandProperty Node
foreach ($dep in $dependencies) {
    Get-PackageVersion -SubSystem $dep.Include -PackageName $dep.Reference
}

# ── Publish summary ───────────────────────────────────────────────────────────
$tableText = $packageVersionsTable -join "`n"
Set-Content -Path PackageVersions.md -Value $tableText
# GHA: append to step summary instead of ##vso[task.uploadsummary]
if ($env:GITHUB_STEP_SUMMARY) {
    "## Package Versions`n`n$tableText" >> $env:GITHUB_STEP_SUMMARY
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
Remove-NugetConfig -Condition $useBranch  -FeedName "TIX-BRANCH"
Remove-NugetConfig -Condition $useCI      -FeedName "TIX-CI"
Remove-NugetConfig -Condition $useNightly -FeedName "TIX-NIGHTLY"
Remove-NugetConfig -Condition $useSprint  -FeedName "TIX-SPRINT"

$env:NUGET_HTTP_CACHE_PATH = $oldNugetCache
Remove-Item -Recurse $tempNugetCache -ErrorAction SilentlyContinue

Write-Output "--- Modified nuget.config ---"; Get-Content $nugetConfigFile
Write-Output "--- PackageVersions.md ---";    Get-Content PackageVersions.md
