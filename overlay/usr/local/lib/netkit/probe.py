"""netkit.probe —— 局域网问题深度检测。

net-doctor 管的是"本机这台机器的网络栈通不通", 这里管的是
**局域网本身有没有毛病**: 网段变了没、网关换没、IP 冲不冲突、
丢包多少、MTU 被谁卡住、DNS 有没有被劫持、无线信号差不差、
上游是不是断了。

每个结论都带一条可直接执行的修复命令 —— 用户不用自己想下一步做什么。
"""

from __future__ import annotations

import re
import socket
import subprocess
import time

from . import netinfo, topo, util

OK = "ok"
WARN = "warn"
BAD = "bad"
INFO = "info"


class Check:
    """一条检查结论。"""

    def __init__(self, status, title, detail="", fix="", extra=""):
        self.status = status
        self.title = title
        self.detail = detail
        self.fix = fix
        self.extra = extra

    def render(self) -> list:
        icon = {OK: ("✅", "green"), WARN: ("⚠️ ", "yellow"), BAD: ("❌", "red"), INFO: ("·", "blue")}.get(
            self.status, ("·", "gray")
        )
        lines = [f"  {util.color(icon[0], icon[1])} {self.title}"]
        if self.detail:
            lines.append(f"      {util.color(self.detail, 'gray')}")
        if self.extra:
            for e in self.extra.splitlines():
                lines.append(f"      {util.color(e, 'gray')}")
        if self.fix:
            lines.append(f"      {util.color('修复: ' + self.fix, 'cyan')}")
        return lines


def _ping_stats(target: str, count: int = 10) -> dict:
    """ping 多次, 统计丢包率/平均/最大/抖动。"""
    cmd = ["ping", "-n", "-c", str(count), "-W", "2", "-i", "0.2", target]
    rc, out, _ = util.run(cmd, timeout=count * 2 + 6)
    stats = {"ok": rc == 0, "sent": count, "received": 0, "loss": 100.0, "avg": None, "max": None, "min": None}
    m = re.search(r"(\d+) packets transmitted, (\d+) (?:packets )?received", out)
    if m:
        stats["sent"] = int(m.group(1))
        stats["received"] = int(m.group(2))
        if stats["sent"]:
            stats["loss"] = 100.0 * (stats["sent"] - stats["received"]) / stats["sent"]
    m = re.search(r"rtt min/avg/max/(?:m?dev) = ([\d.]+)/([\d.]+)/([\d.]+)", out)
    if m:
        stats["min"] = float(m.group(1))
        stats["avg"] = float(m.group(2))
        stats["max"] = float(m.group(3))
    return stats


# ---------------------------------------------------------------- 各单项检查


def check_network_identity(ident: dict, changes: list) -> list:
    out = []
    if not ident.get("ip"):
        out.append(Check(BAD, "本机没有 IPv4 地址", "网卡没拿到地址, 先看网络连接", "sudo nmcli dev status && net doctor"))
        return out
    out.append(
        Check(
            OK,
            f"本机网络身份: {ident['ip']}/{ident['prefixlen']}",
            f"接口 {ident.get('primary_iface')} · 网关 {ident.get('gateway') or '无'} · DNS {' '.join(ident.get('dns') or []) or '无'}",
        )
    )
    if changes:
        out.append(
            Check(
                WARN,
                "网络位置与上次相比发生了变化",
                "; ".join(changes),
                "如果不是你有意改的, 大概率是路由器换了网段/换了网关, 其它设备也要跟着改",
            )
        )
    gw = ident.get("gateway")
    if not gw:
        out.append(Check(BAD, "没有默认路由", "连本网段都出不去", "sudo nmcli networking on && net doctor"))
    return out


