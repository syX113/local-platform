$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

Invoke-DockerCompose -Arguments @("up", "--no-build", "-d", "source-postgres-db")

do {
    & docker compose exec -T source-postgres-db `
        pg_isready -U (Get-EnvValue -Name "SOURCE_POSTGRES_USER") -d (Get-EnvValue -Name "SOURCE_POSTGRES_DB") *> $null

    if ($LASTEXITCODE -eq 0) {
        break
    }

    Write-Host "waiting for source-postgres-db"
    Start-Sleep -Seconds 2
} while ($true)

$sqlFiles = @(
    Join-Path $rootDir "postgres/source-init/01-create-source-schema.sql"
    Join-Path $rootDir "postgres/source-init/02-seed-sample-data.sql"
)

foreach ($sqlFile in $sqlFiles) {
    $sql = Get-Content -LiteralPath $sqlFile -Raw
    $sql | & docker compose exec -T source-postgres-db `
        psql -v ON_ERROR_STOP=1 `
        -U (Get-EnvValue -Name "SOURCE_POSTGRES_USER") `
        -d (Get-EnvValue -Name "SOURCE_POSTGRES_DB")

    if ($LASTEXITCODE -ne 0) {
        throw "failed to execute $sqlFile"
    }
}

& docker compose exec -T source-postgres-db `
    psql -U (Get-EnvValue -Name "SOURCE_POSTGRES_USER") `
    -d (Get-EnvValue -Name "SOURCE_POSTGRES_DB") `
    -c @"
select
  (select count(*) from customers) as customers,
  (select count(*) from orders) as orders,
  (select count(*) from order_items) as order_items;
"@

if ($LASTEXITCODE -ne 0) {
    throw "failed to print PostgreSQL source counts"
}
