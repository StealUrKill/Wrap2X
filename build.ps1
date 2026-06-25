$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

function Initialize-CargoEnv {
    if (Get-Command cargo -ErrorAction SilentlyContinue) { return }
    foreach ($var in 'CARGO_HOME', 'RUSTUP_HOME') {
        foreach ($scope in 'Machine', 'User') {
            $val = [Environment]::GetEnvironmentVariable($var, $scope)
            if ($val) { Set-Item -Path "Env:$var" -Value $val }
        }
    }
    $machPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH = (@($env:PATH, $machPath, $userPath) -join ';')

    if (Get-Command cargo -ErrorAction SilentlyContinue) { return }

    $candidates = @()
    if ($env:CARGO_HOME) { $candidates += (Join-Path $env:CARGO_HOME 'bin') }
    $candidates += (Join-Path $env:USERPROFILE '.cargo\bin')
    foreach ($c in $candidates) {
        if (Test-Path (Join-Path $c 'cargo.exe')) { $env:PATH = "$c;$env:PATH"; return }
    }
}

Initialize-CargoEnv

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "  ERROR: 'cargo' was not found." -ForegroundColor Red
    Write-Host "  Make sure Rust is installed and the PATH is updated." -ForegroundColor Red
    Write-Host "  Press any key..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

$ConfigFile = "packer.toml"

$script:BuildTypes  = @("Full Build", "Pack Only", "Compile Only")
$script:Profiles    = @("Release", "Dev")
$script:CleanModes  = @("Build", "Clean + Build")

$script:BuildTypeIdx  = 0
$script:ProfileIdx    = 0
$script:CleanModeIdx  = 0

function Read-Config {
    $config = @{
        name         = "Application"
        entry_point  = "run.bat"
        brotli_level = "11"
        input_dir    = "packer_files"
        output       = "data.bin"
    }
    if (Test-Path $ConfigFile) {
        foreach ($line in Get-Content $ConfigFile) {
            if ($line -match '^\s*(\w+)\s*=\s*"?([^"#]+)"?\s*$') {
                $config[$Matches[1]] = $Matches[2].Trim()
            }
        }
    }
    return $config
}

function Write-Config($config) {
    @(
        "# name: used for output exe name, SmartScreen, and version info"
        "name = `"$($config.name)`""
        ""
        "# entry_point: the exe or bat to run after extraction"
        "entry_point = `"$($config.entry_point)`""
        ""
        "# brotli compression level (0-11, higher = smaller + slower)"
        "brotli_level = $($config.brotli_level)"
        ""
        "# directory containing files to pack"
        "input_dir = `"$($config.input_dir)`""
        ""
        "# output data.bin path"
        "output = `"$($config.output)`""
    ) | Set-Content $ConfigFile -Encoding UTF8
    Write-Host "`n  Config saved to $ConfigFile" -ForegroundColor Green
}

function Show-Config {
    $config = Read-Config
    Write-Host ""
    Write-Host "  Current Configuration" -ForegroundColor Cyan
    Write-Host "  ---------------------" -ForegroundColor DarkCyan
    Write-Host "  Name           : " -NoNewline; Write-Host "$($config.name)" -ForegroundColor White
    Write-Host "  Entry Point    : " -NoNewline; Write-Host "$($config.entry_point)" -ForegroundColor White
    Write-Host "  Brotli Level   : " -NoNewline; Write-Host "$($config.brotli_level)" -ForegroundColor White
    Write-Host "  Input Directory: " -NoNewline; Write-Host "$($config.input_dir)" -ForegroundColor White
    Write-Host "  Output File    : " -NoNewline; Write-Host "$($config.output)" -ForegroundColor White

    $inputDir = $config.input_dir
    if (Test-Path $inputDir) {
        $files = Get-ChildItem -Path $inputDir -Recurse -File
        $totalSize = ($files | Measure-Object -Property Length -Sum).Sum
        if (-not $totalSize) { $totalSize = 0 }
        Write-Host ""
        Write-Host "  Files in ${inputDir}: $($files.Count) ($([math]::Round($totalSize / 1KB, 1)) KB)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
        Write-Host "  WARNING: Input directory '$inputDir' not found!" -ForegroundColor Yellow
    }
    Write-Host ""
}

