<#
.SYNOPSIS
    Replace container image tags in GitOps deployment YAML files.
.DESCRIPTION
    GHA port of YAML/scripts/ReplaceImageTags.ps1.

    Changes from ADO original:
      - git commit message uses GITHUB_WORKFLOW / GITHUB_RUN_NUMBER
        instead of BUILD_DEFINITIONNAME / BUILD_BUILDNUMBER.
      - No other ADO-specific commands; logic is identical.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string]$ImageFilePath,
    [Parameter(Mandatory)] [string]$GitOpsDirectory,
    [Parameter(Mandatory)] [string]$GitOpsEnvironment,
    [Parameter(Mandatory)] [bool]  $Commit,
    [string]$ImageRegistry = "tipsregistry.azurecr.io"
)

Set-StrictMode -Version 3.0

$global:totalChangeCount = 0
$ImageRegistry = $ImageRegistry.TrimEnd("/")

function ProcessDeploymentYamlValueFiles($deploymentDir, $imagesFromBuild, $imageNamesFromBuild) {
    Write-Host "--- Processing deployment yaml value files ---"
    Get-ChildItem -Path $deploymentDir -Recurse -Filter "*values-imageVersionOverrides*" | ForEach-Object {
        $path        = $_.FullName
        $changeCount = 0
        $yaml        = Get-Content $path
        $yaml | ForEach-Object {
            $split = $_.ToString().Split(":")
            if ($split.Length -gt 1) {
                $imageName = $split[0].Trim()
                if ($imageNamesFromBuild -contains $imageName) {
                    $imageNamesFromBuild.Remove($imageName) | Out-Null
                    $replaceToImage = ($imagesFromBuild | Where-Object { $_ -like "$imageName`:*" }).Split(":")
                    $replaceToName  = "$imageName`: `"$($replaceToImage[1])`""
                    Write-Host "  --> Replacing: $_ → $replaceToName"
                    $yaml = $yaml.Replace($_.Trim(), $replaceToName)
                    $changeCount++
                }
            }
        }
        if ($changeCount -gt 0) {
            $global:totalChangeCount += $changeCount
            $yaml | Set-Content $path
            if ($Commit) { git add $path }
        }
    }
}

function ProcessDeploymentYamlFiles($deploymentDir, $imagesFromBuild, $imageNamesFromBuild) {
    Write-Host "--- Processing deployment yaml files ---"
    Get-ChildItem -Path $deploymentDir -Recurse -Filter "*deployments.yml" | ForEach-Object {
        $path = $_.FullName
        if ($path -like "*-branch-*") { Write-Host "Skipping branch yaml: $path"; return }
        $changeCount = 0
        $yaml        = Get-Content $path
        $yaml | Select-String "image:" | ForEach-Object {
            $split     = $_.ToString().Split(":")
            $image     = $split[1].Trim()
            $imageName = $image.Split(":")[0].Replace("$ImageRegistry/","")
            $oldVersion= $split[2].Trim()
            if ($imageNamesFromBuild -contains $imageName) {
                $imageNamesFromBuild.Remove($imageName) | Out-Null
                $replaceToName = "$ImageRegistry/" + ($imagesFromBuild | Where-Object { $_ -like "$imageName`:*" })
                Write-Host "  --> Replacing: $image`:$oldVersion → $replaceToName"
                $yaml = $yaml.Replace("$image`:$oldVersion", $replaceToName)
                $changeCount++
            }
        }
        if ($changeCount -gt 0) {
            $global:totalChangeCount += $changeCount
            $yaml | Set-Content $path
            if ($Commit) { git add $path }
        }
    }
}

if (!(Test-Path $ImageFilePath)) { Write-Error "Image file '$ImageFilePath' does not exist." }

$deploymentDirs = Resolve-Path "$GitOpsDirectory/$GitOpsEnvironment"
foreach ($dir in $deploymentDirs) {
    if (!(Test-Path $dir)) { Write-Error "Deployment directory '$dir' does not exist." }
}

$imageNamesFromBuild = [System.Collections.ArrayList]::new()
$imagesFromBuild     = @()

Get-Content $ImageFilePath | ForEach-Object {
    $image = $_.Split("/")[1]
    $imagesFromBuild += $image
    $imageNamesFromBuild.Add($image.Split(":")[0]) | Out-Null
    Write-Host "Image from build: $image"
}

Push-Location $GitOpsDirectory

if ($Commit) {
    git config user.email "no-reply@tietoevry.com"
    git config user.name  "AutoUpdateBot"
    git fetch
    git switch main
    git reset --hard origin/main
    git pull
}

foreach ($dir in $deploymentDirs) {
    ProcessDeploymentYamlValueFiles $dir $imagesFromBuild $imageNamesFromBuild.Clone()
    ProcessDeploymentYamlFiles      $dir $imagesFromBuild $imageNamesFromBuild.Clone()
}

if ($global:totalChangeCount -eq 0) {
    Write-Host "No GitOps changes needed."
    Pop-Location
    exit 0
}

if ($Commit) {
    # GHA: use GITHUB_WORKFLOW and GITHUB_RUN_NUMBER instead of ADO BUILD_DEFINITIONNAME / BUILD_BUILDNUMBER
    $msg = "Replace image tags for $env:GITHUB_WORKFLOW run $env:GITHUB_RUN_NUMBER"
    git commit -m $msg
    git push
}

Pop-Location
