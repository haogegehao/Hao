# pppoe-hotspot-relay

> [中文](README.md) | English

**Turn a Windows PPPoE broadband connection into a working WiFi hotspot.**

No Connectify, no mHotspot, **no Windows ICS (Internet Connection Sharing)**, and no third-party kernel drivers.

---

## Why this exists

Windows ICS (the `SharedAccess` service / `ipnathlp.dll`) is seriously broken when the
uplink is a **PPPoE dial-up connection**:

- Enabling sharing throws `0xc0000005` — a memory access violation inside `ipnathlp.dll`.
  The service process crashes outright.
- Or it throws `0x80040201` — a COM event-sink failure. The `InterfaceList` registry key
  is never written.
- The result: **the hotspot comes up, your phone connects, but it never gets internet.**

Almost every third-party hotspot tool (mHotspot, Connectify Lite, and the various
Chinese "WiFi sharing" utilities) is just a wrapper around ICS. On a machine with broken
ICS **they all fail the same way** — it is not their fault, it is ICS.

This project rebuilds the whole chain from **three built-in Windows components**,
completely bypassing `ipnathlp.dll`:

```
   PPPoE dial-up (Broadband Connection)
          ↑
   ┌──────┴──────┐
   │   WinNat    │  Windows NAT engine (same one Hyper-V uses), independent of ICS
   └──────┬──────┘
          ↓
   Windows Mobile Hotspot (WinRT API)   ← not netsh hosted network, not ICS
          ↓
   dhcp_server.py                       ← ICS DHCP is broken too, so we roll our own
          ↓
        phone / tablet / TV
```

## How it works

| Layer | Component used | Why not the ICS-based approach |
|---|---|---|
| **AP** | Windows Mobile Hotspot (`Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager`, Win10 1709+) | A completely different sharing stack with no relation to `ipnathlp.dll` |
| **DHCP** | `dhcp_server.py` (this project, pure Python stdlib) | The ICS DHCP component dies together with `SharedAccess` |
| **NAT** | `WinNat` (`New-NetNat`) | A built-in, independent driver — unaffected by ICS crashes |
| **Uplink** | Native Windows PPPoE dial-up | Kept exactly as-is |

## Requirements

- Windows 10 1709+ / Windows 11 (with the Mobile Hotspot WinRT API)
- A wireless adapter that supports hosted network or mobile hotspot
  (check `netsh wlan show drivers` — "Hosted network supported" must be `Yes`)
- Python 3.8+ (developed and verified on 3.14.7)
- Administrator privileges

## Quick start

### 1. Dial up first

Connect your PPPoE connection in "Network Connections". The script auto-detects a
connected PPPoE interface as the uplink.

### 2. One-click install

Open PowerShell **as Administrator**:

```powershell
cd pppoe-hotspot-relay
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

The script will:

1. Detect and enable Mobile Hotspot (`netsh wlan set hostednetwork mode=disallow` frees the adapter)
2. Start the hotspot via the WinRT API and set SSID / passphrase
3. Create a `WinNat` instance (internal prefix `192.168.137.0/24`)
4. Add firewall rules (allow DHCP UDP 67/68 and the hotspot subnet)
5. Register the DHCP server as a **Scheduled Task** (auto-start, highest privileges, no login required)

### 3. Connect

Look for the SSID configured in `config.json` (default `DormHotspot`) and connect.
Your phone should get an address in `192.168.137.100-200`.

## Configuration

Edit `config.json`:

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

Re-run `install.ps1` to apply changes.

## Changing the subnet

The default subnet is `192.168.137.0/24`. **Windows Mobile Hotspot itself uses this
subnet**, and Hyper-V's Default Switch uses it too, so conflicts are likely. If your
upstream network is also in this range you must change it.

**You only need to edit `config.json`.** `install.ps1` derives the NAT prefix from
`gateway` automatically (last octet zeroed + `/24`), so no script changes are needed:

```powershell
$cfg  = Get-Content .\config.json -Raw | ConvertFrom-Json
$pool = ($cfg.gateway -replace '\.\d+$', '.0') + '/24'   # this is what the script does
```

### Steps

**1. Edit `config.json`** — for example to `10.20.30.0/24`:

```json
{
  "gateway": "10.20.30.1",
  "pool_start": "10.20.30.100",
  "pool_end": "10.20.30.200"
}
```

**2. Re-run `install.ps1`** (it removes the old WinNat instance and firewall rules first,
then rebuilds for the new subnet):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**3. Verify**:

```powershell
Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active
Get-NetUDPEndpoint -LocalPort 67        # LocalAddress should be the new gateway
```

### Notes

- **The mask is fixed at `/24`.** Keep `gateway` and `pool_*` inside the same `/24`.
- **The pool must not include the gateway address.** With gateway `10.20.30.1`, start the pool at `.100`.
- **Avoid conflicting ranges**: `192.168.137.0/24` (Mobile Hotspot + Hyper-V default) and
  whatever your upstream network uses. Check with `route print` or
  `Get-NetRoute -AddressFamily IPv4`.
- Devices must **re-obtain their addresses** after a change. If a phone keeps its old
  address, "Forget" the WiFi and reconnect.
- To revert: edit `config.json` back and re-run `install.ps1`. No uninstall needed.

## Daily use

```powershell
# Check status
powershell -File .\scripts\status.ps1

