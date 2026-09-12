# pppoe-hotspot-relay

**在 Windows 上把 PPPoE 宽带连接转成可用的 WiFi 热点。**

不依赖 Connectify，不依赖 mHotspot，**不依赖 Windows ICS（Internet 连接共享）**，无需安装任何第三方内核驱动。

---

## 为什么需要这个

Windows 的 ICS（`SharedAccess` 服务 / `ipnathlp.dll`）在处理 **PPPoE 拨号连接**时存在严重缺陷：

- 配置共享时报 `0xc0000005`（`ipnathlp.dll` 内存访问违例），服务进程直接崩溃
- 或报 `0x80040201`（COM 事件链路断开），`InterfaceList` 注册表项永远写不进去
- 结果是：**热点能开、手机能连，但永远上不了网**

绝大多数第三方热点软件（mHotspot、Connectify Lite、各类国产 WiFi 共享工具）本质上都是给 ICS 套壳，
所以在 ICS 坏掉的机器上**它们全都失败**——这不是软件的问题，是 ICS 的问题。

本项目用 **Windows 自带的三套组件重新搭了一条完整链路**，全程绕开 `ipnathlp.dll`：

```
   PPPoE 拨号 (宽带连接)
          ↑
   ┌──────┴──────┐
   │   WinNat    │  Windows 自带 NAT 引擎 (Hyper-V 同款), 独立于 ICS
   └──────┬──────┘
          ↓
   Windows 移动热点 (WinRT API)   ← 不是 netsh 承载网络, 也不是 ICS
          ↓
   dhcp_server.py                 ← 因为 ICS 的 DHCP 组件同样不可用
          ↓
        手机 / 平板 / 电视
```

## 工作原理

| 层 | 用的组件 | 为什么不用 ICS 的方案 |
|---|---|---|
| **AP 层** | Windows 移动热点（`Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager`，Win10 1709+） | WinRT 的全新共享栈，与 `ipnathlp.dll` 无关联 |
| **DHCP 层** | `dhcp_server.py`（本项目，纯 Python 标准库） | ICS 的 DHCP 组件随 `SharedAccess` 一起失效 |
| **NAT 层** | `WinNat`（`New-NetNat`） | 系统自带、独立驱动，不受 ICS 崩溃影响 |
| **上行** | 系统原生 PPPoE 拨号 | 保留原拨号方式，不改动 |

## 环境要求

- Windows 10 1709+ / Windows 11（需支持移动热点 WinRT API）
- 一块**支持承载网络或移动热点**的无线网卡
  （用 `netsh wlan show drivers` 检查"支持的承载网络"是否为"是"）
- Python 3.8+（本项目在 3.14.7 上开发验证）
- 管理员权限

## 快速开始

### 1. 先拨上宽带

在「网络连接」里连上 PPPoE（脚本会自动寻找已连接的 PPPoE 连接作为上行）。

### 2. 一键安装

**以管理员身份**打开 PowerShell：

```powershell
cd pppoe-hotspot-relay
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

脚本会自动完成：

1. 检测并启用「移动热点」（`netsh wlan set hostednetwork mode=disallow` 释放网卡）
2. 通过 WinRT API 启动热点，设置 SSID 与密码
3. 创建 `WinNat` 实例（内部网段 `192.168.137.0/24`）
4. 添加防火墙规则（放行 DHCP UDP 67/68 与热点网段）
5. 把 DHCP 服务器注册为**计划任务**（开机自启、最高权限、无需登录）

### 3. 连接

手机搜索 `install.ps1` 里配置的 SSID（默认 `DormHotspot`）并连接即可。
手机应该会拿到 `192.168.137.100-200` 之间的地址。

## 配置

编辑 `config.json`（首次运行 `install.ps1` 会自动生成）：

```json
{
  "ssid": "DormHotspot",
  "passphrase": "dorm12345678",
  "gateway": "192.168.137.1",
  "pool_start": "192.168.137.100",
  "pool_end": "192.168.137.200",
  "dns": ["223.5.5.5", "114.114.114.114"],
  "lease_time": 3600
}
```

改完重新跑一次 `install.ps1` 即可生效。

## 日常使用

```powershell
# 查看状态
powershell -File .\scripts\status.ps1

# 卸载（撤销全部改动）
powershell -File .\uninstall.ps1
```

开机后无需任何操作，热点与 DHCP 会自动启动。
如果拨号掉线重连，重跑一次 `install.ps1` 即可（幂等，可反复执行）。

## 故障排查

### 手机连上了但拿不到 IP

1. 看 DHCP 日志：`logs\dhcp.log`
   - 有 `DISCOVER ... -> OFFER` 但没有 `REQUEST ... -> ACK` → **OFFER 没送到手机**
   - 完全没有 `DISCOVER` → DHCP 请求没到达主机（防火墙或绑定问题）
2. 确认 DHCP 服务在跑：
   ```powershell
   Get-ScheduledTask -TaskName 'PppoeHotspotRelay-DHCP'
   Get-NetUDPEndpoint -LocalPort 67
   ```
3. 确认绑定到了正确地址（应为 `192.168.137.1:67`，**不是** `0.0.0.0:67`）
   > 这一点很关键：绑 `0.0.0.0` 时 Windows 可能选错源地址，导致 OFFER 被丢弃。

### 手机有 IP 但上不了网

1. 检查 WinNat 是否存在且激活：
   ```powershell
   Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active
   ```
2. 检查是否有 NAT 会话（有会话说明流量正在被转换）：
   ```powershell
   Get-NetNatSession | Select-Object -First 10
   ```
3. 确认 PPPoE 上行正常：`ping 223.5.5.5`

### 热点起不来

- 无线网卡可能被客户端连接占用：一块网卡不能同时当客户端和 AP
- 检查驱动：`netsh wlan show drivers` 里"支持的承载网络"必须是"是"

## 已知限制

- **占用 `192.168.137.0/24` 网段**。如果你的上级网络也用这个网段，会造成冲突，需要同时修改 `config.json` 里的 `gateway` / `pool_*` 和 `install.ps1` 里的 NAT 网段。
- **Hyper-V 的 Default Switch 也使用 `192.168.137.0/24`**，两者可能冲突。若同时使用请改网段。
- 热点运行在 **5GHz（默认自动选信道）**，部分老旧设备可能搜不到，需要的话在设备管理器里限制网卡频段。
- 依赖 Windows 移动热点功能，精简版系统可能缺失该组件。

## 免责声明

本项目仅用于把**你自己拥有合法使用权的宽带连接**共享给**你自己**的设备。
请遵守你所在网络（宿舍/校园/运营商）的使用规定。作者不对任何滥用行为负责。

## 许可

MIT