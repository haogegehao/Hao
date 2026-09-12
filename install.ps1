# =====================================================================
#  pppoe-hotspot-relay  一键安装
#  以管理员身份运行。可反复执行（幂等）。
# =====================================================================
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$CfgPath  = Join-Path $Root 'config.json'
$TaskName = 'PppoeHotspotRelay-DHCP'
$NatName  = 'PppoeHotspotRelayNat'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }

Say "pppoe-hotspot-relay  安装程序" 'White'
Say "工程目录: $Root"

# ---------------------- 前置检查 ----------------------
Head "[1/8] 环境检查"
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Say "错误: 需要管理员权限。" 'Red'; exit 1 }
Say "  管理员权限: OK" 'Green'

# 找 Python
$PyExe = $null
foreach ($cand in @('C:\Python314\pythonw.exe', 'C:\Python314\python.exe', 'pythonw.exe', 'python.exe')) {
    if (Test-Path $cand) { $PyExe = (Resolve-Path $cand).Path; break }
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd) {
        # python.exe -> 优先同目录 pythonw.exe
        $pw = Join-Path (Split-Path $cmd.Source -Parent) 'pythonw.exe'
        $PyExe = if (Test-Path $pw) { $pw } else { $cmd.Source }
        break
    }
}
if (-not $PyExe) { Say "错误: 找不到 Python。请安装 Python 3.8+ 并加入 PATH。" 'Red'; exit 1 }
Say "  Python: $PyExe" 'Green'

$dhcpScript = Join-Path $Root 'dhcp_server.py'
if (-not (Test-Path $dhcpScript)) { Say "错误: 缺少 dhcp_server.py" 'Red'; exit 1 }

# 读配置
if (-not (Test-Path $CfgPath)) { Say "错误: 缺少 config.json" 'Red'; exit 1 }
$cfg = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$SSID     = $cfg.ssid
$PASS     = $cfg.passphrase
$Gateway  = $cfg.gateway
$Pool     = ($Gateway -replace '\.\d+$', '.0') + '/24'
Say "  SSID        : $SSID"
Say "  网关        : $Gateway"
Say "  NAT 内部网段: $Pool"

# ---------------------- 上行检查 ----------------------
Head "[2/8] 检查 PPPoE 上行"
$ppp = Get-NetAdapter -ErrorAction SilentlyContinue |
       Where-Object { $_.InterfaceDescription -match 'WAN Miniport|PPP|PPPOE' -and $_.Status -eq 'Up' }
if ($ppp) {
    Say ("  PPPoE 上行: {0}" -f ($ppp.Name -join ', ')) 'Green'
    $pppIp = @(Get-NetIPAddress -InterfaceAlias $ppp[0].Name -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike '169.254.*' })
    if ($pppIp) { Say ("  公网 IP: {0}" -f (($pppIp.IPAddress) -join ', ')) 'Green' }
    else { Say "  警告: PPPoE 已连接但没拿到 IPv4 地址。" 'Yellow' }
} else {
    Say "  警告: 没有处于已连接状态的 PPPoE 连接。" 'Yellow'
    Say "  请先在「网络连接」里连上宽带连接, 否则手机无法上网。" 'Yellow'
}

# ---------------------- 启动热点 ----------------------
Head "[3/8] 启动 Windows 移动热点 (WinRT API)"
# 释放网卡: 关闭 netsh 承载网络, 交给移动热点
netsh wlan stop hostednetwork | Out-Null
netsh wlan set hostednetwork mode=disallow | Out-Null
Say "  已关闭 netsh 承载网络 (让移动热点独占网卡)"