function Edit-Config {
    $config = Read-Config

    Write-Host ""
    Write-Host "  Edit Configuration " -ForegroundColor Cyan -NoNewline
    Write-Host "(Enter to keep current)" -ForegroundColor DarkGray
    Write-Host ""

    $val = Read-Host "  Name [$($config.name)]"
    if ($val) { $config.name = $val }

    $val = Read-Host "  Entry point [$($config.entry_point)]"
    if ($val) { $config.entry_point = $val }

    $val = Read-Host "  Brotli level 0-11 [$($config.brotli_level)]"
    if ($val) {
        $lvl = [int]$val
        if ($lvl -ge 0 -and $lvl -le 11) { $config.brotli_level = "$lvl" }
        else { Write-Host "  Invalid level, keeping $($config.brotli_level)" -ForegroundColor Yellow }
    }

    $val = Read-Host "  Input directory [$($config.input_dir)]"
    if ($val) { $config.input_dir = $val }

    $val = Read-Host "  Output file [$($config.output)]"
    if ($val) { $config.output = $val }

    Write-Config $config
}

function Get-ProfileFlag {
    if ($script:Profiles[$script:ProfileIdx] -eq "Release") { return "--release" }
    return $null
}

function Get-ProfileDir {
    if ($script:Profiles[$script:ProfileIdx] -eq "Release") { return "release" }
    return "debug"
}

function Invoke-Pack {
    Write-Host ""
    Write-Host "  Packing files into data.bin..." -ForegroundColor Cyan
    Write-Host ""

    $ErrorActionPreference = "Continue"
    & cargo run --bin pack 2>&1 | ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = "Stop"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n  Pack FAILED!" -ForegroundColor Red
        return $false
    }

    Write-Host "`n  Pack complete." -ForegroundColor Green
    return $true
}

function Invoke-BuildStub {
    $profileName = $script:Profiles[$script:ProfileIdx]
    $profileFlag = Get-ProfileFlag
    $profileDir  = Get-ProfileDir

    Write-Host ""
    Write-Host "  Building stub exe ($profileName)..." -ForegroundColor Cyan
    Write-Host ""

    $cargoArgs = @("build", "--bin", "stub")
    if ($profileFlag) { $cargoArgs += $profileFlag }

    $ErrorActionPreference = "Continue"
    & cargo @cargoArgs 2>&1 | ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = "Stop"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "`n  Build FAILED!" -ForegroundColor Red
        return $false
    }

    $exePath = "target\$profileDir\stub.exe"
    if (Test-Path $exePath) {
        $config = Read-Config
        $outName = "$($config.name).exe"
        $outPath = Join-Path $ScriptDir $outName
        Copy-Item $exePath $outPath -Force

        $size = (Get-Item $outPath).Length
        $sizeStr = if ($size -ge 1MB) { "$([math]::Round($size / 1MB, 2)) MB" }
                   elseif ($size -ge 1KB) { "$([math]::Round($size / 1KB, 1)) KB" }
                   else { "$size B" }
        Write-Host "`n  Built: $outPath ($sizeStr)" -ForegroundColor Green
    }
    return $true
}

function Invoke-Clean {
    Write-Host ""
    Write-Host "  Cleaning..." -ForegroundColor Yellow
    $ErrorActionPreference = "Continue"
    & cargo clean 2>&1 | Out-Null
    $ErrorActionPreference = "Stop"
    if (Test-Path "data.bin") { Remove-Item "data.bin" -Force }
    Write-Host "  Clean done." -ForegroundColor Green
}

function Invoke-Execute {
    $buildType = $script:BuildTypes[$script:BuildTypeIdx]
    $cleanMode = $script:CleanModes[$script:CleanModeIdx]

    if ($cleanMode -eq "Clean + Build") { Invoke-Clean }

    switch ($buildType) {
        "Full Build" {
            $ok = Invoke-Pack
            if ($ok) { Invoke-BuildStub | Out-Null }
        }
        "Pack Only" {
            Invoke-Pack | Out-Null
        }
        "Compile Only" {
            Invoke-BuildStub | Out-Null
        }
    }
}

