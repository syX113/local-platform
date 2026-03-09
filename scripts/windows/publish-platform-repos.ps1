param(
    [switch]$SkipVariableSync,
    [switch]$InitHistory,
    [switch]$InitSdpHistory,
    [switch]$InitEdpHistory
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "common.ps1")

$rootDir = Get-RepoRoot
Set-Location $rootDir
Ensure-PlatformEnv -RootDir $rootDir

if ($InitHistory) {
    $InitSdpHistory = $true
    $InitEdpHistory = $true
}

$bootstrapEnv = Join-Path $rootDir "gitlab-runner/generated/bootstrap.env"
$projectsEnv = Join-Path $rootDir "gitlab-runner/generated/projects.env"
if (-not (Test-Path -LiteralPath $bootstrapEnv) -or -not (Test-Path -LiteralPath $projectsEnv)) {
    throw "missing GitLab bootstrap metadata. Run pwsh ./scripts/windows/bootstrap-gitlab.ps1 first."
}

Import-EnvFile -Path $bootstrapEnv -OverrideExisting
Import-EnvFile -Path $projectsEnv -OverrideExisting

if ([string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_BOOTSTRAP_PAT")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_SDP_PROJECT_PATH")) -or
    [string]::IsNullOrEmpty((Get-EnvValue -Name "GITLAB_EDP_PROJECT_PATH"))) {
    throw "bootstrap metadata is incomplete. Re-run pwsh ./scripts/windows/bootstrap-gitlab.ps1."
}

function Invoke-GitLabApi {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [hashtable]$Body,
        [switch]$Raw
    )

    $headers = @{ "PRIVATE-TOKEN" = (Get-EnvValue -Name "GITLAB_BOOTSTRAP_PAT") }
    $uri = "http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')/api/v4$Path"
    Invoke-GitLabWebRequest -Method $Method -Uri $uri -Headers $headers -Body $Body -Raw:$Raw
}

function Unprotect-MainBranch {
    param([string]$ProjectId)
    Invoke-GitLabApi -Method "DELETE" -Path "/projects/$ProjectId/protected_branches/main" -Raw | Out-Null
}

function Protect-MainBranch {
    param([string]$ProjectId)
    $body = @{
        name               = "main"
        push_access_level  = "40"
        merge_access_level = "40"
        allow_force_push   = "false"
    }
    Invoke-GitLabApi -Method "POST" -Path "/projects/$ProjectId/protected_branches" -Body $body -Raw | Out-Null
}

function Ensure-GitRepo {
    param([string]$RepoDir)

    if (-not (Test-Path -LiteralPath (Join-Path $RepoDir ".git"))) {
        Invoke-Git -Arguments @("-C", $RepoDir, "init", "-b", "main")
    }

    Invoke-Git -Arguments @("-C", $RepoDir, "config", "user.name", "Codex Local")
    Invoke-Git -Arguments @("-C", $RepoDir, "config", "user.email", "codex-local@example.com")
}

function Test-RemoteRepoIsEmpty {
    param([string]$RemoteUrl)

    $output = & git ls-remote --heads $RemoteUrl 2>$null
    return [string]::IsNullOrWhiteSpace(($output -join [Environment]::NewLine))
}

function Set-RemoteUrl {
    param(
        [string]$RepoDir,
        [string]$RemoteName,
        [string]$RemoteUrl
    )

    & git -C $RepoDir remote get-url $RemoteName *> $null
    if ($LASTEXITCODE -eq 0) {
        Invoke-Git -Arguments @("-C", $RepoDir, "remote", "set-url", $RemoteName, $RemoteUrl)
    }
    else {
        Invoke-Git -Arguments @("-C", $RepoDir, "remote", "add", $RemoteName, $RemoteUrl)
    }
}

