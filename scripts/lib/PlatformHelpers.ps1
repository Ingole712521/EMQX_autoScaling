# Cross-platform helpers for PowerShell (Windows PowerShell 5.1, PowerShell Core 7+, macOS, Linux, WSL).

function Test-IsWindowsPlatform {
    if ($null -ne $IsWindows) {
        return [bool]$IsWindows
    }
    return $env:OS -eq "Windows_NT" -and [string]::IsNullOrEmpty($env:WSL_DISTRO_NAME)
}

function Test-IsMacOSPlatform {
    if ($null -ne $IsMacOS) {
        return [bool]$IsMacOS
    }
    return $env:OS -eq "Darwin" -or ($env:OSTYPE -match "darwin")
}

function Test-IsLinuxPlatform {
    if ($null -ne $IsLinux) {
        return [bool]$IsLinux
    }
    if ($env:OS -eq "Windows_NT" -and -not [string]::IsNullOrEmpty($env:WSL_DISTRO_NAME)) {
        return $true
    }
    return $env:OS -eq "Linux" -or ($env:OSTYPE -match "linux")
}

function Join-MultiplePath {
    param([Parameter(Mandatory = $true)][string[]]$Segments)

    $path = $Segments[0]
    for ($i = 1; $i -lt $Segments.Count; $i++) {
        $path = Join-Path $path $Segments[$i]
    }
    return $path
}

function Test-TcpPortOpen {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutMs = 5000
    )

    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return $false
    }

    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connect = $client.BeginConnect($HostName, $Port, $null, $null)
        $connected = $connect.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $connected) {
            return $false
        }
        $client.EndConnect($connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) {
            $client.Dispose()
        }
    }
}

function Test-PythonExecutableWorks {
    param([Parameter(Mandatory = $true)][string]$PythonPath)

    if ($PythonPath -match 'WindowsApps[/\\](python3?\.exe)?$') {
        return $false
    }

    try {
        $output = & $PythonPath -c "import sys; print(sys.version_info[0])" 2>$null
        if ($LASTEXITCODE -ne 0 -and -not $?) {
            return $false
        }
        return "$output" -eq "3"
    }
    catch {
        return $false
    }
}

function Get-PythonExecutable {
    if (Test-IsWindowsPlatform -and (Get-Command py -ErrorAction SilentlyContinue)) {
        $launcherPath = & py -3 -c "import sys; print(sys.executable)" 2>$null
        if ($launcherPath -and (Test-PythonExecutableWorks $launcherPath.Trim())) {
            return $launcherPath.Trim()
        }
    }

    foreach ($name in @("python3", "python")) {
        $commands = @(Get-Command $name -ErrorAction SilentlyContinue)
        foreach ($cmd in $commands) {
            if ($cmd -and (Test-PythonExecutableWorks $cmd.Source)) {
                return $cmd.Source
            }
        }
    }

    return $null
}

function Get-PwshExecutable {
    foreach ($name in @("pwsh", "powershell")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            return $cmd.Source
        }
    }
    return $null
}

function Get-ProjectVenvPython {
    param([string]$ProjectRoot)

    if (Test-IsWindowsPlatform) {
        return Join-MultiplePath @($ProjectRoot, ".venv", "Scripts", "python.exe")
    }
    return Join-MultiplePath @($ProjectRoot, ".venv", "bin", "python")
}

function Initialize-ProjectPython {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot
    )

    $basePython = Get-PythonExecutable
    if (-not $basePython) {
        throw "Python 3 is required. Install python3 (macOS: brew install python; Windows: python.org or winget install Python.Python.3)."
    }

    $venvPython = Get-ProjectVenvPython -ProjectRoot $ProjectRoot
    $venvDir = Join-Path $ProjectRoot ".venv"

    if (-not (Test-Path $venvPython)) {
        Write-Host "Creating Python virtual environment at .venv..."
        & $basePython -m venv $venvDir
        if ($LASTEXITCODE -ne 0 -and -not $?) {
            throw "Failed to create .venv. On Linux install python3-venv; on macOS use python.org or Homebrew Python."
        }
    }

    if (-not (Test-PythonExecutableWorks $venvPython)) {
        throw "Virtual environment at .venv is invalid. Delete .venv and retry."
    }

    return $venvPython
}

function Install-PythonRequirements {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [string]$RequirementsFile = "loadtest/requirements.txt"
    )

    $python = Initialize-ProjectPython -ProjectRoot $ProjectRoot
    $reqPath = Join-MultiplePath (@($ProjectRoot) + ($RequirementsFile -split '/'))
    & $python -m pip install -q -r $reqPath
    if ($LASTEXITCODE -ne 0 -and -not $?) {
        throw "pip install failed for $RequirementsFile"
    }
    return $python
}

