$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$baseSdpOrdersDatabase = Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE"
$baseSdpCustomersDatabase = Get-EnvValue -Name "SNOWFLAKE_SDP_CUSTOMERS_DATABASE"

function Set-RuntimeTarget {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("dev", "prd")]
        [string]$Target
    )

    switch ($Target) {
        "dev" {
            Set-EnvValue -Name "SNOWFLAKE_SDP_DATABASE" -Value $baseSdpOrdersDatabase
            Set-EnvValue -Name "SNOWFLAKE_SDP_CUSTOMERS_DATABASE" -Value $baseSdpCustomersDatabase
            Set-EnvValue -Name "SNOWFLAKE_SDP_DBT_PROJECT" -Value (Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT")
            Set-EnvValue -Name "SNOW_DBT_TARGET_NAME" -Value "dev"
            Set-EnvValue -Name "DLT_PIPELINE_NAME" -Value (Get-EnvValue -Name "DEV_DLT_PIPELINE_NAME")
            Set-EnvValue -Name "ICEBERG_CATALOG_NAME" -Value (Get-EnvValue -Name "DEV_ICEBERG_CATALOG_NAME")
            Set-EnvValue -Name "ICEBERG_NAMESPACE" -Value (Get-EnvValue -Name "DEV_ICEBERG_NAMESPACE")
            Set-EnvValue -Name "MINIO_PREFIX" -Value (Get-EnvValue -Name "DEV_MINIO_PREFIX")
            Set-EnvValue -Name "OBJECT_STORE_BUCKET" -Value "s3://$(Get-EnvValue -Name 'MINIO_BUCKET')/$(Get-EnvValue -Name 'DEV_MINIO_PREFIX')"
        }
        "prd" {
            Set-EnvValue -Name "SNOWFLAKE_SDP_DATABASE" -Value (Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DATABASE")
            Set-EnvValue -Name "SNOWFLAKE_SDP_CUSTOMERS_DATABASE" -Value (Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE")
            Set-EnvValue -Name "SNOWFLAKE_SDP_DBT_PROJECT" -Value (Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DBT_PROJECT")
            Set-EnvValue -Name "SNOW_DBT_TARGET_NAME" -Value "prd"
            Set-EnvValue -Name "DLT_PIPELINE_NAME" -Value (Get-EnvValue -Name "PRD_DLT_PIPELINE_NAME")
            Set-EnvValue -Name "ICEBERG_CATALOG_NAME" -Value (Get-EnvValue -Name "PRD_ICEBERG_CATALOG_NAME")
            Set-EnvValue -Name "ICEBERG_NAMESPACE" -Value (Get-EnvValue -Name "PRD_ICEBERG_NAMESPACE")
            Set-EnvValue -Name "MINIO_PREFIX" -Value (Get-EnvValue -Name "PRD_MINIO_PREFIX")
            Set-EnvValue -Name "OBJECT_STORE_BUCKET" -Value "s3://$(Get-EnvValue -Name 'MINIO_BUCKET')/$(Get-EnvValue -Name 'PRD_MINIO_PREFIX')"
        }
    }
}

$requiredVars = @(
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_PASSWORD",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_SDP_DATABASE",
    "SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
    "PRD_SNOWFLAKE_SDP_DATABASE",
    "PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE",
    "SNOWFLAKE_EDP_DATABASE",
    "SNOWFLAKE_EDP_CUSTOMERS_DATABASE",
    "PRD_SNOWFLAKE_EDP_DATABASE",
    "PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"
)

foreach ($key in $requiredVars) {
    if ([string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
        throw "missing required Snowflake variable: $key"
    }
}

$sdpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_source_finnova" -RootDir $rootDir
$sdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($sdpDbtProject)) {
    $sdpDbtProject = "DEV_DBT_PROJECT_SOURCE_FINNOVA"
}

Write-Host "reloading deterministic source sample data"
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")

Write-Host "dropping lingering Snowflake CI clone databases"
& (Join-Path $PSScriptRoot "cleanup-snowflake-ci-clones.ps1")

Write-Host "dropping Snowflake control and all product databases for a clean rebuild"
$dropScript = @'
import os
import snowflake.connector

def ident(name: str) -> str:
    return f'"{name}"'

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    autocommit=True,
)

try:
    with connection.cursor() as cursor:
        cursor.execute(f'use role {ident(os.environ["SNOWFLAKE_ROLE"])}')
        cursor.execute(f'use warehouse {ident(os.environ["SNOWFLAKE_WAREHOUSE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_CONTROL_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["PRD_SNOWFLAKE_SDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_CUSTOMERS_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_DATABASE"])}')
finally:
    connection.close()

print(
    {
        "dropped_control_database": os.environ["SNOWFLAKE_CONTROL_DATABASE"],
        "dropped_sdp_database": os.environ["SNOWFLAKE_SDP_DATABASE"],
        "dropped_sdp_customers_database": os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
        "dropped_edp_database": os.environ["SNOWFLAKE_EDP_DATABASE"],
        "dropped_edp_customers_database": os.environ["SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
        "dropped_prd_sdp_database": os.environ["PRD_SNOWFLAKE_SDP_DATABASE"],
        "dropped_prd_sdp_customers_database": os.environ["PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE"],
        "dropped_prd_edp_database": os.environ["PRD_SNOWFLAKE_EDP_DATABASE"],
        "dropped_prd_edp_customers_database": os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"],
    }
)
'@

Invoke-DockerComposeWithStdin -InputText $dropScript -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "-")

Write-Host "recreating Snowflake foundation"
& (Join-Path $PSScriptRoot "ensure-snowflake-foundation.ps1")

Set-RuntimeTarget -Target "dev"

Write-Host "refreshing DEV Iceberg artifacts"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_orders.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_customers.py")

Write-Host "syncing inbound Snowflake raw tables"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=orders python /opt/platform/dlt/snowflake_raw_sync.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=customers python /opt/platform/dlt/snowflake_raw_sync.py")

Write-Host "deploying DEV Snowflake dbt projects"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $sdpProjectDir, "--project-name", $sdpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA"), "--target-name", "dev")

Write-Host "building SDP data product in Snowflake"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $sdpDbtProject, "build")

Write-Host "deploying PRD Airflow DAG and PRD SDP objects"
& (Join-Path $PSScriptRoot "deploy-airflow-dag.ps1") "prd" "orders" | Out-Null
& (Join-Path $PSScriptRoot "deploy-airflow-dag.ps1") "prd" "customers" | Out-Null
Set-RuntimeTarget -Target "prd"
$prdSdpDbtProject = Get-EnvValue -Name "PRD_SNOWFLAKE_SDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($prdSdpDbtProject)) {
    $prdSdpDbtProject = "PRD_DBT_PROJECT_SOURCE_FINNOVA"
}
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_orders.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline_customers.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=orders python /opt/platform/dlt/snowflake_raw_sync.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "bash", "-lc", "RAW_SYNC_SCOPE=customers python /opt/platform/dlt/snowflake_raw_sync.py")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $sdpProjectDir, "--project-name", $prdSdpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_CONTROL_SCHEMA"), "--target-name", "prd")
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $prdSdpDbtProject, "build")

