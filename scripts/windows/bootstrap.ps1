$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

$generatedDir = Join-Path $rootDir "gitlab-runner/generated"
if (-not (Test-Path -LiteralPath $generatedDir)) {
    New-Item -ItemType Directory -Path $generatedDir | Out-Null
}

Invoke-DockerCompose -Arguments @("build", "airflow-webserver", "dlt-extractor", "dbt-executor")
Invoke-DockerCompose -Arguments @("up", "-d", "airflow-metadata-db", "source-postgres-db", "lakehouse-object-store", "gitlab-platform")
Invoke-DockerCompose -Arguments @("up", "-d", "lakehouse-bucket-init", "airflow-init")
& (Join-Path $PSScriptRoot "load-source-sample-data.ps1")
Invoke-DockerCompose -Arguments @("up", "-d", "airflow-webserver", "airflow-scheduler")

Write-Host "stack is starting"
Write-Host "next:"
Write-Host "  1. wait for GitLab on http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')"
Write-Host "  2. run pwsh ./scripts/windows/bootstrap-gitlab.ps1 to create the SDP and EDP GitLab projects and start the GitLab runner"
& (Join-Path $PSScriptRoot "print-setup-summary.ps1")

