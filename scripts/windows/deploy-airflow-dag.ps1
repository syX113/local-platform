$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prd", "current")]
    [string]$TargetEnv,
    [Parameter(Mandatory = $true)]
    [ValidateSet("orders", "customers")]
    [string]$Scope,
    [string]$CurrentLabel = ""
)

. (Join-Path $PSScriptRoot "common.ps1")

function Convert-ToPythonStringLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = $Value.Replace("\", "\\").Replace("'", "\'")
    return "'$escaped'"
}

function Convert-ToSanitizedToken {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $lowered = $Value.ToLowerInvariant()
    $sanitized = [regex]::Replace($lowered, "[^a-z0-9]+", "_")
    return $sanitized.Trim("_")
}

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

function Resolve-ScopeConfig {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("dev", "prd", "current")]
        [string]$Target,
        [Parameter(Mandatory = $true)]
        [ValidateSet("orders", "customers")]
        [string]$SourceScope
    )

    $cfg = @{}
    $cfg.Scope = $SourceScope
    $cfg.ScopeTitle = $SourceScope.Substring(0,1).ToUpperInvariant() + $SourceScope.Substring(1)

    switch ($Target) {
        "dev" {
            $cfg.DagId = if ($SourceScope -eq "orders") { Get-EnvValue -Name "DEV_ORDERS_AIRFLOW_DAG_ID" } else { Get-EnvValue -Name "DEV_CUSTOMERS_AIRFLOW_DAG_ID" }
            if ([string]::IsNullOrEmpty($cfg.DagId)) {
                $cfg.DagId = if ($SourceScope -eq "orders") { "DEV_local_platform_orders_ingest" } else { "DEV_local_platform_customers_ingest" }
            }
            $cfg.DltPipelineName = if ($SourceScope -eq "orders") { Get-EnvValue -Name "DEV_SOURCE_ORDERS_DLT_PIPELINE_NAME" } else { Get-EnvValue -Name "DEV_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME" }
            if ([string]::IsNullOrEmpty($cfg.DltPipelineName)) {
                $cfg.DltPipelineName = $cfg.DagId
            }
            $cfg.IcebergCatalogName = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_ICEBERG_CATALOG_NAME"))) { "dev" } else { Get-EnvValue -Name "DEV_ICEBERG_CATALOG_NAME" }
            $cfg.IcebergNamespace = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_ICEBERG_NAMESPACE"))) { "postgres" } else { Get-EnvValue -Name "DEV_ICEBERG_NAMESPACE" }
            $cfg.MinioPrefix = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_MINIO_PREFIX"))) { "landing/dev" } else { Get-EnvValue -Name "DEV_MINIO_PREFIX" }
            $cfg.SnowflakeSdpDatabase = if ($SourceScope -eq "orders") { Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE" } else { Get-EnvValue -Name "SNOWFLAKE_SDP_CUSTOMERS_DATABASE" }
            $cfg.SnowflakeEdpDatabase = if ($SourceScope -eq "orders") { Get-EnvValue -Name "SNOWFLAKE_EDP_DATABASE" } else { Get-EnvValue -Name "SNOWFLAKE_EDP_CUSTOMERS_DATABASE" }
            $cfg.SnowflakeSdpDbtProject = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"))) { "DEV_DBT_PROJECT_SOURCE_FINNOVA" } else { Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT" }
            $cfg.SnowflakeEdpDbtProject = if ($SourceScope -eq "orders") {
                if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_DBT_PROJECT"))) { "DEV_DBT_PROJECT_EDP_ORDERS" } else { Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_DBT_PROJECT" }
            } else {
                if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT"))) { "DEV_DBT_PROJECT_EDP_CUSTOMERS" } else { Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT" }
            }
            $cfg.TargetLabel = "dev-$SourceScope"
            $cfg.SnowDbtTargetName = "dev"
        }
        "prd" {
            $cfg.DagId = if ($SourceScope -eq "orders") { Get-EnvValue -Name "PRD_ORDERS_AIRFLOW_DAG_ID" } else { Get-EnvValue -Name "PRD_CUSTOMERS_AIRFLOW_DAG_ID" }
            if ([string]::IsNullOrEmpty($cfg.DagId)) {
                $cfg.DagId = if ($SourceScope -eq "orders") { "PRD_local_platform_orders_ingest" } else { "PRD_local_platform_customers_ingest" }
            }
            $cfg.DltPipelineName = if ($SourceScope -eq "orders") { Get-EnvValue -Name "PRD_SOURCE_ORDERS_DLT_PIPELINE_NAME" } else { Get-EnvValue -Name "PRD_SOURCE_CUSTOMERS_DLT_PIPELINE_NAME" }
            if ([string]::IsNullOrEmpty($cfg.DltPipelineName)) {
                $cfg.DltPipelineName = $cfg.DagId
            }
            $cfg.IcebergCatalogName = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_ICEBERG_CATALOG_NAME"))) { "prd" } else { Get-EnvValue -Name "PRD_ICEBERG_CATALOG_NAME" }
            $cfg.IcebergNamespace = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_ICEBERG_NAMESPACE"))) { "postgres" } else { Get-EnvValue -Name "PRD_ICEBERG_NAMESPACE" }
            $cfg.MinioPrefix = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_MINIO_PREFIX"))) { "landing/prd" } else { Get-EnvValue -Name "PRD_MINIO_PREFIX" }
            $cfg.SnowflakeSdpDatabase = if ($SourceScope -eq "orders") { Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DATABASE" } else { Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE" }
            $cfg.SnowflakeEdpDatabase = if ($SourceScope -eq "orders") { Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_DATABASE" } else { Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE" }
            $cfg.SnowflakeSdpDbtProject = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DBT_PROJECT"))) { "PRD_DBT_PROJECT_SOURCE_FINNOVA" } else { Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DBT_PROJECT" }
            $cfg.SnowflakeEdpDbtProject = if ($SourceScope -eq "orders") {
                if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_DBT_PROJECT"))) { "PRD_DBT_PROJECT_EDP_ORDERS" } else { Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_DBT_PROJECT" }
            } else {
                if ([string]::IsNullOrEmpty((Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT"))) { "PRD_DBT_PROJECT_EDP_CUSTOMERS" } else { Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_CUSTOMERS_DBT_PROJECT" }
            }
            $cfg.TargetLabel = "prd-$SourceScope"
            $cfg.SnowDbtTargetName = "prd"
        }
        "current" {
            $cfg.DagId = Get-EnvValue -Name "AIRFLOW_ACTIVE_DAG_ID"
            if ([string]::IsNullOrEmpty($cfg.DagId)) {
                throw "AIRFLOW_ACTIVE_DAG_ID must be set for target 'current'"
            }
            $cfg.DltPipelineName = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "DLT_PIPELINE_NAME"))) { $cfg.DagId } else { Get-EnvValue -Name "DLT_PIPELINE_NAME" }
            $cfg.IcebergCatalogName = Get-EnvValue -Name "ICEBERG_CATALOG_NAME"
            $cfg.IcebergNamespace = Get-EnvValue -Name "ICEBERG_NAMESPACE"
            $cfg.MinioPrefix = Get-EnvValue -Name "MINIO_PREFIX"
            $cfg.SnowflakeSdpDatabase = Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE"
            $cfg.SnowflakeEdpDatabase = Get-EnvValue -Name "SNOWFLAKE_EDP_DATABASE"
            $cfg.SnowflakeSdpDbtProject = Get-EnvValue -Name "SNOWFLAKE_SDP_DBT_PROJECT"
            $cfg.SnowflakeEdpDbtProject = Get-EnvValue -Name "SNOWFLAKE_EDP_DBT_PROJECT"
            $cfg.TargetLabel = if ([string]::IsNullOrEmpty($CurrentLabel)) { "current-$SourceScope" } else { $CurrentLabel }
            $cfg.SnowDbtTargetName = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "SNOW_DBT_TARGET_NAME"))) { "dev" } else { Get-EnvValue -Name "SNOW_DBT_TARGET_NAME" }
        }
    }

    return $cfg
}

