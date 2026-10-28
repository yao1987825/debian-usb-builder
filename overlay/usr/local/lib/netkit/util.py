"""netkit 公共工具: 跑命令、终端颜色、JSON 落盘。

设计原则:
- **不假设任何命令存在**: 镜像里工具是"轻量选装", 缺 arp-scan 就退回 ping
  扫描, 缺 lldpcli 就跳过 LLDP。任何一个工具缺失都不能让整个工具崩掉。
- **命令一律走数组 + timeout**: 防止某个命令卡死把整个扫描拖住。
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from datetime import datetime

# ---------------------------------------------------------------- 终端颜色

_NO_COLOR = os.environ.get("NO_COLOR") is not None or not os.environ.get("TERM")
_FORCE = os.environ.get("NETKIT_COLOR", "").lower()


def _use_color(stream) -> bool:
    if _FORCE in ("1", "always", "yes"):
        return True
    if _FORCE in ("0", "never", "no"):
        return False
    if _NO_COLOR:
        return False
    try:
        return bool(stream.isatty())
    except Exception:
        return False


_C = {
    "reset": "\033[0m",
    "bold": "\033[1m",
    "dim": "\033[2m",
    "red": "\033[1;31m",
    "green": "\033[1;32m",
    "yellow": "\033[1;33m",
    "blue": "\033[1;34m",
    "magenta": "\033[1;35m",
    "cyan": "\033[1;36m",
    "gray": "\033[2;37m",
}


def color(text: str, name: str, stream=None) -> str:
    """给文本套色; 非 tty 时原样返回(写报告文件时不会被塞满转义符)。"""
    stream = stream or __import__("sys").stdout
    if name not in _C or not _use_color(stream):
        return text
    return f"{_C[name]}{text}{_C['reset']}"


# ---------------------------------------------------------------- 执行外部命令


def which(name: str) -> str | None:
    return shutil.which(name)


def run(cmd: list[str], timeout: float = 10.0, need_root: bool = False):
    """执行命令, 返回 (rc, stdout, stderr)。失败不抛异常, 只返回非 0 的 rc。"""
    if need_root and os.geteuid() != 0:
        sudo = which("sudo")
        if not sudo:
            return 127, "", "没有 sudo"
        cmd = [sudo, "-n"] + cmd
    try:
        p = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
            errors="replace",
        )
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except OSError as exc:  # 命令不存在之类的
        return 127, "", str(exc)
    return p.returncode, p.stdout, p.stderr


def sh(cmd: list[str], timeout: float = 10.0, need_root: bool = False) -> str:
    """只要 stdout 的便捷封装; 失败返回空串。"""
    rc, out, _ = run(cmd, timeout=timeout, need_root=need_root)
    return out if rc == 0 else ""


def sh_json(cmd: list[str], timeout: float = 10.0, need_root: bool = False):
    """跑一个输出 JSON 的命令, 解析成 Python 对象; 解析不了返回 None。"""
    raw = sh(cmd, timeout=timeout, need_root=need_root)
    if not raw.strip():
        return None
    try:
        return json.loads(raw)
    except (ValueError, TypeError):
        return None


def have(name: str) -> bool:
    return which(name) is not None


# ---------------------------------------------------------------- 小工具


def now_iso() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def stamp() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def ip_to_int(ip: str) -> int | None:
    try:
        parts = ip.split(".")
        if len(parts) != 4:
            return None
        v = 0
        for p in parts:
            n = int(p)
            if not 0 <= n <= 255:
                return None
            v = (v << 8) | n
        return v
    except (ValueError, AttributeError):
        return None


def int_to_ip(v: int) -> str:
    return ".".join(str((v >> s) & 0xFF) for s in (24, 16, 8, 0))


def cidr_of(ip: str, prefixlen: int) -> str:
    """把 IP+掩码长度算成 CIDR, 例如 192.168.6.133/24 -> 192.168.6.0/24"""
    v = ip_to_int(ip)
    if v is None:
        return f"{ip}/{prefixlen}"
    mask = (0xFFFFFFFF << (32 - prefixlen)) & 0xFFFFFFFF if prefixlen else 0
    return f"{int_to_ip(v & mask)}/{prefixlen}"


def in_same_subnet(ip_a: str, ip_b: str, prefixlen: int) -> bool:
    a, b = ip_to_int(ip_a), ip_to_int(ip_b)
    if a is None or b is None:
        return False
    if prefixlen <= 0:
        return True
    mask = (0xFFFFFFFF << (32 - prefixlen)) & 0xFFFFFFFF
    return (a & mask) == (b & mask)


def host_range(cidr: str, limit: int = 1024) -> list[str]:
    """CIDR -> 可扫描的主机 IP 列表(跳过网络号与广播号), 超大网段截断。"""
    if "/" not in cidr:
        return []
    net, _, plen = cidr.partition("/")
    try:
        plen_i = int(plen)
    except ValueError:
        return []
    base = ip_to_int(net)
    if base is None:
        return []
    size = 1 << (32 - plen_i)
    if size > 4096:
        return []
    out = []
    for i in range(1, min(size - 1, limit)):
        out.append(int_to_ip(base + i))
    return out


def mac_of(iface_data: dict) -> str:
    """取接口 MAC。

    `ip -j link show` 的 address 字段是字符串数组(["aa:bb:cc:dd:ee:ff"]),
    但有些 iproute2 版本给的是对象数组, 两种都认。
    """
    for a in iface_data.get("address", []) or []:
        if isinstance(a, str):
            if ":" in a:
                return a
        elif isinstance(a, dict) and a.get("family") == "ether":
            return a.get("addr", "")
    return ""


def normalize_mac(mac: str) -> str:
    return (mac or "").strip().lower().replace("-", ":")


# ---------------------------------------------------------------- 报告落盘


def report_dir() -> str:
    d = os.path.join(os.path.expanduser("~"), "net-reports")
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        d = "/tmp"
    return d


def save_report(prefix: str, content: str, ext: str = "txt") -> str:
    path = os.path.join(report_dir(), f"{prefix}-{stamp()}.{ext}")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(content)
    except OSError:
        return ""
    return path


def save_json(prefix: str, obj) -> str:
    path = os.path.join(report_dir(), f"{prefix}-{stamp()}.json")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False, indent=2)
    except (OSError, TypeError):
        return ""
    return path


# ---------------------------------------------------------------- 其它


def state_dir() -> str:
    d = os.path.join(os.path.expanduser("~"), ".local", "state", "netkit")
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        d = "/tmp"
    return d


def read_json(path: str):
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def ping_ms(target: str, count: int = 1, timeout: float = 2.0, deadline: float = None) -> float | None:
    """ping 一个地址, 返回平均 RTT(ms); ping 不通返回 None。"""
    cmd = ["ping", "-n", "-c", str(count), "-W", str(int(timeout) + 1), "-i", "0.3", target]
    if deadline:
        cmd = ["timeout", str(max(1, int(deadline)))] + cmd
    rc, out, _ = run(cmd, timeout=(deadline or count * timeout) + 3)
    if rc != 0:
        return None
    for line in out.splitlines():
        if "rtt" in line and "avg" in line:
            try:
                part = line.split("=")[-1].strip()
                return float(part.split("/")[0])
            except (ValueError, IndexError):
                continue
    return None


def tcp_open(host: str, port: int, timeout: float = 0.6) -> bool:
    import socket

    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False
