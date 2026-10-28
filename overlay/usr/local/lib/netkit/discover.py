"""netkit.discover —— 局域网设备发现(多源合并)。

单一手段都不可靠:
- 只看 ARP 表: 只见过面的设备才在里面, 刚上线的设备看不到;
- 只 ping 扫描: 关了 ICMP 的设备 ping 不通, 但它明明在线;
- 只看 mDNS: 只有开了 mDNS 的设备才广播。

所以这里把四个来源合起来, 每个设备记录"它是从哪儿被发现的"(sources),
这样用户能判断"这个设备是真的在线, 还是只是 ARP 表里的旧记录"。

发现手段(按可用性自动降级):
  1. arp-scan      —— 二层 ARP 扫描, 最准, 需要 root(系统里 sudo 免密)
  2. arping        —— arp-scan 缺失时的替代, 也是二层
  3. ping sweep    —— 上面都没有时的兜底, 三层
  4. ip neigh      —— 被动读取内核已有的邻居表(零成本, 永远先做)
另外还抓 mDNS(avahi)与 LLDP(交换机通告), 用来补主机名和设备类型。
"""

from __future__ import annotations

import concurrent.futures
import re
import socket

from . import util


# ---------------------------------------------------------------- 邻居表(被动)


def neighbors() -> dict:
    """读内核 ARP/IP 邻居表 -> {ip: {"mac":..., "state":...}}"""
    out = {}
    data = util.sh_json(["ip", "-j", "neigh", "show"]) or []
    for item in data:
        ip = item.get("dst", "")
        if not ip or ip.lower() == "failed":
            continue
        out[ip] = {
            "mac": util.normalize_mac(item.get("lladdr", "")),
            "state": item.get("state", ""),
            "iface": item.get("dev", ""),
        }
    return out


# ---------------------------------------------------------------- ARP 扫描(二层)


def arp_scan(cidr: str, iface: str = "") -> dict:
    """arp-scan 扫一个网段 -> {ip: mac}; 没有 arp-scan 或失败返回空字典。"""
    if not util.have("arp-scan"):
        return {}
    cmd = ["arp-scan", "-q", "-x"]
    if iface:
        cmd += ["-I", iface]
    cmd.append(cidr)
    rc, out, err = util.run(cmd, timeout=90, need_root=True)
    if rc != 0:
        return {}
    found = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        ip, mac = parts[0], util.normalize_mac(parts[1])
        if util.ip_to_int(ip) is None or not mac:
            continue
        found[ip] = {"mac": mac, "state": "REACHABLE"}
    return found


def arping_scan(cidr: str, iface: str = "") -> dict:
    """arping 逐个 ping(并行), 拿到二层 MAC -> {ip: mac}"""
    if not util.have("arping"):
        return {}
    targets = util.host_range(cidr)
    if not targets:
        return {}
    found = {}
    workers = 32
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {}
        for ip in targets:
            cmd = ["arping", "-c", "1", "-w", "1"]
            if iface:
                cmd += ["-I", iface]
            cmd.append(ip)
            futs[pool.submit(util.run, cmd, 3.0, True)] = ip
        for fut in concurrent.futures.as_completed(futs):
            ip = futs[fut]
            rc, out, _ = fut.result()
            if rc != 0:
                continue
            m = re.search(r"([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5})", out)
            if m:
                found[ip] = {"mac": util.normalize_mac(m.group(1)), "state": "REACHABLE"}
    return found


# ---------------------------------------------------------------- ping 扫描(三层)


def ping_sweep(cidr: str, workers: int = 64) -> list:
    """扫网段里哪些 IP 回应 ICMP -> [ip, ...]"""
    targets = util.host_range(cidr)
    if not targets:
        return []
    alive = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(util.run, ["ping", "-n", "-c", "1", "-W", "1", ip], 3.0, False): ip for ip in targets}
        for fut in concurrent.futures.as_completed(futs):
            ip = futs[fut]
            rc, out, _ = fut.result()
            if rc == 0 and "bytes from" in out:
                alive.append(ip)
    return alive


# ---------------------------------------------------------------- mDNS / 主机名


