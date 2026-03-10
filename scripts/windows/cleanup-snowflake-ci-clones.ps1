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
    "SNOWFLAKE_WAREHOUSE"
)

foreach ($key in $requiredVars) {
    if ([string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
        Write-Host "skipping Snowflake CI clone cleanup because $key is not set"
        exit 0
    }
}

$dbtExecutorImage = Get-RuntimeImageRef -ServiceName "dbt-executor"
& docker image inspect $dbtExecutorImage *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "skipping Snowflake CI clone cleanup because $dbtExecutorImage is not available yet"
    exit 0
}

Invoke-DockerCompose -Arguments @(
    "run", "--rm", "--no-deps",
    "-e", "SNOWFLAKE_ACCOUNT=$(Get-EnvValue -Name 'SNOWFLAKE_ACCOUNT')",
    "-e", "SNOWFLAKE_USER=$(Get-EnvValue -Name 'SNOWFLAKE_USER')",
    "-e", "SNOWFLAKE_PASSWORD=$(Get-EnvValue -Name 'SNOWFLAKE_PASSWORD')",
    "-e", "SNOWFLAKE_ROLE=$(Get-EnvValue -Name 'SNOWFLAKE_ROLE')",
    "-e", "SNOWFLAKE_WAREHOUSE=$(Get-EnvValue -Name 'SNOWFLAKE_WAREHOUSE')",
    "dbt-executor",
    "python", "/opt/platform/dbt/scripts/manage_ci_clones.py", "purge-ci"
)

Invoke-DockerCompose -Arguments @(
    "run", "--rm", "--no-deps",
    "dbt-executor",
    "python", "/opt/platform/dbt/scripts/snow_dbt_cli.py", "purge"
)
