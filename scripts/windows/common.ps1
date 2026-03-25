$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($null -eq $value) {
        return ""
    }
    return $value
}

function Set-EnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    [Environment]::SetEnvironmentVariable($Name, $Value)
}

function Normalize-EnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed.Length -ge 2) {
        if (($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) -or ($trimmed.StartsWith("'") -and $trimmed.EndsWith("'"))) {
            return $trimmed.Substring(1, $trimmed.Length - 2)
        }
    }
    return $trimmed
}

function Import-EnvFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [switch]$OverrideExisting
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#") -or -not $line.Contains("=")) {
            continue
        }

        $parts = $line.Split("=", 2)
        $key = $parts[0].Trim()
        $value = Normalize-EnvValue -Value $parts[1]

        if (-not $OverrideExisting -and -not [string]::IsNullOrEmpty((Get-EnvValue -Name $key))) {
            continue
        }

        Set-EnvValue -Name $key -Value $value
    }
}

function Update-EnvFileValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $lines = @()
    $updated = $false

    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match "^$([regex]::Escape($Name))=") {
                $lines += "$Name=`"$Value`""
                $updated = $true
            }
            else {
                $lines += $line
            }
        }
    }

    if (-not $updated) {
        $lines += "$Name=`"$Value`""
    }

    $content = ($lines -join [Environment]::NewLine)
    if (-not $content.EndsWith([Environment]::NewLine)) {
        $content += [Environment]::NewLine
    }
    Set-Content -LiteralPath $Path -Value $content -Encoding UTF8
}

function Ensure-PlatformEnv {
    param(
        [string]$RootDir = (Get-RepoRoot)
    )

    $envFile = Join-Path $RootDir ".env"
    if (-not (Test-Path -LiteralPath $envFile)) {
        $envExample = Join-Path $RootDir ".env.example"
        $ciEnvExample = Join-Path $RootDir "ci/.env.example"
        if (Test-Path -LiteralPath $envExample) {
            Copy-Item -LiteralPath $envExample -Destination $envFile
        }
        elseif (Test-Path -LiteralPath $ciEnvExample) {
            Copy-Item -LiteralPath $ciEnvExample -Destination $envFile
        }
        else {
            throw "unable to create .env: no .env.example or ci/.env.example found"
        }
        Write-Host "created .env from .env.example"
    }

    Import-EnvFile -Path $envFile

    if ([string]::IsNullOrEmpty((Get-EnvValue -Name "LOCAL_PLATFORM_ROOT"))) {
        Set-EnvValue -Name "LOCAL_PLATFORM_ROOT" -Value $RootDir
        Update-EnvFileValue -Path $envFile -Name "LOCAL_PLATFORM_ROOT" -Value $RootDir
    }
}

function Get-RuntimeImagePrefix {
    $prefix = Get-EnvValue -Name "RUNTIME_IMAGE_PREFIX"
    if (-not [string]::IsNullOrEmpty($prefix)) {
        return $prefix
    }

    $composeProject = Get-EnvValue -Name "COMPOSE_PROJECT_NAME"
    if (-not [string]::IsNullOrEmpty($composeProject)) {
        return $composeProject
    }

    return "local-platform"
}

function Get-RuntimeImageRef {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServiceName
    )

    return "$(Get-RuntimeImagePrefix)/$ServiceName`:dev"
}

function Resolve-ContainerDbtProjectDir {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectSlug,
        [string]$RootDir = (Get-RepoRoot)
    )

    $nestedProject = Join-Path $RootDir "dbt/projects/$ProjectSlug/dbt_project.yml"
    if (Test-Path -LiteralPath $nestedProject) {
        return "/opt/platform/dbt/projects/$ProjectSlug"
    }

    $singleProject = Join-Path $RootDir "dbt/dbt_project.yml"
    if (Test-Path -LiteralPath $singleProject) {
        return "/opt/platform/dbt"
    }

    throw "unable to resolve dbt project dir for $ProjectSlug"
}

function Get-LoomManifestBucket {
    $bucket = Get-EnvValue -Name "MINIO_MANIFEST_BUCKET"
    if ([string]::IsNullOrEmpty($bucket)) {
        return "dbt-manifests"
    }
    return $bucket
}

function Get-LoomManifestObjectKeyForRepo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoPath
    )

    return "dbt-loom/$RepoPath/manifest.json.gz"
}

