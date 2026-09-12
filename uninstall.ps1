# =====================================================================
#  pppoe-hotspot-relay  卸载
#  撤销 install.ps1 造成的全部改动。
#  注意: 会关闭当前热点; 请先确认该热点上的设备不再需要联网。
# =====================================================================
#Requires -RunAsAdministrator
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Definition
$TaskName = 'PppoeHotspotRelay-DHCP'
$NatName  = 'PppoeHotspotRelayNat'

# 从 config.json 读取网关, 推导热点网段前缀。
# 网段是可配置的 (见 README「修改网段」), 所以不能写死。
$CfgFile = Join-Path $Root 'config.json'
$GwPrefix = if (Test-Path $CfgFile) {
    try {
        $g = (Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json).gateway
        $g -replace '\.\d+$', '.*'
    } catch { '192.168.137.*' }
} else { '192.168.137.*' }

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head($m) { Write-Host ""; Write-Host "===== $m =====" -ForegroundColor Cyan }

Say "pppoe-hotspot-relay  卸载程序" 'White'

# ---------------------- 安全确认 ----------------------
Head "[0/6] 安全确认"
$phone = Get-NetNeighbor -ErrorAction SilentlyContinue |
         Where-Object { $_.IPAddress -like $GwPrefix -and $_.State -ne 'Unreachable' `
                        -and $_.LinkLayerAddress -notlike 'FF-*' }
if ($phone) {
    Say "检测到热点上仍有设备连接:" 'Yellow'
    $phone | Format-Table IPAddress, LinkLayerAddress, State -Auto | Out-String | ForEach-Object { Say $_ 'Gray' }
    Say "卸载会断开这些设备。5 秒后继续 (Ctrl+C 取消)..." 'Yellow'
    Start-Sleep -Seconds 5
} else {
    Say "  热点上没有活动设备, 可以安全卸载。" 'Green'
}

# ---------------------- 停止并移除计划任务 ----------------------
Head "[1/6] 移除 DHCP 计划任务"
$t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($t) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Say ("  已移除: {0}" -f $TaskName) 'Green'
} else {
    Say "  计划任务不存在" 'Gray'
}

# ---------------------- 停止残留的 DHCP 进程 ----------------------
Head "[2/6] 停止残留 DHCP 进程"
$stopped = 0
foreach ($p in @(Get-Process pythonw, python -ErrorAction SilentlyContinue)) {
    try {
        $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction SilentlyContinue).CommandLine
        if ($cmdline -and $cmdline -match 'dhcp_server\.py') {
            Stop-Process -Id $p.Id -Force -ErrorAction Stop
            Say ("  已停止 PID {0}" -f $p.Id) 'Green'
            $stopped++
        }
    } catch {}
}
if ($stopped -eq 0) { Say "  没有需要停止的进程" 'Gray' }

# ---------------------- 移除 WinNat ----------------------
Head "[3/6] 移除 WinNat 实例"
$nats = @(Get-NetNat -ErrorAction SilentlyContinue)
if ($nats) {
    foreach ($n in $nats) {
        Remove-NetNat -Name $n.Name -Confirm:$false -ErrorAction SilentlyContinue
        Say ("  已移除 NAT: {0}" -f $n.Name) 'Green'
    }
} else {
    Say "  没有 NAT 实例" 'Gray'
}

# ---------------------- 移除防火墙规则 ----------------------
Head "[4/6] 移除防火墙规则"
$fw = @(Get-NetFirewallRule -DisplayName 'PppoeHotspotRelay-*' -ErrorAction SilentlyContinue)
if ($fw) {
    $fw | Remove-NetFirewallRule -ErrorAction SilentlyContinue
    Say ("  已移除 {0} 条规则" -f $fw.Count) 'Green'
} else {
    Say "  没有相关规则" 'Gray'
}
# 兼容早期手工创建的规则名
$legacy = @(Get-NetFirewallRule -DisplayName 'DormHotspot-*' -ErrorAction SilentlyContinue)
if ($legacy) {
    Say ("  发现早期规则 {0} 条, 一并移除" -f $legacy.Count) 'Yellow'
    $legacy | Remove-NetFirewallRule -ErrorAction SilentlyContinue
}

# ---------------------- 关闭热点 ----------------------
Head "[5/6] 关闭移动热点"
try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime -ErrorAction SilentlyContinue
    [void][Windows.Networking.Connectivity.NetworkInformation,Windows.Networking.Connectivity,ContentType=WindowsRuntime]
    [void][Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager,Windows.Networking.NetworkOperators,ContentType=WindowsRuntime]
    $profile = [Windows.Networking.Connectivity.NetworkInformation]::GetInternetConnectionProfile()
    if ($profile) {
        $mgr = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager]::CreateFromConnectionProfile($profile)
        $null = $mgr.StopTetheringAsync()
        Start-Sleep -Seconds 6
        Say ("  热点状态: {0}" -f $mgr.TetheringOperationalState) 'Green'
    } else {
        Say "  没有 Internet 配置, 跳过" 'Gray'
    }
} catch {
    Say ("  关闭热点失败: {0}" -f $_.Exception.Message) 'Yellow'
}

# ---------------------- 网络配置清理提示 ----------------------
Head "[6/6] 完成"
Say "以下内容已回滚:" 'White'
Say "  - DHCP 计划任务"
Say "  - WinNat 实例"
Say "  - 防火墙规则"
Say "  - 移动热点已关闭"
Say ""
Say "以下内容保留 (不影响系统, 如需清理请手动操作):" 'Gray'
Say "  - 承载网络配置 (netsh wlan, 已置为 disallow)"
Say "  - 网卡上可能残留的 $((Get-Content (Join-Path $Root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json).gateway) 地址 (随热点关闭自动释放)"
Say ""
Say "日志保留在 logs\ 目录, 可手动删除。" 'Gray'