#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
诊断并修复 WinNat 实例创建失败的问题。

适用症状:
    install.ps1 倒数第二步「验证服务链」中「WinNat 实例」显示 ✗

用法 (必须管理员权限):
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts\fix-netnat.ps1

本脚本只做诊断 + 尝试修复, 每一步都会打印判断依据。
"""

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$CfgFile = Join-Path $Root 'config.json'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }

# ---------------------- 权限 ----------------------
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Say "错误: 需要管理员权限。" 'Red'
    Say "请用管理员身份打开 PowerShell 后再运行。" 'Yellow'
    exit 1
}

# ---------------------- 读取配置 ----------------------
$Gateway = '192.168.137.1'
$NatName = 'PppoeHotspotRelayNat'
if (Test-Path $CfgFile) {
    try {
        $cfg = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $Gateway = $cfg.gateway
        if ($cfg.nat_name) { $NatName = $cfg.nat_name }
    } catch { Say "config.json 解析失败, 使用默认值" 'Yellow' }
}
$Pool = ($Gateway -replace '\.\d+$', '.0') + '/24'

Say "pppoe-hotspot-relay  WinNat 诊断修复" 'White'
Say ("  网关      : {0}" -f $Gateway)
Say ("  NAT 网段  : {0}" -f $Pool)
Say ("  NAT 实例名: {0}" -f $NatName)

# ---------------------- [1] WinNat 服务 ----------------------
Head "[1/6] WinNat 驱动服务"
$svc = Get-Service WinNat -ErrorAction SilentlyContinue
if (-not $svc) {
    Say "  未找到 WinNat 服务!" 'Red'
    Say "  说明: 该系统缺少 Windows NAT Driver。" 'Yellow'
    Say "  常见于精简版 / LTSC / 被优化工具删除组件的系统。" 'Yellow'
    Say "" 'Yellow'
    Say "  解决方向:" 'Cyan'
    Say "    a) 启用 Hyper-V 功能 (WinNat 随 Hyper-V 平台一起安装):" 'Gray'
    Say "       Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All" 'Gray'
    Say "    b) 或改用「其他方案」中的 ICS / 商业工具 (见 README)" 'Gray'
    exit 1
}
Say ("  服务状态    : {0}" -f $svc.Status) $(if ("$($svc.Status)" -eq 'Running') { 'Green' } else { 'Yellow' })
Say ("  启动类型    : {0}" -f $svc.StartType)

if ($svc.StartType -eq 'Disabled') {
    Say "  启动类型为 Disabled, 正在改为 Manual..." 'Yellow'
    try { Set-Service WinNat -StartupType Manual -ErrorAction Stop; Say "  已改为 Manual" 'Green' }
    catch { Say ("  修改失败: {0}" -f $_.Exception.Message) 'Red' }
}
if ((Get-Service WinNat).Status -ne 'Running') {
    Say "  正在启动 WinNat..." 'Yellow'
    try {
        Start-Service WinNat -ErrorAction Stop
        Start-Sleep -Seconds 2
        Say ("  启动后状态: {0}" -f (Get-Service WinNat).Status) 'Green'
    } catch {
        Say ("  启动失败: {0}" -f $_.Exception.Message) 'Red'
        Say "  查依赖服务:" 'Yellow'
        Get-Service -Name (Get-Service WinNat).DependentServices -ErrorAction SilentlyContinue |
            Format-Table Name, Status -Auto | Out-String | ForEach-Object { Say $_ }
    }
}

# ---------------------- [2] 现有 NAT 实例 ----------------------
Head "[2/6] 现有 NAT 实例"
$existing = @(Get-NetNat -ErrorAction SilentlyContinue)
if ($existing.Count -eq 0) {
    Say "  没有 NAT 实例 (正常, 可以创建)" 'Gray'
} else {
    Write-Host ""
    $existing | Format-Table Name, InternalIPInterfaceAddressPrefix, Active, Store -Auto |
        Out-String | ForEach-Object { Say $_ }
    Say "  已有实例! WinNat 限制: 一个网段只能有一个 NAT 实例。" 'Yellow'
    Say "  正在清理同名与同网段的实例..." 'Yellow'
    foreach ($n in $existing) {
        # 只删除本项目的, 或与目标网段冲突的; 不碰 Hyper-V 自己的
        $isOurs = ($n.Name -eq $NatName)
        $isConflict = ($n.InternalIPInterfaceAddressPrefix -eq $Pool)
        if ($isOurs -or $isConflict) {
            try {
                Remove-NetNat -Name $n.Name -Confirm:$false -ErrorAction Stop
                Say ("    已移除 {0} ({1})" -f $n.Name, $n.InternalIPInterfaceAddressPrefix) 'Green'
            } catch {
                Say ("    移除失败 {0}: {1}" -f $n.Name, $_.Exception.Message) 'Red'
            }
        } else {
            Say ("    保留 {0} ({1}) —— 与本项目不冲突" -f $n.Name, $n.InternalIPInterfaceAddressPrefix) 'Gray'
        }
    }
}

# ---------------------- [3] 网段冲突检查 ----------------------
Head "[3/6] 网段冲突检查"
$conflicts = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -like "$(($Pool -replace '/24','') -replace '\.0$','')*" -and
                              $_.InterfaceAlias -notlike '*本地连接*' -and
                              $_.InterfaceAlias -notlike '*Local Area*' })
if ($conflicts.Count -gt 0) {
    Say "  以下接口已占用该网段, 可能与 WinNat 冲突:" 'Yellow'
    $conflicts | Format-Table InterfaceAlias, IPAddress, PrefixOrigin -Auto | Out-String | ForEach-Object { Say $_ }
    Say "  特别注意 Hyper-V 的 Default Switch —— 它默认也用 192.168.137.0/24。" 'Yellow'
    Say "  解决: 编辑 config.json 换成其他网段 (见 README「修改网段」)" 'Cyan'
} else {
    Say "  无冲突。" 'Green'
}
# Hyper-V 内部交换机上的 192.168.137.1
$hvNat = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -eq $Gateway -and $_.InterfaceAlias -like '*Default Switch*' })
if ($hvNat.Count -gt 0) {
    Say ("  警告: {0} 已被 Hyper-V Default Switch 占用!" -f $Gateway) 'Red'
    Say "  必须改网段才能创建 WinNat。" 'Red'
}

# ---------------------- [4] 网关地址 ----------------------
Head "[4/6] 热点网关地址"
$gw = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Gateway })
if ($gw.Count -gt 0) {
    Say ("  {0} 存在 (网卡: {1})" -f $Gateway, ($gw.InterfaceAlias -join ',')) 'Green'
} else {
    Say ("  {0} 不存在 —— 热点可能未启动。" -f $Gateway) 'Yellow'
    Say "  WinNat 创建通常不要求网关先存在, 但热点必须起来才能让客户端上网。" 'Gray'
}

# ---------------------- [5] 尝试创建 ----------------------
Head "[5/6] 尝试创建 WinNat 实例"
$created = $false
try {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Pool -ErrorAction Stop | Out-Null
    Say ("  创建成功: {0} -> {1}" -f $NatName, $Pool) 'Green'
    $created = $true
} catch {
    $msg = $_.Exception.Message
    Say ("  创建失败: {0}" -f $msg) 'Red'
    Write-Host ""
    Say "  --- 常见错误与对策 ---" 'Cyan'
    if ($msg -match 'already exists|已存在') {
        Say "  「已存在」: 换个 nat_name, 或先执行 Remove-NetNat -Name '*' " 'Yellow'
    } elseif ($msg -match '0x80070005|Access is denied|拒绝访问') {
        Say "  「拒绝访问」: 确认是管理员; 检查 WinNat 服务是否 Running" 'Yellow'
    } elseif ($msg -match '0x803B0012|specified|参数') {
        Say "  「参数错误」: 网段格式必须形如 192.168.137.0/24" 'Yellow'
    } else {
        Say "  未知错误。建议按顺序尝试:" 'Yellow'
        Say "    1) Restart-Service WinNat -Force" 'Gray'
        Say "    2) Remove-NetNat -Name '$NatName' -Confirm:`$false" 'Gray'
        Say "    3) 换网段 (config.json) 后重跑 install.ps1" 'Gray'
        Say "    4) 启用 Hyper-V: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All" 'Gray'
    }
}

# ---------------------- [6] 验证 ----------------------
Head "[6/6] 验证"
Start-Sleep -Seconds 2
$nat = @(Get-NetNat -ErrorAction SilentlyContinue)
if ($nat.Count -gt 0) {
    $nat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active -Auto | Out-String | ForEach-Object { Say $_ }
} else {
    Say "  没有 NAT 实例" 'Red'
}

$active = @($nat | Where-Object { $_.Active })
Say ""
if ($active.Count -gt 0) {
    Say "WinNat 就绪 ✓" 'Green'
    Say "接下来如果手机仍上不了网, 检查:" 'Cyan'
    Say "  1) 热点是否已启动 (网关 $Gateway 是否存在)" 'Gray'
    Say "  2) DHCP 服务是否在跑: Get-ScheduledTask -TaskName 'PppoeHotspotRelay-DHCP'" 'Gray'
    Say "  3) 拨号上行是否正常: ping 223.5.5.5" 'Gray'
    Say "  4) 防火墙规则: Get-NetFirewallRule -DisplayName 'PppoeHotspotRelay-*'" 'Gray'
    Say "  5) 若有 NAT 会话说明流量正在转换: Get-NetNatSession" 'Gray'
} else {
    Say "WinNat 仍未就绪 ✗" 'Red'
    Say "请把本脚本的完整输出发到项目 Issue。" 'Yellow'
}