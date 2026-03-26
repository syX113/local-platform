$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$bootstrapEnv = Join-Path $rootDir "gitlab-runner/generated/bootstrap.env"
$projectsEnv = Join-Path $rootDir "gitlab-runner/generated/projects.env"
if (Test-Path -LiteralPath $bootstrapEnv) {
    Import-EnvFile -Path $bootstrapEnv -OverrideExisting
}
if (Test-Path -LiteralPath $projectsEnv) {
    Import-EnvFile -Path $projectsEnv -OverrideExisting
}

$gitlabHttpUrl = "http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')"
$airflowUrl = "http://localhost:$(Get-EnvValue -Name 'AIRFLOW_PORT')"
$minioConsoleUrl = "http://localhost:$(Get-EnvValue -Name 'MINIO_CONSOLE_PORT')"
$minioApiUrl = "http://localhost:$(Get-EnvValue -Name 'MINIO_API_PORT')"

$sdpProjectPath = Get-EnvValue -Name "GITLAB_SDP_PROJECT_PATH"
$edpProjectPath = Get-EnvValue -Name "GITLAB_EDP_PROJECT_PATH"
$edpCustomersProjectPath = Get-EnvValue -Name "GITLAB_EDP_CUSTOMERS_PROJECT_PATH"

$snowflakeStatus = "configured"
if ([string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_ACCOUNT")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_USER")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_PASSWORD"))) {
    $snowflakeStatus = "missing credentials"
}

$openCatalogStatus = "configured"
if ([string]::IsNullOrEmpty((Get-EnvValue -Name "OPEN_CATALOG_URI")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "OPEN_CATALOG_NAME")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "OPEN_CATALOG_CLIENT_ID")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "OPEN_CATALOG_CLIENT_SECRET"))) {
    $openCatalogStatus = "missing configuration"
}

Write-Host ""
Write-Host "== Local Platform Access Summary =="
Write-Host ""
Write-Host "Repository"
Write-Host "  Root: $rootDir"
Write-Host "  Env file: $rootDir/.env"
Write-Host ""
Write-Host "Web URLs"
Write-Host "  GitLab UI: $gitlabHttpUrl"
Write-Host "  GitLab SDP project: $gitlabHttpUrl/root/$sdpProjectPath"
Write-Host "  GitLab domain transactions project: $gitlabHttpUrl/root/$edpProjectPath"
Write-Host "  GitLab domain customer project: $gitlabHttpUrl/root/$edpCustomersProjectPath"
Write-Host "  Airflow UI: $airflowUrl"
Write-Host "  MinIO Console: $minioConsoleUrl"
Write-Host "  MinIO API: $minioApiUrl"
Write-Host ""
Write-Host "Core Credentials"
Write-Host "  GitLab root email: $(Get-EnvValue -Name 'GITLAB_ROOT_EMAIL')"
Write-Host "  GitLab root password: $(Get-EnvValue -Name 'GITLAB_ROOT_PASSWORD')"
Write-Host "  Airflow admin username: $(Get-EnvValue -Name 'AIRFLOW_ADMIN_USERNAME')"
Write-Host "  Airflow admin password: $(Get-EnvValue -Name 'AIRFLOW_ADMIN_PASSWORD')"
Write-Host "  MinIO access key: $(Get-EnvValue -Name 'MINIO_ROOT_USER')"
Write-Host "  MinIO secret key: $(Get-EnvValue -Name 'MINIO_ROOT_PASSWORD')"
Write-Host ""
Write-Host "Storage And Data Targets"
Write-Host "  Object store URI: $(Get-EnvValue -Name 'OBJECT_STORE_BUCKET')"
Write-Host "  Iceberg catalog: $(Get-EnvValue -Name 'ICEBERG_CATALOG_NAME')"
Write-Host "  Iceberg namespace: $(Get-EnvValue -Name 'ICEBERG_NAMESPACE')"
Write-Host "  Snowflake SDP database: $(Get-EnvValue -Name 'SNOWFLAKE_SDP_DATABASE')"
Write-Host "  Snowflake SDP customers database: $(Get-EnvValue -Name 'SNOWFLAKE_SDP_CUSTOMERS_DATABASE')"
Write-Host "  Snowflake EDP orders database target: $(Get-EnvValue -Name 'SNOWFLAKE_EDP_DATABASE') (not materialized after initialization; branch/MR CI uses isolated suffixed databases)"
Write-Host "  Snowflake EDP customers database target: $(Get-EnvValue -Name 'SNOWFLAKE_EDP_CUSTOMERS_DATABASE') (deployed during initialization)"
Write-Host "  Snowflake PRD SDP database: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_SDP_DATABASE')"
Write-Host "  Snowflake PRD SDP customers database: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE')"
Write-Host "  Snowflake PRD EDP orders database target: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_EDP_DATABASE') (not materialized after initialization; branch/MR CI uses isolated suffixed databases)"
Write-Host "  Snowflake PRD EDP customers database target: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE') (deployed during initialization)"
Write-Host "  DEV source dbt project: $(Get-EnvValue -Name 'DEV_SNOWFLAKE_SDP_DBT_PROJECT')"
Write-Host "  DEV domain transactions dbt project: $(Get-EnvValue -Name 'DEV_SNOWFLAKE_EDP_DBT_PROJECT') (deployed during initialization; executes into isolated branch/MR databases until CD deploy)"
Write-Host "  DEV domain customer dbt project: $(Get-EnvValue -Name 'DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT') (deployed during initialization)"
Write-Host "  PRD source dbt project: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_SDP_DBT_PROJECT')"
Write-Host "  PRD domain transactions dbt project: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_EDP_DBT_PROJECT') (deployed during initialization; PRD database is created only after PRD CD deploy)"
Write-Host "  PRD domain customer dbt project: $(Get-EnvValue -Name 'PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT') (deployed during initialization)"
Write-Host "  Snowflake warehouse: $(Get-EnvValue -Name 'SNOWFLAKE_WAREHOUSE')"
Write-Host ""
Write-Host "Snowflake And Open Catalog Status"
Write-Host "  Snowflake status: $snowflakeStatus"
Write-Host "  Snowflake account: $(Get-EnvValue -Name 'SNOWFLAKE_ACCOUNT')"
Write-Host "  Snowflake user: $(Get-EnvValue -Name 'SNOWFLAKE_USER')"
Write-Host "  Open Catalog status: $openCatalogStatus"
Write-Host "  Open Catalog URI: $(Get-EnvValue -Name 'OPEN_CATALOG_URI')"
Write-Host ""
Write-Host "Useful Commands"
Write-Host "  Reset local platform (Unix/macOS): ./scripts/reset-platform.sh"
Write-Host "  Reset local platform (Windows): pwsh ./scripts/windows/reset-platform.ps1"
Write-Host "  Bootstrap local platform (Unix/macOS): ./scripts/bootstrap.sh"
Write-Host "  Bootstrap local platform (Windows): pwsh ./scripts/windows/bootstrap.ps1"
Write-Host "  Bootstrap GitLab (Unix/macOS): ./scripts/bootstrap-gitlab.sh"
Write-Host "  Bootstrap GitLab (Windows): pwsh ./scripts/windows/bootstrap-gitlab.ps1"
Write-Host "  Snowflake-only rebuild (Unix/macOS): ./scripts/bootstrap-snowflake-products.sh"
Write-Host "  Snowflake-only rebuild (Windows): pwsh ./scripts/windows/bootstrap-snowflake-products.ps1"
Write-Host ""
