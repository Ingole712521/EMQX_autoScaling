# Cluster resilience validation — replicant termination and core reboot scenarios.
param(
    [string]$Region = "ap-south-1",
    [string]$DashboardPassword = $env:EMQX_DASHBOARD_PASSWORD,
    [string]$DashboardUser = "admin",
    [int]$LoadClients = 100,
    [ValidateSet("replicant-terminate", "core-reboot", "all")]
    [string]$Scenario = "replicant-terminate",
    [switch]$DryRun,
    [switch]$FromTerraform
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$coreIp = terraform output -raw emqx_core_public_ip
$mqttHost = terraform output -raw mqtt_nlb_dns_name
$asgName = terraform output -raw replicant_asg_name
$coreInstanceId = terraform output -raw emqx_core_instance_id 2>$null

if (-not $DashboardPassword) {
    $tfvars = Join-Path $Root "terraform.tfvars"
    if (Test-Path $tfvars) {
        $t = Get-Content -Raw $tfvars
        if ($t -match 'emqx_dashboard_password\s*=\s*"([^"]*)"') { $DashboardPassword = $Matches[1] }
    }
}
if ([string]::IsNullOrWhiteSpace($DashboardPassword)) {
    Write-Host "Set EMQX_DASHBOARD_PASSWORD or terraform.tfvars"
    exit 1
}

python -m pip install -q -r loadtest/requirements.txt

$env:EMQX_CORE_IP = $coreIp
$env:MQTT_HOST = $mqttHost
$env:ASG_NAME = $asgName
$env:EMQX_CORE_INSTANCE_ID = $coreInstanceId
$env:EMQX_DASHBOARD_USERNAME = $DashboardUser
$env:EMQX_DASHBOARD_PASSWORD = $DashboardPassword
$env:AWS_REGION = $Region

$argsList = @(
    "loadtest/resilience_test.py",
    "--region", $Region,
    "--core-ip", $coreIp,
    "--mqtt-host", $mqttHost,
    "--asg-name", $asgName,
    "--load-clients", "$LoadClients",
    "--scenario", $Scenario,
    "--dashboard-user", $DashboardUser
)
if ($coreInstanceId) { $argsList += @("--core-instance-id", $coreInstanceId) }
if ($DryRun) { $argsList += "--dry-run" }

python @argsList
exit $LASTEXITCODE