function Invoke-ResetConfig {
    $config = Read-Config
    $config.name = "Application"
    $config.entry_point = "run.exe"
    Write-Config $config
    Write-Host ""
    Write-Host "  Config reset (name/entry_point) to defaults." -ForegroundColor Yellow
}

function Write-Option($key, $label, $values, $activeIdx) {
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "$key" -NoNewline -ForegroundColor Yellow
    Write-Host "] " -NoNewline -ForegroundColor DarkGray
    Write-Host "$label  " -NoNewline -ForegroundColor Gray

    for ($i = 0; $i -lt $values.Count; $i++) {
        if ($i -eq $activeIdx) {
            Write-Host " $($values[$i]) " -NoNewline -ForegroundColor White -BackgroundColor DarkCyan
        } else {
            Write-Host " $($values[$i]) " -NoNewline -ForegroundColor DarkGray
        }
        if ($i -lt $values.Count - 1) { Write-Host "/" -NoNewline -ForegroundColor DarkGray }
    }
    Write-Host ""
}

function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================" -ForegroundColor DarkCyan
    Write-Host "           EXE Packer Build Menu" -ForegroundColor Cyan
    Write-Host "  ============================================" -ForegroundColor DarkCyan
    Write-Host ""

    Write-Option "1" "Build Type: " $script:BuildTypes  $script:BuildTypeIdx
    Write-Option "2" "Profile:    " $script:Profiles     $script:ProfileIdx
    Write-Option "3" "Clean:      " $script:CleanModes   $script:CleanModeIdx

    Write-Host ""
    Write-Host "  ---" -ForegroundColor DarkGray
    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "Enter" -NoNewline -ForegroundColor Green
    Write-Host "]  " -NoNewline -ForegroundColor DarkGray
    Write-Host "GO" -ForegroundColor Green

    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "C" -NoNewline -ForegroundColor Yellow
    Write-Host "]      " -NoNewline -ForegroundColor DarkGray
    Write-Host "Show Config" -ForegroundColor Gray

    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "E" -NoNewline -ForegroundColor Yellow
    Write-Host "]      " -NoNewline -ForegroundColor DarkGray
    Write-Host "Edit Config" -ForegroundColor Gray

    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "F" -NoNewline -ForegroundColor Yellow
    Write-Host "]      " -NoNewline -ForegroundColor DarkGray
    Write-Host "Open packer_files" -ForegroundColor Gray

    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "R" -NoNewline -ForegroundColor Yellow
    Write-Host "]      " -NoNewline -ForegroundColor DarkGray
    Write-Host "Reset Config (name/entry_point)" -ForegroundColor Gray

    Write-Host "  [" -NoNewline -ForegroundColor DarkGray
    Write-Host "Q" -NoNewline -ForegroundColor Red
    Write-Host "]      " -NoNewline -ForegroundColor DarkGray
    Write-Host "Quit" -ForegroundColor DarkGray

    Write-Host ""
}

while ($true) {
    Show-Menu

    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

    switch ($key.VirtualKeyCode) {
        13 {
            Invoke-Execute
            Write-Host ""
            Write-Host "  Press any key..." -ForegroundColor DarkGray
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        49 {
            $script:BuildTypeIdx = ($script:BuildTypeIdx + 1) % $script:BuildTypes.Count
        }
        50 {
            $script:ProfileIdx = ($script:ProfileIdx + 1) % $script:Profiles.Count
        }
        51 {
            $script:CleanModeIdx = ($script:CleanModeIdx + 1) % $script:CleanModes.Count
        }
        default {
            $ch = [char]::ToLower($key.Character)
            switch ($ch) {
                'c' { Show-Config; Write-Host "  Press any key..." -ForegroundColor DarkGray; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
                'e' { Edit-Config; Write-Host "  Press any key..." -ForegroundColor DarkGray; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
                'r' { Invoke-ResetConfig; Write-Host "  Press any key..." -ForegroundColor DarkGray; $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") }
                'f' {
                    $config = Read-Config; $dir = $config.input_dir
                    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
                    Start-Process explorer.exe $dir
                }
                'q' { Write-Host ""; exit 0 }
            }
        }
    }
}