def check_gateway(ident: dict) -> list:
    out = []
    gw = ident.get("gateway")
    if not gw:
        return out
    st = _ping_stats(gw, count=8)
    if st["ok"] and st["loss"] == 0:
        out.append(Check(OK, f"网关可达 {gw}", f"平均 {st['avg']:.1f}ms · 抖动 {st['max'] - st['min']:.1f}ms · 丢包 0%"))
    elif st["ok"]:
        lvl = WARN if st["loss"] < 20 else BAD
        out.append(
            Check(
                lvl,
                f"网关 {gw} 丢包 {st['loss']:.0f}%",
                f"平均 {st['avg'] or 0:.1f}ms · 最大 {st['max'] or 0:.1f}ms",
                "丢包高通常是网线/交换机端口/WiFi 信号问题: 先 ping 网关再 ping 本机其它设备对比",
            )
        )
    else:
        out.append(
            Check(
                BAD,
                f"ping 不通网关 {gw}",
                "网关不可达 —— 本机与局域网的连接断了",
                "sudo ip link set <网卡> up; 换根网线/换网口; WiFi 看 net probe 的无线段",
            )
        )
    return out


def check_public(ident: dict) -> list:
    out = []
    for target, label in (("223.5.5.5", "阿里 DNS"), ("1.1.1.1", "Cloudflare")):
        st = _ping_stats(target, count=4)
        if st["ok"]:
            out.append(Check(OK, f"公网可达 {target} ({label})", f"平均 {st['avg']:.1f}ms · 丢包 {st['loss']:.0f}%"))
            break
    else:
        out.append(
            Check(
                WARN,
                "公网 IP 不可达",
                "网关能通但出不去 —— 多半是路由/上游/运营商的问题, 不是本机设置",
                "traceroute -n 1.1.1.1 看在哪一跳断的; sudo ip route show 看默认路由",
            )
        )
    return out


def check_dns(ident: dict) -> list:
    out = []
    servers = ident.get("dns") or []
    if not servers:
        out.append(Check(BAD, "没有 DNS 服务器", "/etc/resolv.conf 是空的", "sudo net fix"))
        return out
    domains = ["www.baidu.com", "www.qq.com", "github.com"]
    results = {}
    for d in domains:
        t0 = time.time()
        try:
            socket.setdefaulttimeout(4)
            infos = socket.getaddrinfo(d, None)
            dt = (time.time() - t0) * 1000
            results[d] = sorted({i[4][0] for i in infos})
            out.append(Check(OK, f"解析 {d}", f"{', '.join(results[d])} · {dt:.0f}ms"))
        except OSError:
            results[d] = []
            out.append(Check(BAD, f"解析 {d} 失败", "域名解析不出来(名字能 ping 通但名字不解析)", "sudo net fix"))
    # 多 DNS 对比: 同一域名不同 DNS 返回不同 IP, 有可能是劫持
    if len(servers) >= 2:
        mismatch = []
        for d in list(results)[:2]:
            sets = []
            for s in servers[:3]:
                rc, out2, _ = util.run(["dig", "+short", "+time=2", "+tries=1", f"@{s}", d], timeout=6)
                if rc == 0 and out2.strip():
                    sets.append((s, set(out2.split())))
            if len(sets) >= 2:
                first = sets[0][1]
                for s, got in sets[1:]:
                    if got and first and not (got & first):
                        mismatch.append(f"{d}: {sets[0][0]} -> {','.join(first)} vs {s} -> {','.join(got)}")
        if mismatch:
            out.append(
                Check(
                    WARN,
                    "不同 DNS 返回的 IP 不一致",
                    "; ".join(mismatch),
                    "可能是分流/劫持/不同 CDN 节点; 若伴随打不开网页, 换 DNS: sudo net fix --dns 223.5.5.5",
                )
            )
    return out


def check_mtu(ident: dict) -> list:
    """MTU 探测: 找一个能把包完整发出去的最大 payload。"""
    out = []
    gw = ident.get("gateway")
    target = gw or "223.5.5.5"
    if not util.have("ping"):
        return out
    best = None
    for payload in (1472, 1400, 1300, 1200, 1100):
        rc, _, _ = util.run(["ping", "-n", "-c", "1", "-W", "2", "-M", "do", "-s", str(payload), target], timeout=5)
        if rc == 0:
            best = payload
            break
    if best is None:
        out.append(
            Check(
                WARN,
                "大包发不出去(MTU 被卡)",
                f"连 {target} 都发不了 1100 字节的包",
                "常见于 VPN/PPPoE 隧道; 可降 MTU: sudo ip link set <网卡> mtu 1400",
            )
        )
    elif best < 1472:
        out.append(
            Check(
                WARN,
                f"链路 MTU 小于标准值(实测 {best + 28} 字节)",
                f"1500 字节的包会被拆包, 大文件传输会变慢",
                f"sudo ip link set <网卡> mtu {best + 28}",
            )
        )
    else:
        out.append(Check(OK, f"MTU 正常({best + 28} 字节)", "标准以太网 1500 字节"))
    return out


