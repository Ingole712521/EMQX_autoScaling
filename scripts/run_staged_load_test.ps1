# Run staged MQTT load against EMQX NLB to trigger autoscaling.
param(
    [string]$MqttHost = $env:MQTT_HOST,
    [string]$TerraformDir = ".",
    [switch]$FromTerraform,
    [string]$PublishInterval = $env:PUBLISH_INTERVAL,
    [string]$PayloadSize = $env:PAYLOAD_SIZE,
    [string]$MessagesPerBurst = $env:MESSAGES_PER_BURST,
    [string]$LoadStages = $env:LOAD_STAGES
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path (Join-Path $PSScriptRoot "lib") "PlatformHelpers.ps1")

$AsgName = $env:ASG_NAME
if ($FromTerraform) {
    if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
        throw "terraform is not installed or not on PATH."
    }
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

if (-not (Get-PythonExecutable)) {
    throw "Python 3 is required."
}

if ([string]::IsNullOrWhiteSpace($PublishInterval)) { $PublishInterval = "0.001" }
if ([string]::IsNullOrWhiteSpace($PayloadSize)) { $PayloadSize = "16384" }
if ([string]::IsNullOrWhiteSpace($MessagesPerBurst)) { $MessagesPerBurst = "10" }
if ([string]::IsNullOrWhiteSpace($LoadStages)) {
    $LoadStages = "40:180:baseline-heavy,80:300:scale-out-2,120:300:scale-out-3,10:90:scale-in"
}

Write-Host "Installing dependencies..."
Install-PythonRequirements -ProjectRoot $Root | Out-Null

Write-Host "MQTT preflight..."
$probeExit = Invoke-ProjectPython -ProjectRoot $Root scripts/mqtt_probe.py --host $MqttHost
if ($probeExit -ne 0) {
    Write-Host "Preflight failed. Run: ./scripts/fix_mqtt_anonymous_ssm.ps1 then ./scripts/prove_emqx_cluster.ps1" -ForegroundColor Yellow
    exit 1
}
$env:PYTHONUNBUFFERED = "1"
Write-Host "Starting staged load test on $MqttHost"
$pyArgs = @(
    "-u", "loadtest/staged_load.py",
    "--host", $MqttHost,
    "--publish-interval", $PublishInterval,
    "--payload-size", $PayloadSize,
    "--messages-per-burst", $MessagesPerBurst,
    "--stages", $LoadStages
)
if (-not [string]::IsNullOrWhiteSpace($AsgName)) {
    $pyArgs += @("--asg-name", $AsgName)
}
$exitCode = Invoke-ProjectPython -ProjectRoot $Root @pyArgs
exit $exitCode
