#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pppoe-hotspot-relay —— 极简 DHCP 服务器

为 Windows 移动热点提供 IP 分配, 绕开损坏的 ICS DHCP 组件。
纯 Python 标准库实现, 无第三方依赖。

用法:
    python dhcp_server.py [--config config.json] [--quiet]

需要管理员权限 (绑定 UDP 67)。
"""

import argparse
import ipaddress
import json
import os
import socket
import struct
import sys
import threading
import time

# ============================ 默认配置 ============================
DEFAULTS = {
    "gateway": "192.168.137.1",
    "subnet_mask": "255.255.255.0",
    "pool_start": "192.168.137.100",
    "pool_end": "192.168.137.200",
    "dns": ["223.5.5.5", "114.114.114.114"],
    "lease_time": 3600,
}

# ============================ DHCP 常量 ============================
DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPDECLINE = 1, 2, 3, 4
DHCPACK, DHCPNAK, DHCPRELEASE, DHCPINFORM = 5, 6, 7, 8

OPT_SUBNET_MASK = 1
OPT_ROUTER = 3
OPT_DNS = 6
OPT_HOSTNAME = 12
OPT_REQUESTED_IP = 50
OPT_LEASE_TIME = 51
OPT_MSG_TYPE = 53
OPT_SERVER_ID = 54
OPT_END = 255

MAGIC_COOKIE = b"\x63\x82\x53\x63"
BROADCAST = "255.255.255.255"
MSG_TYPE_NAME = {
    DHCPDISCOVER: "DISCOVER", DHCPOFFER: "OFFER", DHCPREQUEST: "REQUEST",
    DHCPDECLINE: "DECLINE", DHCPACK: "ACK", DHCPNAK: "NAK",
    DHCPRELEASE: "RELEASE", DHCPINFORM: "INFORM",
}

# ============================ 运行时状态 ============================
CFG = dict(DEFAULTS)
LEASES = {}
LOCK = threading.Lock()
LOGFILE = None
QUIET = False


def log(msg, echo=True):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}"
    if not QUIET and echo:
        print(line, flush=True)
    if LOGFILE:
        try:
            with open(LOGFILE, "a", encoding="utf-8") as f:
                f.write(line + "\n")
        except Exception:
            pass


def load_config(path=None):
    """按优先级加载配置: 显式路径 > 脚本同目录 config.json > 当前目录 > 默认值"""
    global CFG
    candidates = []
    if path:
        candidates.append(path)
    here = os.path.dirname(os.path.abspath(__file__))
    candidates.append(os.path.join(here, "config.json"))
    candidates.append(os.path.join(os.getcwd(), "config.json"))
    for c in candidates:
        if c and os.path.isfile(c):
            try:
                with open(c, "r", encoding="utf-8") as f:
                    data = json.load(f)
                for k, v in DEFAULTS.items():
                    CFG[k] = data.get(k, v)
                log(f"已加载配置: {c}")
                return c
            except Exception as e:
                log(f"读取配置失败 {c}: {e}")
    log("未找到 config.json, 使用默认配置")
    return None


def ip_to_bytes(ip):
    return socket.inet_aton(ip)


def bytes_to_ip(b):
    return socket.inet_ntoa(b)


def alloc_ip(mac, requested=None):
    """分配 IP: 复用未过期租约 > 满足 requested > 顺序分配"""
    with LOCK:
        now = time.time()
        if mac in LEASES and LEASES[mac]["expires"] > now:
            return LEASES[mac]["ip"]
        used = {v["ip"] for v in LEASES.values() if v["expires"] > now and v.get("ip")}
        if requested and requested not in used:
            try:
                net = ipaddress.ip_network(
                    f"{CFG['pool_start']}/{CFG['subnet_mask']}", strict=False)
                if ipaddress.ip_address(requested) in net:
                    LEASES[mac] = {"ip": requested, "expires": now + CFG["lease_time"],
                                   "hostname": ""}
                    return requested
            except Exception:
                pass
        start = int(ipaddress.ip_address(CFG["pool_start"]))
        end = int(ipaddress.ip_address(CFG["pool_end"]))
        for n in range(start, end + 1):
            cand = str(ipaddress.ip_address(n))
            if cand not in used:
                LEASES[mac] = {"ip": cand, "expires": now + CFG["lease_time"],
                               "hostname": ""}
                return cand
        return None


def parse_options(data):
    opts, i = {}, 0
    while i < len(data):
        code = data[i]
        if code == 0:
            i += 1
            continue
        if code == OPT_END or i + 1 >= len(data):
            break
        length = data[i + 1]
        opts[code] = data[i + 2:i + 2 + length]
        i += 2 + length
    return opts


def build_reply(xid, mac, yiaddr, msg_type, hostname=""):
    """构造 DHCP 响应 (BOOTP 固定头 236 字节 + magic cookie + options)"""
    pkt = struct.pack("!BBBBIHH", 2, 1, 6, 0, xid, 0, 0)
    pkt += ip_to_bytes("0.0.0.0")            # ciaddr
    pkt += ip_to_bytes(yiaddr)               # yiaddr  —— 分配给客户端的地址
    pkt += ip_to_bytes(CFG["gateway"])       # siaddr
    pkt += ip_to_bytes("0.0.0.0")            # giaddr
    pkt += mac.ljust(16, b"\x00")            # chaddr
    pkt += b"\x00" * 64                      # sname
    pkt += b"\x00" * 128                     # file
    pkt += MAGIC_COOKIE

    opts = bytes([OPT_MSG_TYPE, 1, msg_type])
    opts += bytes([OPT_SERVER_ID, 4]) + ip_to_bytes(CFG["gateway"])
    opts += bytes([OPT_LEASE_TIME, 4]) + struct.pack("!I", CFG["lease_time"])
    opts += bytes([OPT_SUBNET_MASK, 4]) + ip_to_bytes(CFG["subnet_mask"])
    opts += bytes([OPT_ROUTER, 4]) + ip_to_bytes(CFG["gateway"])
    dns = CFG["dns"]
    opts += bytes([OPT_DNS, 4 * len(dns)]) + b"".join(ip_to_bytes(d) for d in dns)
    if hostname:
        hb = hostname.encode("utf-8", "ignore")[:32]
        opts += bytes([OPT_HOSTNAME, len(hb)]) + hb
    opts += bytes([OPT_END])

    pkt += opts
    if len(pkt) < 300:
        pkt += b"\x00" * (300 - len(pkt))
    return pkt


def send_reply(tx, rx, pkt, client_ip, client_addr, tag):
    """广播 + 单播双发。广播可能被丢弃, 单播是保底路径。"""
    sent = []
    try:
        tx.sendto(pkt, (BROADCAST, 68))
        sent.append("bcast")
    except Exception as e:
        sent.append(f"bcast_FAIL:{e}")

    for dst in {client_addr, client_ip}:
        if dst and dst not in ("0.0.0.0", BROADCAST):
            try:
                tx.sendto(pkt, (dst, 68))
                sent.append(f"uni:{dst}")
            except Exception as e:
                sent.append(f"uni_FAIL:{e}")

    if tx is not rx:
        try:
            rx.sendto(pkt, (BROADCAST, 68))
            sent.append("bcast2")
        except Exception:
            pass
    return ", ".join(sent)


def make_rx_socket(bind_ip):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind((bind_ip, 67))
    return s


def main():
    global CFG, LOGFILE, QUIET

    ap = argparse.ArgumentParser(description="pppoe-hotspot-relay DHCP server")
    ap.add_argument("--config", help="配置文件路径")
    ap.add_argument("--quiet", action="store_true", help="只写日志文件, 不输出控制台")
    args = ap.parse_args()
    QUIET = args.quiet

    # 日志文件
    here = os.path.dirname(os.path.abspath(__file__))
    logdir = os.path.join(here, "logs")
    try:
        os.makedirs(logdir, exist_ok=True)
        LOGFILE = os.path.join(logdir, "dhcp.log")
    except Exception:
        LOGFILE = None

    load_config(args.config)

    # ---------- 绑定接收 socket ----------
    # 关键: 必须绑定到网关具体地址。绑 0.0.0.0 时 Windows 可能选错源地址,
    # 导致 OFFER/ACK 被内核丢弃, 客户端会卡在"正在获取 IP 地址"。
    rx = None
    for bind_ip in (CFG["gateway"], "0.0.0.0"):
        try:
            rx = make_rx_socket(bind_ip)
            log(f"接收 socket 绑定成功: {bind_ip}:67")
            break
        except OSError as e:
            log(f"绑定 {bind_ip}:67 失败: {e}")
    if rx is None:
        log("无法绑定 UDP 67 —— 请以管理员身份运行", echo=True)
        return 1

    # ---------- 发送 socket ----------
    tx = rx
    try:
        ts = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        ts.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        ts.bind((CFG["gateway"], 67))
        tx = ts
        log(f"发送 socket 绑定: {CFG['gateway']}:67 (源地址确定)")
    except OSError as e:
        log(f"发送 socket 独立绑定失败 ({e}), 复用接收 socket")

    log("=" * 62)
    log("  pppoe-hotspot-relay  DHCP 服务器")
    log("=" * 62)
    log(f"  网关 / 服务器 : {CFG['gateway']}")
    log(f"  地址池        : {CFG['pool_start']} - {CFG['pool_end']}")
    log(f"  子网掩码      : {CFG['subnet_mask']}")
    log(f"  DNS           : {', '.join(CFG['dns'])}")
    log(f"  租约          : {CFG['lease_time']} 秒")
    if LOGFILE:
        log(f"  日志文件      : {LOGFILE}")
    log("=" * 62)
    log("  等待 DHCP 请求...")
    log("")

    # ---------- 主循环 ----------
    while True:
        try:
            data, addr = rx.recvfrom(2048)
        except OSError as e:
            log(f"接收错误: {e}")
            time.sleep(0.5)
            continue

        if len(data) < 240 or data[236:240] != MAGIC_COOKIE or data[0] != 1:
            continue

        xid = struct.unpack("!I", data[4:8])[0]
        mac = data[28:34]
        opts = parse_options(data[240:])
        if OPT_MSG_TYPE not in opts:
            continue

        mt = opts[OPT_MSG_TYPE][0]
        host = opts.get(OPT_HOSTNAME, b"").decode("utf-8", "ignore")
        req = bytes_to_ip(opts[OPT_REQUESTED_IP]) if OPT_REQUESTED_IP in opts else None
        macs = ":".join(f"{b:02x}" for b in mac)
        kind = MSG_TYPE_NAME.get(mt, str(mt))

        if mt == DHCPDISCOVER:
            ip = alloc_ip(mac, req)
            if not ip:
                log(f"{kind:9s} {macs} {host} -> 地址池耗尽")
                continue
            pkt = build_reply(xid, mac, ip, DHCPOFFER, host)
            how = send_reply(tx, rx, pkt, ip, addr[0], "offer")
            log(f"{kind:9s} {macs} {host} -> OFFER {ip}   [{how}]")

        elif mt == DHCPREQUEST:
            with LOCK:
                cur = LEASES.get(mac, {}).get("ip")
            ip = cur or req or alloc_ip(mac, req)
            if not ip:
                try:
                    tx.sendto(build_reply(xid, mac, "0.0.0.0", DHCPNAK), (BROADCAST, 68))
                except Exception:
                    pass
                log(f"{kind:9s} {macs} -> NAK (无可用地址)")
                continue
            with LOCK:
                LEASES[mac] = {"ip": ip, "expires": time.time() + CFG["lease_time"],
                               "hostname": host}
            pkt = build_reply(xid, mac, ip, DHCPACK, host)
            how = send_reply(tx, rx, pkt, ip, addr[0], "ack")
            log(f"{kind:9s} {macs} {host} -> ACK {ip}   ★ 完成   [{how}]")

        elif mt == DHCPRELEASE:
            with LOCK:
                if mac in LEASES:
                    log(f"{kind:9s} {macs} 释放 {LEASES[mac]['ip']}")
                    del LEASES[mac]

        elif mt == DHCPDECLINE:
            with LOCK:
                if mac in LEASES:
                    log(f"{kind:9s} {macs} 拒绝 {LEASES[mac]['ip']}")
                    del LEASES[mac]

        elif mt == DHCPINFORM:
            # 客户端已有地址, 只要配置信息
            pkt = build_reply(xid, mac, addr[0], DHCPACK, host)
            try:
                tx.sendto(pkt, (addr[0], 68))
            except Exception:
                pass
            log(f"{kind:9s} {macs} -> ACK (INFORM)")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log("\n[停止] DHCP 服务器已退出")
        sys.exit(0)