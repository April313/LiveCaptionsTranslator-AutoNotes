<#
  实时翻译 + 自动笔记  ——  一键初始化（绿色版）
  ==========================================================================
  这个脚本只做「准备环境 + 写默认配置」：不写注册表、不复制到别处。
  整个文件夹就是程序本体，想卸载直接删文件夹。

  它会：
    0. 检查系统版本、目录是否可写、程序是否正在运行
    1. 看 Smart App Control 状态，决定程序该用哪种方式跑（fdd / 单文件 exe）
    2. 检查 Ollama 服务，并按需拉取两个模型
    3. 生成 setting.json（笔记目录写成绝对路径，避免 fdd/exe 两种方式错位）
    4. 建好 notes 目录，创建桌面快捷方式
    5. 打印 Windows 实时字幕的必做设置

  用法：
    powershell -ExecutionPolicy Bypass -File .\install.ps1
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Yes            # 全部自动同意（会下载约 9GB 模型）
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -SkipOllama     # 跳过模型检查
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -NotesDir "D:\Obsidian\LiveCaptions"
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Launch         # 装完直接启动
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$NotesDir,
    [switch]$Yes,
    [switch]$SkipOllama,
    [switch]$SkipShortcut,
    [switch]$Launch
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:AssumeYes = [bool]$Yes

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Info($m) { Write-Host "  $m" }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Bad($m)  { Write-Host "  [X] $m" -ForegroundColor Red }

# 交互确认。非交互环境（管道/脚本调用/无控制台）下，绝不为「下载/安装」类问题
# 自动答"是"，一律按 -NonInteractiveNo 指定的安全默认值处理。
function Confirm([string]$question, [bool]$default = $true, [switch]$NonInteractiveNo) {
    if ($script:AssumeYes) { Info "$question -> 自动选择：是（-Yes）"; return $true }
    if ([Console]::IsInputRedirected) {
        $answer = if ($NonInteractiveNo) { $false } else { $default }
        Info "$question -> 当前是非交互环境，按默认处理：$(if ($answer) { '是' } else { '否' })"
        return $answer
    }
    $suffix = if ($default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host "  $question $suffix " -NoNewline
        $a = Read-Host
        if ([string]::IsNullOrWhiteSpace($a)) { return $default }
        if ($a -match '^(y|yes|是|好|1)$') { return $true }
        if ($a -match '^(n|no|否|不|0)$') { return $false }
    }
}

if ([string]::IsNullOrEmpty($PSScriptRoot)) {
    Bad '这个脚本必须作为文件运行，不能整段粘贴到控制台。'
    exit 1
}
$root = $PSScriptRoot
. (Join-Path $root 'runtime-detect.ps1')

$exePath     = Join-Path $root 'LiveCaptionsTranslator-AutoNotes.exe'
$fddDll      = Join-Path $root 'fdd\LiveCaptionsTranslator.dll'
$settingTpl  = Join-Path $root 'setting.default.json'
$settingPath = Join-Path $root 'setting.json'
if (-not $NotesDir) { $NotesDir = Join-Path $root 'notes' }

Write-Host @"
==========================================================
  实时翻译 + 自动笔记   一键初始化
  目录：$root
==========================================================
"@ -ForegroundColor White

# ============================================================ 0. 环境
Step '0/5 环境检查'

$build = [Environment]::OSVersion.Version.Build
if ($build -lt 22621) {
    Warn "当前 Windows build $build，低于 22621（Win11 22H2）。Windows 实时字幕在这个版本以下不可用。"
} else {
    Ok "Windows build $build（满足实时字幕要求）"
}
if (-not [Environment]::Is64BitOperatingSystem) { Warn '本包只有 win-x64 版本，32 位系统无法运行。' }
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { Warn '检测到 ARM64，程序会以 x64 兼容模式运行，可能较慢。' }

