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

function Get-EndpointStatus {
    param([string]$Uri)
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Get -SkipHttpErrorCheck -TimeoutSec 30
        return [int]$response.StatusCode
    }
    catch {
        return 0
    }
}

function Wait-ForGitLab {
    $stable = 0
    $gitlabPort = Get-EnvValue -Name "GITLAB_HTTP_PORT"
    while ($stable -lt 2) {
        $helpStatus = Get-EndpointStatus -Uri "http://localhost:$gitlabPort/help"
        $signInStatus = Get-EndpointStatus -Uri "http://localhost:$gitlabPort/users/sign_in"
        $apiStatus = Get-EndpointStatus -Uri "http://localhost:$gitlabPort/api/v4/version"

        if ($helpStatus -eq 200 -and $signInStatus -eq 200 -and ($apiStatus -eq 200 -or $apiStatus -eq 401)) {
            $stable += 1
            Write-Host "GitLab endpoints are healthy ($stable/2)"
            Start-Sleep -Seconds 5
            continue
        }

        $stable = 0
        Write-Host "waiting for GitLab UI/API readiness (help=$helpStatus sign_in=$signInStatus api=$apiStatus)"
        Start-Sleep -Seconds 10
    }
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

    $headers = @{ "PRIVATE-TOKEN" = $script:BootstrapPat }
    $uri = "http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')/api/v4$Path"
    Invoke-GitLabWebRequest -Method $Method -Uri $uri -Headers $headers -Body $Body -Raw:$Raw
}

function Test-BootstrapPat {
    param([string]$Token)
    if ([string]::IsNullOrEmpty($Token)) {
        return $false
    }

    $headers = @{ "PRIVATE-TOKEN" = $Token }
    $uri = "http://localhost:$(Get-EnvValue -Name 'GITLAB_HTTP_PORT')/api/v4/user"
    $response = Invoke-GitLabWebRequest -Method "GET" -Uri $uri -Headers $headers -Raw
    return $response.StatusCode -eq 200
}

function Delete-MatchingRunners {
    param([string]$RunnerDescription)

    $runners = Invoke-GitLabApi -Method "GET" -Path "/runners/all?per_page=100"
    foreach ($runner in $runners) {
        if ($runner.description -eq $RunnerDescription) {
            Invoke-GitLabApi -Method "DELETE" -Path "/runners/$($runner.id)" -Raw | Out-Null
        }
    }
}

function Create-OrResolveProject {
    param(
        [string]$ProjectName,
        [string]$ProjectPath
    )

    $response = Invoke-GitLabApi -Method "POST" -Path "/projects" -Body @{
        name = $ProjectName
        path = $ProjectPath
    } -Raw

    if ($response.StatusCode -eq 200 -or $response.StatusCode -eq 201) {
        return @{
            Id     = ($response.Content | ConvertFrom-Json).id.ToString()
            Status = "created"
        }
    }

    $projects = Invoke-GitLabApi -Method "GET" -Path "/projects?search=$ProjectPath"
    foreach ($project in $projects) {
        if ($project.path -eq $ProjectPath) {
            return @{
                Id     = $project.id.ToString()
                Status = "existing"
            }
        }
    }

    throw "failed to resolve project $ProjectPath"
}

function Create-ProjectRunnerToken {
    param(
        [string]$ProjectId,
        [string]$RunnerDescription
    )

    Delete-MatchingRunners -RunnerDescription $RunnerDescription
    $runner = Invoke-GitLabApi -Method "POST" -Path "/user/runners" -Body @{
        runner_type = "project_type"
        project_id  = $ProjectId
        description = $RunnerDescription
        tag_list    = (Get-EnvValue -Name "GITLAB_RUNNER_TAGS")
    }

    return $runner.token
}

function Enable-LocalWebhookRequests {
    $ruby = @"
settings = ApplicationSetting.current
settings.update!(allow_local_requests_from_web_hooks_and_services: true)
puts settings.allow_local_requests_from_web_hooks_and_services
"@

    $output = Invoke-DockerCompose -Arguments @("exec", "-T", "gitlab-platform", "gitlab-rails", "runner", $ruby) -CaptureOutput
    return ($output.Split([Environment]::NewLine) | Select-Object -Last 1).Trim()
}