try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]

    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if (-not $profile) {
        Say "  错误: 没有 Internet 连接配置。请先拨号。" 'Red'
    } else {
        Say ("  上网配置: {0}" -f $profile.ProfileName) 'Green'
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)

        # 注意: PS 5.1 无法等待 WinRT 的 IAsyncOperation/IAsyncAction
        # (AsTask 泛型推断失败, GetResults 不存在), 这里采用 fire-and-forget + 轮询确认
        $ap = New-Object Windows.Networking.NetworkOperators.NetworkOperatorTetheringAccessPointConfiguration
        $ap.Ssid = $SSID
        $ap.Passphrase = $PASS
        try { $null = $mgr.ConfigureAccessPointAsync($ap) } catch { Say ("  配置异常: {0}" -f $_.Exception.Message) 'Yellow' }
        Start-Sleep -Seconds 3

        $cur = $mgr.GetCurrentAccessPointConfiguration()
        Say ("  已设置 SSID/密码: {0} / {1}" -f $cur.Ssid, $cur.Passphrase) 'Green'

        if ("$($mgr.TetheringOperationalState)" -ne 'On') {
            try { $null = $mgr.StartTetheringAsync() } catch { Say ("  启动异常: {0}" -f $_.Exception.Message) 'Yellow' }
            Start-Sleep -Seconds 8
        }
        Say ("  热点状态: {0}" -f $mgr.TetheringOperationalState) `
            $(if ("$($mgr.TetheringOperationalState)" -eq 'On') { 'Green' } else { 'Red' })
    }
} catch {
    Say ("  WinRT 失败: {0}" -f $_.Exception.Message) 'Red'
    Say "  你的系统可能不支持移动热点 (需 Win10 1709+)" 'Yellow'
}

# 等网关地址出现
for ($i = 0; $i -lt 10; $i++) {
    $gw = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $Gateway })
    if ($gw.Count -gt 0) { break }
    Start-Sleep -Seconds 2
}
$gw = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $Gateway })
if ($gw.Count -gt 0) {
    Say ("  热点网关 {0} 已就绪 (网卡: {1})" -f $Gateway, ($gw.InterfaceAlias -join ',')) 'Green'
} else {
    Say ("  警告: 未出现网关地址 {0}, 热点可能未真正启动。" -f $Gateway) 'Yellow'
}

# ---------------------- WinNat ----------------------
Head "[4/8] 创建 WinNat 实例"

# WinNat 是独立驱动服务, 创建 NAT 前必须确保它可用
$natSvc = Get-Service WinNat -ErrorAction SilentlyContinue
if (-not $natSvc) {
    Say "  错误: 未找到 WinNat 服务 (Windows NAT Driver)。" 'Red'
    Say "  该系统可能缺少该组件 (精简版 / LTSC / 组件被清理过)。" 'Red'
    Say "  尝试启用 Hyper-V 平台:" 'Yellow'
    Say "    Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All" 'Gray'
    Say "  或改用 README「其他方案」中的做法。" 'Yellow'
} else {
    Say ("  WinNat 服务: {0} / {1}" -f $natSvc.Status, $natSvc.StartType) `
        $(if ("$($natSvc.Status)" -eq 'Running') { 'Green' } else { 'Yellow' })
    if ($natSvc.StartType -eq 'Disabled') {
        Say "  启动类型为 Disabled, 改为 Manual..." 'Yellow'
        try { Set-Service WinNat -StartupType Manual -ErrorAction Stop } catch {}
    }
    if ((Get-Service WinNat).Status -ne 'Running') {
        Say "  正在启动 WinNat..." 'Yellow'
        try { Start-Service WinNat -ErrorAction Stop; Start-Sleep -Seconds 2 } catch {
            Say ("  启动失败: {0}" -f $_.Exception.Message) 'Red'
        }
        Say ("  状态: {0}" -f (Get-Service WinNat).Status) 'Cyan'
    }
}

# 清理: 只删除本项目的、以及与目标网段冲突的实例。
# 不无差别删除 —— Hyper-V 的 Default Switch 也依赖 NAT 实例, 删错会影响虚拟机网络。
foreach ($n in @(Get-NetNat -ErrorAction SilentlyContinue)) {
    $isOurs = ($n.Name -eq $NatName)
    $isConflict = ($n.InternalIPInterfaceAddressPrefix -eq $Pool)
    if ($isOurs -or $isConflict) {
        Say ("  移除冲突 NAT: {0} ({1})" -f $n.Name, $n.InternalIPInterfaceAddressPrefix) 'Yellow'
        Remove-NetNat -Name $n.Name -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        Say ("  保留其他 NAT 实例: {0} ({1})" -f $n.Name, $n.InternalIPInterfaceAddressPrefix) 'Gray'
    }
}