# Uninstall (reverts everything)
powershell -File .\uninstall.ps1
```

Nothing to do after boot — the hotspot and DHCP start automatically.
If the PPPoE link drops and reconnects, just re-run `install.ps1` (it is idempotent).

## Troubleshooting

### Phone connects but never gets an IP

1. Check the DHCP log: `logs\dhcp.log`
   - `DISCOVER ... -> OFFER` but no `REQUEST ... -> ACK` → **the OFFER never reached the phone**
   - No `DISCOVER` at all → the DHCP request never arrived (firewall or bind issue)
2. Confirm the DHCP server is running:
   ```powershell
   Get-ScheduledTask -TaskName 'PppoeHotspotRelay-DHCP'
   Get-NetUDPEndpoint -LocalPort 67
   ```
3. Confirm it is bound to the right address. It must be `192.168.137.1:67`,
   **not** `0.0.0.0:67`.
   > This matters a lot. When bound to `0.0.0.0`, Windows may pick the wrong source
   > address and the kernel silently drops the OFFER.

### Phone has an IP but no internet

1. Check the WinNat instance exists and is active:
   ```powershell
   Get-NetNat | Format-Table Name, InternalIPInterfaceAddressPrefix, Active
   ```
2. Check for NAT sessions (sessions mean traffic is being translated):
   ```powershell
   Get-NetNatSession | Select-Object -First 10
   ```
3. Confirm the PPPoE uplink works: `ping 223.5.5.5`

### Hotspot won't start

- The wireless adapter may be occupied by a client connection: one adapter cannot be a
  client and an AP at the same time
- Check the driver: `netsh wlan show drivers` — "Hosted network supported" must be `Yes`

## Alternative approaches

If this project does not fit your situation, these are the realistic alternatives.

### 1. Use Windows ICS manually (try this first)

`Win+R` → `ncpa.cpl` → right-click your PPPoE connection → Properties → **Sharing** tab →
tick *"Allow other network users to connect through this computer's Internet connection"* →
pick the hotspot adapter → OK.

Worth trying before anything else: it is the built-in path, and if it works you need no
extra software at all. It fails on this author's machine with `ipnathlp.dll` crashes, but
many machines are fine.

### 2. Let the phone dial PPPoE itself

The PC only provides the WiFi AP; the phone runs a PPPoE client with the same credentials.
No NAT, no DHCP, no ICS involved.

- **Requires** your provider/network to allow multiple concurrent sessions on one account
  (common in some Chinese dorm networks, not universal).
- Android has no built-in PPPoE client — this generally needs root, or a phone that can
  be configured for PPPoE over Ethernet/WiFi.
- Also uses one more simultaneous session, which some ISPs cap.

### 3. Move the PPPoE dial to a router

Cheapest permanent fix: any inexpensive router that speaks PPPoE, with its WAN port on the
dorm line. PC and phone both become plain clients and Windows never touches the routing.

- Costs money (but very little, and no software to maintain).
- Does not work if you cannot physically reach or modify the network.

### 4. Buy a commercial tool with its own NAT driver

Connectify Hotspot **Pro** ships its own NAT driver and does not depend on ICS. This is
one of the very few commercial tools that genuinely bypasses ICS.

- **Paid** (the free Lite edition uses ICS and will fail the same way).
- ⚠️ Avoid "cracked" copies: these regularly bundle miners and backdoors, and they load a
  kernel-mode NDIS driver, so an infection means full machine compromise.

### 5. Run a software router in a VM (OpenWrt)

Run OpenWrt under Hyper-V/VMware, let it dial PPPoE and do NAT itself, and connect the PC
to its LAN.

- **Requires the `New-NetNat` / Hyper-V features** and a working virtual switch.
- **Hyper-V has no native USB passthrough**, so a *USB* WiFi adapter cannot be handed to
  the VM — which means the VM cannot host the WiFi AP itself. You would still need
  Windows to run the AP.
- Heavier and harder to maintain than this project.

## Known limitations

- **Occupies the `192.168.137.0/24` subnet.** Conflicts with upstream networks or Hyper-V's
  Default Switch. Changing it requires editing `config.json` only (see "Changing the subnet").
- **The NAT subnet is fixed at `/24`.** `install.ps1` derives it from `gateway`
  (last octet zeroed + `/24`), so `gateway` and `pool_*` must share the same `/24`.
- The hotspot runs on **5GHz by default** (channel auto-selected). Some older devices may
  not see it; restrict the adapter band in Device Manager if needed.
- Depends on the Windows Mobile Hotspot feature, which some trimmed-down Windows images lack.

## Development notes

Three non-obvious traps that were hit while building this, all encoded in the code and CI:

1. **The DHCP socket must bind to the gateway address, not `0.0.0.0`.** When bound to the
   wildcard address, Windows may select the wrong source address and the kernel silently
   drops the OFFER/ACK. The client then loops forever sending `DISCOVER` and stalls at
   "Obtaining IP address".
2. **PowerShell 5.1 cannot await WinRT `IAsyncOperation` / `IAsyncAction`.** The types are
   not auto-loaded, `AsTask` generic inference fails, and neither `GetResults()` nor
   `Status` is reachable. The scripts use fire-and-forget calls followed by polling.
3. **`.ps1` files need a UTF-8 BOM.** PowerShell 5.1 decodes a BOM-less script using the
   system ANSI code page (GBK on Chinese systems), which mangles non-ASCII string literals
   and produces confusing syntax errors. `scripts/check_ps_syntax.py` enforces this in CI.

## Disclaimer

This project is for sharing a broadband connection **you are legitimately entitled to use**
with **your own** devices. Follow the usage policies of your network (dorm, campus, ISP).
The author is not responsible for misuse.

## License

MIT