function Sync-RenderedRepo {
    param(
        [string]$RepoDir,
        [string]$RemoteName,
        [string]$RemoteUrl,
        [string]$CommitMessage,
        [bool]$InitializeHistory,
        [string]$ProjectId
    )

    Ensure-GitRepo -RepoDir $RepoDir
    Set-RemoteUrl -RepoDir $RepoDir -RemoteName $RemoteName -RemoteUrl $RemoteUrl

    if (-not $InitializeHistory -and (Test-RemoteRepoIsEmpty -RemoteUrl $RemoteUrl)) {
        $InitializeHistory = $true
    }

    if ($InitializeHistory) {
        if (-not [string]::IsNullOrEmpty($ProjectId)) {
            Unprotect-MainBranch -ProjectId $ProjectId
        }

        Invoke-Git -Arguments @("-C", $RepoDir, "checkout", "--orphan", "__init_artifacts__")
        Invoke-Git -Arguments @("-C", $RepoDir, "add", "-A")
        Invoke-Git -Arguments @("-C", $RepoDir, "commit", "--allow-empty", "-m", "init-artifacts")
        Invoke-Git -Arguments @("-C", $RepoDir, "branch", "-M", "__init_artifacts__", "main")
        try {
            Invoke-Git -Arguments @("-C", $RepoDir, "push", "--force", "--set-upstream", $RemoteName, "main")
        }
        finally {
            if (-not [string]::IsNullOrEmpty($ProjectId)) {
                Protect-MainBranch -ProjectId $ProjectId
            }
        }
        return
    }

    Invoke-Git -Arguments @("-C", $RepoDir, "checkout", "-B", "main")
    Invoke-Git -Arguments @("-C", $RepoDir, "add", "-A")
    $status = Invoke-Git -Arguments @("-C", $RepoDir, "status", "--short") -CaptureOutput
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        Invoke-Git -Arguments @("-C", $RepoDir, "commit", "-m", $CommitMessage)
    }
    Invoke-Git -Arguments @("-C", $RepoDir, "push", "--set-upstream", $RemoteName, "main")
}

& python3 (Join-Path $rootDir "scripts/render_gitlab_project_repos.py")

$platformSha = "manual"
try {
    $platformSha = Invoke-Git -Arguments @("rev-parse", "--short", "HEAD") -CaptureOutput
}
catch {
}

$sdpRepoDir = Join-Path $rootDir "gitlab-projects/generated/$(Get-EnvValue -Name 'GITLAB_SDP_PROJECT_PATH')"
$edpRepoDir = Join-Path $rootDir "gitlab-projects/generated/$(Get-EnvValue -Name 'GITLAB_EDP_PROJECT_PATH')"
$gitlabBaseUrl = "http://oauth2:$(Get-EnvValue -Name 'GITLAB_BOOTSTRAP_PAT')@localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')/root"

Write-Host "publishing rendered SDP platform repo"
Sync-RenderedRepo `
    -RepoDir $sdpRepoDir `
    -RemoteName "local-gitlab-sdp" `
    -RemoteUrl "$gitlabBaseUrl/$(Get-EnvValue -Name 'GITLAB_SDP_PROJECT_PATH').git" `
    -CommitMessage "Sync SDP project from local platform $platformSha" `
    -InitializeHistory ([bool]$InitSdpHistory) `
    -ProjectId (Get-EnvValue -Name "GITLAB_SDP_PROJECT_ID")

Write-Host "publishing rendered EDP platform repo"
Sync-RenderedRepo `
    -RepoDir $edpRepoDir `
    -RemoteName "local-gitlab-edp" `
    -RemoteUrl "$gitlabBaseUrl/$(Get-EnvValue -Name 'GITLAB_EDP_PROJECT_PATH').git" `
    -CommitMessage "Sync EDP project from local platform $platformSha" `
    -InitializeHistory ([bool]$InitEdpHistory) `
    -ProjectId (Get-EnvValue -Name "GITLAB_EDP_PROJECT_ID")

if (-not $SkipVariableSync) {
    Write-Host "syncing GitLab CI variables"
    & (Join-Path $PSScriptRoot "sync-gitlab-ci-variables.ps1")
}

Write-Host "rendered platform repositories published"
Write-Host "source repository remotes were not modified"
