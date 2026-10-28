"""netkit.netinfo —— 本机网络身份采集 + 历史快照(用来发现"网段变了")。

用户最常见的一类故障: 家里路由器的网段从 192.168.1.0/24 改成了 192.168.6.0/24,
或者 DHCP 把本机挪到了另一个网段, 于是设备之间互相看不见。
这个模块把"本机现在处于什么网络位置"固化下来, 存进历史文件, 下次一比就知道变没变。
"""

from __future__ import annotations

import os
import socket

from . import util


def _iface_map() -> dict:
    """接口名 -> ip -j link 的那条记录。"""
    data = util.sh_json(["ip", "-j", "link", "show"]) or []
    out = {}
    for item in data:
        name = item.get("ifname")
        if name:
            out[name] = item
    return out


def interfaces() -> list:
    """所有非回环接口的基础信息: 名字/MAC/状态/IP/掩码。"""
    addr = util.sh_json(["ip", "-j", "addr", "show"]) or []
    links = _iface_map()
    out = []
    for item in addr:
        name = item.get("ifname", "")
        if not name or name == "lo":
            continue
        link = links.get(name, {})
        ips = []
        for a in item.get("addr_info", []) or []:
            if a.get("family") in ("inet", "inet6"):
                ips.append(
                    {
                        "family": a.get("family"),
                        "ip": a.get("local", ""),
                        "prefixlen": a.get("prefixlen", 0),
                        "cidr": f"{a.get('local')}/{a.get('prefixlen')}",
                    }
                )
        out.append(
            {
                "name": name,
                "mac": util.mac_of(link),
                "operstate": item.get("operstate", link.get("operstate", "")),
                "flags": item.get("flags", []),
                "mtu": link.get("mtu", 0),
                "kind": link.get("linkinfo", {}).get("info_kind", ""),
                "addresses": ips,
                "ipv4": next((i["ip"] for i in ips if i["family"] == "inet"), ""),
                "prefixlen": next((i["prefixlen"] for i in ips if i["family"] == "inet"), 0),
                "cidr": next((i["cidr"] for i in ips if i["family"] == "inet"), ""),
                "ipv6": next((i["ip"] for i in ips if i["family"] == "inet6"), ""),
            }
        )
    return out


def routes() -> list:
    """路由表(ip -j route), 网关/网段都从这里推。"""
    return util.sh_json(["ip", "-j", "route", "show"]) or []


def default_gateway() -> dict:
    """默认网关: {ip, iface, metric} —— 没有就返回空字典。"""
    best = {}
    for r in routes():
        if r.get("dst") != "default":
            continue
        gw = r.get("gateway", "")
        if not gw:
            continue
        metric = int(r.get("metric") or 0)
        if not best or metric < best.get("metric", 9999):
            best = {"ip": gw, "iface": r.get("dev", ""), "metric": metric}
    return best


def connected_routes() -> list:
    """直连网段(目标不是 default 的那条), 用来判断本机所在网段。"""
    out = []
    for r in routes():
        if r.get("dst") in ("default", None):
            continue
        if r.get("gateway"):
            continue  # 这条是走网关的, 不是直连
        out.append({"dst": r.get("dst", ""), "iface": r.get("dev", ""), "metric": r.get("metric", 0)})
    return out