try {
    $probe = Join-Path $root '.write-test.tmp'
    [System.IO.File]::WriteAllText($probe, 'ok')
    Remove-Item $probe -Force
    Ok '目录可写'
} catch {
    Bad "目录不可写：$root"
    Bad '请不要放在 C:\Program Files 或只读位置，换到 D:\ 或用户目录下再运行。'
    exit 1
}

$running = @()
try { $running += Get-Process -Name 'LiveCaptionsTranslator-AutoNotes' -ErrorAction SilentlyContinue } catch { }
try {
    $running += Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'LiveCaptionsTranslator\.dll' } |
        ForEach-Object { [pscustomobject]@{ Id = $_.ProcessId; ProcessName = 'dotnet (fdd)' } }
} catch { }
if ($running.Count -gt 0) {
    Warn "程序似乎正在运行（PID: $(($running | ForEach-Object { $_.Id }) -join ', ')）。"
    Warn '请先关闭它再继续，否则它退出时会把配置覆盖回去。'
    if (-not (Confirm '仍然继续？' $false)) { exit 0 }
}

# ============================================================ 1. 运行方式
Step '1/5 决定运行方式（Smart App Control / .NET 运行时）'

$sac     = Get-SmartAppControlState
$runtime = Get-DesktopRuntimeHost -Root $root

Info "Smart App Control：$(Format-SmartAppControl $sac)"
if ($sac -eq 1) {
    Info '  -> 未签名的单文件 exe 很可能被静默拦下，所以本机应该走 fdd（dotnet 宿主签名）。'
}

if ($runtime) {
    if ($runtime.Exact) {
        Ok "已找到 .NET $($runtime.Version) 桌面运行时：$($runtime.Path)"
        Ok 'fdd 方式直接可用，不需要再装任何运行时。'
    } else {
        Warn "只找到 .NET $($runtime.Version) 桌面运行时（程序面向 .NET 8）：$($runtime.Path)"
        Info '  fdd 会用 DOTNET_ROLL_FORWARD=LatestMajor 跨大版本加载，多数情况没问题。'
        Info '  想更保险就装上 .NET 8 桌面运行时（约 60MB）。'
    }
} else {
    Warn '没有找到任何可用的 .NET 桌面运行时。'
    if ($sac -eq 1) {
        Bad 'Smart App Control 在强制开启，而单文件 exe 未签名 —— 大概率起不来。'
        Info '建议装上 .NET 8 桌面运行时，让程序走 fdd 方式。'
    } else {
        Info '不影响使用：会走单文件自包含 exe（自带 .NET 8 运行时）。'
    }
}

$needRuntime = (-not $runtime) -or (-not $runtime.Exact)
if ($needRuntime) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget -and (Confirm '现在安装 .NET 8 桌面运行时（约 60MB，推荐）？' $true -NonInteractiveNo)) {
        Info '正在安装：winget install Microsoft.DotNet.DesktopRuntime.8'
        & winget install --id Microsoft.DotNet.DesktopRuntime.8 --accept-package-agreements --accept-source-agreements
        $runtime = Get-DesktopRuntimeHost -Root $root
        if ($runtime -and $runtime.Exact) { Ok "安装完成：.NET $($runtime.Version)（$($runtime.Path)）" }
        else { Warn '安装后仍未检测到 .NET 8，可能需要重开一个命令行窗口，或重启让 SAC 策略刷新。' }
    } elseif (-not $winget) {
        Info '没找到 winget。手动下载（选 “.NET Desktop Runtime 8.x” -> Windows x64 Installer）：'
        Info '  https://dotnet.microsoft.com/download/dotnet/8.0'
    } else {
        Info '已跳过。安装命令：winget install Microsoft.DotNet.DesktopRuntime.8'
    }
}

# ============================================================ 2. Ollama
Step '2/5 检查 Ollama 与模型'