function Ensure-ProjectBranchWebhook {
    param(
        [string]$ProjectId,
        [string]$HookUrl
    )

    $hooks = Invoke-GitLabApi -Method "GET" -Path "/projects/$ProjectId/hooks"
    $existingHook = $hooks | Where-Object { $_.url -eq $HookUrl } | Select-Object -First 1
    $body = @{
        url                     = $HookUrl
        push_events             = "true"
        tag_push_events         = "false"
        issues_events           = "false"
        merge_requests_events   = "false"
        job_events              = "false"
        pipeline_events         = "false"
        wiki_page_events        = "false"
        enable_ssl_verification = "false"
        token                   = (Get-EnvValue -Name "GITLAB_BRANCH_PROVISIONER_WEBHOOK_TOKEN")
    }

    if ($null -ne $existingHook) {
        Invoke-GitLabApi -Method "PUT" -Path "/projects/$ProjectId/hooks/$($existingHook.id)" -Body $body -Raw | Out-Null
    }
    else {
        Invoke-GitLabApi -Method "POST" -Path "/projects/$ProjectId/hooks" -Body $body -Raw | Out-Null
    }
}

function Render-RunnerConfig {
    param(
        [string]$SdpRunnerDescription,
        [string]$SdpRunnerToken,
        [string]$EdpRunnerDescription,
        [string]$EdpRunnerToken
    )

    $template = Get-Content -LiteralPath (Join-Path $rootDir "gitlab-runner/config.template.toml") -Raw

    $renderedSdp = $template.Replace("__RUNNER_DESCRIPTION__", $SdpRunnerDescription).
        Replace("__GITLAB_URL__", "http://gitlab/").
        Replace("__RUNNER_TOKEN__", $SdpRunnerToken).
        Replace("__CLONE_URL__", "http://gitlab").
        Replace("__JOB_IMAGE__", (Get-EnvValue -Name "GITLAB_RUNNER_JOB_IMAGE")).
        Replace("__RUNNER_NETWORK__", (Get-EnvValue -Name "PLATFORM_DOCKER_NETWORK"))

    $renderedEdp = $template.Replace("__RUNNER_DESCRIPTION__", $EdpRunnerDescription).
        Replace("__GITLAB_URL__", "http://gitlab/").
        Replace("__RUNNER_TOKEN__", $EdpRunnerToken).
        Replace("__CLONE_URL__", "http://gitlab").
        Replace("__JOB_IMAGE__", (Get-EnvValue -Name "GITLAB_RUNNER_JOB_IMAGE")).
        Replace("__RUNNER_NETWORK__", (Get-EnvValue -Name "PLATFORM_DOCKER_NETWORK"))

    $config = @(
        "concurrent = 4",
        "check_interval = 2",
        "",
        $renderedSdp.TrimEnd(),
        "",
        $renderedEdp.TrimEnd(),
        ""
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath (Join-Path $generatedDir "config.toml") -Value $config -Encoding UTF8
}

Wait-ForGitLab

$script:BootstrapPat = ""
$bootstrapEnvPath = Join-Path $generatedDir "bootstrap.env"
if (Test-Path -LiteralPath $bootstrapEnvPath) {
    Import-EnvFile -Path $bootstrapEnvPath -OverrideExisting
    $existingToken = Get-EnvValue -Name "GITLAB_BOOTSTRAP_PAT"
    if (Test-BootstrapPat -Token $existingToken) {
        $script:BootstrapPat = $existingToken
    }
}

if ([string]::IsNullOrEmpty($script:BootstrapPat)) {
    Write-Host "creating bootstrap PAT"
    $ruby = @"
user = User.find_by_username('root')
user.personal_access_tokens.where(name: 'local-platform-bootstrap').each(&:revoke!)
token = user.personal_access_tokens.create!(scopes: ['api', 'create_runner', 'admin_mode'], name: 'local-platform-bootstrap', expires_at: 365.days.from_now)
puts token.token
"@
    $output = Invoke-DockerCompose -Arguments @("exec", "-T", "gitlab-platform", "gitlab-rails", "runner", $ruby) -CaptureOutput
    $script:BootstrapPat = ($output.Split([Environment]::NewLine) | Select-Object -Last 1).Trim()
}

Set-Content -LiteralPath $bootstrapEnvPath -Value "GITLAB_BOOTSTRAP_PAT=$script:BootstrapPat`n" -Encoding UTF8

Write-Host "enabling local webhook callbacks in GitLab"
if ((Enable-LocalWebhookRequests) -ne "true") {
    throw "failed to enable local webhook callbacks in GitLab"
}

$sdpProjectName = Get-EnvValue -Name "GITLAB_SDP_PROJECT_NAME"
$sdpProjectPath = Get-EnvValue -Name "GITLAB_SDP_PROJECT_PATH"
$edpProjectName = Get-EnvValue -Name "GITLAB_EDP_PROJECT_NAME"
$edpProjectPath = Get-EnvValue -Name "GITLAB_EDP_PROJECT_PATH"
$runnerPrefix = Get-EnvValue -Name "GITLAB_RUNNER_DESCRIPTION_PREFIX"
$sdpRunnerDescription = "$runnerPrefix-sdp"
$edpRunnerDescription = "$runnerPrefix-edp"
$branchProvisionerPort = Get-EnvValue -Name "GITLAB_BRANCH_PROVISIONER_PORT"
$branchProvisionerHost = Get-EnvValue -Name "GITLAB_BRANCH_PROVISIONER_WEBHOOK_HOST"

Write-Host "creating or resolving SDP GitLab project"
$sdpProject = Create-OrResolveProject -ProjectName $sdpProjectName -ProjectPath $sdpProjectPath

Write-Host "creating or resolving EDP GitLab project"
$edpProject = Create-OrResolveProject -ProjectName $edpProjectName -ProjectPath $edpProjectPath

Write-Host "creating SDP project runner token"
$sdpRunnerToken = Create-ProjectRunnerToken -ProjectId $sdpProject.Id -RunnerDescription $sdpRunnerDescription

Write-Host "creating EDP project runner token"
$edpRunnerToken = Create-ProjectRunnerToken -ProjectId $edpProject.Id -RunnerDescription $edpRunnerDescription

$projectsEnvContent = @"
GITLAB_SDP_PROJECT_ID=$($sdpProject.Id)
GITLAB_SDP_PROJECT_PATH=$sdpProjectPath
GITLAB_SDP_RUNNER_TOKEN=$sdpRunnerToken
GITLAB_EDP_PROJECT_ID=$($edpProject.Id)
GITLAB_EDP_PROJECT_PATH=$edpProjectPath
GITLAB_EDP_RUNNER_TOKEN=$edpRunnerToken
"@
Set-Content -LiteralPath (Join-Path $generatedDir "projects.env") -Value ($projectsEnvContent.Trim() + [Environment]::NewLine) -Encoding UTF8

Render-RunnerConfig `
    -SdpRunnerDescription $sdpRunnerDescription `
    -SdpRunnerToken $sdpRunnerToken `
    -EdpRunnerDescription $edpRunnerDescription `
    -EdpRunnerToken $edpRunnerToken

New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot "gitlab-branch-provisioner/state") | Out-Null

