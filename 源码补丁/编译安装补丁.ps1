<#
  Auto Notes 补丁：一键编译 + 安装到本机
  ======================================

  做四件事：
    1. 找到（必要时用户级安装）.NET SDK
    2. 把本包 src\ 下的补丁文件覆盖到 LiveCaptions Translator 源码树
    3. dotnet publish 生成单文件自包含 exe
    4. 复制到 LiveCaptionsTranslator 安装目录（保留原程序，不覆盖）
    5. 校验本地 Ollama 服务与模型

  用法：
    powershell -ExecutionPolicy Bypass -File .\install-autonotes.ps1
    powershell -ExecutionPolicy Bypass -File .\install-autonotes.ps1 -SourceDir "C:\src\LiveCaptions-Translator" -InstallDir "C:\Users\me\LiveCaptionsTranslator"

  说明：-SourceDir 省略时会依次尝试 ..\LiveCaptionsTranslator-src 与
        %USERPROFILE%\LiveCaptionsTranslator\src-checkout；两者都没有时会自动
        从 Downloads\LiveCaptions-Translator-master.zip 解压一份。
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$SourceDir,
    [string]$SdkDir = (Join-Path $env:LOCALAPPDATA 'dotnet-sdk'),
    [string]$InstallDir = (Join-Path $env:USERPROFILE 'LiveCaptionsTranslator'),
    [string]$OutputDir,
    [string]$PackagesDir,
    [string]$Configuration = 'Release',
    [string]$Runtime = 'win-x64',
    [string]$Channel = '8.0',
    [string]$SdkVersion = '8.0.425',
    [switch]$FrameworkDependent,
    [switch]$SkipOllamaCheck,
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "  [X] $m" -ForegroundColor Red; exit 1 }

if ([string]::IsNullOrEmpty($PSScriptRoot)) {
    Write-Host "本脚本必须作为文件运行，不能整段粘贴到控制台。" -ForegroundColor Red
    Write-Host "正确用法：" -ForegroundColor Yellow
    Write-Host '  powershell -ExecutionPolicy Bypass -File ".\编译安装补丁.ps1" -SourceDir C:\src\LiveCaptions-Translator'
    exit 1
}

$root = $PSScriptRoot
if (-not $OutputDir)   { $OutputDir   = Join-Path $root 'publish' }
if (-not $PackagesDir) { $PackagesDir = Join-Path $root '.nuget' }

# ---------------------------------------------------------------- 1. SDK
Step "1/5 定位 .NET SDK"
$dotnet = $null
foreach ($cand in @((Join-Path $SdkDir 'dotnet.exe'), (Join-Path ${env:ProgramFiles} 'dotnet\dotnet.exe'))) {
    if (Test-Path $cand) {
        $sdks = & $cand --list-sdks 2>$null
        if ($sdks) { $dotnet = $cand; break }
    }
}
if (-not $dotnet) {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) {
        $sdks = & $cmd.Source --list-sdks 2>$null
        if ($sdks) { $dotnet = $cmd.Source }
    }
}
if ($dotnet) {
    Ok "使用 SDK：$dotnet"
} else {
    Warn "未找到 .NET SDK，尝试用户级安装（不需要管理员）"
    $boot = Join-Path $root 'dotnet-install.ps1'
    if (-not (Test-Path $boot)) {
        $boot = Join-Path $env:TEMP 'dotnet-install.ps1'
    }
    if (-not (Test-Path $boot)) {
        Try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $boot -UseBasicParsing
        } Catch {
            Die "无法下载 dotnet-install.ps1（$($_.Exception.Message)）。请先安装 .NET 8 SDK：winget install Microsoft.DotNet.SDK.8"
        }
    }
    # 先按精确版本装（直连 builds.dotnet.microsoft.com 的 zip）。
    # 用 -Channel 时脚本可能回退到 aka.ms 的 windows tar.gz，而 8.0 并没有
    # Windows tarball，于是必然报 "Unable to download ...tar.gz"。
    & $boot -Version $SdkVersion -InstallDir $SdkDir -NoPath
    $dotnet = Join-Path $SdkDir 'dotnet.exe'
    if (-not (Test-Path $dotnet)) {
        Warn "按版本 $SdkVersion 安装失败，改用 -Channel $Channel 再试一次"
        & $boot -Channel $Channel -InstallDir $SdkDir -NoPath
    }
    if (-not (Test-Path $dotnet)) {
        Write-Host @"

无法自动下载 .NET SDK。请任选一种方式装上，然后重新运行本脚本：

  A) winget（最省事）
       winget install Microsoft.DotNet.SDK.8

  B) 手动下载官方 zip（$SdkVersion，约 200 MB）后解压到 $SdkDir
       官方：https://builds.dotnet.microsoft.com/dotnet/Sdk/$SdkVersion/dotnet-sdk-$SdkVersion-win-x64.zip
       国内镜像（同目录结构，速度通常更快）：
             https://mirrors.huaweicloud.com/dotnet/Sdk/$SdkVersion/dotnet-sdk-$SdkVersion-win-x64.zip
       解压后确认存在：$SdkDir\dotnet.exe

  C) 指定已下载好的 dotnet-install 源：
       .\install-autonotes.ps1 -SdkVersion $SdkVersion