$natOk = $false
try {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $Pool -ErrorAction Stop | Out-Null
    Say ("  已创建 NAT: {0}  内部网段 {1}" -f $NatName, $Pool) 'Green'
} catch {
    Say ("  创建失败: {0}" -f $_.Exception.Message) 'Red'
}

# 回读验证 —— 不能只看 New-NetNat 有没有抛异常
Start-Sleep -Seconds 2
$natNow = @(Get-NetNat -ErrorAction SilentlyContinue)
if (@($natNow | Where-Object { $_.Name -eq $NatName }).Count -gt 0) { $natOk = $true }

if ($natNow.Count -gt 0) {
    $natNow | Format-Table Name, InternalIPInterfaceAddressPrefix, Active -Auto | Out-String |
        ForEach-Object { Say $_ }
}

if (-not $natOk) {
    Write-Host ""
    Say "  WinNat 实例未创建成功。诊断与修复:" 'Red'
    if (@(Get-NetNat -ErrorAction SilentlyContinue).Count -eq 0) {
        Say "  Get-NetNat 返回空, 但创建也失败 —— 典型原因:" 'Yellow'
        Say "    · WinNat 服务未能启动 (见上面 [4/8] 的状态输出)" 'Gray'
        Say "    · 该系统缺少 Windows NAT Driver 组件" 'Gray'
    } else {
        Say "  机器上已有其他 NAT 实例占用网段 (常见于 Hyper-V Default Switch," 'Yellow'
        Say "  它默认也用 192.168.137.0/24)。WinNat 限制一个网段只能有一个实例。" 'Yellow'
        Say "  >>> 解决办法: 改网段。" 'Cyan'
        Say "      编辑 config.json 里的 gateway / pool_start / pool_end (如 10.20.30.x)," 'Cyan'
        Say "      然后重新运行本脚本。详见 README「修改网段」。" 'Cyan'
    }
    Say "  一键诊断: powershell -File .\scripts\fix-netnat.ps1" 'Cyan'
}

# ---------------------- 防火墙 ----------------------
Head "[5/8] 配置防火墙规则"
Get-NetFirewallRule -DisplayName 'PppoeHotspotRelay-*' -ErrorAction SilentlyContinue |
    Remove-NetFirewallRule -ErrorAction SilentlyContinue

$rules = @(
    @{N='PppoeHotspotRelay-DHCP-67-In';  D='Inbound';  Proto='UDP'; Port=67},
    @{N='PppoeHotspotRelay-DHCP-68-In';  D='Inbound';  Proto='UDP'; Port=68},
    @{N='PppoeHotspotRelay-DHCP-68-Out'; D='Outbound'; Proto='UDP'; Port=68},
    @{N='PppoeHotspotRelay-DNS-In';      D='Inbound';  Proto='UDP'; Port=53}
)
$n = 0
foreach ($r in $rules) {
    try {
        New-NetFirewallRule -DisplayName $r.N -Direction $r.D -Action Allow `
            -Protocol $r.Proto -LocalPort $r.Port -Profile Any -ErrorAction Stop | Out-Null
        $n++; Say ("  已添加 {0}" -f $r.N) 'Green'
    } catch { Say ("  {0} 失败: {1}" -f $r.N, $_.Exception.Message) 'Yellow' }
}
foreach ($d in @('Inbound', 'Outbound')) {
    $nm = "PppoeHotspotRelay-Pool-$d"
    try {
        New-NetFirewallRule -DisplayName $nm -Direction $d -Action Allow `
            -RemoteAddress $Pool -Profile Any -ErrorAction Stop | Out-Null
        $n++; Say ("  已添加 {0}" -f $nm) 'Green'
    } catch { Say ("  {0} 失败: {1}" -f $nm, $_.Exception.Message) 'Yellow' }
}
Say ("  共添加 {0}/6 条规则" -f $n) 'Cyan'

