# Message durability validation — sent/received/lost counters during failure scenarios.
param(
    [string]$Region = "ap-south-1",
    [string]$MqttHost = $env:MQTT_HOST,
    [int]$Count = 100000,
    [int]$Rate = 2000,
    [int]$Qos = 1,
    [ValidateSet("pub", "sub", "both")]
    [string]$Mode = "both",
    [switch]$FromTerraform,
    [switch]$OnLoadGenerator
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if ($FromTerraform) {
    $MqttHost = terraform output -raw mqtt_nlb_dns_name
}

if ([string]::IsNullOrWhiteSpace($MqttHost)) {
    Write-Host "Set -MqttHost or use -FromTerraform after terraform apply."
    exit 1
}

python -m pip install -q -r loadtest/requirements.txt

$pyArgs = @(
    "loadtest/durability_test.py",
    "--host", $MqttHost,
    "--count", "$Count",
    "--rate", "$Rate",
    "--qos", "$Qos",
    "--mode", $Mode
)

if ($OnLoadGenerator) {
    $lgId = terraform output -raw load_generator_instance_id 2>$null
    if (-not $lgId) {
        Write-Host "enable_load_generator=true required in terraform.tfvars"
        exit 1
    }
    Write-Host "Deploying scripts to load generator $lgId ..."
    & "$PSScriptRoot/deploy_validation_bundle.ps1" -InstanceId $lgId -Region $Region
    $remote = "python3 /opt/emqx-validation/durability_test.py --host $MqttHost --count $Count --rate $Rate --qos $Qos --mode $Mode"
    aws ssm send-command --region $Region --instance-ids $lgId `
        --document-name "AWS-RunShellScript" `
        --parameters "commands=$remote" --output text
    Write-Host "Check output: aws ssm list-command-invocations --command-id <id> --details"
    exit 0
}

python @pyArgs
exit $LASTEXITCODE