def check_conflicts(hosts: dict) -> list:
    """IP 冲突: 同一 IP 出现多个 MAC, 或同一 MAC 拿到多个 IP。"""
    out = []
    ip2mac = {}
    mac2ip = {}
    for ip, rec in hosts.items():
        mac = rec.get("mac", "")
        if not mac:
            continue
        ip2mac.setdefault(ip, set()).add(mac)
        mac2ip.setdefault(mac, set()).add(ip)
    for ip, macs in ip2mac.items():
        if len(macs) > 1:
            out.append(
                Check(
                    BAD,
                    f"IP 冲突: {ip} 对应多个 MAC",
                    ", ".join(sorted(macs)),
                    "同 IP 有两台设备在抢: 断电重启其中一台(多半是 DHCP 地址池太小), 或把地址池调大",
                )
            )
    for mac, ips in mac2ip.items():
        if len(ips) > 1:
            out.append(
                Check(
                    WARN,
                    f"同一 MAC 拿到多个 IP: {mac}",
                    ", ".join(sorted(ips)),
                    "一般是网卡同时接了两条网线, 或虚拟机/网桥抢地址",
                )
            )
    if not any(c.status in (BAD, WARN) for c in out):
        out.append(Check(OK, "没发现 IP 冲突", f"扫到 {len(hosts)} 个有 MAC 的地址"))
    return out


def check_loop(ident: dict) -> list:
    """环路检测: traceroute 出现重复跳 = 路由成环。"""
    out = []
    target = ident.get("gateway") or "223.5.5.5"
    if not util.have("traceroute"):
        return out
    rc, raw, _ = util.run(["traceroute", "-n", "-w", "1", "-q", "1", "-m", "8", target], timeout=20)
    if rc != 0:
        return out
    seen = []
    loop = False
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) < 2 or not parts[0].isdigit():
            continue
        ip = parts[1]
        if ip in seen:
            loop = True
            break
        seen.append(ip)
    if loop:
        out.append(
            Check(
                BAD,
                "路由成环(TTL 耗尽)",
                f"traceroute 到 {target} 时地址重复出现",
                "路由器/交换机之间配错静态路由了; 挨个 ping 环路上的地址, 去路由器上看路由表",
            )
        )
    else:
        out.append(Check(OK, f"到 {target} 的路由路径正常", f"{len(seen)} 跳: {' → '.join(seen)}"))
    return out


def check_wifi(ident: dict) -> list:
    out = []
    wifi = ident.get("wifi") or {}
    if not wifi.get("present"):
        return out
    if not wifi.get("ssid"):
        out.append(Check(WARN, "无线未连接", f"接口 {wifi.get('iface')} 没有连上任何 AP", "wifi scan && wifi connect \"SSID\""))
        return out
    detail = f"SSID {wifi['ssid']} · 信道 {wifi.get('channel') or '?'} · 频率 {wifi.get('freq') or '?'}MHz"
    sig = wifi.get("signal_dbm")
    if sig:
        try:
            v = int(sig)
            detail += f" · 信号 {v}dBm"
            if v < -70:
                out.append(
                    Check(
                        BAD,
                        f"无线信号很差({v}dBm)",
                        detail,
                        "离路由器太远/隔墙多: 靠近路由器, 或改连 5G/有线; 密码: wifi connect \"SSID\"",
                    )
                )
                return out
            if v < -60:
                out.append(Check(WARN, f"无线信号偏弱({v}dBm)", detail, "挪近路由器或换 5G 频段"))
                return out
        except ValueError:
            pass
    out.append(Check(OK, f"无线正常: {wifi['ssid']}", detail))
    return out