# ---------------------- 注册 DHCP 计划任务 ----------------------
Head "[6/8] 注册 DHCP 服务器为计划任务"
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute $PyExe `
          -Argument "`"$dhcpScript`" --quiet" -WorkingDirectory $Root
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount `
             -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description 'pppoe-hotspot-relay DHCP server' `
        -ErrorAction Stop | Out-Null
    Say ("  已注册计划任务: {0}" -f $TaskName) 'Green'
    Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    $ti = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
          Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    Say ("  任务状态: {0}" -f (Get-ScheduledTask -TaskName $TaskName).State) 'Green'
} catch {
    Say ("  注册失败: {0}" -f $_.Exception.Message) 'Red'
    Say "  回退方案: 手动运行 pythonw dhcp_server.py --quiet" 'Yellow'
}

# ---------------------- 验证 ----------------------
Head "[7/8] 验证服务链"
$checks = @(
    @{N='热点网关 IP';   C={ @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object {$_.IPAddress -eq $Gateway}).Count -gt 0 }},
    @{N='DHCP 监听 67';  C={ @(Get-NetUDPEndpoint -LocalPort 67 -EA SilentlyContinue | Where-Object {$_.LocalAddress -eq $Gateway}).Count -gt 0 }},
    @{N='WinNat 实例';   C={ @(Get-NetNat -EA SilentlyContinue | Where-Object {$_.Active}).Count -gt 0 }},
    @{N='防火墙规则';    C={ @(Get-NetFirewallRule -DisplayName 'PppoeHotspotRelay-*' -EA SilentlyContinue).Count -gt 0 }},
    @{N='PPPoE 上行';    C={ @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object {$_.InterfaceAlias -match '宽带|PPPoE' -and $_.IPAddress -notlike '169.*'}).Count -gt 0 }}
)
$allOk = $true
$failHints = @{
    'WinNat 实例' = @(
        '添加-网段冲突最常见: Hyper-V 的 Default Switch 默认也占 192.168.137.0/24,',
        '        而 WinNat 限制一个网段只能有一个实例。改网段即可 (编辑 config.json 后重跑本脚本)。',
        '      · 也可能是 WinNat 服务没起来, 或该系统缺少 Windows NAT Driver。',
        '      · 一键诊断: powershell -File .\scripts\fix-netnat.ps1'
    )
    'DHCP 监听 67' = @(
        'DHCP 未绑定到网关地址。检查计划任务是否运行:',
        '        Get-ScheduledTask -TaskName ''PppoeHotspotRelay-DHCP''',
        '      若任务正常, 看日志 logs\dhcp.log 里 socket 绑定那一行。'
    )
    '热点网关 IP' = @(
        '热点未真正启动。确认无线网卡支持承载网络:',
        '        netsh wlan show drivers  (「支持的承载网络」必须为「是」)'
    )
    'PPPoE 上行' = @(
        '没有处于已连接状态的 PPPoE 连接。请先在「网络连接」里拨号。'
    )
    '防火墙规则' = @(
        '规则未创建。以管理员身份重跑本脚本。'
    )
}
foreach ($c in $checks) {
    $ok = & $c.C
    if (-not $ok) { $allOk = $false }
    Say ("  [{0}] {1}" -f $(if ($ok) { '✓' } else { '✗' }), $c.N) $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok -and $failHints.ContainsKey($c.N)) {
        foreach ($h in $failHints[$c.N]) { Say ("      $h") 'Yellow' }
    }
}

Head "[8/8] 完成"
if ($allOk) {
    Say "全部就绪!" 'Green'
    Say ("用手机连接 WiFi: {0}   密码: {1}" -f $SSID, $PASS) 'Green'
    Say "手机应获得 $($cfg.pool_start) - $($cfg.pool_end) 之间的地址。" 'Gray'
} else {
    Say "部分检查未通过, 请查看上面的红色项。" 'Yellow'
}
Say ""
Say ("日志: {0}" -f (Join-Path $Root 'logs\dhcp.log')) 'Cyan'
Say "      (DHCP 服务器写的是文件, 不输出到终端。文件要到手机首次获取 IP 时才建立)" 'Gray'
Say ("状态: powershell -File `"{0}`"" -f (Join-Path $Root 'scripts\status.ps1')) 'Cyan'
Say ("卸载: powershell -File `"{0}`"" -f (Join-Path $Root 'uninstall.ps1')) 'Cyan'
Say ("诊断: powershell -File `"{0}`"" -f (Join-Path $Root 'scripts\fix-netnat.ps1')) 'Cyan'