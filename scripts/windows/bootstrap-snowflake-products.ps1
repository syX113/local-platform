$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$requiredVars = @(
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_PASSWORD",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_SDP_DATABASE",
    "SNOWFLAKE_EDP_DATABASE"
)

foreach ($key in $requiredVars) {
    if ([string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
        throw "missing required Snowflake variable: $key"
    }
}

$sdpProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug "proj_sdp_orders" -RootDir $rootDir
$sdpDbtProject = Get-EnvValue -Name "DEV_SNOWFLAKE_SDP_DBT_PROJECT"
if ([string]::IsNullOrEmpty($sdpDbtProject)) {
    $sdpDbtProject = "DEV_DBT_PROJECT_SDP_ORDERS"
}

Write-Host "reloading deterministic source sample data"
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")

Write-Host "dropping lingering Snowflake CI clone databases"
& (Join-Path $PSScriptRoot "cleanup-snowflake-ci-clones.ps1")

Write-Host "dropping Snowflake control, SDP and EDP databases for a clean rebuild"
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
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_EDP_DATABASE"])}')
        cursor.execute(f'drop database if exists {ident(os.environ["SNOWFLAKE_SDP_DATABASE"])}')
finally:
    connection.close()

print(
    {
        "dropped_control_database": os.environ["SNOWFLAKE_CONTROL_DATABASE"],
        "dropped_sdp_database": os.environ["SNOWFLAKE_SDP_DATABASE"],
        "dropped_edp_database": os.environ["SNOWFLAKE_EDP_DATABASE"],
    }
)
'@

Invoke-DockerComposeWithStdin -InputText $dropScript -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "-")

Write-Host "recreating Snowflake foundation"
& (Join-Path $PSScriptRoot "ensure-snowflake-foundation.ps1")

Write-Host "refreshing DEV Iceberg artifacts"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/pipeline.py")

Write-Host "syncing inbound Snowflake raw tables"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dlt-extractor", "python", "/opt/platform/dlt/snowflake_raw_sync.py")

Write-Host "deploying DEV Snowflake dbt projects"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "deploy", "--project-dir", $sdpProjectDir, "--project-name", $sdpDbtProject, "--database", (Get-EnvValue -Name "SNOWFLAKE_SDP_DATABASE"), "--schema", (Get-EnvValue -Name "SNOWFLAKE_SDP_CORE_SCHEMA"), "--target-name", "dev")

Write-Host "building SDP data product in Snowflake"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "execute", "--project-name", $sdpDbtProject, "build")

Write-Host "validating zero-copy clone semantics"
Invoke-DockerCompose -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/zero_copy_clone_check.py")

Write-Host "validating rebuilt SDP row counts and undeployed EDP state"
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
        edp_project_name = os.environ["SNOWFLAKE_EDP_DBT_PROJECT"]
        if edp_project_name in dbt_projects:
            raise SystemExit(f"unexpected EDP dbt project object present after initialization: {edp_project_name}")

        for schema_name in (
            os.environ["SNOWFLAKE_EDP_IN_SCHEMA"],
            os.environ["SNOWFLAKE_EDP_CORE_SCHEMA"],
            os.environ["SNOWFLAKE_EDP_ACC_SCHEMA"],
        ):
            cursor.execute(
                f"""
                select count(*)
                from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'])}.information_schema.tables
                where table_schema = %s
                  and table_type in ('BASE TABLE', 'EXTERNAL TABLE', 'EVENT TABLE', 'MATERIALIZED VIEW')
                """,
                (schema_name,),
            )
            table_count = cursor.fetchone()[0]
            if table_count != 0:
                raise SystemExit(
                    f"unexpected EDP table-like objects in {os.environ['SNOWFLAKE_EDP_DATABASE']}.{schema_name}: {table_count}"
                )

            cursor.execute(
                f"""
                select count(*)
                from {ident(os.environ['SNOWFLAKE_EDP_DATABASE'])}.information_schema.views
                where table_schema = %s
                """,
                (schema_name,),
            )
            view_count = cursor.fetchone()[0]
            if view_count != 0:
                raise SystemExit(
                    f"unexpected EDP views in {os.environ['SNOWFLAKE_EDP_DATABASE']}.{schema_name}: {view_count}"
                )

        print("edp_dbt_project_present=False")
        print("edp_user_objects_present=False")
finally:
    connection.close()
'@

Invoke-DockerComposeWithStdin -InputText $validationScript -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "-")

Write-Host "snowflake-only bootstrap complete"
