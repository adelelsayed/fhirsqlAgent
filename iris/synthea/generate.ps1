<#
    Regenerate the synthetic FHIR population this demo runs on. (Windows)

    Parameters are not invented: they are read back from the bulk-export
    manifest Synthea wrote alongside the data we actually loaded
    (iris/data/synthea/metadata/*.json). See README.md in this directory.

      seed / clinicianSeed / referenceTime : 20261101
      state                                : Massachusetts
      -p 300                               -> 337 patients
      exporter.fhir.bulk_data=true         -> NDJSON per resource type
      exporter.years_of_history=10

    Usage:
      .\generate.ps1
      .\generate.ps1 -OutDir D:\somewhere\synthea
#>
param(
    [string]$OutDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'data\synthea'),
    [string]$Jar    = (Join-Path $PSScriptRoot 'synthea-with-dependencies.jar')
)

$ErrorActionPreference = 'Stop'

$Seed       = 20261101
$Population = 300
$State      = 'Massachusetts'

if ($null -eq (Get-Command java -ErrorAction SilentlyContinue)) {
    throw "java not found. Synthea needs a JRE; this dataset was built with 17.0.20."
}

if (-not (Test-Path $Jar)) {
    Write-Host "Synthea jar not found at: $Jar"
    Write-Host ""
    Write-Host "Download it (about 200 MB) with:"
    Write-Host "  Invoke-WebRequest -Uri https://github.com/synthetichealth/synthea/releases/download/master-branch-latest/synthea-with-dependencies.jar -OutFile `"$Jar`""
    Write-Host ""
    Write-Host "NOTE ON REPRODUCIBILITY: a Synthea seed is deterministic for a GIVEN BUILD,"
    Write-Host "not across builds. The data in this repository came from v3.4.0-18-ga07a65555,"
    Write-Host "a master snapshot. A newer jar with the same seed produces a valid population"
    Write-Host "of the same shape, but not the identical patients -- so the row counts in the"
    Write-Host "README and the article are the ones from that build."
    throw "jar missing"
}

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force $OutDir | Out-Null }

Write-Host "generating $Population patients ($State, seed $Seed) into $OutDir ..."

& java -jar $Jar `
    -p  $Population `
    -s  $Seed `
    -cs $Seed `
    -r  $Seed `
    --exporter.baseDirectory $OutDir `
    --exporter.fhir.bulk_data true `
    --exporter.years_of_history 10 `
    $State

if ($LASTEXITCODE -ne 0) { throw "synthea exited with $LASTEXITCODE" }

Write-Host ""
Write-Host "done. NDJSON is in $OutDir\fhir"
Write-Host ""
Write-Host @'
BEFORE LOADING, strip Synthea's conditional references:

    python ..\sidecar\fix_refs.py <out>\fhir C:\temp\fixed

Synthea writes references of the form

    "location": { "reference": "Location?identifier=https://github.com/..." }

which are legal inside a transaction bundle but rejected for a standalone POST
with <HSFHIRErr>MalformedRelativeReference. HS.FHIRServer.Tools.DataLoader
reports "Completed successfully" while refusing 100% of such a file, so always
load with pDisplayProgress=1. See the Gotchas section of iris\README.md.
'@
