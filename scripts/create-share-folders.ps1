<#
.SYNOPSIS
  Creates the sub-folders on the Azure Files share that the apps mount through "subPath".
.EXAMPLE
  .\create-share-folders.ps1 -StorageAccount <name> -ResourceGroup <rg> [-Subscription <id>] [-Share containers]
#>
param(
    [Parameter(Mandatory)] [string] $StorageAccount,
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [string] $Subscription,
    [string] $Share = 'containers'
)

$ErrorActionPreference = 'Stop'

$subArgs = @()
if ($Subscription) { $subArgs = @('--subscription', $Subscription) }

$key = az storage account keys list -g $ResourceGroup -n $StorageAccount @subArgs --query '[0].value' -o tsv

# Parents first: each level must exist before the next one is created.
$folders = @(
    'graphic-elements-v1', 'graphic-elements-v1/torch', 'graphic-elements-v1/cache',
    'ocr-v1',
    'page-elements-v3', 'page-elements-v3/cache', 'page-elements-v3/weight',
    'table-structure-v1', 'table-structure-v1/cache', 'table-structure-v1/weight',
    'nano-12b-v2-vl', 'nano-12b-v2-vl/cache'
)

foreach ($f in $folders) {
    az storage directory create --account-name $StorageAccount --account-key $key --share-name $Share --name $f --only-show-errors -o none
    Write-Host "created $Share/$f"
}