function Invoke-ProjectPython {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$PythonArgs
    )

    $python = Initialize-ProjectPython -ProjectRoot $ProjectRoot
    & $python @PythonArgs | ForEach-Object { Write-Host $_ }
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 0 }
    if (-not $?) { $exitCode = 1 }
    return ,$exitCode
}

function ConvertTo-AwsFileUri {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolved = (Resolve-Path $Path).Path -replace '\\', '/'
    return "file://$resolved"
}

function Open-UrlInBrowser {
    param([Parameter(Mandatory = $true)][string]$Url)

    if (Test-IsMacOSPlatform) {
        & open $Url
        return
    }

    if (Test-IsLinuxPlatform) {
        if (Get-Command xdg-open -ErrorAction SilentlyContinue) {
            & xdg-open $Url
        }
        else {
            Write-Host "Open in browser: $Url"
        }
        return
    }

    Start-Process $Url
}

function Get-StagedLoadBashCommand {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectRoot,
        [Parameter(Mandatory = $true)][string]$MqttHost
    )

    $shScript = Join-MultiplePath @($ProjectRoot, "scripts", "run_staged_load_test.sh")
    $escapedRoot = $ProjectRoot -replace "'", "'\\''"
    $escapedHost = $MqttHost -replace "'", "'\\''"
    $escapedSh = $shScript -replace "'", "'\\''"
    $loadStages = "40:180:baseline-heavy,80:300:scale-out-2,120:300:scale-out-3,10:90:scale-in"

    return @(
        "cd '$escapedRoot'"
        "export MQTT_HOST='$escapedHost'"
        "export PUBLISH_INTERVAL='0.001'"
        "export PAYLOAD_SIZE='16384'"
        "export MESSAGES_PER_BURST='10'"
        "export LOAD_STAGES='$loadStages'"
        "export PYTHONUNBUFFERED='1'"
        "bash '$escapedSh'"
    ) -join " && "
}

function Start-LoadTestInNewTerminal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProjectRoot,
        [Parameter(Mandatory = $true)]
        [string]$MqttHost
    )

    $bashCmd = Get-StagedLoadBashCommand -ProjectRoot $ProjectRoot -MqttHost $MqttHost

    if (Test-IsMacOSPlatform) {
        $escapedForOsascript = $bashCmd -replace '\\', '\\\\' -replace '"', '\"'
        & osascript -e "tell application `"Terminal`" to do script `"$escapedForOsascript`""
        Write-Host "Load test started in a new Terminal window." -ForegroundColor Green
        return
    }

    if (Test-IsLinuxPlatform) {
        if (Get-Command gnome-terminal -ErrorAction SilentlyContinue) {
            & gnome-terminal -- bash -lc "$bashCmd; exec bash"
            Write-Host "Load test started in a new terminal." -ForegroundColor Green
            return
        }
        if (Get-Command x-terminal-emulator -ErrorAction SilentlyContinue) {
            & x-terminal-emulator -e bash -lc "$bashCmd; exec bash"
            Write-Host "Load test started in a new terminal." -ForegroundColor Green
            return
        }
        if (Get-Command konsole -ErrorAction SilentlyContinue) {
            & konsole -e bash -lc "$bashCmd; exec bash"
            Write-Host "Load test started in a new terminal." -ForegroundColor Green
            return
        }
    }

    $bash = Get-Command bash -ErrorAction SilentlyContinue
    if ($bash) {
        Start-Process $bash.Source -ArgumentList @("-lc", "$bashCmd; exec bash")
        Write-Host "Load test started in a new terminal (bash)." -ForegroundColor Green
        return
    }

    $loadScript = Join-MultiplePath @($ProjectRoot, "scripts", "run_staged_load_test.ps1")
    $shell = Get-PwshExecutable
    if (-not $shell) {
        Write-Host "Could not open a new terminal. Run manually:" -ForegroundColor Yellow
        Write-Host "  pwsh -File ./scripts/run_staged_load_test.ps1 -MqttHost '$MqttHost'" -ForegroundColor Yellow
        return
    }

    $isLegacyWindows = $shell -match "WindowsPowerShell[/\\]v1\.0[/\\]powershell\.exe$"
    $command = @"
Set-Location '$escapedRoot'
`$env:MQTT_HOST = '$MqttHost'
`$env:PYTHONUNBUFFERED = '1'
`$env:PUBLISH_INTERVAL = '0.001'
`$env:PAYLOAD_SIZE = '16384'
`$env:MESSAGES_PER_BURST = '10'
`$env:LOAD_STAGES = '40:180:baseline-heavy,80:300:scale-out-2,120:300:scale-out-3,10:90:scale-in'
& '$loadScript' -MqttHost '$MqttHost'
"@
    $shellArgs = @("-NoExit", "-Command", $command)
    if ($isLegacyWindows) {
        $shellArgs = @("-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $command)
    }
    Start-Process $shell -ArgumentList $shellArgs
    Write-Host "Load test started in a new PowerShell window." -ForegroundColor Green
}