$cfg = Resolve-ScopeConfig -Target $TargetEnv -SourceScope $Scope
$modulePrefix = Convert-ToSanitizedToken -Value $cfg.DagId
if ([string]::IsNullOrEmpty($modulePrefix)) {
    throw "unable to derive Airflow module prefix from $($cfg.DagId)"
}

$dagFilename = "$modulePrefix.py"
$supportModule = "${modulePrefix}_platform_support"
$implModule = "${modulePrefix}_pipeline_impl"
$minioBucket = Get-EnvValue -Name "MINIO_BUCKET"
if ([string]::IsNullOrEmpty($minioBucket)) {
    throw "MINIO_BUCKET must be set"
}

$objectStoreBucket = "s3://$minioBucket/$($cfg.MinioPrefix)"
$snowflakeControlDatabase = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE"))) { "LOCAL_PLATFORM_CONTROL" } else { Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE" }
$snowflakeControlSchema = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA"))) { "OPERATIONS" } else { Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA" }
$snowflakeDbtStage = if ([string]::IsNullOrEmpty((Get-EnvValue -Name "SNOWFLAKE_DBT_STAGE"))) { "DBT_PROJECT_STAGE" } else { Get-EnvValue -Name "SNOWFLAKE_DBT_STAGE" }
$targetLabelUpper = $cfg.TargetLabel.ToUpperInvariant()

