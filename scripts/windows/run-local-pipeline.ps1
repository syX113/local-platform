$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$sdpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_source_finnova" -RootDir $rootDir
$sdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($sdpDbtProject)) {
    $sdpDbtProject = "DEV_DBT_PROJECT_SOURCE_FINNOVA"
}

Invoke-DockerCompose -Arguments @("up", "-d", "airflow-metadata-db", "source-postgres-db", "lakehouse-object-store")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "lakehouse-bucket-init")
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_orders.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_customers.py")

if (-not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_ACCOUNT")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_USER")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_PASSWORD"))) {
    & (Join-Path $PSScriptRoot "ensure-snowflake-foundation.ps1")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=orders python /opt/platform/dlt/snowflake_raw_sync.py")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=customers python /opt/platform/dlt/snowflake_raw_sync.py")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $sdpProjectDir, "--project-name", $sdpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA"), "--target-name", "dev")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $sdpDbtProject, "build")
    Write-Host "EDP deploy/build is intentionally skipped here; use the EDP CI/CD pipelines or the dedicated EDP deploy scripts."
}
else {
    Write-Host "Skipping Snowflake-native dbt build because Snowflake credentials are not set in .env"
}