$modelsRequired = @('qwen2.5:7b', 'deepseek-r1:7b')
if ($SkipOllama) {
    Warn '已指定 -SkipOllama，跳过。自动笔记需要这两个模型，之后可手动 ollama pull。'
} else {
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Warn '没找到 ollama 命令（翻译功能不需要它，自动笔记/整合需要）。'
        Info '安装方式任选：'
        Info '  winget install Ollama.Ollama'
        Info '  或从 https://ollama.com/download/windows 下载安装包'
        $winget = Get-Command winget -ErrorAction SilentlyContinue
        if ($winget -and (Confirm '现在用 winget 安装 Ollama？' $true -NonInteractiveNo)) {
            & winget install --id Ollama.Ollama --accept-package-agreements --accept-source-agreements
            $ollama = Get-Command ollama -ErrorAction SilentlyContinue
        }
    }
    if ($ollama) {
        Ok "ollama：$($ollama.Source)"
        $alive = $false
        try { $alive = (Invoke-WebRequest 'http://localhost:11434' -UseBasicParsing -TimeoutSec 3).StatusCode -ge 200 } catch { $alive = $false }
        if (-not $alive) {
            Info '正在后台启动 ollama serve ...'
            try { Start-Process -FilePath $ollama.Source -ArgumentList 'serve' -WindowStyle Hidden } catch { }
            for ($i = 0; $i -lt 20 -and -not $alive; $i++) {
                Start-Sleep -Seconds 1
                try { $alive = (Invoke-WebRequest 'http://localhost:11434' -UseBasicParsing -TimeoutSec 2).StatusCode -ge 200 } catch { $alive = $false }
            }
        }
        if ($alive) { Ok 'Ollama 服务在 http://localhost:11434 正常应答' }
        else { Warn 'Ollama 服务没起来；生成笔记时会失败，手动执行 ollama serve 即可。' }

        $installed = @()
        try { $installed = @(& ollama list 2>$null | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] }) } catch { }
        foreach ($m in $modelsRequired) {
            if ($installed -contains $m) { Ok "模型已就绪：$m"; continue }
            Warn "缺少模型：$m（约 4.7GB）"
            if (Confirm "现在下载 $m ？" $true -NonInteractiveNo) {
                & ollama pull $m
                if ($LASTEXITCODE -eq 0) { Ok "$m 下载完成" } else { Warn "$m 下载失败，可稍后手动执行 ollama pull $m" }
            } else {
                Info "已跳过。之后手动执行：ollama pull $m"
            }
        }
        if ($installed -contains 'live-translator:latest') {
            Info '顺带一提：本机还有 live-translator:latest，可在设置页把翻译模型换成它，延迟更低。'
        }
    }
}

# ============================================================ 3. setting.json
Step '3/5 生成 setting.json'

