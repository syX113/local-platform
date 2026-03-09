$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

try {
    & (Join-Path $PSScriptRoot "cleanup-snowflake-ci-clones.ps1")
}
catch {
    Write-Warning $_
}

Invoke-DockerCompose -Arguments @("down", "-v", "--remove-orphans") -IgnoreExitCode

$pathsToRemove = @(
    (Join-Path $rootDir "artifacts"),
    (Join-Path $rootDir "dbt/target"),
    (Join-Path $rootDir "dbt/logs"),
    (Join-Path $rootDir "dbt/profiles/.user.yml"),
    (Join-Path $rootDir "dlt/.dlt"),
    (Join-Path $rootDir "gitlab-projects/generated"),
    (Join-Path $rootDir "gitlab-runner/generated/config.toml"),
    (Join-Path $rootDir "gitlab-runner/generated/bootstrap.env"),
    (Join-Path $rootDir "gitlab-runner/generated/project.env"),
    (Join-Path $rootDir "gitlab-runner/generated/projects.env"),
    (Join-Path $rootDir "gitlab-branch-provisioner/state")
)

foreach ($path in $pathsToRemove) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -Recurse
    }
}

Get-ChildItem -LiteralPath $rootDir -Directory -Recurse -Force |
    Where-Object {
        $_.Name -in @("__pycache__", "logs", "target") -and
        $_.FullName -notlike "$rootDir/.git*" -and
        $_.FullName -notlike "$rootDir/gitlab-runner/generated*" -and
        $_.FullName -notlike "$rootDir/gitlab-projects/generated*"
    } |
    Sort-Object FullName -Descending |
    ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -Recurse
    }

Write-Host "local platform stack and transient artifacts removed"
Write-Host "next:"
Write-Host "  1. pwsh ./scripts/windows/bootstrap.ps1"
Write-Host "  2. wait for GitLab and Airflow to become healthy"
Write-Host "  3. pwsh ./scripts/windows/bootstrap-gitlab.ps1"