function Publish-SourceLoomManifests {
    param(
        [string]$SourceProjectSlug = "proj_source_finnova"
    )

    $sourceProjectDir = Resolve-ContainerDbtProjectDir -ProjectSlug $SourceProjectSlug -RootDir (Get-RepoRoot)
    $bucket = Get-LoomManifestBucket
    $edpRepoPath = Get-EnvValue -Name "GITLAB_EDP_PROJECT_PATH"
    if ([string]::IsNullOrEmpty($edpRepoPath)) {
        $edpRepoPath = "proj_edp_orders"
    }
    $edpCustomersRepoPath = Get-EnvValue -Name "GITLAB_EDP_CUSTOMERS_PROJECT_PATH"
    if ([string]::IsNullOrEmpty($edpCustomersRepoPath)) {
        $edpCustomersRepoPath = "proj_edp_customers"
    }

    Invoke-DockerCompose -Arguments @(
        "run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/loom_manifest.py", "publish",
        "--project-dir", $sourceProjectDir,
        "--bucket", $bucket,
        "--object-key", (Get-LoomManifestObjectKeyForRepo -RepoPath $edpRepoPath),
        "--object-key", (Get-LoomManifestObjectKeyForRepo -RepoPath $edpCustomersRepoPath)
    )
}

function Ensure-DbtLoomManifestForProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectSlug
    )

    switch ($ProjectSlug) {
        "proj_edp_orders" {}
        "proj_edp_customers" {}
        default { return }
    }

    $projectDir = Resolve-ContainerDbtProjectDir -ProjectSlug $ProjectSlug -RootDir (Get-RepoRoot)
    Invoke-DockerCompose -Arguments @(
        "run", "--rm", "--no-deps", "dbt-executor", "python", "/opt/platform/dbt/scripts/loom_manifest.py", "fetch",
        "--project-dir", $projectDir,
        "--bucket", (Get-LoomManifestBucket),
        "--object-key", (Get-LoomManifestObjectKeyForRepo -RepoPath $ProjectSlug)
    )
}

function Invoke-DockerCompose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput,
        [switch]$IgnoreExitCode
    )

    $output = & docker compose @Arguments 2>&1 | Where-Object {
        $_ -notmatch "No services to build" -and
        $_ -notmatch "Found orphan containers"
    }
    $exitCode = $LASTEXITCODE

    if (-not $CaptureOutput) {
        foreach ($line in $output) {
            Write-Host $line
        }
    }

    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        throw "docker compose $($Arguments -join ' ') failed with exit code $exitCode"
    }

    if ($CaptureOutput) {
        return ($output -join [Environment]::NewLine).Trim()
    }
}

function Invoke-DockerComposeBuild {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Services
    )

    foreach ($service in $Services) {
        if ([string]::IsNullOrWhiteSpace($service)) {
            continue
        }

        $attempt = 1
        while ($true) {
            try {
                Write-Host "building compose service: $service"
                Invoke-DockerCompose -Arguments @("build", $service)
                break
            }
            catch {
                if ($attempt -ge 3) {
                    throw
                }

                Write-Host "retrying compose build for $service after 5s"
                Start-Sleep -Seconds 5
                $attempt++
            }
        }
    }
}

function Invoke-DockerComposeWithStdin {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputText,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput,
        [switch]$IgnoreExitCode
    )

    $output = $InputText | & docker compose @Arguments 2>&1 | Where-Object {
        $_ -notmatch "No services to build" -and
        $_ -notmatch "Found orphan containers"
    }
    $exitCode = $LASTEXITCODE

    if (-not $CaptureOutput) {
        foreach ($line in $output) {
            Write-Host $line
        }
    }

    if ($exitCode -ne 0 -and -not $IgnoreExitCode) {
        throw "docker compose $($Arguments -join ' ') failed with exit code $exitCode"
    }

    if ($CaptureOutput) {
        return ($output -join [Environment]::NewLine).Trim()
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$CaptureOutput
    )

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $exitCode`n$($output -join [Environment]::NewLine)"
    }
    if ($CaptureOutput) {
        return ($output -join [Environment]::NewLine).Trim()
    }
    foreach ($line in $output) {
        Write-Host $line
    }
}

function Invoke-GitLabWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body,
        [switch]$Raw
    )

    $params = @{
        Method             = $Method
        Uri                = $Uri
        SkipHttpErrorCheck = $true
        TimeoutSec         = 30
    }
    if ($Headers) {
        $params.Headers = $Headers
    }
    if ($null -ne $Body) {
        $params.Body = $Body
    }

    $response = Invoke-WebRequest @params
    if ($Raw) {
        return $response
    }

    if ([string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }

    return $response.Content | ConvertFrom-Json
}
