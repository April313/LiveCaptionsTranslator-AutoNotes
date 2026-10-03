<#
  实时翻译 + 自动笔记  ——  启动器
  ==========================================================================
  只负责「用哪种方式把程序跑起来」，不修改任何程序文件。

  包里带两种运行方式：
    fdd ：fdd\LiveCaptionsTranslator.dll —— 由微软签名的 dotnet.exe 当宿主加载。
          开启 Smart App Control 的电脑会拒绝未签名的 exe，走这条路最稳。
    exe ：LiveCaptionsTranslator-AutoNotes.exe —— 单文件自包含，自带 .NET 8，
          依赖最少，但未签名，可能被 Smart App Control 拦下。

  Auto 模式的选择顺序：
    Smart App Control 强制开启           -> fdd（宿主签名，能过）
    其它情况（含 SAC 关闭 / 评估模式）    -> 单文件 exe（自带运行时，依赖最少）
    exe 不存在                           -> fdd

  用法：
    powershell -ExecutionPolicy Bypass -File .\launch.ps1
    powershell -ExecutionPolicy Bypass -File .\launch.ps1 -DryRun     # 只看判定，不启动
    powershell -ExecutionPolicy Bypass -File .\launch.ps1 -Mode Exe   # 强制某一种方式
    powershell -ExecutionPolicy Bypass -File .\launch.ps1 -Wait       # 前台运行，看报错
    powershell -ExecutionPolicy Bypass -File .\launch.ps1 -NoOllama   # 不自动拉起 Ollama
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Fdd', 'Exe')]
    [string]$Mode = 'Auto',
    [switch]$NoOllama,
    [switch]$Wait,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Info($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }

$root = $PSScriptRoot
. (Join-Path $root 'runtime-detect.ps1')

$exePath     = Join-Path $root 'LiveCaptionsTranslator-AutoNotes.exe'
$fddDll      = Join-Path $root 'fdd\LiveCaptionsTranslator.dll'
$settingPath = Join-Path $root 'setting.json'
$tmplPath    = Join-Path $root 'setting.default.json'

