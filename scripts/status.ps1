# =====================================================================
#  pppoe-hotspot-relay  状态查询
# =====================================================================
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root     = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$CfgPath  = Join-Path $Root 'config.json'
$TaskName = 'PppoeHotspotRelay-DHCP'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }

$cfg = if (Test-Path $CfgPath) { Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { $null }
$Gateway = if ($cfg) { $cfg.gateway } else { '192.168.137.1' }

Say "pppoe-hotspot-relay  状态" 'White'

Head "服务链"
$checks = @(
    @{N='热点网关 IP';   C={ @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object {$_.IPAddress -eq $Gateway}).Count -gt 0 }},
    @{N='DHCP 监听 67';  C={ @(Get-NetUDPEndpoint -LocalPort 67 -EA SilentlyContinue | Where-Object {$_.LocalAddress -eq $Gateway}).Count -gt 0 }},
    @{N='WinNat 激活';   C={ @(Get-NetNat -EA SilentlyContinue | Where-Object {$_.Active}).Count -gt 0 }},
    @{N='防火墙规则';    C={ @(Get-NetFirewallRule -DisplayName 'PppoeHotspotRelay-*' -EA SilentlyContinue).Count -gt 0 }},
    @{N='PPPoE 上行';    C={ @(Get-NetIPAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object {$_.InterfaceAlias -match '宽带|PPPoE' -and $_.IPAddress -notlike '169.*'}).Count -gt 0 }}
)
foreach ($c in $checks) {
    $ok = & $c.C
    Say ("  [{0}] {1}" -f $(if ($ok) { '✓' } else { '✗' }), $c.N) $(if ($ok) { 'Green' } else { 'Red' })
}

Head "热点"
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if ($profile) {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
        Say ("  上网配置       : {0}" -f $profile.ProfileName)
        Say ("  热点状态       : {0}" -f $mgr.TetheringOperationalState) `
            $(if ("$($mgr.TetheringOperationalState)" -eq 'On') { 'Green' } else { 'Red' })
        $ap = $mgr.GetCurrentAccessPointConfiguration()
        Say ("  SSID / 密码    : {0} / {1}" -f $ap.Ssid, $ap.Passphrase)
    } else { Say "  没有 Internet 连接配置 (未拨号)" 'Yellow' }
} catch { Say ("  WinRT 查询失败: {0}" -f $_.Exception.Message) 'Yellow' }

Head "计划任务"
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    Say ("  状态: {0}" -f $t.State) $(if ("$($t.State)" -eq 'Running') { 'Green' } else { 'Yellow' })
    $ti = $t | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
    if ($ti) { Say ("  上次运行: {0}   结果: {1}" -f $ti.LastRunTime, $ti.LastTaskResult) }
} else { Say "  未注册" 'Red' }

Head "网络接口"
Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Up' } |
    Format-Table Name, InterfaceDescription, Status -Auto | Out-String | ForEach-Object { Say $_ }
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' } |
    Format-Table InterfaceAlias, IPAddress, PrefixOrigin -Auto | Out-String | ForEach-Object { Say $_ }

Head "默认路由"
Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object RouteMetric |
    Format-Table InterfaceAlias, NextHop, RouteMetric, InterfaceMetric -Auto |
    Out-String | ForEach-Object { Say $_ }

Head "NAT 会话 (手机流量是否正在被转换)"
$sess = @(Get-NetNatSession -ErrorAction SilentlyContinue)
Say ("  会话数: {0}" -f $sess.Count) $(if ($sess.Count -gt 0) { 'Green' } else { 'Yellow' })
if ($sess.Count -gt 0) {
    $sess | Select-Object -First 8 |
        Format-Table InternalSourceAddress, InternalSourcePort, ExternalSourceAddress, Protocol -Auto |
        Out-String | ForEach-Object { Say $_ }
}

Head "热点上的设备"
Get-NetNeighbor -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like "$(($Gateway -replace '\.\d+$',''))*" -and $_.State -ne 'Unreachable' `
                    -and $_.LinkLayerAddress -notlike 'FF-*' -and $_.IPAddress -notlike '*.255' } |
    Format-Table IPAddress, LinkLayerAddress, State -Auto | Out-String | ForEach-Object { Say $_ }
Say "(空 = 当前没有设备连接)"

Head "最近 DHCP 日志"
$log = Join-Path $Root 'logs\dhcp.log'
if (Test-Path $log) {
    Get-Content $log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Say ("  {0}" -f $_) 'Gray' }
} else { Say "  暂无日志" 'Gray' }