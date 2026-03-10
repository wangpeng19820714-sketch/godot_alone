param(
    [ValidateSet("editor", "template_release", "template_debug", "template_unsafe")]
    [string]$Target = "template_release",
    [ValidateSet("", "windows", "linuxbsd", "macos", "android", "ios", "web", "visionos")]
    [string]$Platform = "",
    [int]$Jobs = 0,
    [switch]$Clean,
    [switch]$Export,
    [string]$ProjectPath = "",
    [string]$ExportPreset = "",
    [string]$ExportOutput = "",
    [string]$SConsPath = "",
    [string]$PipIndex = "",
    [string[]]$SConsOptions,
    [switch]$AutoInstallSCons
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
Set-Location $repoRoot

if (-not $Platform) {
    if ($IsWindows -or $env:OS -eq "Windows_NT") {
        $Platform = "windows"
    } elseif ($IsLinux) {
        $Platform = "linuxbsd"
    } elseif ($IsMacOS) {
        $Platform = "macos"
    } else {
        throw "未识别当前操作系统，请手动指定 -Platform 参数。"
    }
}

if ($Jobs -le 0) {
    $Jobs = [Environment]::ProcessorCount
}

if ($IsWindows -or $env:OS -eq "Windows_NT") {
    $cmdExe = Join-Path $env:windir "System32\\cmd.exe"
    if (Test-Path $cmdExe) {
        $env:COMSPEC = $cmdExe
        $env:SHELL = $cmdExe
    }
}

if (-not (Test-Path -PathType Container "bin")) {
    New-Item -ItemType Directory -Path "bin" | Out-Null
}
if (-not (Test-Path -PathType Container (Join-Path $repoRoot "build\logs"))) {
    New-Item -ItemType Directory -Path "build\logs" -Force | Out-Null
}

$logFile = Join-Path $repoRoot ("build\logs\build-" + $Platform + "-" + $Target + "-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$script:SConsPythonPath = ""
$buildDeps = Join-Path $repoRoot "build\\deps"
$buildPyDeps = Join-Path $repoRoot "build\\pydeps"
if (-not (Test-Path -PathType Container $buildDeps)) {
    New-Item -ItemType Directory -Path $buildDeps -Force | Out-Null
}
if (-not (Test-Path -PathType Container $buildPyDeps)) {
    New-Item -ItemType Directory -Path $buildPyDeps -Force | Out-Null
}

function Get-PythonCandidates {
    $candidates = @()
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $candidates += $python.Source
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $candidates += $py.Source
    }
    return ($candidates | Select-Object -Unique)
}

function Get-SConsWheel {
    return Get-ChildItem -Path $buildDeps -Filter "scons-*.whl" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Install-SConsFromWheel {
    param([string[]]$PythonCandidates, [string]$WheelPath)

    foreach ($pythonExe in $PythonCandidates) {
        Write-Host "安装 SCons 到本地路径: $buildPyDeps"
        Write-Host "  Python: $pythonExe"
        & $pythonExe -m pip install --upgrade --target $buildPyDeps $WheelPath
        if ($LASTEXITCODE -eq 0) {
            if (Test-Path (Join-Path $buildPyDeps "bin\\scons.exe")) {
                return $true
            }
        }
    }
    return $false
}

function Download-SConsWheel {
    param([string[]]$PythonCandidates)

    foreach ($pythonExe in $PythonCandidates) {
        Write-Host "尝试使用 $pythonExe 从 PyPI 下载 scons"
        $downloadArgs = @("-m", "pip", "download", "--no-deps", "--only-binary=:all:", "-d", $buildDeps, "scons")
        if ($PipIndex) {
            $downloadArgs += @("-i", $PipIndex)
        }
        & $pythonExe @downloadArgs
        if ($LASTEXITCODE -eq 0) {
            return $true
        }
    }
    return $false
}

function Ensure-LocalSCons {
    if (Test-Path (Join-Path $buildPyDeps "bin\\scons.exe")) {
        return $true
    }

    $pythonCandidates = Get-PythonCandidates
    if ($pythonCandidates.Count -eq 0) {
        return $false
    }

    $wheel = Get-SConsWheel
    if (-not $wheel -and $AutoInstallSCons) {
        Write-Host "未检测到本地 SCons wheel，尝试联网下载..."
        if (-not (Download-SConsWheel -PythonCandidates $pythonCandidates)) {
            return $false
        }
        $wheel = Get-SConsWheel
    }

    if ($wheel) {
        return Install-SConsFromWheel -PythonCandidates $pythonCandidates -WheelPath $wheel.FullName
    }
    return $false
}

function Resolve-SConsCommand {
    $null = Ensure-LocalSCons
    if (Test-Path (Join-Path $buildPyDeps "bin\\scons.exe")) {
        $script:SConsPythonPath = $buildPyDeps
        return ,(Join-Path $buildPyDeps "bin\\scons.exe")
    }

    if ($SConsPath) {
        if (Test-Path $SConsPath) {
            $item = Get-Item $SConsPath
            if (-not $item.PSIsContainer) {
                if ($item.Name -ieq "scons.py" -and (Test-Path (Join-Path $buildPyDeps "SCons\\__init__.py"))) {
                    $script:SConsPythonPath = $buildPyDeps
                }
                return ,$item.FullName
            }
            throw "参数 -SConsPath 指向了目录，请改为可执行文件路径（如 ...\Scripts\scons.py 或 scons.exe）。"
        }
        throw "参数 -SConsPath 指定路径不存在: $SConsPath"
    }

    $scons = Get-Command scons -ErrorAction SilentlyContinue
    if ($scons) {
        return ,("scons")
    }

    $pythonCandidates = @()
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $pythonCandidates += ,$python.Source
    }
    $py = Get-Command py -ErrorAction SilentlyContinue
    if ($py) {
        $pythonCandidates += ,$py.Source
    }
    if ($pythonCandidates.Count -eq 0) {
            throw "未找到 scons，也未找到 python。请先安装 Python 并配置到 PATH。"
    }

    function Test-SConsModule {
        param([string]$PythonExe)
        $probe = & $PythonExe -m SCons --version 2>&1
        return ($LASTEXITCODE -eq 0)
    }

    foreach ($pythonExe in $pythonCandidates) {
        if (Test-SConsModule $pythonExe) {
            $script:SConsPythonPath = ""
            return @($pythonExe, "-m", "SCons")
        }

        $pythonDir = Split-Path $pythonExe -Parent
        $sconsBin = Join-Path $pythonDir "Scripts\\scons.py"
        if (Test-Path $sconsBin) {
            $script:SConsPythonPath = $pythonDir
            return @($pythonExe, $sconsBin)
        }
        $sconsExe = Join-Path $pythonDir "Scripts\\scons.exe"
        if (Test-Path $sconsExe) {
            $script:SConsPythonPath = $pythonDir
            return ,$sconsExe
        }
    }

    if ($AutoInstallSCons) {
        Write-Host "未检测到 SCons，尝试自动安装..."
        $pipInstallArgs = @("-m", "pip", "install", "--user", "scons")
        if ($PipIndex) {
            $pipInstallArgs += @("-i", $PipIndex)
        }
        $installed = $false
        foreach ($pythonExe in $pythonCandidates) {
            Write-Host "尝试使用: $pythonExe 安装 SCons"
            & $pythonExe @pipInstallArgs
            if ($LASTEXITCODE -eq 0) {
                $installed = $true
                break
            }
        }
        if (-not $installed) {
            throw @"
自动安装 SCons 失败。可尝试按以下任一命令执行：
  python -m pip install scons
  py -m pip install scons
  (若在受限网络，添加 -i https://pypi.tuna.tsinghua.edu.cn/simple
  如 python -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple scons)
"@
        }
        foreach ($pythonExe in $pythonCandidates) {
            if (Test-SConsModule $pythonExe) {
                $script:SConsPythonPath = ""
                return @($pythonExe, "-m", "SCons")
            }
            $pythonDir = Split-Path $pythonExe -Parent
            $sconsBin = Join-Path $pythonDir "Scripts\\scons.py"
            if (Test-Path $sconsBin) {
                $script:SConsPythonPath = $pythonDir
                return @($pythonExe, $sconsBin)
            }
            $sconsExe = Join-Path $pythonDir "Scripts\\scons.exe"
            if (Test-Path $sconsExe) {
                $script:SConsPythonPath = $pythonDir
                return ,$sconsExe
            }
        }
    }

    $candidateText = ($pythonCandidates -join ", ")
    throw @"
未检测到可用的 SCons。

可选处理方式之一（推荐）：
  python -m pip install scons
或
  py -m pip install scons

 当前脚本检测到的 Python 路径：
  $candidateText

安装后可直接重试:
  pwsh -File build/build.ps1
"@
}

function Invoke-SCons {
    param([string[]]$SConsArgs)

    $cmd = Resolve-SConsCommand
    $cmd = @($cmd)
    $program = [string]$cmd[0]
    $baseArgs = @()
    if ($cmd.Length -gt 1) {
        $baseArgs = $cmd[1..($cmd.Length - 1)]
    }
    $allArgs = @() + $baseArgs + $SConsArgs

    $oldPythonPath = $env:PYTHONPATH
    if ($script:SConsPythonPath) {
        if ([string]::IsNullOrWhiteSpace($oldPythonPath)) {
            $env:PYTHONPATH = $script:SConsPythonPath
        } else {
            $env:PYTHONPATH = $script:SConsPythonPath + ";" + $oldPythonPath
        }
    }

    Write-Host "执行: $program $($allArgs -join ' ')"
    Write-Host "日志: $logFile"

    try {
        & $program @allArgs 2>&1 | Tee-Object -FilePath $logFile
        if ($LASTEXITCODE -ne 0) {
            $logText = ""
            if (Test-Path $logFile) {
                $logText = Get-Content -Path $logFile -Tail 40 -Raw
            }
            if ($logText -like "*C:\\WINDOWS\\System32\\cmd.exe: Permission denied*") {
                throw "SCons 构建失败，检测到 cmd.exe 创建失败。请优先重试：pwsh -NoProfile -File build/build.ps1 -Jobs 4 -SConsOptions d3d12=no"
            }
            throw "SCons 构建失败，终止码=$LASTEXITCODE。请查看日志: $logFile"
        }
    } finally {
        if ($script:SConsPythonPath) {
            if ($oldPythonPath -eq $null -or $oldPythonPath -eq "") {
                Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
            } else {
                $env:PYTHONPATH = $oldPythonPath
            }
        }
    }
}

function Get-BuiltBinary {
    param([string]$TargetPlatform, [string]$TargetKind)

    $binDir = Join-Path $repoRoot "bin"
    $patterns = @(
        "godot.$TargetPlatform.$TargetKind*",
        "godot.windows.opt.tools.$TargetKind*",
        "godot.$TargetPlatform.opt.tools.$TargetKind*"
    )
    foreach ($pattern in $patterns) {
        $candidate = Get-ChildItem $binDir -Filter $pattern -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "\.(exe|x86_64|arm64)$" -or $IsMacOS } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($candidate) {
            return $candidate.FullName
        }
    }
    return $null
}

