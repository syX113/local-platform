$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("dev", "prd")]
    [string]$TargetEnv
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

switch ($TargetEnv) {
    "dev" {
        $dagId = Get-EnvValue -Name "DEV_AIRFLOW_DAG_ID"
        if ([string]::IsNullOrEmpty($dagId)) { $dagId = "DEV_local_platform_ingest" }
        $dltPipelineName = Get-EnvValue -Name "DEV_DLT_PIPELINE_NAME"
        if ([string]::IsNullOrEmpty($dltPipelineName)) { $dltPipelineName = $dagId }
        $icebergCatalogName = Get-EnvValue -Name "DEV_ICEBERG_CATALOG_NAME"
        if ([string]::IsNullOrEmpty($icebergCatalogName)) { $icebergCatalogName = "dev" }
        $icebergNamespace = Get-EnvValue -Name "DEV_ICEBERG_NAMESPACE"
        if ([string]::IsNullOrEmpty($icebergNamespace)) { $icebergNamespace = "postgres" }
        $minioPrefix = Get-EnvValue -Name "DEV_MINIO_PREFIX"
        if ([string]::IsNullOrEmpty($minioPrefix)) { $minioPrefix = "landing/dev" }
        $snowflakeSdpDatabase = Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE"
        $snowflakeEdpDatabase = Get-EnvValue -Name "SNOWFLAKE_EDP_DATABASE"
        $snowflakeSdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"
        if ([string]::IsNullOrEmpty($snowflakeSdpDbtProject)) { $snowflakeSdpDbtProject = "DEV_DBT_PROJECT_SOURCE_FINNOVA" }
        $snowflakeEdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_EDP_DBT_PROJECT"
        if ([string]::IsNullOrEmpty($snowflakeEdpDbtProject)) { $snowflakeEdpDbtProject = "DEV_DBT_PROJECT_EDP_ORDERS" }
        $snowDbtTargetName = "dev"
        $dltRunnerImage = Get-EnvValue -Name "DLT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($dltRunnerImage)) { $dltRunnerImage = Get-RuntimeImageRef -ServiceName "dlt-extractor" }
        $snowDbtRunnerImage = Get-EnvValue -Name "SNOW_DBT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($snowDbtRunnerImage)) { $snowDbtRunnerImage = Get-RuntimeImageRef -ServiceName "dbt-executor" }
        $dbtRunnerImage = Get-EnvValue -Name "DBT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($dbtRunnerImage)) { $dbtRunnerImage = $snowDbtRunnerImage }
    }
    "prd" {
        $dagId = Get-EnvValue -Name "PRD_AIRFLOW_DAG_ID"
        if ([string]::IsNullOrEmpty($dagId)) { $dagId = "PRD_local_platform_ingest" }
        $dltPipelineName = Get-EnvValue -Name "PRD_DLT_PIPELINE_NAME"
        if ([string]::IsNullOrEmpty($dltPipelineName)) { $dltPipelineName = $dagId }
        $icebergCatalogName = Get-EnvValue -Name "PRD_ICEBERG_CATALOG_NAME"
        if ([string]::IsNullOrEmpty($icebergCatalogName)) { $icebergCatalogName = "prd" }
        $icebergNamespace = Get-EnvValue -Name "PRD_ICEBERG_NAMESPACE"
        if ([string]::IsNullOrEmpty($icebergNamespace)) { $icebergNamespace = "postgres" }
        $minioPrefix = Get-EnvValue -Name "PRD_MINIO_PREFIX"
        if ([string]::IsNullOrEmpty($minioPrefix)) { $minioPrefix = "landing/prd" }
        $snowflakeSdpDatabase = Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DATABASE"
        $snowflakeEdpDatabase = Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_DATABASE"
        $snowflakeSdpDbtProject = Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DBT_PROJECT"
        if ([string]::IsNullOrEmpty($snowflakeSdpDbtProject)) { $snowflakeSdpDbtProject = "PRD_DBT_PROJECT_SOURCE_FINNOVA" }
        $snowflakeEdpDbtProject = Get-EnvValue -Name "PRD_SNOWFLAKE_EDP_DBT_PROJECT"
        if ([string]::IsNullOrEmpty($snowflakeEdpDbtProject)) { $snowflakeEdpDbtProject = "PRD_DBT_PROJECT_EDP_ORDERS" }
        $snowDbtTargetName = "prd"
        $runtimePrefix = Get-EnvValue -Name "PRD_SDP_RUNTIME_IMAGE_PREFIX"
        if ([string]::IsNullOrEmpty($runtimePrefix)) { $runtimePrefix = "local-platform-prd-sdp" }
        $dltRunnerImage = Get-EnvValue -Name "DLT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($dltRunnerImage)) { $dltRunnerImage = "$runtimePrefix/dlt-extractor`:dev" }
        $snowDbtRunnerImage = Get-EnvValue -Name "SNOW_DBT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($snowDbtRunnerImage)) { $snowDbtRunnerImage = "$runtimePrefix/dbt-executor`:dev" }
        $dbtRunnerImage = Get-EnvValue -Name "DBT_RUNNER_IMAGE"
        if ([string]::IsNullOrEmpty($dbtRunnerImage)) { $dbtRunnerImage = $snowDbtRunnerImage }
    }
}

