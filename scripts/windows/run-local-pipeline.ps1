$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$sdpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_sdp_orders" -RootDir $rootDir
$edpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_edp_orders" -RootDir $rootDir
$sdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($sdpDbtProject)) {
    $sdpDbtProject = "DEV_DBT_PROJECT_SDP_ORDERS"
}
$edpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($edpDbtProject)) {
    $edpDbtProject = "DEV_DBT_PROJECT_EDP_ORDERS"
}

Invoke-DockerCompose -Arguments @("up", "-d", "airflow-metadata-db", "source-postgres-db", "lakehouse-object-store")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "lakehouse-bucket-init")
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline.py")

if (-not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_ACCOUNT")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_USER")) -and
    -not [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_PASSWORD"))) {
    & (Join-Path $PSScriptRoot "ensure-snowflake-foundation.ps1")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/snowflake_raw_sync.py")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $sdpProjectDir, "--project-name", $sdpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_SDP_CORE_SCHEMA"), "--target-name", "dev")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $edpProjectDir, "--project-name", $edpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_EDP_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_EDP_CORE_SCHEMA"), "--target-name", "dev")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $sdpDbtProject, "build")
    Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $edpDbtProject, "build")
}
else {
    Write-Host "Skipping Snowflake-native dbt build because Snowflake credentials are not set in .env"
}