# ------------------------------------------------- 笔记目录（只读，不写盘）
$notesDir = Join-Path $root 'notes'
try {
    if (Test-Path $settingPath) {
        $m0 = [regex]::Match([System.IO.File]::ReadAllText($settingPath, [System.Text.Encoding]::UTF8),
                             '"AutoNotesDirectory"\s*:\s*"([^"]*)"')
        if ($m0.Success -and $m0.Groups[1].Value) {
            $v = $m0.Groups[1].Value.Replace('\\', '\')
            $notesDir = if ([System.IO.Path]::IsPathRooted($v)) { $v } else { Join-Path $root $v }
        }
    }
} catch { }

# --------------------------------------------------------- 运行环境探测
$runtime = Get-DesktopRuntimeHost -Root $root
$sac     = Get-SmartAppControlState
$canExe  = Test-Path $exePath
$canFdd  = (Test-Path $fddDll) -and $runtime

# --------------------------------------------------------------- 选运行方式
$reason = ''
if ($Mode -eq 'Auto') {
    if ($sac -eq 1 -and $canFdd) {
        $Mode = 'Fdd'
        $reason = 'Smart App Control 强制开启：未签名的单文件 exe 会被拦，改用微软签名的 dotnet 宿主'
    } elseif ($canExe) {
        $Mode = 'Exe'
        $reason = '单文件 exe 自带 .NET 8 运行时，依赖最少'
    } elseif ($canFdd) {
        $Mode = 'Fdd'
        $reason = '缺少单文件 exe，改用 fdd'
    } else {
        Die '包里既没有可执行文件、也没有可用的 .NET 宿主。压缩包可能没解压完整。'
    }
}
if ($Mode -eq 'Fdd') {
    if (-not (Test-Path $fddDll)) { Die '缺少 fdd\LiveCaptionsTranslator.dll。改用 -Mode Exe 试试。' }
    if (-not $runtime) {
        Warn '本机没有可用的 .NET 桌面运行时，退回单文件 exe。'
        if ($canExe) { $Mode = 'Exe'; $reason = '没有可用的 .NET 宿主' }
        else { Die '既没有桌面运行时，也没有单文件 exe。请先运行 install.ps1。' }
    }
}
if ($Mode -eq 'Exe' -and -not $canExe) {
    Die '缺少 LiveCaptionsTranslator-AutoNotes.exe，请重新解压压缩包。'
}

# 只有更高大版本的桌面运行时（9/10/...）时，必须允许跨大版本前滚
$rollForward = $false
if ($Mode -eq 'Fdd' -and $runtime -and -not $runtime.Exact) { $rollForward = $true }

# ------------------------------------------------------------------- DryRun
if ($DryRun) {
    Write-Host ''
    Info "目录             : $root"
    Info "Smart App Control: $(Format-SmartAppControl $sac)"
    Info "dotnet 宿主      : $(if ($runtime) { "$($runtime.Path)  [WindowsDesktop.App $($runtime.Version)$(if ($runtime.Exact) { '' } else { '，需前滚' })]" } else { '（未找到）' })"
    Info "运行时来源       : $(if ($rollForward) { 'DOTNET_ROLL_FORWARD=LatestMajor（跨大版本前滚）' } else { '精确匹配 .NET 8' })"
    Info "单文件 exe       : $(if ($canExe) { $exePath } else { '（缺失）' })"
    Info "fdd DLL          : $(if (Test-Path $fddDll) { $fddDll } else { '（缺失）' })"
    Info "选定运行方式     : $Mode"
    if ($reason) { Info "理由             : $reason" }
    Info "setting.json     : $(if (Test-Path $settingPath) { $settingPath } else { '（还没有；程序首次启动会用默认值生成）' })"
    Info "笔记目录         : $notesDir"
    Write-Host ''
    Info '仅检查，未启动。'
    exit 0
}

# --------------------------------------------------- setting.json 工作目录修正
# 程序读 setting.json 用的是「当前工作目录」，而相对笔记目录是按「程序文件所在
# 目录」解析的：fdd 会落到 fdd\notes，单文件 exe 会落到根目录\notes。
# 这里把相对路径固定成绝对路径，消掉这个歧义。
if (-not (Test-Path $settingPath) -and (Test-Path $tmplPath)) {
    try {
        Copy-Item $tmplPath $settingPath -Force
        Info '已按出厂模板生成 setting.json'
    } catch { Warn "setting.json 生成失败：$($_.Exception.Message)" }
}
if (Test-Path $settingPath) {
    try {
        $raw = [System.IO.File]::ReadAllText($settingPath, [System.Text.Encoding]::UTF8)
        $m = [regex]::Match($raw, '"AutoNotesDirectory"\s*:\s*"([^"]*)"')
        if ($m.Success -and $m.Groups[1].Value -and -not [System.IO.Path]::IsPathRooted($m.Groups[1].Value)) {
            $abs = (Join-Path $root $m.Groups[1].Value).Replace('\', '\\')
            $new = $raw.Remove($m.Groups[1].Index, $m.Groups[1].Length).Insert($m.Groups[1].Index, $abs)
            Copy-Item $settingPath "$settingPath.bak" -Force
            [System.IO.File]::WriteAllText($settingPath, $new, (New-Object System.Text.UTF8Encoding($false)))
            $notesDir = Join-Path $root $m.Groups[1].Value
            Info "笔记目录已固定为：$notesDir"
        }
    } catch {
        Warn "setting.json 里的笔记目录没能自动修正（不影响启动）：$($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------- 笔记目录
try { New-Item -ItemType Directory -Force -Path $notesDir | Out-Null } catch { }

# --------------------------------------------------------- Ollama 服务（可选）
if (-not $NoOllama) {
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if ($ollama) {
        $alive = $false
        try { $alive = (Invoke-WebRequest 'http://localhost:11434' -UseBasicParsing -TimeoutSec 2).StatusCode -ge 200 } catch { $alive = $false }
        if (-not $alive) {
            Info 'Ollama 没在运行，正在后台拉起 ...'
            try { Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden } catch { }
        }
    } else {
        Warn '没找到 ollama 命令。字幕翻译仍可用，但自动笔记会失败——见 使用说明.md。'
    }
}

# --------------------------------------------------------------------- 启动
if ($Mode -eq 'Fdd') {
    if ($rollForward) {
        Warn "本机只有 .NET $($runtime.Version) 桌面运行时，而程序面向 .NET 8。"
        Warn '将用 DOTNET_ROLL_FORWARD=LatestMajor 跨大版本加载；若界面异常，请装 .NET 8 桌面运行时或改用 -Mode Exe。'
        $env:DOTNET_ROLL_FORWARD = 'LatestMajor'
    }
    Info "运行方式：fdd（dotnet 宿主 $($runtime.Path)）"
    if ($Wait) {
        & $runtime.Path $fddDll
    } else {
        # 用 ShellExecute（UseShellExecute = true）启动：子进程拿到自己的控制台，
        # 不挂在本启动器的控制台上。否则启动器一退出、控制台一关，dotnet 宿主会被
        # 一起结束（表现为"闪一下就没了"）。这与 quiet-start.vbs 里的
        # WScript.Shell.Run(cmd, 0, False) 是同一套机制。
        # 注意：别用 cmd /c start —— 经 PowerShell 转发时引号会被吃掉，进程根本起不来。
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $runtime.Path
        $psi.Arguments = '"' + $fddDll + '"'
        $psi.WorkingDirectory = $root
        $psi.UseShellExecute = $true
        $psi.WindowStyle = 'Hidden'
        $proc = [System.Diagnostics.Process]::Start($psi)
        # 起完看一眼：若两秒半就退了，多半是没走通，直接说清楚而不是静默失败
        Start-Sleep -Milliseconds 2500
        $proc.Refresh()
        if ($proc.HasExited) {
            Warn "进程启动后立刻退出（退出码 $($proc.ExitCode)），这条路没走通。"
            Warn '换单文件 exe 再试：powershell -ExecutionPolicy Bypass -File .\launch.ps1 -Mode Exe -Wait'
            if ($rollForward) { Warn "也可能是 .NET $($runtime.Version) 跨大版本加载不兼容，装上 .NET 8 桌面运行时即可。" }
            exit 1
        }
    }
} else {
    Info '运行方式：单文件 exe（自带运行时）'
    if ($Wait) { & $exePath } else { Start-Process -FilePath $exePath -WorkingDirectory $root }
}

Write-Host ''
Info '已启动。首次使用请按 使用说明.md 配好 Windows 实时字幕（Win+Ctrl+L）。'
if ($Mode -eq 'Exe' -and $sac -eq 1) {
    Warn '注意：Smart App Control 在强制开启，单文件 exe 可能被静默拦下。'
    Warn '如果程序没出现，请装 .NET 8 桌面运行时后重试，或运行 install.ps1。'
}
