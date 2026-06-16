param(
    [string]$Region = "ap-south-1",
    [string]$ProjectName = "emqx-prod"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path (Join-Path $PSScriptRoot "lib") "PlatformHelpers.ps1")

$coreIp = terraform output -raw emqx_core_public_ip
$mqttHost = terraform output -raw mqtt_nlb_dns_name
$dashboardUrl = terraform output -raw emqx_dashboard_url

Write-Host ""
Write-Host "=== EMQX Deployment Verification ===" -ForegroundColor Cyan
Write-Host "Dashboard: $dashboardUrl"
Write-Host "MQTT NLB:  tcp://${mqttHost}:1883"
Write-Host ""

$dashboardOpen = Test-TcpPortOpen -HostName $coreIp -Port 18083
$mqttOpen = Test-TcpPortOpen -HostName $mqttHost -Port 1883

Write-Host ("Dashboard 18083: {0}" -f $(if ($dashboardOpen) { "PASS" } else { "FAIL" }))
Write-Host ("MQTT NLB 1883:   {0}" -f $(if ($mqttOpen) { "PASS" } else { "FAIL" }))

if ($mqttOpen -and (Get-PythonExecutable)) {
    Install-PythonRequirements -ProjectRoot $Root | Out-Null
    Invoke-ProjectPython -ProjectRoot $Root scripts/mqtt_probe.py --host $mqttHost
}

if (Get-Command aws -ErrorAction SilentlyContinue) {
    Write-Host ""
    Write-Host "=== NLB target health ===" -ForegroundColor Cyan
    $arn = aws elbv2 describe-target-groups --region $Region --names "${ProjectName}-mqtt-tg" `
        --query "TargetGroups[0].TargetGroupArn" --output text 2>$null
    if ($arn -and $arn -ne "None") {
        aws elbv2 describe-target-health --region $Region --target-group-arn $arn `
            --query "TargetHealthDescriptions[*].[Target.Id,TargetHealth.State,TargetHealth.Reason]" --output table
        $states = aws elbv2 describe-target-health --region $Region --target-group-arn $arn `
            --query "TargetHealthDescriptions[*].TargetHealth.State" --output text 2>$null
        if ($states -match "initial|draining") {
            Write-Host ""
            Write-Host "Note: MQTT via NLB fails until a target is 'healthy' (bootstrap ~5-15 min)." -ForegroundColor Yellow
            Write-Host "      Watch: ./scripts/watch_bootstrap.ps1 (or ./scripts/watch_bootstrap.sh)" -ForegroundColor Yellow
        }
        if ($states -match "unhealthy") {
            Write-Host ""
            Write-Host "If unhealthy >10 min, check replicant: sudo tail -50 /var/log/emqx-bootstrap.log" -ForegroundColor Yellow
            Write-Host "      OSS 5.8+ must NOT set EMQX_NODE__ROLE=replicant (fixed in userdata)." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Full proof: ./scripts/prove_emqx_cluster.ps1 (or ./scripts/prove_emqx_cluster.sh)" -ForegroundColor Cyan

if ($dashboardOpen -and $mqttOpen) { exit 0 }
exit 1