def check_ipv6(ident: dict) -> list:
    out = []
    # fe80:: 是链路本地地址, 每张网卡都有, 不能算"支持 IPv6"
    def global_v6(ip):
        return bool(ip) and not ip.startswith("fe80") and ip != "::1"

    has_v6 = any(global_v6(i.get("ipv6")) for i in ident.get("interfaces", []))
    if not has_v6:
        out.append(Check(INFO, "没有可用的 IPv6 地址", "只有 IPv4 也能上网, 除非某些服务强制要 v6"))
        return out
    v6 = next((i["ipv6"] for i in ident["interfaces"] if global_v6(i.get("ipv6"))), "")
    rc, _, _ = util.run(["ping", "-n", "-c", "2", "-W", "2", "2400:3200::1"], timeout=8)
    if rc == 0:
        out.append(Check(OK, f"IPv6 可用 ({v6})", "能 ping 通 IPv6 地址"))
    else:
        out.append(Check(WARN, f"有 IPv6 地址但不通 ({v6})", "IPv6 配了但路由有问题, 不影响 IPv4 上网"))
    return out


def check_proxy() -> list:
    out = []
    env = {}
    for k, v in list(__import__("os").environ.items()):
        if k.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy"):
            env[k] = v
    if env:
        out.append(
            Check(
                WARN,
                "环境里设了代理",
                " ".join(f"{k}={v}" for k, v in env.items()),
                "U 盘上通常没跑 Clash, 代理会让下载全失败: unset http_proxy https_proxy all_proxy",
            )
        )
    else:
        out.append(Check(OK, "没有代理干扰", "环境变量干净"))
    return out


def check_devices(disc: dict, topo_data: dict) -> list:
    out = []
    hosts = disc.get("hosts", {})
    online = len(hosts)
    out.append(Check(OK, f"局域网在线设备 {online} 台", f"发现手段: {' '.join(disc.get('methods', [])) or '-'}"))
    # 名字相同但 MAC 不同 -> 可能是 DHCP 换机器了, 或者克隆 MAC
    byname = {}
    for ip, rec in hosts.items():
        name = rec.get("hostname") or ""
        if not name:
            continue
        byname.setdefault(name, set()).add(rec.get("mac", ""))
    for name, macs in byname.items():
        if len(macs) > 1:
            out.append(
                Check(
                    WARN,
                    f"同名设备出现多个 MAC: {name}",
                    ", ".join(sorted(m for m in macs if m)),
                    "DHCP 重新分配了地址, 或者有人在改 MAC; 若两台都在, 查一下是否有 IP 冲突",
                )
            )
    return out


# ---------------------------------------------------------------- 汇总


def run(ident: dict, disc: dict, topo_data: dict, changes: list) -> list:
    """跑全部检查, 返回 [(段名, [Check...]), ...]"""
    sections = [
        ("1. 本机网络身份", check_network_identity(ident, changes)),
        ("2. 网关与上游", check_gateway(ident) + check_public(ident)),
        ("3. 路由与环路", check_loop(ident)),
        ("4. DNS", check_dns(ident)),
        ("5. MTU", check_mtu(ident)),
        ("6. IP 冲突与设备盘点", check_conflicts(disc.get("hosts", {})) + check_devices(disc, topo_data)),
        ("7. 无线", check_wifi(ident)),
        ("8. IPv6", check_ipv6(ident)),
        ("9. 代理干扰", check_proxy()),
    ]
    return [(name, checks) for name, checks in sections if checks]


def render(sections: list) -> tuple:
    """渲染检查结果 -> (文本, 错误项数, 警告项数)"""
    lines = []
    bad = warn = 0
    for name, checks in sections:
        lines.append("")
        lines.append(util.color(f"==> {name}", "blue"))
        for c in checks:
            lines.extend(c.render())
            if c.status == BAD:
                bad += 1
            elif c.status == WARN:
                warn += 1
    lines.append("")
    if bad == 0 and warn == 0:
        lines.append(util.color("✅ 局域网检测全部通过", "green"))
    elif bad == 0:
        lines.append(util.color(f"⚠️  {warn} 项需要注意(上面每条都给了处理建议)", "yellow"))
    else:
        lines.append(util.color(f"❌ {bad} 项有问题, {warn} 项需要注意(上面每条都给了处理建议)", "red"))
    return "\n".join(lines), bad, warn
