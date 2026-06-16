# 100 MQTT clients through NLB until you press Ctrl+C (drives autoscaling).
param(
    [string]$MqttHost = $env:MQTT_HOST,
    [string]$TerraformDir = ".",
    [switch]$FromTerraform,
    [int]$Clients = 100,
    [string]$PublishInterval = $env:PUBLISH_INTERVAL,
    [string]$PayloadSize = $env:PAYLOAD_SIZE,
    [string]$MessagesPerBurst = $env:MESSAGES_PER_BURST
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path (Join-Path $PSScriptRoot "lib") "PlatformHelpers.ps1")

$AsgName = $env:ASG_NAME
if ($FromTerraform) {
    Push-Location $TerraformDir
    try {
        foreach ($name in @("mqtt_nlb_dns_name", "nlb_dns_name")) {
            $value = terraform output -raw $name 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
                $MqttHost = $value
                break
            }
        }
        $asg = terraform output -raw replicant_asg_name 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($asg)) {
            $AsgName = $asg
        }
    }
    finally {
        Pop-Location
    }
}

if ([string]::IsNullOrWhiteSpace($MqttHost)) {
    Write-Host "Set -MqttHost or use -FromTerraform after terraform apply."
    exit 1
}

if ([string]::IsNullOrWhiteSpace($PublishInterval)) { $PublishInterval = "0.01" }
if ([string]::IsNullOrWhiteSpace($PayloadSize)) { $PayloadSize = "8192" }
if ([string]::IsNullOrWhiteSpace($MessagesPerBurst)) { $MessagesPerBurst = "5" }

Write-Host "Installing dependencies..."
Install-PythonRequirements -ProjectRoot $Root | Out-Null

Write-Host "MQTT preflight..."
$probeExit = Invoke-ProjectPython -ProjectRoot $Root scripts/mqtt_probe.py --host $MqttHost
if ($probeExit -ne 0) { exit 1 }

Write-Host ""
Write-Host "Starting $Clients clients on $MqttHost - press Ctrl+C to stop." -ForegroundColor Green
Write-Host ""

$env:PYTHONUNBUFFERED = "1"
$pyArgs = @(
    "-u", "loadtest/staged_load.py",
    "--host", $MqttHost,
    "--sustained",
    "--clients", "$Clients",
    "--publish-interval", $PublishInterval,
    "--payload-size", $PayloadSize,
    "--messages-per-burst", $MessagesPerBurst
)
if (-not [string]::IsNullOrWhiteSpace($AsgName)) {
    $pyArgs += @("--asg-name", $AsgName)
}
$exitCode = Invoke-ProjectPython -ProjectRoot $Root @pyArgs
exit $exitCode
