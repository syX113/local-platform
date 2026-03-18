$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$snowflakeHostRoot = Join-Path $rootDir "snowflake"
$snowflakeContainerRoot = "/opt/platform/snowflake"
if (-not (Test-Path -LiteralPath $snowflakeHostRoot) -and (Test-Path -LiteralPath (Join-Path $rootDir "ci/snowflake"))) {
    $snowflakeHostRoot = Join-Path $rootDir "ci/snowflake"
    $snowflakeContainerRoot = "/opt/platform/ci/snowflake"
}

$requiredVars = @(
    "SNOWFLAKE_ACCOUNT",
    "SNOWFLAKE_USER",
    "SNOWFLAKE_PASSWORD",
    "SNOWFLAKE_ROLE",
    "SNOWFLAKE_WAREHOUSE",
    "SNOWFLAKE_CONTROL_DATABASE",
    "SNOWFLAKE_CONTROL_SCHEMA",
    "SNOWFLAKE_DBT_STAGE"
)

foreach ($key in $requiredVars) {
    if ([string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
        throw "missing required Snowflake variable: $key"
    }
}

$sqlFiles = @(
    "$snowflakeContainerRoot/sql/01_snowflake_foundation.sql.tpl"
)

$productsDir = Join-Path $snowflakeHostRoot "sql/products"
if (Test-Path -LiteralPath $productsDir) {
    foreach ($sqlFile in Get-ChildItem -LiteralPath $productsDir -File -Filter "*.sql.tpl" | Sort-Object Name) {
        $sqlFiles += "$snowflakeContainerRoot/sql/products/$($sqlFile.Name)"
    }
}

$openCatalogKeys = @(
    "OPEN_CATALOG_URI",
    "OPEN_CATALOG_NAME",
    "OPEN_CATALOG_CLIENT_ID",
    "OPEN_CATALOG_CLIENT_SECRET"
)
$openCatalogReady = $true
foreach ($key in $openCatalogKeys) {
    if ([string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
        $openCatalogReady = $false
        break
    }
}

if ($openCatalogReady) {
    $integrationFile = Join-Path $snowflakeHostRoot "sql/02_open_catalog_integration.sql.tpl"
    $linkedDbFile = Join-Path $snowflakeHostRoot "sql/03_catalog_linked_database.sql.tpl"
    if ((Test-Path -LiteralPath $integrationFile) -and (Test-Path -LiteralPath $linkedDbFile)) {
        $sqlFiles += @(
            "$snowflakeContainerRoot/sql/02_open_catalog_integration.sql.tpl",
            "$snowflakeContainerRoot/sql/03_catalog_linked_database.sql.tpl"
        )
    }
}
else {
    Write-Host "Skipping Open Catalog foundation because OPEN_CATALOG_* variables are incomplete"
}

$arguments = @("run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/apply_sql.py")
$arguments += $sqlFiles
Invoke-DockerCompose -Arguments $arguments

$verificationScript = @'
import os
import snowflake.connector

def ident(*parts: str) -> str:
    return ".".join(f'"{part}"' for part in parts)

control_database = os.environ["SNOWFLAKE_CONTROL_DATABASE"]
control_schema = os.environ["SNOWFLAKE_CONTROL_SCHEMA"]
control_stage = os.environ["SNOWFLAKE_DBT_STAGE"]

connection = snowflake.connector.connect(
    account=os.environ["SNOWFLAKE_ACCOUNT"],
    user=os.environ["SNOWFLAKE_USER"],
    password=os.environ["SNOWFLAKE_PASSWORD"],
    role=os.environ["SNOWFLAKE_ROLE"],
    warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
)

try:
    with connection.cursor() as cursor:
        cursor.execute(f"show databases like '{control_database}'")
        if not cursor.fetchall():
            raise SystemExit(f"missing Snowflake control database: {control_database}")

        cursor.execute(f"show schemas like '{control_schema}' in database {ident(control_database)}")
        if not cursor.fetchall():
            raise SystemExit(
                f"missing Snowflake control schema: {control_database}.{control_schema}"
            )

        cursor.execute(
            f"show stages like '{control_stage}' in schema {ident(control_database, control_schema)}"
        )
        if not cursor.fetchall():
            raise SystemExit(
                f"missing Snowflake dbt stage: {control_database}.{control_schema}.{control_stage}"
            )
finally:
    connection.close()

print(
    {
        "control_database": control_database,
        "control_schema": control_schema,
        "control_stage": control_stage,
    }
)
'@

Invoke-DockerComposeWithStdin -InputText $verificationScript -Arguments @("run", "--rm", "--no-deps", "dbt-executor", "python", "-")
