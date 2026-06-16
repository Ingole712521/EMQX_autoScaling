param(
    [switch]$SkipApply,
    [switch]$SkipLoadTest,
    [string]$TerraformDir = "."
)

function Get-TerraformOutputValue {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Names,
        [string]$TerraformDir = "."
    )

    Push-Location $TerraformDir
    try {
        foreach ($name in $Names) {
            $value = terraform output -raw $name 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }
    finally {
        Pop-Location
    }

    return $null
}

function Show-DeploySummary {
    param(
        [string]$DashboardUrl,
        [string]$MqttHost,
        [string]$CoreIp,
        [string]$AsgName
    )

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host " EMQX DEPLOYMENT READY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Dashboard : $DashboardUrl"
    Write-Host "MQTT NLB  : tcp://${MqttHost}:1883"
    Write-Host "Core IP   : $CoreIp"
    Write-Host "ASG       : $AsgName"
    Write-Host ""
    Write-Host "Firewall (security groups):"
    Write-Host "  - Port 18083 (dashboard) open per dashboard_allowed_cidr"
    Write-Host "  - Port 1883  (MQTT)      via NLB only (replicants accept NLB SG)"
    Write-Host "  - Port 22    (SSH)       open per ssh_allowed_cidr"
    Write-Host ""
    Write-Host "Autoscaling (step +1/-1):"
    Write-Host "  - Scale OUT +1 when NLB/ASG network > ~5 KB/s for 2 minutes (or CPU > 25%)"
    Write-Host "  - Scale IN  -1 when CPU < 5% for ~60 seconds"
    Write-Host "  - Scale-out cooldown: 60 seconds"
    Write-Host "  - Replicants: min 1, max 4"
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-TerraformStateAvailable {
    param([string]$StateFile = "terraform.tfstate")

    if (-not (Test-Path $StateFile)) {
        return $true
    }

    try {
        $stream = [System.IO.File]::Open(
            (Resolve-Path $StateFile),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
        $stream.Close()
        return $true
    }
    catch {
        return $false
    }
}

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path (Join-Path $PSScriptRoot "lib") "PlatformHelpers.ps1")

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    throw "terraform is not installed or not on PATH."
}

if (-not $SkipApply) {
    if (-not (Test-TerraformStateAvailable)) {
        Write-Host ""
        Write-Host "terraform.tfstate is locked by another process." -ForegroundColor Yellow
        Write-Host "Wait for any running 'terraform apply/plan' to finish, then retry."
        Write-Host "Or run with -SkipApply if apply already completed:"
        Write-Host '  pwsh -File ./scripts/deploy_and_load_test.ps1 -SkipApply'
        Write-Host ""
        throw "Terraform state file is locked."
    }

    Write-Host "Running terraform init..."
    terraform init -input=false
    if ($LASTEXITCODE -ne 0) {
        throw "terraform init failed."
    }

    Write-Host "Running terraform apply..."
    terraform apply -auto-approve -input=false
    if ($LASTEXITCODE -ne 0) {
        throw "terraform apply failed."
    }
    Write-Host ""
    Write-Host "terraform apply completed successfully." -ForegroundColor Green
    Write-Host ""
    Write-Host "IMPORTANT:" -ForegroundColor Yellow
    Write-Host "  AWS infrastructure is created, but EMQX is still installing on EC2."
    Write-Host "  This usually takes 5-15 minutes. Live bootstrap logs will appear next."
    Write-Host ""
}

$dashboardUrl = Get-TerraformOutputValue -Names @("emqx_dashboard_url") -TerraformDir $TerraformDir
$coreIp = Get-TerraformOutputValue -Names @("emqx_core_public_ip") -TerraformDir $TerraformDir
$mqttHost = Get-TerraformOutputValue -Names @("mqtt_nlb_dns_name", "nlb_dns_name") -TerraformDir $TerraformDir
$asgName = Get-TerraformOutputValue -Names @("replicant_asg_name") -TerraformDir $TerraformDir

if ([string]::IsNullOrWhiteSpace($dashboardUrl) -and -not [string]::IsNullOrWhiteSpace($coreIp)) {
    $dashboardUrl = "http://${coreIp}:18083"
}

if ([string]::IsNullOrWhiteSpace($mqttHost) -or [string]::IsNullOrWhiteSpace($coreIp)) {
    throw "Missing terraform outputs. Run terraform apply first."
}

if ([string]::IsNullOrWhiteSpace($asgName)) {
    $asgName = "emqx-prod-replicants-asg"
}

Show-DeploySummary -DashboardUrl $dashboardUrl -MqttHost $mqttHost -CoreIp $coreIp -AsgName $asgName

$watchScript = Join-Path (Join-Path $Root "scripts") "watch_bootstrap.ps1"
Write-Host "Watching EMQX bootstrap progress (live logs from instance)..."
$bootstrapReady = & $watchScript -CoreIp $coreIp -MqttHost $mqttHost

if (-not $bootstrapReady) {
    throw "EMQX did not become ready in time. Check /var/log/emqx-bootstrap.log on the core instance."
}

Write-Host "Opening dashboard in browser..."
Open-UrlInBrowser -Url $dashboardUrl

if (-not $SkipLoadTest) {
    Start-LoadTestInNewTerminal -ProjectRoot $Root -MqttHost $mqttHost
}

Write-Host "Done. Watch Auto Scaling Group activity in AWS Console." -ForegroundColor Green
