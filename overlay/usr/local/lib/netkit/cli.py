"""netkit.cli —— `net` 命令的子命令分发。

子命令:
  topo    扫描局域网, 打印拓扑图(ASCII 树)
  probe   局域网问题深度检测(丢包/MTU/IP冲突/环路/DNS/无线 ...)
  doctor  本机网络栈自检(= 老的 net-doctor) + 局域网摘要
  fix     安全自动修复(DHCP 续租/清 DNS 缓存/重建 resolv.conf/切 DNS ...)
  ai      用 opencode + 网络排障 skills 问 AI
  report  查看历史报告
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

from . import discover, netinfo, probe, topo, util

BINDIR = "/usr/local/bin"


def _print(text: str) -> None:
    print(text)


# ---------------------------------------------------------------- topo


def cmd_topo(args) -> int:
    ident = netinfo.identity()
    cidr = args.cidr or ident.get("cidr") or ""
    iface = args.iface or ident.get("primary_iface") or ""
    if not cidr:
        _print(util.color("没有可用的网段: 本机还没有 IPv4 地址", "red"))
        _print("先解决『拿到地址』这一步: net doctor")
        return 2
    _print(util.color(f"扫描 {cidr} (接口 {iface or '自动'}) ...", "cyan"))
    disc = discover.discover(
        cidr=cidr,
        iface=iface,
        deep=not args.quick,
        ports=not args.no_ports,
        ident_gw=ident.get("gateway", ""),
    )
    topo_data = topo.build(ident, disc)
    changes = netinfo.compare_with_history(ident)
    netinfo.record_snapshot(ident)
    _print("")
    _print(topo.render(topo_data, changes))
    if args.json:
        path = util.save_json("topology", topo.snapshot(topo_data))
        if path:
            _print("")
            _print(util.color(f"JSON 已保存: {path}", "cyan"))
    if args.save:
        path = util.save_report("topology", topo.plain(topo_data))
        if path:
            _print(util.color(f"报告已保存: {path}", "cyan"))
    return 0


# ---------------------------------------------------------------- probe


def cmd_probe(args) -> int:
    ident = netinfo.identity()
    cidr = args.cidr or ident.get("cidr") or ""
    iface = args.iface or ident.get("primary_iface") or ""
    disc = {
        "hosts": {},
        "lldp": [],
        "methods": [],
        "scanned": cidr,
    }
    if cidr and not args.quick:
        _print(util.color(f"扫描 {cidr} ...", "cyan"))
        disc = discover.discover(cidr=cidr, iface=iface, deep=True, ports=False, ident_gw=ident.get("gateway", ""))
    elif cidr:
        disc = discover.discover(cidr=cidr, iface=iface, deep=False, ports=False, ident_gw=ident.get("gateway", ""))
    topo_data = topo.build(ident, disc)
    changes = netinfo.compare_with_history(ident)
    netinfo.record_snapshot(ident)
    sections = probe.run(ident, disc, topo_data, changes)
    text, bad, warn = probe.render(sections)
    _print(util.color("=== 局域网检测 ===", "blue"))
    _print(text)
    path = util.save_report("probe", text)
    if path:
        _print(util.color(f"报告已保存: {path}", "cyan"))
    return 1 if bad else 0


# ---------------------------------------------------------------- doctor


def cmd_doctor(args) -> int:
    """跑老的那套 net-doctor(本机栈), 再补一段局域网摘要。"""
    doctor = os.path.join(BINDIR, "net-doctor")
    rc = 0
    if os.path.exists(doctor):
        cmd = [doctor]
        if args.fix:
            cmd.append("--fix")
        proc = subprocess.run(cmd, text=True)
        rc = proc.returncode
    else:
        _print(util.color("找不到 net-doctor", "red"))
        rc = 127
    _print("")
    _print(util.color("==> 局域网摘要", "blue"))
    ident = netinfo.identity()
    _print(f"  · 本机 {ident.get('ip') or '无地址'}  网段 {ident.get('cidr') or '未知'}  网关 {ident.get('gateway') or '无'}")
    _print("  · 看完整拓扑: net topo     深度检测: net probe")
    return rc


# ---------------------------------------------------------------- fix


def _run(cmd, sudo=False):
    return util.run(cmd, timeout=30, need_root=sudo)


def cmd_fix(args) -> int:
    """安全修复: 只做可逆、标准化的操作, 每步都说明在干什么。"""
    steps = []

    def step(name, fn):
        _print(f"  → {name} ...")
        ok, detail = fn()
        steps.append((name, ok, detail))
        _print(util.color(f"    {'✅' if ok else '⚠️ '} {detail}", "green" if ok else "yellow"))

    if args.dns:
        def _dns():
            target = "/etc/resolv.conf"
            try:
                with open(target, "w", encoding="utf-8") as fh:
                    fh.write(f"nameserver {args.dns}\n")
            except OSError as exc:
                return False, f"写 {target} 失败: {exc}"
            _run(["systemctl", "restart", "systemd-resolved"], sudo=True)
            return True, f"DNS 已设为 {args.dns}"

        step(f"把 DNS 设为 {args.dns}", _dns)

    if args.flush_dns or not args.dns:
        def _flush():
            rc, out, err = _run(["resolvectl", "flush-caches"], sudo=True)
            if rc != 0:
                return False, "resolvectl flush-caches 没成功(可能没装 systemd-resolved)"
            return True, "DNS 缓存已清空"

        step("清空 DNS 缓存", _flush)

    if args.renew or args.dns:
        def _renew():
            if util.have("nmcli"):
                rc, out, _ = _run(["nmcli", "device", "reapply", "eth0"], sudo=True)
                con = util.sh(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"], timeout=8)
                for line in con.splitlines():
                    name, _, dev = line.partition(":")
                    if not dev:
                        continue
                    rc2, _, _ = _run(["nmcli", "connection", "down", name], sudo=True)
                    _run(["nmcli", "connection", "up", name], sudo=True)
                    return True, f"已重连连接 {name} (设备 {dev}), DHCP 重新申请地址"
                return False, "没有活动的 NetworkManager 连接"
            rc2, _, _ = _run(["dhclient", "-r"], sudo=True)
            return rc2 == 0, "已尝试释放 DHCP 租约"

        step("重新申请 DHCP 地址", _renew)

    if args.flush_arp:
        def _arp():
            _run(["ip", "-s", "-s", "neigh", "flush", "all"], sudo=True)
            return True, "ARP/邻居表已清空(网段变了以后特别有用)"

        step("清空 ARP 邻居表", _arp)

    if args.restart_nm:
        def _nm():
            rc, _, err = _run(["systemctl", "restart", "NetworkManager"], sudo=True)
            return rc == 0, "NetworkManager 已重启" if rc == 0 else f"重启失败: {err.strip()[:80]}"

        step("重启 NetworkManager", _nm)

    if args.rebuild_resolv:
        def _resolv():
            if os.path.exists("/run/systemd/resolve/stub-resolv.conf"):
                try:
                    if os.path.islink("/etc/resolv.conf"):
                        os.unlink("/etc/resolv.conf")
                    os.symlink("/run/systemd/resolve/stub-resolv.conf", "/etc/resolv.conf")
                    return True, "/etc/resolv.conf 已重建为指向 stub-resolv.conf"
                except OSError as exc:
                    return False, f"重建失败: {exc}"
            return False, "系统里没有 stub-resolv.conf, 保持现状"

        step("重建 /etc/resolv.conf", _resolv)

    if not steps:
        _print("没指定要修什么。可用参数:")
        _print("  --dns <IP>        把 DNS 设成指定服务器")
        _print("  --renew           重新申请 DHCP 地址")
        _print("  --flush-arp       清空 ARP 表(换网段后用)")
        _print("  --restart-nm      重启 NetworkManager")
        _print("  --rebuild-resolv  重建 /etc/resolv.conf")
        return 0

    _print("")
    _print(util.color("修完再跑一次 net probe 复检。", "cyan"))
    return 0


# ---------------------------------------------------------------- ai


def cmd_ai(args) -> int:
    """把 opencode 拉起来做网络排障助手。"""
    oc = util.which("opencode")
    if not oc:
        _print(util.color("没找到 opencode(镜像里应该已经装好)", "red"))
        _print("可以先用 net probe / net topo 自己做检测。")
        return 127
    prompt = args.prompt or "我的局域网出问题了, 请按 lan-triage 技能的流程分层定位, 先看 net probe 的结果再给修复步骤。"
    env = dict(os.environ)
    env.setdefault("OPENCODE_CONFIG_CONTENT", json.dumps({"share": "disabled"}))
    if args.print_prompt:
        _print(prompt)
        return 0
    _print(util.color("启动 opencode(网络排障 skills 已在 ~/.config/opencode/skill/) ...", "cyan"))
    if args.prompt:
        cmd = [oc, "run", prompt]
    else:
        cmd = [oc]
    try:
        return subprocess.run(cmd, env=env).returncode
    except KeyboardInterrupt:
        return 130


# ---------------------------------------------------------------- report


def cmd_report(args) -> int:
    d = util.report_dir()
    try:
        names = sorted(os.listdir(d))
    except OSError:
        names = []
    if not names:
        _print(f"{d} 里还没有报告")
        return 0
    _print(f"报告目录: {d}")
    for n in names:
        _print(f"  {n}")
    return 0


# ---------------------------------------------------------------- 入口


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="net", description="局域网诊断与修复工具箱")
    sub = p.add_subparsers(dest="cmd")

    t = sub.add_parser("topo", help="扫描局域网并打印拓扑图")
    t.add_argument("--cidr", help="要扫描的网段(默认取本机所在网段)")
    t.add_argument("--iface", help="指定网卡(默认取走默认路由的那块)")
    t.add_argument("--quick", action="store_true", help="只做快速发现(不做二层扫描/端口探测)")
    t.add_argument("--no-ports", action="store_true", help="不探测端口")
    t.add_argument("--json", action="store_true", help="额外保存 JSON")
    t.add_argument("--save", action="store_true", help="额外保存纯文本报告")
    t.set_defaults(func=cmd_topo)

    pr = sub.add_parser("probe", help="局域网问题深度检测")
    pr.add_argument("--cidr", help="网段")
    pr.add_argument("--iface", help="网卡")
    pr.add_argument("--quick", action="store_true", help="跳过设备扫描, 只查本机链路")
    pr.set_defaults(func=cmd_probe)

    d = sub.add_parser("doctor", help="本机网络栈自检(老 net-doctor)")
    d.add_argument("--fix", action="store_true", help="顺带尝试自动修复")
    d.set_defaults(func=cmd_doctor)

    f = sub.add_parser("fix", help="安全自动修复")
    f.add_argument("--dns", help="把 DNS 设成这个地址")
    f.add_argument("--renew", action="store_true", help="重新申请 DHCP 地址")
    f.add_argument("--flush-arp", action="store_true", help="清空 ARP 邻居表")
    f.add_argument("--restart-nm", action="store_true", help="重启 NetworkManager")
    f.add_argument("--rebuild-resolv", action="store_true", help="重建 /etc/resolv.conf")
    f.set_defaults(func=cmd_fix)

    a = sub.add_parser("ai", help="用 opencode + 网络排障技能问 AI")
    a.add_argument("prompt", nargs="?", help="直接提一个问题(不给就进交互模式)")
    a.add_argument("--print-prompt", action="store_true", help="只打印将要使用的提示词")
    a.set_defaults(func=cmd_ai)

    r = sub.add_parser("report", help="查看历史报告")
    r.set_defaults(func=cmd_report)
    return p


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 0
    try:
        return args.func(args)
    except KeyboardInterrupt:
        _print("")
        return 130
    except Exception as exc:  # 任何一步炸了都不该把终端搞崩
        _print(util.color(f"出错了: {exc}", "red"))
        return 1


if __name__ == "__main__":
    sys.exit(main())