if (Test-Path $settingPath) {
    $bak = "$settingPath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Copy-Item $settingPath $bak -Force
    Ok "已备份原配置：$(Split-Path $bak -Leaf)"
}
if (-not (Test-Path $settingTpl)) {
    Bad '缺少模板 setting.default.json，无法生成配置。'
} else {
    $json = [System.IO.File]::ReadAllText($settingTpl, [System.Text.Encoding]::UTF8)
    # 笔记目录写绝对路径：程序读 setting.json 用的是「当前工作目录」，
    # 而相对笔记目录是按「程序文件所在目录」解析的 —— fdd 方式会落到 fdd\notes，
    # 单文件 exe 会落到根目录\notes。写成绝对路径就没有这个歧义。
    $abs = $NotesDir.Replace('\', '\\')
    if ($json -match '"AutoNotesDirectory"\s*:\s*"[^"]*"') {
        $json = [regex]::Replace($json, '("AutoNotesDirectory"\s*:\s*")[^"]*(")', ('${1}' + $abs + '${2}'), 1)
        [System.IO.File]::WriteAllText($settingPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Ok "已写入：$settingPath"
        Ok "笔记目录：$NotesDir"
        try { New-Item -ItemType Directory -Force -Path $NotesDir | Out-Null; Ok '笔记目录已建好' } catch { Warn "笔记目录创建失败：$($_.Exception.Message)" }
        Info '默认：翻译模型 qwen2.5:7b / 整合模型 deepseek-r1:7b / 目标语言 zh-CN / 整合结果 consolidated.md'
    } else {
        Bad '模板里没有 AutoNotesDirectory 字段，配置未生成。'
    }
}

# ============================================================ 4. 快捷方式
Step '4/5 创建快捷方式'

if ($SkipShortcut) {
    Warn '已指定 -SkipShortcut，跳过。'
} else {
    $vbs = Join-Path $root '启动（无窗口）.vbs'
    $target = if (Test-Path $vbs) { $vbs } else { Join-Path $root '启动.cmd' }
    $icon = Join-Path $root 'app.ico'
    if (-not (Test-Path $icon)) { $icon = $exePath }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnkPath = Join-Path $desktop '实时翻译+自动笔记.lnk'
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        $lnk.TargetPath = $target
        $lnk.WorkingDirectory = $root
        $lnk.IconLocation = $icon
        $lnk.Description = '实时翻译 + 自动笔记（Windows 实时字幕 -> 中文 Markdown 笔记）'
        $lnk.Save()
        Ok "桌面快捷方式：$lnkPath"
    } catch {
        Warn "创建桌面快捷方式失败：$($_.Exception.Message)"
        # 退回：在包目录里放一个快捷方式，用户自己拖到桌面/开始菜单即可
        try {
            $localLnk = Join-Path $root '启动 快捷方式.lnk'
            $ws2 = New-Object -ComObject WScript.Shell
            $lnk2 = $ws2.CreateShortcut($localLnk)
            $lnk2.TargetPath = $target
            $lnk2.WorkingDirectory = $root
            $lnk2.IconLocation = $icon
            $lnk2.Description = '实时翻译 + 自动笔记（Windows 实时字幕 -> 中文 Markdown 笔记）'
            $lnk2.Save()
            Ok "已在包目录生成快捷方式：$localLnk"
            Info '把它拖到桌面或开始菜单即可。'
        } catch {
            Info "手动启动即可：双击 $root\启动.cmd（或 启动（无窗口）.vbs）"
        }
    }
}

# ============================================================ 5. 收尾
Step '5/5 完成'

if (Test-Path $exePath) { $willUse = if ($sac -eq 1 -and $runtime) { 'fdd（dotnet 宿主，能过 Smart App Control）' } else { '单文件 exe（自带运行时）' } }
else { $willUse = if ($runtime) { 'fdd（dotnet 宿主）' } else { '无可用方式，包不完整' } }

Write-Host @"

--------------------------------------------------------------
 接下来要在界面里手动做一次（只做一次）：
--------------------------------------------------------------
 1. Win + Ctrl + L 打开 Windows 实时字幕
      首次会让你同意语音处理、下载「英语」语言包 —— 需要联网
 2. 实时字幕 -> 齿轮：
      位置(Position) = Overlaid on screen
      语言(Language) = English
      要翻译麦克风就勾上 Include microphone audio
 3. 启动本程序（桌面快捷方式），左侧 Auto Notes 页确认：
      自动生成笔记            = 开启
      每多少条字幕生成一次      = 20 ~ 30（卡就调大）
      Ollama 模型             = qwen2.5:7b
      Ollama 地址             = http://localhost:11434
      笔记保存目录            = $NotesDir
      生成后自动整合并清理分段笔记 = 开启
      整合模型                = deepseek-r1:7b
 4. 用 Obsidian 直接打开笔记目录即可；最终只留一个 consolidated.md

 运行方式：$willUse
 启动命令：powershell -ExecutionPolicy Bypass -File "$root\launch.ps1"
 只看判定：powershell -ExecutionPolicy Bypass -File "$root\launch.ps1" -DryRun
 卸载：直接删掉整个文件夹
--------------------------------------------------------------
"@ -ForegroundColor Yellow

if ($Launch) {
    Step '启动程序'
    & (Join-Path $root 'launch.ps1')
}