function Ensure-ProjectInputs {
    param([string]$Path, [string]$Preset, [string]$Output)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "项目路径不存在: $Path"
    }
    if (-not $Preset) {
        throw "导出模式已开启，但未提供 -ExportPreset。"
    }
    if (-not $Output) {
        throw "导出模式已开启，但未提供 -ExportOutput。"
    }
    $outputDir = Split-Path $Output -Parent
    if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -PathType Container $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }
}

Write-Host "检测到平台: $Platform"
Write-Host "目标: $Target"
Write-Host "并行核心数: $Jobs"

$buildArgs = @("platform=$Platform", "target=$Target", "-j", $Jobs)
if ($SConsOptions) {
    $buildArgs += $SConsOptions
}
if ($Clean) {
    Write-Host "先清理旧编译文件..."
    Invoke-SCons -SConsArgs @($buildArgs + @("-c"))
}

Invoke-SCons -SConsArgs $buildArgs

$binary = Get-BuiltBinary -TargetPlatform $Platform -TargetKind $Target
if (-not $binary) {
    Write-Warning "未能自动定位到可执行文件，常见路径是 bin\\godot.$Platform.$Target.*"
} else {
    Write-Host "构建产物: $binary"
}

if ($Export) {
    Ensure-ProjectInputs -Path $ProjectPath -Preset $ExportPreset -Output $ExportOutput
    if (-not $binary) {
        throw "导出需要可执行文件，但未找到。"
    }

    Write-Host "开始导出项目: $ProjectPath"
    Write-Host "导出预设: $ExportPreset"
    Write-Host "输出路径: $ExportOutput"

    & $binary --headless --path $ProjectPath --export-release $ExportPreset $ExportOutput
    if ($LASTEXITCODE -ne 0) {
        throw "导出失败，终止码=$LASTEXITCODE。"
    }
    Write-Host "导出完成: $ExportOutput"
}

Write-Host "构建完成。"
