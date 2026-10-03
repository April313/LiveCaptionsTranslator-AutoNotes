<#
  共用工具：定位能加载 net8.0-windows（WPF）程序的 dotnet 宿主 + 读取 Smart App Control 状态。
  由 launch.ps1 与 install.ps1 点源（dot-source）使用。
#>

function Get-DesktopRuntimeHost {
    <#
      返回 $null，或：
        [pscustomobject]@{ Path = 'dotnet.exe 全路径'; Version = [version]; Exact = $true/$false }

      Exact = $true   本机有 Microsoft.WindowsDesktop.App 8.x -> 可直接加载 net8.0 程序，最稳
      Exact = $false  只有更高大版本（9.x/10.x...）-> 需要 DOTNET_ROLL_FORWARD=LatestMajor 才能加载
    #>
    [CmdletBinding()]
    param([string]$Root = $PSScriptRoot)

    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:DOTNET_ROOT) { $cands.Add((Join-Path $env:DOTNET_ROOT 'dotnet.exe')) }
    # 可选：把便携版 .NET 运行时解压到包内 runtime\ 目录，就会优先用它
    if ($Root) { $cands.Add((Join-Path $Root 'runtime\dotnet.exe')) }
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if ($cmd) { $cands.Add($cmd.Source) }
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrEmpty($base)) { continue }
        $cands.Add((Join-Path $base 'dotnet\dotnet.exe'))
        $cands.Add((Join-Path $base 'Microsoft\dotnet\dotnet.exe'))
    }

    $fallback = $null
    foreach ($c in $cands) {
        if ([string]::IsNullOrEmpty($c) -or -not (Test-Path $c)) { continue }
        try { $lines = & $c --list-runtimes 2>$null } catch { continue }
        $vers = @()
        foreach ($l in @($lines)) {
            $m = [regex]::Match([string]$l, '^Microsoft\.WindowsDesktop\.App\s+([0-9][0-9.]*)')
            if ($m.Success) { try { $vers += [version]$m.Groups[1].Value } catch { } }
        }
        if ($vers.Count -eq 0) { continue }

        $v8 = $vers | Where-Object { $_.Major -eq 8 } | Sort-Object -Descending | Select-Object -First 1
        if ($v8) { return [pscustomobject]@{ Path = $c; Version = $v8; Exact = $true } }

        $newer = $vers | Where-Object { $_.Major -gt 8 } | Sort-Object -Descending | Select-Object -First 1
        if ($newer -and -not $fallback) {
            $fallback = [pscustomobject]@{ Path = $c; Version = $newer; Exact = $false }
        }
    }
    return $fallback
}

function Get-SmartAppControlState {
    # 0 = 关闭   1 = 强制开启   2 = 评估模式   -1 = 读不到
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' `
                              -Name 'VerifiedAndReputablePolicyState' -ErrorAction Stop
        return [int]$v.VerifiedAndReputablePolicyState
    } catch {
        return -1
    }
}

function Format-SmartAppControl([int]$state) {
    switch ($state) {
        0 { '关闭' }
        1 { '强制开启（会拦截未签名 exe）' }
        2 { '评估模式' }
        default { '读不到' }
    }
}
