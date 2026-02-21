<#
.SYNOPSIS
    Replace project references with NuGet package references in solution projects.
.DESCRIPTION
    GHA port of YAML/scripts/ReplaceProjectReferences.ps1.

    Changes from ADO original:
      - ##vso[task.setvariable variable=TIX_USEPACKAGES]true
            →  "TIX_USEPACKAGES=true" >> $GITHUB_ENV
      - ##[command] log prefix kept as-is (cosmetic only in GHA).
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] $Solution,
    [Parameter(Mandatory)] $PathPattern
)

Write-Output "ReplaceProjectReferences: Solution=$Solution  PathPattern=$PathPattern"
Write-Output "Running in $pwd"

$SolutionItem = Get-Item $Solution
$SolutionFile = $SolutionItem.FullName
$SolutionDir  = $SolutionItem.Directory.FullName
Write-Output "Solution Directory: $SolutionDir"

Push-Location $SolutionDir

$projects       = dotnet sln $SolutionFile list | Where-Object { $_ -match "\..*proj" }
$keepProjects   = $projects | Where-Object {   $_ -match $PathPattern }
$replaceProjects= $projects | Where-Object { -not ($_ -match $PathPattern) }

Write-Output "Pattern '$PathPattern': keeping $($keepProjects.Length), removing $($replaceProjects.Length) projects."

$keepProjectNames   = $keepProjects    | ForEach-Object { (Split-Path $_ -Leaf) -replace '\.(cs|es)proj$', '' }
$replaceBinaryNames = @('TixRiaServices.DomainServices.Hosting','TixRiaServices.DomainServices.Hosting.Endpoint','TixRiaServices.DomainServices.Server','TixRiaServices.DomainServices.Tools')
$global:save = $false

function Convert-ProjectReferenceToPackageReference([xml]$proj) {
    $proj.SelectNodes("//ProjectReference") | ForEach-Object {
        $name = (Split-Path $_.Include -Leaf) -replace '\.(cs|es)proj$', ''
        if ($keepProjectNames -notcontains $name) {
            $global:save = $true
            $pkg = $proj.CreateElement('PackageReference'); $pkg.SetAttribute('Include', $name)
            $null = $_.ParentNode.ReplaceChild($pkg, $_)
            Write-Host " - Replaced ProjectReference $name"
        }
    }
}

function Convert-OpenApiProjectReferenceToPackageReference([xml]$proj) {
    $proj.SelectNodes("//OpenApiProjectReference") | ForEach-Object {
        $name = (Split-Path $_.Include -Leaf) -replace '\.csproj$', ''
        if ($keepProjectNames -notcontains $name) {
            $global:save = $true
            $pkg = $proj.CreateElement('PackageReference'); $pkg.SetAttribute('Include', $name)
            if ($_.Attributes["Condition"]) { $null = $pkg.SetAttribute('Condition', $_.Attributes["Condition"].Value) }
            if ($_.Attributes["Options"]) {
                $e = $proj.CreateElement('OpenApiGenerationOptions')
                $null = $e.AppendChild($proj.CreateTextNode($_.Attributes["Options"].Value))
                $null = $pkg.AppendChild($e)
            }
            $_.ChildNodes | ForEach-Object {
                $clone = $_.CloneNode($true)
                if ($clone.Name -eq "CodeGenerator") {
                    $clone = $proj.CreateElement('OpenApiCodeGenerator')
                    $null  = $clone.AppendChild($proj.CreateTextNode($_.InnerText))
                }
                $null = $pkg.AppendChild($clone)
            }
            $null = $_.ParentNode.ReplaceChild($pkg, $_)
            Write-Host " - Replaced OpenApiProjectReference $name"
        }
    }
}

function Convert-RiaServiceReferenceToPackageReference([xml]$proj) {
    $proj.SelectNodes("//Reference") | ForEach-Object {
        $name = (Split-Path $_.Include -Leaf) -replace '\.dll$', ''
        if ($replaceBinaryNames -contains $name) {
            $global:save = $true
            $null = $_.ParentNode.RemoveChild($_)
            $pkg  = $proj.CreateElement('PackageReference'); $pkg.SetAttribute('Include', $name)
            $null = $_.ParentNode.AppendChild($pkg)
            Write-Host " - Replaced binary ref $name"
        }
    }
}

function Convert-TixTargetImportToSdkReference([xml]$proj) {
    $importUi5 = $proj.SelectNodes("//Import") | Where-Object { $_.Project -match "Tix.UI5.SDK.targets" }
    if ($importUi5) {
        $null = $importUi5.ParentNode.RemoveChild($importUi5); $global:save = $true
        $sdk = $proj.SelectNodes("//Project") | Where-Object { $_.Sdk -match "MSBuild.SDK.SystemWeb" }
        if ($sdk) { $null = $sdk.SetAttribute("Sdk","Tix.NET.Sdk.Ui5.Web"); $global:save = $true }
    }
    $import = $proj.SelectNodes("//Import") | Where-Object { $_.Project -match "Tix.targets" }
    if ($import) { $null = $import.ParentNode.RemoveChild($import); $global:save = $true }
    $wsdk = $proj.SelectNodes("//Project") | Where-Object { $_.Sdk -match "Microsoft.NET.Sdk.Web" }
    if ($wsdk)  { $null = $wsdk.SetAttribute("Sdk","Tix.NET.Sdk.Web");  $global:save = $true }
    $sdk  = $proj.SelectNodes("//Project") | Where-Object { $_.Sdk -match "^Microsoft.NET.Sdk$" }
    if ($sdk)   { $null = $sdk.SetAttribute("Sdk","Tix.NET.Sdk");       $global:save = $true }
}

foreach ($project in $keepProjects) {
    $fullName = (Get-ChildItem $project).FullName
    Write-Output "Processing $project"
    [xml]$content = Get-Content $fullName
    $global:save  = $false
    Convert-ProjectReferenceToPackageReference        $content
    Convert-OpenApiProjectReferenceToPackageReference $content
    Convert-RiaServiceReferenceToPackageReference     $content
    Convert-TixTargetImportToSdkReference             $content
    if ($global:save) { $content.Save($fullName) }
}

if ($replaceProjects.Length -gt 0) {
    dotnet sln $SolutionFile remove $replaceProjects
}

# GHA: set env var instead of ##vso[task.setvariable]
"TIX_USEPACKAGES=true" >> $env:GITHUB_ENV

Pop-Location
