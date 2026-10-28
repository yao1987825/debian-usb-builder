"""netkit.topo —— 把发现到的信息组装成一张"局域网拓扑图"(终端 ASCII 树)。

拓扑不是画出来的物理拓扑(那需要交换机 SNMP/LLDP 全网采集), 而是
**从本机视角能看到的结构**:

    本机
     ├── 默认网关(路由器/网关)
     │     └── 上游(从 traceroute 看下一跳, 或 LLDP 通告的邻居)
     ├── 交换机(LLDP 通告的邻居)
     └── 同网段其它设备(按类型分组)

对用户来说这就够了: 网段变了没有、网关是谁、哪些设备在线、
哪个设备是打印机/摄像头/手机, 一眼能看出来。
"""

from __future__ import annotations

import collections

from . import devclass, discover, netinfo, util

BOX = {
    "tee": "├── ",
    "last": "└── ",
    "pipe": "│   ",
    "space": "    ",
}


def _lldp_match(lldp_list, mac):
    """在 LLDP 邻居里找 MAC 对得上的那台(交换机/路由器)。"""
    mac = util.normalize_mac(mac)
    if not mac:
        return None
    for item in lldp_list:
        chassis = util.normalize_mac(item.get("chassis", ""))
        if chassis and chassis == mac:
            return item
    return None


def _traceroute_upstream(target: str, hops: int = 3) -> list:
    """traceroute 看网关往外的下一跳, 用于在图上画"上游"。"""
    if not target or not util.have("traceroute"):
        return []
    rc, out, _ = util.run(["traceroute", "-n", "-w", "1", "-q", "1", "-m", str(hops), target], timeout=20)
    if rc != 0:
        return []
    hops_out = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line[0].isdigit() is False:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            hop = int(parts[0])
        except ValueError:
            continue
        ip = parts[1]
        if ip in ("*", "?"):
            continue
        hops_out.append({"hop": hop, "ip": ip})
    return hops_out


def build(ident: dict, disc: dict) -> dict:
    """把身份 + 发现结果组装成拓扑结构。"""
    hosts = disc.get("hosts", {})
    lldp_list = disc.get("lldp", [])
    gw_ip = ident.get("gateway", "")
    gw_mac = ""
    if gw_ip and gw_ip in hosts:
        gw_mac = hosts[gw_ip].get("mac", "")

    # ---- 给每个设备定型 ----
    devices = {}
    for ip, rec in hosts.items():
        rec = dict(rec)
        rec["is_gateway"] = ip == gw_ip
        lldp = _lldp_match(lldp_list, rec.get("mac", ""))
        rec["lldp"] = lldp
        rec["is_switch"] = bool(lldp)
        if lldp:
            rec.setdefault("services", [])
        cls = devclass.classify(rec)
        rec.update(
            {
                "kind": cls["kind"],
                "vendor": cls["vendor"] or devclass.oui_of(rec.get("mac", "")),
                "reason": cls["reason"],
                "icon": cls["icon"],
            }
        )
        # 交换机/网关的厂商优先用 LLDP 通告的品牌
        if lldp:
            desc = lldp.get("system_description", "") or lldp.get("system_name", "")
            rec["lldp_name"] = lldp.get("system_name", "")
            rec["lldp_desc"] = desc
        devices[ip] = rec

    # ---- 分组 ----
    gateway = devices.get(gw_ip)
    switches = [d for d in devices.values() if d.get("is_switch") and d["ip"] != gw_ip]
    # 本机自己、以及别的网卡(容器/隧道)上的地址都不进拓扑树 ——
    # 用户关心的是"局域网里有哪些设备", 不是本机的虚拟网卡邻居
    self_ip = ident.get("ip", "")
    my_net = ident.get("ip", "")
    my_prefix = ident.get("prefixlen", 24)

    def in_my_lan(ip):
        if not my_net:
            return True
        return util.in_same_subnet(ip, my_net, my_prefix)

    others = [
        d
        for d in devices.values()
        if d["ip"] != gw_ip
        and d["ip"] != self_ip
        and not d.get("is_switch")
        and in_my_lan(d["ip"])
    ]
    # 排序: 已知类型在前, 同类按 IP 排
    order = {
        "路由器/网关": 0,
        "交换机": 1,
        "电脑": 2,
        "服务器": 3,
        "NAS": 4,
        "NAS/共享": 5,
        "打印机": 6,
        "摄像头/NVR": 7,
        "电视": 8,
        "手机": 9,
        "Apple 设备": 10,
        "智能家居设备": 11,
        "unknown": 99,
    }
    others.sort(key=lambda d: (order.get(d["kind"], 50), d["ip"]))

    # ---- 上游链路 ----
    upstream = []
    if gw_ip:
        upstream = _traceroute_upstream(gw_ip if gw_ip else "", hops=3)

    return {
        "identity": ident,
        "gateway": gateway,
        "switches": switches,
        "devices": others,
        "upstream": upstream,
        "lldp": lldp_list,
        "methods": disc.get("methods", []),
        "scanned": disc.get("scanned", ""),
    }