def mdns_hosts() -> dict:
    """mDNS 解析 -> {ip: {"hostname":..., "services":[...]}}"""
    out = {}
    if not util.have("avahi-browse"):
        return out
    rc, res, _ = util.run(["avahi-browse", "-rpt"], timeout=12)
    if rc != 0:
        return out
    for line in res.splitlines():
        # 形如: "=";192.168.6.5";"my-laptop";"_workstation._tcp"
        if not line.startswith("="):
            continue
        fields = line.split(";")
        if len(fields) < 4:
            continue
        ip = fields[1].strip('"')
        host = fields[2].strip('"')
        svc = fields[3].strip('"')
        if util.ip_to_int(ip) is None:
            continue
        rec = out.setdefault(ip, {"hostname": "", "services": []})
        if host and host != "nogroup" and not rec["hostname"]:
            rec["hostname"] = host
        if svc:
            rec["services"].append(svc)
    return out


def resolve_name(ip: str) -> str:
    """反向 DNS: 拿到主机名(取不到就返回空串)。"""
    try:
        socket.setdefaulttimeout(1.5)
        name = socket.gethostbyaddr(ip)[0]
        return name or ""
    except (OSError, socket.herror, socket.gaierror):
        return ""


def ssh_banner(ip: str, timeout: float = 1.0) -> str:
    """抓 SSH banner 里的软件标识, 常常能看出是 OpenWrt / 群晖 / 树莓派。"""
    import socket as s

    try:
        with s.create_connection((ip, 22), timeout=timeout) as sock:
            sock.settimeout(timeout)
            data = sock.recv(200).decode("utf-8", "replace").strip()
            return data
    except OSError:
        return ""


# ---------------------------------------------------------------- LLDP(交换机)


def lldp_neighbors() -> list:
    """LLDP 邻居 -> [{chassis, port, system_name, description, ...}]"""
    out = []
    if not util.have("lldpcli"):
        return out
    rc, raw, _ = util.run(["lldpcli", "-f", "keyvalue", "show", "neighbors", "detail"], timeout=10)
    if rc != 0:
        return out
    cur = {}
    for line in raw.splitlines():
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower()
        val = val.strip()
        if key == "lldp chassis id":
            if cur:
                out.append(cur)
            cur = {"chassis": val}
        elif key:
            cur[key.replace(" ", "_").replace("/", "_")] = val
    if cur:
        out.append(cur)
    return out


# ---------------------------------------------------------------- 端口线索


COMMON_PORTS = [22, 80, 443, 445, 554, 631, 3389, 5000, 8080, 9100, 62078, 32400]


def port_scan(hosts: list, ports: list = None, timeout: float = 0.5) -> dict:
    """对已知主机做小范围 TCP 连接探测 -> {ip: [open_port, ...]}

    只连常见服务端口, 每个连接最多 timeout 秒, 用来猜设备类型(打印机 9100、
    NAS 445/32400、摄像头 554/8000、iPhone 62078 ...)。
    """
    ports = ports or COMMON_PORTS
    if not hosts:
        return {}
    out = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=64) as pool:
        futs = {}
        for ip in hosts:
            for p in ports:
                futs[pool.submit(util.tcp_open, ip, p, timeout)] = (ip, p)
        for fut in concurrent.futures.as_completed(futs):
            ip, p = futs[fut]
            if fut.result():
                out.setdefault(ip, []).append(p)
    return {ip: sorted(ps) for ip, ps in out.items()}


# ---------------------------------------------------------------- 汇总


