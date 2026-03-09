$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$sdpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_sdp_orders" -RootDir $rootDir
$edpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_edp_orders" -RootDir $rootDir

Invoke-DockerCompose -Arguments @("up", "-d", "airflow-metadata-db", "source-postgres-db", "lakehouse-object-store")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "lakehouse-bucket-init")
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline.py")

if (-not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_ACCOUNT")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_USER")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_PASSWORD"))) {
    & (Join-Path $PSScriptRoot "ensure-snowflake-foundation.ps1")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/snowflake_raw_sync.py")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "dbt", "build", "--project-dir", $sdpProjectDir, "--profiles-dir", "/opt/platform/dbt/profiles")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "dbt", "build", "--project-dir", $edpProjectDir, "--profiles-dir", "/opt/platform/dbt/profiles")
}
else {
    Write-Host "Skipping dbt build because Snowflake credentials are not set in .env"
}