def _dev_line(dev: dict) -> list:
    """一台设备的详细信息(缩进 1 格起)。"""
    lines = []
    bits = []
    if dev.get("mac"):
        bits.append(f"MAC {dev['mac']}")
    if dev.get("vendor"):
        bits.append(f"厂商 {dev['vendor']}")
    if dev.get("hostname"):
        bits.append(f"主机名 {dev['hostname']}")
    if dev.get("lldp_name"):
        bits.append(f"通告名 {dev['lldp_name']}")
    if dev.get("rtt_ms") is not None:
        bits.append(f"延迟 {dev['rtt_ms']:.1f}ms")
    if dev.get("ports"):
        bits.append("端口 " + ",".join(str(p) for p in dev["ports"][:8]))
    if dev.get("services"):
        bits.append("服务 " + ",".join(s.split(".")[0] for s in dev["services"][:4]))
    if bits:
        lines.append("    · " + " · ".join(bits))
    if dev.get("reason"):
        lines.append(f"    · 判定依据: {dev['reason']}")
    if dev.get("lldp_desc"):
        lines.append(f"    · 设备描述: {dev['lldp_desc']}")
    return lines


def render(topo: dict, changes: list = None) -> str:
    """渲染成终端 ASCII 树(带颜色)。"""
    ident = topo.get("identity", {})
    out = []
    title = f"局域网拓扑 · {ident.get('timestamp', '')} · 本机 {ident.get('hostname', '')}"
    out.append(util.color(f"=== {title} ===", "cyan"))

    # 本机信息
    ifaces = ident.get("interfaces", [])
    if ifaces:
        out.append("")
        out.append(util.color("本机网络身份", "bold"))
        for i in ifaces:
            name = i["name"]
            if name.startswith(("docker", "br-", "veth", "virbr", "tun", "tap")):
                tag = "虚拟网卡"
            elif i.get("kind") == "wifi":
                tag = "WIFI"
            else:
                tag = i.get("kind") or "有线"
            line = f"  · {i['name']:<10} {i.get('ipv4') or '-':<16} {i.get('cidr') or '-':<18} {tag}"
            if i.get("mac"):
                line += f"  {i['mac']}"
            out.append(util.color(line, "gray"))
        gw = ident.get("gateway") or "无"
        dns = " ".join(ident.get("dns") or []) or "无"
        out.append(util.color(f"  · 网关 {gw}    DNS {dns}", "gray"))

    # 网段变化告警
    if changes:
        out.append("")
        for c in changes:
            out.append(util.color(f"⚠ 与上次相比: {c}", "yellow"))

    out.append("")
    out.append(util.color("拓扑结构", "bold"))

    # 网关
    gw = topo.get("gateway")
    branches = []
    if gw:
        extra = []
        if gw.get("mac"):
            extra.append(f"MAC {gw['mac']}")
        if gw.get("vendor"):
            extra.append(f"厂商 {gw['vendor']}")
        if gw.get("hostname"):
            extra.append(f"主机名 {gw['hostname']}")
        if gw.get("rtt_ms") is not None:
            extra.append(f"延迟 {gw['rtt_ms']:.1f}ms")
        gw_lines = ["    · " + " · ".join(extra)] if extra else []
        # 上游跳: 跳过网关自己那一跳, 否则图上会出现"网关 -> 网关"
        up = [h for h in (topo.get("upstream") or []) if h.get("ip") != gw["ip"]]
        for hop in up:
            gw_lines.append(f"    └─ 上游(第{hop['hop']}跳)  {hop['ip']}")
        branches.append(("🌐 路由器/网关  " + gw["ip"], gw_lines))

    for sw in topo.get("switches", []):
        lines = _dev_line(sw)
        head = f"🔀 交换机  {sw['ip']}"
        branches.append((head, lines))

    for dev in topo.get("devices", []):
        icon = dev.get("icon", "•")
        kind = dev.get("kind", "unknown")
        if kind == "unknown":
            kind = "未知设备"
        head = f"{icon} {kind}  {dev['ip']}"
        branches.append((head, _dev_line(dev)))

    if not branches:
        out.append(util.color("  (没发现其它设备 —— 可能整台机器就独占了这个网段)", "gray"))
    MAX_BRANCH = 40
    shown = branches[:MAX_BRANCH]
    for idx, (head, lines) in enumerate(shown):
        last = idx == len(shown) - 1
        out.append(util.color(BOX["last"] if last else BOX["tee"], "cyan") + head)
        prefix = BOX["space"] if last else BOX["pipe"]
        for line in lines:
            out.append(util.color(prefix, "cyan") + line)
    if len(branches) > MAX_BRANCH:
        out.append(util.color(f"    ... 还有 {len(branches) - MAX_BRANCH} 台设备没列(完整清单见 --json/报告)", "gray"))

    # 统计
    kinds = collections.Counter(d.get("kind", "unknown") for d in topo.get("devices", []) + ([topo["gateway"]] if topo.get("gateway") else []))
    vendors = collections.Counter(d.get("vendor") for d in topo.get("devices", []) + ([topo["gateway"]] if topo.get("gateway") else []) if d.get("vendor"))
    out.append("")
    out.append(util.color("统计", "bold"))
    out.append(
        util.color(
            f"  · 在线设备 {len(topo.get('devices', [])) + (1 if topo.get('gateway') else 0) + len(topo.get('switches', []))} 台"
            f" · 网段 {ident.get('cidr') or '未知'}"
            f" · 网关 {ident.get('gateway') or '无'}",
            "gray",
        )
    )
    if kinds:
        dist = " ".join(f"{k}×{v}" for k, v in kinds.most_common())
        out.append(util.color(f"  · 类型分布: {dist}", "gray"))
    if vendors:
        vdist = " ".join(f"{k}×{v}" for k, v in vendors.most_common(8))
        out.append(util.color(f"  · 厂商分布: {vdist}", "gray"))
    if topo.get("methods"):
        out.append(util.color(f"  · 发现手段: {' '.join(topo['methods'])}", "gray"))
    if any("代理ARP" in m for m in topo.get("methods", [])):
        out.append(
            util.color(
                "  · 注意: 路由器开启了 Proxy ARP(它替全网段应答), "
                "所以 ping 扫描不能代表设备是否在线, 只有带 MAC 的才算真设备",
                "yellow",
            )
        )
    return "\n".join(out)


def plain(topo: dict) -> str:
    """不带颜色的纯文本版本(写报告文件用)。"""
    import os

    old = os.environ.get("NO_COLOR")
    os.environ["NO_COLOR"] = "1"
    try:
        return render(topo)
    finally:
        if old is None:
            os.environ.pop("NO_COLOR", None)
        else:
            os.environ["NO_COLOR"] = old


def snapshot(topo: dict) -> dict:
    """给 AI/程序消费的结构化版本。"""
    ident = topo.get("identity", {})
    return {
        "generated_at": ident.get("timestamp"),
        "host": ident.get("hostname"),
        "local": {
            "ip": ident.get("ip"),
            "cidr": ident.get("cidr"),
            "mac": ident.get("mac"),
            "iface": ident.get("primary_iface"),
            "gateway": ident.get("gateway"),
            "dns": ident.get("dns"),
        },
        "gateway": topo.get("gateway"),
        "switches": topo.get("switches"),
        "upstream": topo.get("upstream"),
        "devices": topo.get("devices"),
        "methods": topo.get("methods"),
    }