$tmpDir = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath()) -Name ("airflow-$TargetEnv-$Scope-" + [guid]::NewGuid().ToString("N"))
try {
    $supportFile = Join-Path $tmpDir.FullName "$supportModule.py"
    $implFile = Join-Path $tmpDir.FullName "$implModule.py"
    $wrapperFile = Join-Path $tmpDir.FullName $dagFilename

    Copy-Item -LiteralPath (Join-Path $rootDir "airflow/dags/platform_support.py") -Destination $supportFile

    $pipelineSource = Get-Content -LiteralPath (Join-Path $rootDir "airflow/dags/local_platform_pipeline.py") -Raw
    $pipelineSource = $pipelineSource.Replace("from platform_support import ", "from $supportModule import ")
    $implContent = @"
from pathlib import Path
import sys

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

$pipelineSource
"@
    Set-Content -LiteralPath $implFile -Value $implContent -Encoding UTF8

    $wrapperContent = @"
from pathlib import Path
import sys
from airflow import DAG  # noqa: F401

_THIS_DIR = Path(__file__).resolve().parent
if str(_THIS_DIR) not in sys.path:
    sys.path.insert(0, str(_THIS_DIR))

from $implModule import DEFAULT_TAGS, build_ingest_dag

dag = build_ingest_dag(
    dag_id=$(Convert-ToPythonStringLiteral -Value $cfg.DagId),
    description=$(Convert-ToPythonStringLiteral -Value "$targetLabelUpper deployment for $($cfg.DagId)."),
    runtime_overrides={
        "DLT_PIPELINE_NAME": $(Convert-ToPythonStringLiteral -Value $cfg.DltPipelineName),
        "ICEBERG_CATALOG_NAME": $(Convert-ToPythonStringLiteral -Value $cfg.IcebergCatalogName),
        "ICEBERG_NAMESPACE": $(Convert-ToPythonStringLiteral -Value $cfg.IcebergNamespace),
        "MINIO_PREFIX": $(Convert-ToPythonStringLiteral -Value $cfg.MinioPrefix),
        "OBJECT_STORE_BUCKET": $(Convert-ToPythonStringLiteral -Value $objectStoreBucket),
        "SNOWFLAKE_CONTROL_DATABASE": $(Convert-ToPythonStringLiteral -Value $snowflakeControlDatabase),
        "SNOWFLAKE_CONTROL_SCHEMA": $(Convert-ToPythonStringLiteral -Value $snowflakeControlSchema),
        "SNOWFLAKE_DBT_STAGE": $(Convert-ToPythonStringLiteral -Value $snowflakeDbtStage),
        "DLT_SCRIPT_PATH": $(Convert-ToPythonStringLiteral -Value "/opt/platform/dlt/pipeline_$Scope.py"),
        "SNOWFLAKE_RAW_SYNC_SCOPE": $(Convert-ToPythonStringLiteral -Value $Scope),
        "SNOWFLAKE_SDP_DBT_SELECT": $(Convert-ToPythonStringLiteral -Value $Scope),
        "SNOWFLAKE_SDP_DATABASE": $(Convert-ToPythonStringLiteral -Value $cfg.SnowflakeSdpDatabase),
        "SNOWFLAKE_EDP_DATABASE": $(Convert-ToPythonStringLiteral -Value $cfg.SnowflakeEdpDatabase),
        "SNOWFLAKE_SDP_DBT_PROJECT": $(Convert-ToPythonStringLiteral -Value $cfg.SnowflakeSdpDbtProject),
        "SNOWFLAKE_EDP_DBT_PROJECT": $(Convert-ToPythonStringLiteral -Value $cfg.SnowflakeEdpDbtProject),
        "SNOWFLAKE_LOCAL_RAW_SYNC": $(Convert-ToPythonStringLiteral -Value (Get-EnvValue -Name "SNOWFLAKE_LOCAL_RAW_SYNC")),
        "SNOW_DBT_TARGET_NAME": $(Convert-ToPythonStringLiteral -Value $cfg.SnowDbtTargetName),
    },
    tags=DEFAULT_TAGS + [$(Convert-ToPythonStringLiteral -Value $cfg.TargetLabel), $(Convert-ToPythonStringLiteral -Value $Scope), "deployment"],
)
"@
    Set-Content -LiteralPath $wrapperFile -Value $wrapperContent -Encoding UTF8

    $schedulerContainerId = Invoke-DockerCompose -Arguments @("ps", "-q", "airflow-scheduler") -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($schedulerContainerId)) {
        throw "unable to resolve airflow-scheduler container id"
    }

    Write-Host "airflow-scheduler container is running; deployed DAG files are available via the bind-mounted $hostDeployedDir"

    $artifactDir = Join-Path $rootDir "artifacts/deploy-sdp-$($cfg.TargetLabel)"
    if (-not (Test-Path -LiteralPath $artifactDir)) {
        New-Item -ItemType Directory -Path $artifactDir | Out-Null
    }
    $importsLog = Join-Path $artifactDir "$($cfg.TargetLabel)_airflow_imports.log"
    $dagsLog = Join-Path $artifactDir "$($cfg.TargetLabel)_airflow_dags.log"

    $importOutput = Invoke-DockerCompose -Arguments @("exec", "-T", "airflow-scheduler", "airflow", "dags", "list-import-errors") -CaptureOutput
    Set-Content -LiteralPath $importsLog -Value $importOutput -Encoding UTF8

    $dagsOutput = Invoke-DockerCompose -Arguments @("exec", "-T", "airflow-scheduler", "airflow", "dags", "list", "--subdir", "/opt/airflow/dags/deployed/$dagFilename") -CaptureOutput
    Set-Content -LiteralPath $dagsLog -Value $dagsOutput -Encoding UTF8
    if ($dagsOutput -notmatch [regex]::Escape($cfg.DagId)) {
        throw "deployed $targetLabelUpper Airflow DAG $($cfg.DagId) was not detected"
    }
}
finally {
    if (Test-Path -LiteralPath $tmpDir.FullName) {
        Remove-Item -LiteralPath $tmpDir.FullName -Recurse -Force
    }
}