def discover(cidr: str = "", iface: str = "", deep: bool = True, ports: bool = True,
              ident_gw: str = "") -> dict:
    """做一次完整的局域网发现, 返回设备字典。

    返回结构:
    {
      "hosts": {ip: {"ip","mac","hostname","services","ports","rtt_ms","sources":[...]}},
      "lldp": [...],
      "scanned": "192.168.6.0/24",
      "methods": ["arp-scan", "ping", ...],
    }
    """
    hosts = {}
    methods = []

    def touch(ip):
        return hosts.setdefault(
            ip, {"ip": ip, "mac": "", "hostname": "", "services": [], "ports": [], "rtt_ms": None, "sources": []}
        )

    # 1) 邻居表(被动, 零成本)
    nb = neighbors()
    for ip, info in nb.items():
        rec = touch(ip)
        rec["mac"] = rec["mac"] or info.get("mac", "")
        if "arp" not in rec["sources"]:
            rec["sources"].append("邻居表")

    # 2) 主动扫描
    scan_cidr = cidr
    if not scan_cidr:
        return {"hosts": hosts, "lldp": [], "scanned": "", "methods": ["邻居表"]}

    found = {}
    if deep:
        got = arp_scan(scan_cidr, iface)
        if got:
            methods.append("arp-scan")
        else:
            got = arping_scan(scan_cidr, iface)
            if got:
                methods.append("arping")
    if not found and not deep:
        pass
    for ip, info in found.items():
        rec = touch(ip)
        rec["mac"] = rec["mac"] or info.get("mac", "")
        rec["sources"].append("二层扫描")
    found = found

    # 3) ping sweep 补漏(设备可能不回 ARP 但回 ICMP, 或者 ARP 被限流)
    alive = ping_sweep(scan_cidr)
    if alive:
        methods.append("ping扫描")
    for ip in alive:
        rec = touch(ip)
        if "ping" not in rec["sources"]:
            rec["sources"].append("ping")
    # ping 出来的 IP 再从邻居表里补 MAC
    for ip in alive:
        if not hosts[ip]["mac"] and ip in nb:
            hosts[ip]["mac"] = nb[ip]["mac"]

    # 网关的 MAC: 用来判断哪些 ARP 应答是"网关代答"的假设备
    gw_mac = ""
    if ident_gw:
        nb_gw = neighbors().get(ident_gw, {})
        gw_mac = util.normalize_mac(nb_gw.get("mac", ""))

    # 4) mDNS
    md = mdns_hosts()
    if md:
        methods.append("mDNS")
    for ip, info in md.items():
        rec = touch(ip)
        rec["hostname"] = rec["hostname"] or info.get("hostname", "")
        for s in info.get("services", []):
            if s not in rec["services"]:
                rec["services"].append(s)
        if "mDNS" not in rec["sources"]:
            rec["sources"].append("mDNS")

    # 5) 主机名 + 延迟
    def enrich(item):
        ip, rec = item
        if not rec["hostname"]:
            rec["hostname"] = resolve_name(ip)
        rec["rtt_ms"] = util.ping_ms(ip, count=1, timeout=1.5)

    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as pool:
        list(pool.map(enrich, list(hosts.items())))

    # 6) 端口线索
    if ports and hosts:
        ps = port_scan(list(hosts.keys()))
        for ip, plist in ps.items():
            hosts[ip]["ports"] = plist
        if ps:
            methods.append("端口探测")

    # 7) 代理 ARP 过滤
    #   路由器开了 Proxy ARP 时, 它会替网段里所有地址应答 ARP, 于是 ping 扫描
    #   会把整个 /24 全部报成"在线"(实测某台路由器能报出 70+ 台假设备)。
    #   特征很明显: 一大批 IP 的 MAC 完全相同, 且这个 MAC 就是网关的 MAC。
    #   这种情况下只能信二层信息, 把这些假设备剔掉, 并在报告里说明白。
    proxy = _detect_proxy_arp(hosts, gw_mac)
    if proxy:
        # 网关本身也用这个 MAC, 得留着, 否则拓扑图里连网关都没了
        proxy["keep_ip"] = ident_gw if gw_mac and gw_mac == proxy["mac"] else ""
        for ip in list(hosts.keys()):
            if ip == proxy["keep_ip"]:
                continue
            if hosts[ip].get("mac") == proxy["mac"]:
                del hosts[ip]
        methods.append(f"已过滤代理ARP假设备({proxy['count']}个)")

    lldp = lldp_neighbors()
    if lldp:
        methods.append("LLDP")

    return {
        "hosts": hosts,
        "lldp": lldp,
        "scanned": scan_cidr,
        "methods": methods,
    }


def _detect_proxy_arp(hosts: dict, gw_mac: str) -> dict:
    """识别 Proxy ARP: 大量 IP 指向同一个 MAC。返回 {"mac":..,"count":..,"keep_ip":..} 或空字典。"""
    if not hosts:
        return {}
    counter = {}
    for ip, rec in hosts.items():
        mac = rec.get("mac", "")
        if mac:
            counter.setdefault(mac, []).append(ip)
    if not counter:
        return {}
    mac, ips = max(counter.items(), key=lambda kv: len(kv[1]))
    # 门槛: 同一个 MAC 顶了 8 个以上地址, 且占全部有 MAC 设备的 40% 以上
    total_with_mac = sum(len(v) for v in counter.values())
    if len(ips) >= 8 and len(ips) * 100 >= total_with_mac * 40:
        keep = ""
        if gw_mac and gw_mac == mac:
            keep = gw_mac
        return {"mac": mac, "count": len(ips), "keep_ip": ""}
    return {}
