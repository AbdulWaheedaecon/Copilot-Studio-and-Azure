<#
.SYNOPSIS
  Downloads health-plan sample PDFs, uploads to blob storage, and creates an
  Azure AI Search index + indexer to index the content.

.DESCRIPTION
  Steps:
    1. Downloads 6 PDF files from Azure-Samples/azure-search-sample-data (health-plan).
    2. Uploads them to the blob container provisioned by the Bicep template.
    3. Temporarily enables public network access on the search service.
    4. Creates index schema, data source, and indexer via the Search REST API.
    5. Waits for the indexer to finish its first run.
    6. Re-disables public network access on the search service.

  Prerequisites:
    - Azure CLI signed in with Contributor on the resource group.
    - The Bicep deployment must have been run with deploySampleData=true.
    - Run from the accelerators/private-endpoint/ai-search/ directory.

.PARAMETER ResourceGroup
  Azure resource group name (auto-read from deployment-outputs-aisearch.json if omitted).

.PARAMETER SearchServiceName
  Name of the Azure AI Search service (auto-read from deployment outputs if omitted).

.PARAMETER StorageAccountName
  Name of the sample data storage account (auto-read from deployment outputs if omitted).

.PARAMETER ContainerName
  Blob container name for PDFs. Default: health-plan-pdfs.

.PARAMETER IndexName
  Name for the search index. Default: health-plan-index.

.PARAMETER SkipPublicAccessRestore
  If set, leaves public access enabled after indexing (useful for debugging).

.EXAMPLE
  ./scripts/load-sample-data.ps1