"@ -ForegroundColor Yellow
        Die "缺少 .NET SDK，已停止（未做任何修改）"
    }
    Ok "已安装 SDK $SdkVersion 到 $SdkDir"
}
$env:DOTNET_ROOT = Split-Path $dotnet -Parent
$env:PATH = "$($env:DOTNET_ROOT);$env:PATH"

# ------------------------------------------------------------- 2. 源码树
Step "2/5 准备源码树"
function Resolve-Source([string]$dir) {
    if ($dir -and (Test-Path (Join-Path $dir 'LiveCaptionsTranslator.csproj'))) { return $dir }
    return $null
}
$SourceDir = Resolve-Source $SourceDir
if (-not $SourceDir) { $SourceDir = Resolve-Source (Join-Path (Split-Path $root -Parent) 'LiveCaptionsTranslator-src') }
if (-not $SourceDir) {
    $zip = Get-ChildItem (Join-Path $env:USERPROFILE 'Downloads') -Filter 'LiveCaptions-Translator-master.zip' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($zip) {
        $tmp = Join-Path $root 'src-checkout'
        Warn "从 $($zip.Name) 解压源码到 $tmp"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
        foreach ($e in $z.Entries) {
            if ($e.Name -eq '') { continue }
            $rel = $e.FullName -replace '^LiveCaptions-Translator-master/', ''
            if ($rel -eq $e.FullName) { continue }
            $t = Join-Path $tmp ($rel -replace '/', '\')
            New-Item -ItemType Directory -Force -Path (Split-Path $t -Parent) | Out-Null
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $t, $true)
        }
        $z.Dispose()
        $SourceDir = Resolve-Source $tmp
    }
}
if (-not $SourceDir) { Die "找不到 LiveCaptions Translator 源码（缺少 LiveCaptionsTranslator.csproj）。用 -SourceDir 指定。" }
Ok "源码树：$SourceDir"

