# Copy validation Python scripts to load-generator EC2 via SSM.
param(
    [string]$InstanceId = "",
    [string]$Region = "ap-south-1"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

if ([string]::IsNullOrWhiteSpace($InstanceId)) {
    $InstanceId = terraform output -raw load_generator_instance_id
}

$staging = Join-Path $env:TEMP "emqx-validation-bundle"
if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Path $staging | Out-Null
Copy-Item loadtest/durability_test.py, loadtest/resilience_test.py, loadtest/requirements.txt -Destination $staging

$zip = Join-Path $env:TEMP "emqx-validation.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path "$staging\*" -DestinationPath $zip

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zip))
$chunkSize = 4000
$chunks = @()
for ($i = 0; $i -lt $b64.Length; $i += $chunkSize) {
    $len = [Math]::Min($chunkSize, $b64.Length - $i)
    $chunks += $b64.Substring($i, $len)
}

$cmds = @(
    "rm -rf /tmp/emqx-validation.zip /opt/emqx-validation/*.py",
    "mkdir -p /opt/emqx-validation"
)
$i = 0
foreach ($c in $chunks) {
    $cmds += "echo '$c' >> /tmp/emqx-validation.b64"
    $i++
}
$cmds += @(
    "base64 -d /tmp/emqx-validation.b64 > /tmp/emqx-validation.zip",
    "cd /opt/emqx-validation && unzip -o /tmp/emqx-validation.zip",
    "chmod +x /opt/emqx-validation/*.py",
    "pip3 install -q -r /opt/emqx-validation/requirements.txt",
    "rm -f /tmp/emqx-validation.b64 /tmp/emqx-validation.zip",
    "ls -la /opt/emqx-validation"
)

$params = @{ commands = $cmds }
$json = $params | ConvertTo-Json -Compress
aws ssm send-command --region $Region --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --parameters $json --output json | Write-Host
Write-Host "Deployed to $InstanceId:/opt/emqx-validation"