#>
[CmdletBinding()]
param(
  [string] $ResourceGroup,
  [string] $SearchServiceName,
  [string] $StorageAccountName,
  [string] $ContainerName = 'health-plan-pdfs',
  [string] $IndexName = 'health-plan-index',
  [switch] $SkipPublicAccessRestore
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Load deployment outputs if parameters not supplied
# ---------------------------------------------------------------------------
$outputsFile = Join-Path $PSScriptRoot 'deployment-outputs-aisearch.json'
if (Test-Path $outputsFile) {
  $outputs = Get-Content $outputsFile | ConvertFrom-Json
  if (-not $ResourceGroup)      { $ResourceGroup      = $outputs.resourceGroup }
  if (-not $SearchServiceName)  { $SearchServiceName  = $outputs.searchServiceName }
  if (-not $StorageAccountName) { $StorageAccountName = $outputs.sampleStorageAccountName }
}

foreach ($v in @('ResourceGroup', 'SearchServiceName', 'StorageAccountName')) {
  if (-not (Get-Variable -Name $v -ValueOnly -ErrorAction SilentlyContinue)) {
    throw "Missing parameter '$v'. Run the Bicep deployment with deploySampleData=true first, or provide the value explicitly."
  }
}

# ---------------------------------------------------------------------------
# 1. Download sample PDFs from GitHub
# ---------------------------------------------------------------------------
$pdfFiles = @(
  'Benefit_Options.pdf',
  'Northwind_Health_Plus_Benefits_Details.pdf',
  'Northwind_Standard_Benefits_Details.pdf',
  'PerksPlus.pdf',
  'employee_handbook.pdf',
  'role_library.pdf'
)

$baseUrl = 'https://raw.githubusercontent.com/Azure-Samples/azure-search-sample-data/main/health-plan'
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'aisearch-sample-pdfs'

if (-not (Test-Path $tempDir)) { New-Item -ItemType Directory -Path $tempDir | Out-Null }

Write-Host "==> Downloading sample PDFs from GitHub" -ForegroundColor Cyan
foreach ($file in $pdfFiles) {
  $dest = Join-Path $tempDir $file
  if (-not (Test-Path $dest)) {
    Write-Host "    $file"
    Invoke-WebRequest -Uri "$baseUrl/$file" -OutFile $dest -UseBasicParsing
  } else {
    Write-Host "    $file (cached)"
  }
}

# ---------------------------------------------------------------------------
# 2. Upload PDFs to blob storage
# ---------------------------------------------------------------------------
Write-Host "==> Uploading PDFs to storage account '$StorageAccountName' container '$ContainerName'" -ForegroundColor Cyan

$storageKey = (az storage account keys list -g $ResourceGroup -n $StorageAccountName --query '[0].value' -o tsv)
if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve storage account key." }

foreach ($file in $pdfFiles) {
  $filePath = Join-Path $tempDir $file
  az storage blob upload `
    --account-name $StorageAccountName `
    --account-key $storageKey `
    --container-name $ContainerName `
    --file $filePath `
    --name $file `
    --overwrite true `
    --only-show-errors | Out-Null
  Write-Host "    uploaded: $file"
}

# ---------------------------------------------------------------------------
# 3. Allow deployer's IP through the search service firewall (no full public access)
# ---------------------------------------------------------------------------
Write-Host "==> Detecting deployer public IP" -ForegroundColor Cyan
$deployerIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -UseBasicParsing).Trim()
Write-Host "    Deployer IP: $deployerIp"

Write-Host "==> Adding IP rule for $deployerIp on '$SearchServiceName' (keeping public access scoped)" -ForegroundColor Cyan
az search service update -g $ResourceGroup -n $SearchServiceName `
    --public-access enabled `
    --ip-rules $deployerIp `
    --only-show-errors | Out-Null

# Wait for the firewall change to propagate
Write-Host "    Waiting for firewall rule to propagate..."
Start-Sleep -Seconds 15

# ---------------------------------------------------------------------------
# 4. Get admin key and build REST headers
# ---------------------------------------------------------------------------
$adminKey = (az search admin-key show -g $ResourceGroup --service-name $SearchServiceName --query 'primaryKey' -o tsv)
if ($LASTEXITCODE -ne 0) { throw "Failed to retrieve search admin key." }

$searchEndpoint = "https://$SearchServiceName.search.windows.net"
$apiVersion = '2024-07-01'
$headers = @{
  'api-key'      = $adminKey
  'Content-Type' = 'application/json'
}

# ---------------------------------------------------------------------------
# 5. Create index schema
# ---------------------------------------------------------------------------
Write-Host "==> Creating search index '$IndexName'" -ForegroundColor Cyan

$indexDef = @{
  name = $IndexName
  fields = @(
    @{ name = 'content';                type = 'Edm.String';         searchable = $true;  filterable = $false; sortable = $false; facetable = $false; key = $false; analyzer = 'standard.lucene' }
    @{ name = 'metadata_storage_path';  type = 'Edm.String';         searchable = $false; filterable = $true;  sortable = $false; facetable = $false; key = $true;  retrievable = $true }
    @{ name = 'metadata_storage_name';  type = 'Edm.String';         searchable = $true;  filterable = $true;  sortable = $true;  facetable = $false; key = $false }
    @{ name = 'metadata_content_type';  type = 'Edm.String';         searchable = $false; filterable = $true;  sortable = $false; facetable = $true;  key = $false }
    @{ name = 'metadata_storage_size';  type = 'Edm.Int64';          searchable = $false; filterable = $true;  sortable = $true;  facetable = $false; key = $false }
  )
} | ConvertTo-Json -Depth 10

$resp = Invoke-RestMethod -Method PUT `
  -Uri "$searchEndpoint/indexes/$($IndexName)?api-version=$apiVersion" `
  -Headers $headers `
  -Body $indexDef
Write-Host "    index created: $($resp.name)"

# ---------------------------------------------------------------------------
# 6. Create data source
# ---------------------------------------------------------------------------
Write-Host "==> Creating data source 'ds-health-plan-blobs'" -ForegroundColor Cyan

$storageConnStr = "DefaultEndpointsProtocol=https;AccountName=$StorageAccountName;AccountKey=$storageKey;EndpointSuffix=core.windows.net"

$dataSourceDef = @{
  name = 'ds-health-plan-blobs'
  type = 'azureblob'
  credentials = @{ connectionString = $storageConnStr }
  container = @{ name = $ContainerName }
} | ConvertTo-Json -Depth 10

$resp = Invoke-RestMethod -Method PUT `
  -Uri "$searchEndpoint/datasources/ds-health-plan-blobs?api-version=$apiVersion" `
  -Headers $headers `
  -Body $dataSourceDef
Write-Host "    data source created: $($resp.name)"

# ---------------------------------------------------------------------------
# 7. Create indexer (uses built-in document cracking for PDFs)
# ---------------------------------------------------------------------------
Write-Host "==> Creating indexer 'ixr-health-plan'" -ForegroundColor Cyan

$indexerDef = @{
  name = 'ixr-health-plan'
  dataSourceName = 'ds-health-plan-blobs'
  targetIndexName = $IndexName
  parameters = @{
    configuration = @{
      dataToExtract = 'contentAndMetadata'
      parsingMode = 'default'
    }
  }
  fieldMappings = @(
    @{
      sourceFieldName = 'metadata_storage_path'
      targetFieldName = 'metadata_storage_path'
      mappingFunction = @{ name = 'base64Encode' }
    }
  )
} | ConvertTo-Json -Depth 10

$resp = Invoke-RestMethod -Method PUT `
  -Uri "$searchEndpoint/indexers/ixr-health-plan?api-version=$apiVersion" `
  -Headers $headers `
  -Body $indexerDef
Write-Host "    indexer created: $($resp.name)"

# ---------------------------------------------------------------------------
# 8. Wait for indexer to finish
# ---------------------------------------------------------------------------
Write-Host "==> Waiting for indexer run to complete..." -ForegroundColor Cyan
$maxWait = 180  # seconds
$elapsed = 0
$pollInterval = 10

do {
  Start-Sleep -Seconds $pollInterval
  $elapsed += $pollInterval
  $status = Invoke-RestMethod -Method GET `
    -Uri "$searchEndpoint/indexers/ixr-health-plan/status?api-version=$apiVersion" `
    -Headers $headers

  $lastRun = $status.lastResult
  $runStatus = if ($lastRun) { $lastRun.status } else { 'running' }
  Write-Host "    status: $runStatus ($elapsed s elapsed)"
} while ($runStatus -notin @('success', 'transientFailure', 'persistentFailure') -and $elapsed -lt $maxWait)

if ($runStatus -eq 'success') {
  $docCount = $lastRun.itemsProcessed
  Write-Host "    Indexing complete: $docCount documents indexed." -ForegroundColor Green
} else {
  Write-Warning "Indexer did not complete successfully (status: $runStatus). Check the indexer in the Azure Portal for details."
}

# ---------------------------------------------------------------------------
# 9. Remove deployer IP rule and restore public access disabled
# ---------------------------------------------------------------------------
if (-not $SkipPublicAccessRestore) {
  Write-Host "==> Removing IP rule and disabling public network access on '$SearchServiceName'" -ForegroundColor Cyan
  az search service update -g $ResourceGroup -n $SearchServiceName `
      --public-access disabled `
      --ip-rules '""' `
      --only-show-errors | Out-Null
  Write-Host "    Public access disabled and IP rules cleared." -ForegroundColor Green
} else {
  Write-Warning "SkipPublicAccessRestore set — deployer IP rule ($deployerIp) remains on '$SearchServiceName'."
}

Write-Host ""
Write-Host "Sample data loaded. Index '$IndexName' is ready with health-plan documents." -ForegroundColor Green
Write-Host "You can test from the custom connector with: search=health AND indexName=$IndexName" -ForegroundColor Green
