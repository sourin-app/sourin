[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BuildProject,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCoreSha256
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_package_inventory.ps1')
if (Test-Path -LiteralPath $PackageRoot) { throw 'Package directory must be new' }
$files = @(Get-WindowsPackageInventory $BuildProject)
New-Item -ItemType Directory -Path $PackageRoot | Out-Null
foreach ($file in $files) {
    $destination = Join-Path $PackageRoot $file.Relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination
}
& (Join-Path $PSScriptRoot 'verify_owner_windows_package.ps1') -BuildProject $BuildProject -PackageRoot $PackageRoot -ExpectedCoreSha256 $ExpectedCoreSha256