$patched = @(
    'src/utils/TextUtil.cs',
    'src/Translator.cs',
    'src/utils/AutoNotesService.cs',
    'src/pages/NotesPage.xaml',
    'src/pages/NotesPage.xaml.cs',
    'src/models/Setting.cs',
    'src/windows/MainWindow.xaml',
    'src/App.xaml.cs'
)
foreach ($rel in $patched) {
    $from = Join-Path $root ($rel -replace '/', '\')
    $to = Join-Path $SourceDir ($rel -replace '/', '\')
    if (-not (Test-Path $from)) { Die "补丁文件缺失：$from" }
    New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent) | Out-Null
    # 统一写成带 BOM 的 UTF-8，避免中文在 XAML/编译器里变成乱码
    $text = [System.IO.File]::ReadAllText($from, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($to, $text, (New-Object System.Text.UTF8Encoding($true)))
    Ok "已应用 $rel"
}

# ------------------------------------------------------------- 3. 编译
Step "3/5 编译（首次会下载 NuGet 包，可能需要几分钟）"
New-Item -ItemType Directory -Force -Path $OutputDir, $PackagesDir | Out-Null
$env:NUGET_PACKAGES = $PackagesDir
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$csproj = Join-Path $SourceDir 'LiveCaptionsTranslator.csproj'

$selfContained = (-not $FrameworkDependent).ToString().ToLower()
if ($FrameworkDependent) { Warn "使用框架依赖模式（需要本机已装 .NET 8 桌面运行时）" }
& $dotnet publish $csproj -c $Configuration -r $Runtime --self-contained $selfContained `
    -p:PublishSingleFile=true -p:IncludeAllContentForSelfExtract=false `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:DebugType=none -o $OutputDir
if ($LASTEXITCODE -ne 0) { Die "编译失败（退出码 $LASTEXITCODE）。可加 -FrameworkDependent 再试一次；仍失败请把上面的报错发我。" }
$built = Join-Path $OutputDir 'LiveCaptionsTranslator.exe'
if (-not (Test-Path $built)) { Die "编译结束但找不到 $built" }
# 单文件模式下不该再有成堆的 dll 平铺；若有，说明原生库没被打进 exe，需要提示
$strays = @(Get-ChildItem $OutputDir -File -Filter '*.dll' -ErrorAction SilentlyContinue)
if ($strays.Count -gt 0) { Warn "产物目录另有 $($strays.Count) 个 dll（原生库未内嵌），安装时需一并复制" }
$script:PublishStrays = $strays
Ok ("编译产物：" + $built + " (" + [math]::Round((Get-Item $built).Length / 1MB, 1) + " MB)")

# ------------------------------------------------------------- 4. 安装
Step "4/5 安装到 $InstallDir"
if ($SkipInstall) {
    Warn "已指定 -SkipInstall，跳过复制"
} else {
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
    $target = Join-Path $InstallDir 'LiveCaptionsTranslator-AutoNotes.exe'
    Copy-Item $built $target -Force
    Ok "已安装：$target"
    if ($PublishStrays -and $PublishStrays.Count -gt 0) {
        foreach ($d in $PublishStrays) { Copy-Item $d.FullName (Join-Path $InstallDir $d.Name) -Force }
        Ok "已附带复制 $($PublishStrays.Count) 个原生库 dll"
    }
    $existing = Get-ChildItem $InstallDir -Filter 'LiveCaptionsTranslator*.exe' | Select-Object Name, Length
    Write-Host "  目录内现有可执行文件：" -ForegroundColor DarkGray
    $existing | ForEach-Object { Write-Host ("    - " + $_.Name + "  " + [math]::Round($_.Length / 1MB, 1) + " MB") -ForegroundColor DarkGray }

    # 同时产出「框架依赖 + 非单文件」副本到 <InstallDir>\fdd：
    # 本机 Smart App Control 会拒绝未签名 exe，这个副本用微软签名的 dotnet.exe 作宿主运行，
    # 由 quiet-start.vbs / start-autonotes.cmd / start-live-translator.ps1 启动。
    Step "4b 生成 dotnet 宿主版（fdd）"
    $fddOut = Join-Path $root 'publish-fdd'
    Remove-Item $fddOut -Recurse -Force -ErrorAction SilentlyContinue
    & $dotnet publish $csproj -c $Configuration -r $Runtime --self-contained false `
        -p:PublishSingleFile=false -p:DebugType=none -o $fddOut
    if ($LASTEXITCODE -ne 0) {
        Warn "fdd 版编译失败；仍可用单一 exe（若系统未拦未签名 exe）"
    } else {
        $fddDir = Join-Path $InstallDir 'fdd'
        # 程序可能正从 fdd 里的 DLL 运行（含无窗口的残留实例）：先全部停掉再复制
        Get-Process -Name dotnet -ErrorAction SilentlyContinue |
            ForEach-Object { Warn "停止 dotnet 进程 PID $($_.Id)"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 5
        Remove-Item $fddDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $fddDir | Out-Null
        $copied = $false
        for ($k = 1; $k -le 6; $k++) {
            try {
                Copy-Item (Join-Path $fddOut '*') $fddDir -Recurse -Force -ErrorAction Stop
                $copied = $true
                break
            } catch {
                Warn "第 $k 次复制被占用，4 秒后重试"
                Start-Sleep -Seconds 4
            }
        }
        if ($copied) {
            Ok "已生成：$(Join-Path $fddDir 'LiveCaptionsTranslator.dll')"
            Warn "提示：需要重新启动程序（quiet-start.vbs 或桌面快捷方式）"
        } else {
            Warn "复制 fdd 失败（DLL 被占用）。请关闭程序后重跑：install-autonotes.ps1 -SkipInstall"
        }
    }
}

# --------------------------------------------------------- 5. Ollama 校验
Step "5/5 校验本地 Ollama"
if ($SkipOllamaCheck) {
    Warn "已指定 -SkipOllamaCheck，跳过"
} else {
    $ollama = Get-Command ollama -ErrorAction SilentlyContinue
    if (-not $ollama) {
        Warn "未找到 ollama 命令；Auto Notes 需要在设置里填写可用地址。"
    } else {
        $model = 'qwen2.5:7b'
        $list = & ollama list 2>$null | Out-String
        if ($list -notmatch [regex]::Escape($model)) {
            Warn "本地没有 $model，正在下载（几分钟到几十分钟）..."
            & ollama pull $model
        } else {
            Ok "$model 已存在"
        }
        $body = @{ model = $model; messages = @(@{ role = 'user'; content = '只回答：本地模型正常' }); stream = $false } | ConvertTo-Json -Depth 5
        Try {
            $r = Invoke-RestMethod -Uri 'http://localhost:11434/api/chat' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
            Ok ("Ollama 应答：" + $r.message.content)
        } Catch {
            Warn "Ollama 接口测试失败：$($_.Exception.Message)（确认 ollama serve 正在运行）"
        }
    }
}

Step "完成"
Write-Host @"
下一步（程序内，只需一次）：
  1. 启动新程序：$InstallDir\LiveCaptionsTranslator-AutoNotes.exe
  2. 左侧 Auto Notes 页面：
       自动生成笔记      = 开启
       每多少条字幕生成一次 = 20（延迟高可改 10-15）
       Ollama 模型       = qwen2.5:7b
       Ollama 地址       = http://localhost:11434
       笔记保存目录      = notes
  3. Win+Ctrl+L 打开实时字幕 → 齿轮 → 位置 Overlaid on screen，语言 English
  4. Markdown 会写到 $InstallDir\notes\ ，用 Obsidian 直接打开该文件夹即可（无需同步脚本）
"@ -ForegroundColor Yellow
