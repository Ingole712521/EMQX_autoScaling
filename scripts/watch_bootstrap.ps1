param(
    [string]$CoreIp = "",
    [string]$MqttHost = "",
    [string]$Region = "ap-south-1",
    [string]$ProjectName = "emqx-prod",
    [int]$TimeoutSec = 900,
    [int]$IntervalSec = 20
)

$ErrorActionPreference = "Continue"
. (Join-Path (Join-Path $PSScriptRoot "lib") "PlatformHelpers.ps1")

function Get-CoreInstanceId {
    param(
        [string]$Project,
        [string]$AwsRegion,
        [string]$CorePublicIp = ""
    )

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        return $null
    }

    $instanceId = aws ec2 describe-instances `
        --region $AwsRegion `
        --filters "Name=tag:Name,Values=${Project}-core-1" "Name=instance-state-name,Values=running" `
        --query "Reservations[0].Instances[0].InstanceId" `
        --output text 2>$null

    if (-not [string]::IsNullOrWhiteSpace($instanceId) -and $instanceId -ne "None") {
        return $instanceId
    }

    if (-not [string]::IsNullOrWhiteSpace($CorePublicIp)) {
        return aws ec2 describe-instances `
            --region $AwsRegion `
            --filters "Name=ip-address,Values=$CorePublicIp" "Name=instance-state-name,Values=running" `
            --query "Reservations[0].Instances[0].InstanceId" `
            --output text 2>$null
    }

    return $null
}

function Get-BootstrapLogTail {
    param(
        [string]$InstanceId,
        [string]$AwsRegion
    )

    if ([string]::IsNullOrWhiteSpace($InstanceId) -or $InstanceId -eq "None") {
        return @("Instance ID not available yet.")
    }

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        return @("AWS CLI not available for live log fetch.")
    }

    $ping = aws ssm describe-instance-information `
        --region $AwsRegion `
        --filters "Key=InstanceIds,Values=$InstanceId" `
        --query "InstanceInformationList[0].PingStatus" `
        --output text 2>$null

    if ($ping -ne "Online") {
        return @("SSM agent not online yet (status: $ping). Instance is still booting.")
    }

    $commandId = aws ssm send-command `
        --region $AwsRegion `
        --document-name "AWS-RunShellScript" `
        --instance-ids $InstanceId `
        --parameters "commands=tail -n 12 /var/log/emqx-bootstrap.log 2>/dev/null || echo 'Bootstrap log not created yet.'" `
        --query "Command.CommandId" `
        --output text 2>$null

    if ([string]::IsNullOrWhiteSpace($commandId)) {
        return @("Could not fetch bootstrap log via SSM.")
    }

    Start-Sleep -Seconds 3

    $output = aws ssm get-command-invocation `
        --region $AwsRegion `
        --command-id $commandId `
        --instance-id $InstanceId `
        --query "StandardOutputContent" `
        --output text 2>$null

    if ([string]::IsNullOrWhiteSpace($output)) {
        return @("Bootstrap log is empty or not ready yet.")
    }

    return ($output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-TargetHealthSummary {
    param(
        [string]$Project,
        [string]$AwsRegion
    )

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        return "Target health: AWS CLI not available"
    }

    $tgArn = aws elbv2 describe-target-groups `
        --region $AwsRegion `
        --names "${Project}-mqtt-tg" `
        --query "TargetGroups[0].TargetGroupArn" `
        --output text 2>$null

    if ([string]::IsNullOrWhiteSpace($tgArn) -or $tgArn -eq "None") {
        return "Target health: target group not found"
    }

    $health = aws elbv2 describe-target-health `
        --region $AwsRegion `
        --target-group-arn $tgArn `
        --query "TargetHealthDescriptions[].{Id:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" `
        --output json 2>$null

    if ([string]::IsNullOrWhiteSpace($health)) {
        return "Target health: unavailable"
    }

    $items = $health | ConvertFrom-Json
    $parts = @()
    foreach ($item in $items) {
        $parts += "$($item.Id)=$($item.State)"
    }
    return "NLB targets: " + ($parts -join ", ")
}

function Test-PortOpen {
    param(
        [string]$HostName,
        [int]$Port
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $false
    }

    return Test-TcpPortOpen -HostName $HostName -Port $Port
}

if ([string]::IsNullOrWhiteSpace($CoreIp)) {
    $CoreIp = terraform output -raw emqx_core_public_ip 2>$null
}

if ([string]::IsNullOrWhiteSpace($MqttHost)) {
    foreach ($name in @("mqtt_nlb_dns_name", "nlb_dns_name")) {
        $value = terraform output -raw $name 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($value)) {
            $MqttHost = $value
            break
        }
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host " EMQX BOOTSTRAP WATCHER" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Terraform 'Apply complete' only means AWS resources exist."
Write-Host "EMQX software install on EC2 usually takes 5-15 minutes."
Write-Host ""
Write-Host "Dashboard target: http://${CoreIp}:18083"
Write-Host "MQTT target:      tcp://${MqttHost}:1883"
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$attempt = 0

while ((Get-Date) -lt $deadline) {
    $attempt++
    $elapsed = [int]($TimeoutSec - ($deadline - (Get-Date)).TotalSeconds)
    $instanceId = Get-CoreInstanceId -Project $ProjectName -Region $Region -CorePublicIp $CoreIp

    Write-Host ("[{0}s] Check #{1}" -f $elapsed, $attempt) -ForegroundColor Cyan
    Write-Host "  Core instance: $instanceId"

    $targetHealth = Get-TargetHealthSummary -Project $ProjectName -Region $Region
    Write-Host "  $targetHealth"

    $dashboardOpen = Test-PortOpen -HostName $CoreIp -Port 18083
    $mqttOpen = Test-PortOpen -HostName $MqttHost -Port 1883
    Write-Host ("  Ports: dashboard(18083)={0}, mqtt(1883)={1}" -f $(if ($dashboardOpen) { "OPEN" } else { "closed" }), $(if ($mqttOpen) { "OPEN" } else { "closed" }))

    Write-Host "  Latest bootstrap log (core node):"
    $logLines = Get-BootstrapLogTail -InstanceId $instanceId -Region $Region
    foreach ($line in $logLines) {
        Write-Host "    $line"
    }
    Write-Host ""

    if ($dashboardOpen -and $mqttOpen) {
        Write-Host "========================================" -ForegroundColor Green
        Write-Host " EMQX IS READY" -ForegroundColor Green
        Write-Host "========================================" -ForegroundColor Green
        Write-Host "Dashboard: http://${CoreIp}:18083"
        Write-Host "MQTT NLB:  tcp://${MqttHost}:1883"
        if ($instanceId -and $instanceId -ne "None") {
            Write-Host "Core instance: $instanceId"
        }
        Write-Host "Login: use emqx_dashboard_username / emqx_dashboard_password from terraform.tfvars"
        return $true
    }

    Start-Sleep -Seconds $IntervalSec
}

Write-Host "Timed out waiting for EMQX to become ready." -ForegroundColor Red
Write-Host "Check AWS EC2 -> Instances -> emqx-prod-core-1 -> Connect (SSM)"
Write-Host "Then run: sudo tail -f /var/log/emqx-bootstrap.log"
return $false