def dns_servers() -> list:
    """DNS 服务器: 优先 systemd-resolved, 退回读 /etc/resolv.conf。"""
    servers = []
    rc, out, _ = util.run(["resolvectl", "dns"], timeout=5)
    if rc == 0 and out.strip():
        for line in out.splitlines():
            # 形如 "Link 2 (enp3s0): 192.168.6.1 223.5.5.5"
            if ":" in line:
                tail = line.split(":", 1)[1].strip()
            else:
                tail = line.strip()
            for tok in tail.split():
                if util.ip_to_int(tok) is not None:
                    servers.append(tok)
    if not servers:
        try:
            with open("/etc/resolv.conf", "r", encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if line.startswith("nameserver"):
                        parts = line.split()
                        if len(parts) > 1 and util.ip_to_int(parts[1]) is not None:
                            servers.append(parts[1])
        except OSError:
            pass
    # 去重且保持顺序
    seen, out = set(), []
    for s in servers:
        if s not in seen:
            seen.add(s)
            out.append(s)
    return out


def hostname() -> str:
    return socket.gethostname()


def wifi_info() -> dict:
    """无线网卡状态: 接口/SSID/信号/频段/信道/速率。"""
    info = {"present": False, "iface": "", "ssid": "", "signal_dbm": "", "freq": "", "channel": ""}
    if not util.have("iw"):
        return info
    devs = util.sh(["iw", "dev"], timeout=5)
    for line in devs.splitlines():
        if line.strip().startswith("Interface "):
            info["iface"] = line.split("Interface", 1)[1].strip()
            info["present"] = True
            break
    if not info["present"]:
        return info
    det = util.sh(["iw", "dev", info["iface"], "link"], timeout=5)
    for line in det.splitlines():
        s = line.strip()
        if s.startswith("SSID:"):
            info["ssid"] = s.split(":", 1)[1].strip()
        elif s.startswith("signal:"):
            info["signal_dbm"] = s.split(":", 1)[1].strip().split()[0]
        elif s.startswith("freq:"):
            info["freq"] = s.split(":", 1)[1].strip().split()[0]
        elif s.startswith("channel:"):
            info["channel"] = s.split(":", 1)[1].strip()
    return info


def identity() -> dict:
    """本机网络身份快照 —— 拓扑图与"网段变化检测"的输入。"""
    ifaces = interfaces()
    gw = default_gateway()
    primary = ""
    for i in ifaces:
        if gw.get("iface") and i["name"] == gw["iface"]:
            primary = i["name"]
            break
    if not primary:
        for i in ifaces:
            if i["ipv4"]:
                primary = i["name"]
                break
    pi = next((i for i in ifaces if i["name"] == primary), None)
    # cidr 必须是**网段地址**(192.168.6.0/24), 不是本机地址(192.168.6.186/24) ——
    # 后面拿它去扫全网段, 用主机地址扫会从 .187 开始, 漏掉前面一大片。
    cidr = util.cidr_of(pi["ipv4"], pi["prefixlen"]) if pi and pi["ipv4"] else ""
    return {
        "hostname": hostname(),
        "timestamp": util.now_iso(),
        "interfaces": ifaces,
        "primary_iface": primary,
        "ip": pi["ipv4"] if pi else "",
        "prefixlen": pi["prefixlen"] if pi else 0,
        "cidr": cidr,
        "mac": pi["mac"] if pi else "",
        "gateway": gw.get("ip", ""),
        "gw_iface": gw.get("iface", ""),
        "dns": dns_servers(),
        "routes": routes(),
        "connected": connected_routes(),
        "wifi": wifi_info(),
    }


# ---------------------------------------------------------------- 历史快照


def history_path() -> str:
    return os.path.join(util.state_dir(), "history.json")


def record_snapshot(ident: dict) -> str:
    """把本次身份存进历史(最多留 50 条)。"""
    path = history_path()
    data = util.read_json(path) or []
    if not isinstance(data, list):
        data = []
    entry = {
        "ts": ident.get("timestamp", util.now_iso()),
        "iface": ident.get("primary_iface", ""),
        "ip": ident.get("ip", ""),
        "cidr": ident.get("cidr", ""),
        "gateway": ident.get("gateway", ""),
        "dns": ident.get("dns", []),
    }
    data.append(entry)
    data = data[-50:]
    try:
        import json

        with open(path, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False, indent=2)
    except OSError:
        return ""
    return path


def previous_snapshot() -> dict:
    """上一次(不含本次)的快照; 没有就返回空字典。"""
    data = util.read_json(history_path()) or []
    if not isinstance(data, list) or not data:
        return {}
    return data[-1]


def compare_with_history(ident: dict) -> list:
    """和历史比一遍, 返回变化描述列表(空列表 = 没变化)。"""
    prev = previous_snapshot()
    if not prev:
        return []
    changes = []
    if prev.get("cidr") and ident.get("cidr") and prev["cidr"] != ident["cidr"]:
        changes.append(f"网段变了: {prev['cidr']} -> {ident['cidr']}")
    if prev.get("ip") and ident.get("ip") and prev["ip"] != ident["ip"]:
        changes.append(f"本机 IP 变了: {prev['ip']} -> {ident['ip']}")
    if prev.get("gateway") and ident.get("gateway") and prev["gateway"] != ident["gateway"]:
        changes.append(f"默认网关变了: {prev['gateway']} -> {ident['gateway']}")
    if prev.get("dns") and ident.get("dns") and set(prev["dns"]) != set(ident["dns"]):
        changes.append(f"DNS 变了: {' '.join(prev['dns'])} -> {' '.join(ident['dns'])}")
    return changes
