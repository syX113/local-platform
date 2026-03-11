$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$bootstrapEnv = Join-Path $rootDir "gitlab-runner/generated/bootstrap.env"
$projectsEnv = Join-Path $rootDir "gitlab-runner/generated/projects.env"
if (-not (Test-Path -LiteralPath $bootstrapEnv) -or -not (Test-Path -LiteralPath $projectsEnv)) {
    throw "GitLab bootstrap artifacts are missing; run pwsh ./scripts/windows/bootstrap-gitlab.ps1 first"
}

Import-EnvFile -Path $bootstrapEnv -OverrideExisting
Import-EnvFile -Path $projectsEnv -OverrideExisting

if ([string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_BOOTSTRAP_PAT")) -or
    ([string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_SDP_PROJECT_ID")) -and [string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_EDP_PROJECT_ID")))) {
    throw "GitLab bootstrap token or project ids are missing"
}

$ciVariableKeys = @(
    "LOCAL_PLATFORM_PROJECT_NAME",
    "COMPOSE_PROJECT_NAME",
    "PLATFORM_DOCKER_NETWORK",
    "AIRFLOW_PORT",
    "AIRFLOW_UID",
    "AIRFLOW_ADMIN_USERNAME",
    "AIRFLOW_ADMIN_PASSWORD",
    "AIRFLOW_ADMIN_EMAIL",
    "AIRFLOW_FERNET_KEY",
    "AIRFLOW_WEBSERVER_SECRET_KEY",
    "AIRFLOW_METADATA_DB_USER",
    "AIRFLOW_METADATA_DB_PASSWORD",
    "AIRFLOW_METADATA_DB_NAME",
    "AIRFLOW_METADATA_DB_PORT",
    "SOURCE_POSTGRES_HOST",
    "SOURCE_POSTGRES_PORT",
    "SOURCE_POSTGRES_EXPOSE_PORT",
    "SOURCE_POSTGRES_DB",
    "SOURCE_POSTGRES_USER",
    "SOURCE_POSTGRES_PASSWORD",
    "SOURCE_POSTGRES_SCHEMA",
    "DLT_PIPELINE_NAME",
    "DLT_REFRESH_MODE",
    "ICEBERG_CATALOG_NAME",
    "ICEBERG_NAMESPACE",
    "ICEBERG_CATALOG_TYPE",
    "ICEBERG_SQL_URI",
    "MINIO_API_PORT",
    "MINIO_CONSOLE_PORT",
    "MINIO_ROOT_USER",
    "MINIO_ROOT_PASSWORD",
    "MINIO_REGION",
    "MINIO_BUCKET",
    "MINIO_PREFIX",
    "MINIO_ENDPOINT",
    "MINIO_PUBLIC_ENDPOINT",
    "MINIO_USE_SSL",
    "OBJECT_STORE_TYPE",
    "OBJECT_STORE_BUCKET",
    "OBJECT_STORE_ACCESS_KEY_ID",
    "OBJECT_STORE_SECRET_ACCESS_KEY",
    "OBJECT_STORE_ENDPOINT_URL",
    "OBJECT_STORE_REGION",
    "OBJECT_STORE_USE_SSL",
    "OPEN_CATALOG_URI",
    "OPEN_CATALOG_NAME",
    "OPEN_CATALOG_CLIENT_ID",
    "OPEN_CATALOG_CLIENT_SECRET",
    "OPEN_CATALOG_SCOPE",
    "OPEN_CATALOG_ACCESS_DELEGATION",
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_PASSWORD",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_SDP_DATABASE",
    "SNOWFLAKE_SDP_IN_SCHEMA",
    "SNOWFLAKE_SDP_CORE_SCHEMA",
    "SNOWFLAKE_SDP_ACC_SCHEMA",
    "SNOWFLAKE_EDP_DATABASE",
    "SNOWFLAKE_EDP_IN_SCHEMA",
    "SNOWFLAKE_EDP_CORE_SCHEMA",
    "SNOWFLAKE_EDP_ACC_SCHEMA",
    "SNOWFLAKE_CATALOG_INTEGRATION",
    "SNOWFLAKE_CLONE_SCHEMA",
    "SNOWFLAKE_LOCAL_RAW_SYNC",
    "DBT_THREADS"
)

function Sync-ProjectVariables {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectId
    )

    $baseUrl = "http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')/api/v4/projects/$ProjectId/variables"
    $headers = @{ "PRIVATE-TOKEN" = (Get-EnvValue -Name "GITLAB_BOOTSTRAP_PAT") }

    foreach ($key in $ciVariableKeys) {
        $value = Get-EnvValue -Name $key
        if ($null -eq $value -or $value -eq "") {
            continue
        }

        $existing = Invoke-GitLabWebRequest -Method "GET" -Uri "$baseUrl/$key" -Headers $headers -Raw
        $body = @{
            value     = $value
            masked    = "false"
            protected = "false"
            raw       = "true"
        }

        if ($existing.StatusCode -eq 200) {
            Invoke-GitLabWebRequest -Method "PUT" -Uri "$baseUrl/$key" -Headers $headers -Body $body | Out-Null
        }
        else {
            $body.key = $key
            Invoke-GitLabWebRequest -Method "POST" -Uri $baseUrl -Headers $headers -Body $body | Out-Null
        }
    }
}

$sdpProjectId = Get-EnvValue -Name "GITLAB_SDP_PROJECT_ID"
if (-not [string]::IsNullOrEmpty($sdpProjectId)) {
    Sync-ProjectVariables -ProjectId $sdpProjectId
    Write-Host "Synced $($ciVariableKeys.Count) GitLab CI/CD variables to SDP project $sdpProjectId"
}

$edpProjectId = Get-EnvValue -Name "GITLAB_EDP_PROJECT_ID"
if (-not [string]::IsNullOrEmpty($edpProjectId)) {
    Sync-ProjectVariables -ProjectId $edpProjectId
    Write-Host "Synced $($ciVariableKeys.Count) GitLab CI/CD variables to EDP project $edpProjectId"
}
