<#
  Waits for the latest CI build of the current commit, then downloads either
  the .ipa (success) or the compiler errors (failure) into .\dist

    powershell -ExecutionPolicy Bypass -File scripts\fetch-build.ps1          # just fetch
    powershell -ExecutionPolicy Bypass -File scripts\fetch-build.ps1 -Push    # git push first
#>
param([switch]$Push)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

if ($Push) { git push }

$sha = (git rev-parse HEAD).Trim()
Write-Host "Waiting for CI run of $($sha.Substring(0,7))..."
$runId = $null
for ($i = 0; $i -lt 30 -and -not $runId; $i++) {
    $runId = gh run list --workflow build.yml --commit $sha --limit 1 --json databaseId --jq '.[0].databaseId'
    if (-not $runId) { Start-Sleep -Seconds 5 }
}
if (-not $runId) { throw "No CI run found for $sha (did you push?)" }

gh run watch $runId --exit-status --interval 20
$ok = $LASTEXITCODE -eq 0

$dist = Join-Path (Get-Location) 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
if ($ok) {
    gh run download $runId --name QVision-ipa --dir $dist
    $ipa = Get-ChildItem $dist -Filter *.ipa | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Host "`nIPA ready: $($ipa.FullName)" -ForegroundColor Green
    Write-Host "Next: open iloader -> Vision Pro -> Import IPA -> pick this file."
} else {
    gh run download $runId --name build-log --dir (Join-Path $dist 'build-log')
    Write-Host "`nBuild FAILED. Errors:" -ForegroundColor Red
    Get-Content (Join-Path $dist 'build-log\errors.txt')
    exit 1
}