Write-Host "publishing dbt loom manifests for downstream EDP projects"
Publish-SourceLoomManifests

Write-Host "validating zero-copy clone semantics"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/zero_copy_clone_check.py")

Set-RuntimeTarget -Target "dev"

Write-Host "validating rebuilt DEV and PRD source row counts and undeployed EDP state"
$validationScript = @'
import os
import snowflake.connector

def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)

queries = {
    "sdp_ext_raw_orders": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDERS_RAW')}",
        30,
    ),
    "sdp_ext_raw_order_items": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_ORDER_ITEMS_RAW')}",
        60,
    ),
    "sdp_core_orders_clean": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_CORE_SCHEMA'], 'T_ORDERS_CLEAN')}",
        30,
    ),
    "sdp_access_orders_customer_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_ORDERS_CUSTOMER_GRAIN')}",
        12,
    ),
    "sdp_ext_customers_raw": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_IN_SCHEMA'], 'EXT_CUSTOMERS_RAW')}",
        12,
    ),
    "sdp_access_customers_entity_grain": (
        f"select count(*) from {ident(os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE'], os.environ['SNOWFLAKE_SDP_ACC_SCHEMA'], 'T_CUSTOMERS_ENTITY_GRAIN')}",
        12,
    ),
}

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        for name, (sql, expected) in queries.items():
            cursor.execute(sql)
            actual = cursor.fetchone()[0]
            if actual != expected:
                raise SystemExit(f"expected {expected} rows for {name}, found {actual}")
            print(f"{name}={actual}")

        cursor.execute(
            f"show dbt projects in schema {ident(os.environ['SNOWFLAKE_CONTROL_DATABASE'], os.environ['SNOWFLAKE_CONTROL_SCHEMA'])}"
        )
        cursor.execute('select "name" from table(result_scan(last_query_id()))')
        dbt_projects = {row[0] for row in cursor.fetchall()}
        sdp_project_name = os.environ["SNOWFLAKE_SDP_DBT_PROJECT"]
        edp_project_name = os.environ["SNOWFLAKE_EDP_DBT_PROJECT"]
        prd_sdp_project_name = os.environ["PRD_SNOWFLAKE_SDP_DBT_PROJECT"]
        prd_edp_project_name = os.environ["PRD_SNOWFLAKE_EDP_DBT_PROJECT"]
        if sdp_project_name not in dbt_projects:
            raise SystemExit(f"expected SDP dbt project object to exist after initialization: {sdp_project_name}")
        if prd_sdp_project_name not in dbt_projects:
            raise SystemExit(f"expected PRD SDP dbt project object to exist after initialization: {prd_sdp_project_name}")
        if edp_project_name in dbt_projects:
            raise SystemExit(f"unexpected EDP dbt project object present after initialization: {edp_project_name}")
        if prd_edp_project_name in dbt_projects:
            raise SystemExit(f"unexpected PRD EDP dbt project object present after initialization: {prd_edp_project_name}")

        cursor.execute("show databases")
        databases = {row[1] for row in cursor.fetchall()}
        if os.environ["SNOWFLAKE_SDP_DATABASE"] not in databases:
            raise SystemExit(f"expected SDP database to exist after initialization: {os.environ['SNOWFLAKE_SDP_DATABASE']}")
        if os.environ["SNOWFLAKE_SDP_CUSTOMERS_DATABASE"] not in databases:
            raise SystemExit(f"expected SDP customers database to exist after initialization: {os.environ['SNOWFLAKE_SDP_CUSTOMERS_DATABASE']}")
        if os.environ["PRD_SNOWFLAKE_SDP_DATABASE"] not in databases:
            raise SystemExit(f"expected PRD SDP database to exist after initialization: {os.environ['PRD_SNOWFLAKE_SDP_DATABASE']}")
        if os.environ["PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE"] not in databases:
            raise SystemExit(f"expected PRD SDP customers database to exist after initialization: {os.environ['PRD_SNOWFLAKE_SDP_CUSTOMERS_DATABASE']}")
        if os.environ["SNOWFLAKE_EDP_DATABASE"] in databases:
            raise SystemExit(f"unexpected EDP database present after initialization: {os.environ['SNOWFLAKE_EDP_DATABASE']}")
        if os.environ["SNOWFLAKE_EDP_CUSTOMERS_DATABASE"] in databases:
            raise SystemExit(f"unexpected EDP customers database present after initialization: {os.environ['SNOWFLAKE_EDP_CUSTOMERS_DATABASE']}")
        if os.environ["PRD_SNOWFLAKE_EDP_DATABASE"] in databases:
            raise SystemExit(f"unexpected PRD EDP database present after initialization: {os.environ['PRD_SNOWFLAKE_EDP_DATABASE']}")
        if os.environ["PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE"] in databases:
            raise SystemExit(f"unexpected PRD EDP customers database present after initialization: {os.environ['PRD_SNOWFLAKE_EDP_CUSTOMERS_DATABASE']}")

        print("sdp_deployed=True")
        print("sdp_customers_deployed=True")
        print("prd_sdp_deployed=True")
        print("prd_sdp_customers_deployed=True")
        print("edp_deployed=False")
        print("edp_customers_deployed=False")
        print("prd_deployed=False")
        print("prd_edp_customers_deployed=False")
finally:
    connection.close()
'@

Invoke-DockerComposeWithStdin -InputText $validationScript -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "-")

Write-Host "snowflake-only bootstrap complete"