$modulePrefix = Convert-ToSanitizedToken -Value $dagId
if ([string]::IsNullOrEmpty($modulePrefix)) {
    throw "unable to derive Airflow module prefix from $dagId"
}

$dagFilename = "$modulePrefix.py"
$supportModule = "${modulePrefix}_platform_support"
$implModule = "${modulePrefix}_pipeline_impl"
$minioBucket = Get-EnvValue -Name "MINIO_BUCKET"
if ([string]::IsNullOrEmpty($minioBucket)) {
    throw "MINIO_BUCKET must be set"
}

$objectStoreBucket = "s3://$minioBucket/$minioPrefix"
$snowflakeControlDatabase = Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE"
if ([string]::IsNullOrEmpty($snowflakeControlDatabase)) { $snowflakeControlDatabase = "LOCAL_PLATFORM_CONTROL" }
$snowflakeControlSchema = Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA"
if ([string]::IsNullOrEmpty($snowflakeControlSchema)) { $snowflakeControlSchema = "OPERATIONS" }
$snowflakeDbtStage = Get-EnvValue -Name "SNOWFLAKE_DBT_STAGE"
if ([string]::IsNullOrEmpty($snowflakeDbtStage)) { $snowflakeDbtStage = "DBT_PROJECT_STAGE" }

$tmpDir = New-Item -ItemType Directory -Path ([System.IO.Path]::GetTempPath()) -Name ("airflow-$TargetEnv-dag-" + [guid]::NewGuid().ToString("N"))
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
    dag_id=$(Convert-ToPythonStringLiteral -Value $dagId),
    description=$(Convert-ToPythonStringLiteral -Value "$($TargetEnv.ToUpperInvariant()) deployment for $dagId."),
    runtime_overrides={
        "DLT_PIPELINE_NAME": $(Convert-ToPythonStringLiteral -Value $dltPipelineName),
        "ICEBERG_CATALOG_NAME": $(Convert-ToPythonStringLiteral -Value $icebergCatalogName),
        "ICEBERG_NAMESPACE": $(Convert-ToPythonStringLiteral -Value $icebergNamespace),
        "MINIO_PREFIX": $(Convert-ToPythonStringLiteral -Value $minioPrefix),
        "OBJECT_STORE_BUCKET": $(Convert-ToPythonStringLiteral -Value $objectStoreBucket),
        "SNOWFLAKE_CONTROL_DATABASE": $(Convert-ToPythonStringLiteral -Value $snowflakeControlDatabase),
        "SNOWFLAKE_CONTROL_SCHEMA": $(Convert-ToPythonStringLiteral -Value $snowflakeControlSchema),
        "SNOWFLAKE_DBT_STAGE": $(Convert-ToPythonStringLiteral -Value $snowflakeDbtStage),
        "SNOWFLAKE_SDP_DATABASE": $(Convert-ToPythonStringLiteral -Value $snowflakeSdpDatabase),
        "SNOWFLAKE_EDP_DATABASE": $(Convert-ToPythonStringLiteral -Value $snowflakeEdpDatabase),
        "SNOWFLAKE_SDP_DBT_PROJECT": $(Convert-ToPythonStringLiteral -Value $snowflakeSdpDbtProject),
        "SNOWFLAKE_EDP_DBT_PROJECT": $(Convert-ToPythonStringLiteral -Value $snowflakeEdpDbtProject),
        "SNOW_DBT_TARGET_NAME": $(Convert-ToPythonStringLiteral -Value $snowDbtTargetName),
        "DLT_RUNNER_IMAGE": $(Convert-ToPythonStringLiteral -Value $dltRunnerImage),
        "DBT_RUNNER_IMAGE": $(Convert-ToPythonStringLiteral -Value $dbtRunnerImage),
        "SNOW_DBT_RUNNER_IMAGE": $(Convert-ToPythonStringLiteral -Value $snowDbtRunnerImage),
    },
    tags=DEFAULT_TAGS + [$(Convert-ToPythonStringLiteral -Value $TargetEnv), "deployment"],
)
"@
    Set-Content -LiteralPath $wrapperFile -Value $wrapperContent -Encoding UTF8

    $schedulerContainerId = Invoke-DockerCompose -Arguments @("ps", "-q", "airflow-scheduler") -CaptureOutput
    if ([string]::IsNullOrWhiteSpace($schedulerContainerId)) {
        throw "unable to resolve airflow-scheduler container id"
    }

    Invoke-DockerCompose -Arguments @("exec", "-T", "airflow-scheduler", "mkdir", "-p", "/opt/airflow/dags/deployed")
    & docker cp $supportFile "${schedulerContainerId}:/opt/airflow/dags/deployed/$([System.IO.Path]::GetFileName($supportFile))" | Out-Null
    & docker cp $implFile "${schedulerContainerId}:/opt/airflow/dags/deployed/$([System.IO.Path]::GetFileName($implFile))" | Out-Null
    & docker cp $wrapperFile "${schedulerContainerId}:/opt/airflow/dags/deployed/$dagFilename" | Out-Null

    $artifactDir = Join-Path $rootDir "artifacts/deploy-sdp-$TargetEnv"
    if (-not (Test-Path -LiteralPath $artifactDir)) {
        New-Item -ItemType Directory -Path $artifactDir | Out-Null
    }
    $importsLog = Join-Path $artifactDir "${TargetEnv}_airflow_imports.log"
    $dagsLog = Join-Path $artifactDir "${TargetEnv}_airflow_dags.log"

    $importOutput = Invoke-DockerCompose -Arguments @("exec", "-T", "airflow-scheduler", "airflow", "dags", "list-import-errors") -CaptureOutput
    Set-Content -LiteralPath $importsLog -Value $importOutput -Encoding UTF8

    $dagsOutput = Invoke-DockerCompose -Arguments @("exec", "-T", "airflow-scheduler", "airflow", "dags", "list", "--subdir", "/opt/airflow/dags/deployed/$dagFilename") -CaptureOutput
    Set-Content -LiteralPath $dagsLog -Value $dagsOutput -Encoding UTF8
    if ($dagsOutput -notmatch [regex]::Escape($dagId)) {
        throw "deployed $($TargetEnv.ToUpperInvariant()) Airflow DAG $dagId was not detected"
    }
}
finally {
    if (Test-Path -LiteralPath $tmpDir.FullName) {
        Remove-Item -LiteralPath $tmpDir.FullName -Recurse -Force
    }
}
