# pppoe-hotspot-relay
> 中文 | [English](README_EN.md)


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

## 修改网段

默认占用 `192.168.137.0/24`。**Windows 移动热点本身会使用这个网段**，Hyper-V 的
Default Switch 同样占用它，两者可能冲突。如果你的上级网络也在这个网段内，必须换一个。

**好消息：只需改 `config.json` 一处。** `install.ps1` 会从 `gateway` 自动推导 NAT 网段
（末位归零 + `/24`），无需改动脚本：

```powershell
$cfg  = Get-Content .\config.json -Raw | ConvertFrom-Json
$pool = ($cfg.gateway -replace '\.\d+$', '.0') + '/24'   # 脚本内部就是这么算的
```

### 步骤

**1. 编辑 `config.json`**，换成新网段（以 `10.20.30.0/24` 为例）：

```json
{
  "gateway": "10.20.30.1",
  "pool_start": "10.20.30.100",
  "pool_end": "10.20.30.200"
}
```

**2. 重新执行 `install.ps1`**（会先移除旧 WinNat 与旧防火墙规则，再按新网段重建）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**3. 验证**：

```powershell
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active
Get-NetUDPEndpoint -LocalPort 67        # LocalAddress 应为新的 gateway
```

### 注意事项

- **子网掩码固定 `/24`**，请保持 `gateway` 与 `pool_*` 在同一个 `/24` 内。
- **地址池不要包含网关地址**。例如 gateway 为 `10.20.30.1`，池从 `.100` 起。
- **避开冲突网段**：`192.168.137.0/24`（移动热点 + Hyper-V 默认），以及上级网络
  正在使用的网段。用 `route print` 或 `Get-NetRoute -AddressFamily IPv4` 可查看现有路由。
- 改完需让热点上的设备**重新获取地址**。手机上若残留旧网段地址，先在手机上
  「忘记」该 WiFi 再重连。
- 想彻底改回默认值：编辑 `config.json` 后重跑 `install.ps1` 即可，无需先卸载。

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


## 其他方案

如果本项目不适合你的情况，这些是现实可选的替代路径。

### 1. 先手动开 ICS（建议第一步就试）

`Win+R` → `ncpa.cpl` → 右键你的 PPPoE 连接 → 属性 → **共享** 选项卡 →
勾选「允许其他网络用户通过此计算机的 Internet 连接来连接」→ 选择承载网卡 → 确定。

**这是最该先试的一条**：它是系统内置路径，成了就完全不需要任何额外软件。
作者这台机器上它会触发 `ipnathlp.dll` 崩溃，但**很多机器是正常的**——
也许你只需要点一下勾选框。

### 2. 让手机自己拨 PPPoE

电脑只提供 WiFi 承载，手机用同一组账号密码自己跑 PPPoE 客户端。
**完全不涉及 NAT、DHCP、ICS。**

- **前提**：你的宽带/宿舍允许**同一账号多设备同时拨号**（部分校园网支持，但不通用）。
- **难点**：安卓没有内置 PPPoE 客户端，通常需要 root，或用支持 PPPoE over WiFi 的设备。
- 也会多占用一个并发会话数，部分运营商会限制。

### 3. 把拨号搬到路由器上

最省事的永久方案：随便一台几十块的支持 PPPoE 的路由器，WAN 口接宿舍网线，
路由器自己拨号。电脑和手机都退化成普通客户端，**Windows 完全不需要管路由**。

- 需要花钱（但很少，且**之后零维护**）。
- 如果你物理上接触不到线路、也没法改网络，这条路不通。

### 4. 买自带 NAT 驱动的商业工具

Connectify Hotspot **Pro** 自带 NAT 驱动，不依赖 ICS——
这是极少数真正绕过 ICS 的商业软件。

- **付费**（免费版 Lite 走的就是 ICS，会以同样的方式失败）。
- ⚠️ **别用破解版**：这类破解包普遍捆绑挖矿与后门，而它们要加载**内核态 NDIS 驱动**，
  一旦中招等于整机权限失守。作者最初也是想找破解版，绕了一圈才确认正版或本项目
  才是省事的选择。

### 5. 虚拟机里跑软路由（OpenWrt）

用 Hyper-V/VMware 跑 OpenWrt，让它自己拨 PPPoE 并做 NAT，电脑接入它的 LAN。

- **需要** `New-NetNat` / Hyper-V 功能可用，以及可用的虚拟交换机。
- **Hyper-V 没有原生 USB 直通**，所以 **USB 无线网卡无法交给虚拟机**——
  这意味着虚拟机自己开不了 WiFi AP，仍然要靠 Windows 起热点。
- 比本项目重，维护成本更高。
## 已知限制

- **占用 `192.168.137.0/24` 网段**。若上级网络或 Hyper-V 的 Default Switch 也用这个网段会冲突。改网段只需编辑 `config.json` 一处，详见上文「修改网段」。
- **NAT 网段固定为 `/24`**。`install.ps1` 从 `gateway` 自动推导（末位归零 + `/24`），所以 `gateway` 与 `pool_*` 必须在同一个 `/24` 内。
- 热点运行在 **5GHz（默认自动选信道）**，部分老旧设备可能搜不到，需要的话在设备管理器里限制网卡频段。
- 依赖 Windows 移动热点功能，精简版系统可能缺失该组件。

## 免责声明

本项目仅用于把**你自己拥有合法使用权的宽带连接**共享给**你自己**的设备。
请遵守你所在网络（宿舍/校园/运营商）的使用规定。作者不对任何滥用行为负责。

## 许可

MIT