Invoke-DockerCompose -Arguments @("up", "-d", "gitlab-branch-provisioner")

$branchHookUrl = "http://$branchProvisionerHost`:$branchProvisionerPort/gitlab/webhook"

Write-Host "configuring SDP GitLab branch webhook"
Ensure-ProjectBranchWebhook -ProjectId $sdpProject.Id -HookUrl $branchHookUrl

Write-Host "configuring EDP GitLab branch webhook"
Ensure-ProjectBranchWebhook -ProjectId $edpProject.Id -HookUrl $branchHookUrl

Invoke-DockerCompose -Arguments @("up", "-d", "gitlab-fargate-runner")

$publishArgs = @()
if ($sdpProject.Status -eq "created") {
    $publishArgs += "-InitSdpHistory"
}
if ($edpProject.Status -eq "created") {
    $publishArgs += "-InitEdpHistory"
}

& (Join-Path $PSScriptRoot "publish-platform-repos.ps1") @publishArgs

Write-Host "gitlab bootstrap complete"
Write-Host "SDP project id: $($sdpProject.Id)"
Write-Host "EDP project id: $($edpProject.Id)"
Write-Host "runner config: gitlab-runner/generated/config.toml"
Write-Host "bootstrap pat: gitlab-runner/generated/bootstrap.env"
Write-Host "project metadata: gitlab-runner/generated/projects.env"
& (Join-Path $PSScriptRoot "print-setup-summary.ps1")
