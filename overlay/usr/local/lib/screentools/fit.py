#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fit.py —— 自动把每一块屏幕设成它自己的原生分辨率

背景:
    同一张 U 盘插到不同显示器 / 投影仪上, Xorg 经常随便挑一个模式(常见是
    1024x768 或 1280x1024), 于是字糊、画面拉伸、字小得看不清。
    实际每块屏都有"原生分辨率", 显示器通过 EDID 告诉系统这个值。

做法:
    1. xrandr --verbose 里取出每块已连接屏幕的 EDID 原始数据
    2. 解析 EDID 的第一个 Detailed Timing Descriptor —— 按 EDID 规范,
       第一个 DTD 就是这块屏的"首选/原生"时序
    3. 在 xrandr 列出的模式里找 (宽,高) 一致的那一个, 取刷新率最高的变体
    4. EDID 读不到时退回启发式: 在合理尺寸范围内选刷新率 >=60 的最大分辨率
    5. 用 xrandr 逐块屏设置 —— 每块屏各用各的原生值, 不共用一个全局模式

只用标准库, 不依赖任何第三方包。
"""

import json
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------- EDID 解析

EDID_HEADER = b"\x00\xff\xff\xff\xff\xff\xff\x00"


def parse_edid_preferred(edid):
    """从 EDID 字节串里取出首选(原生)分辨率。

    EDID 基础块 128 字节, 54..125 是 4 个 18 字节描述符。
    每个描述符前两字节为 0x0000 表示"监视器描述符"(文本),
    否则是 Detailed Timing Descriptor:
        [0:2]   像素时钟 (10 kHz)
        [2]     水平有效像素低字节
        [4] 高4位 水平有效像素高字节
        [5]     垂直有效行数低字节
        [7] 高4位 垂直有效行数高字节
    按规范第一个 DTD 就是首选模式。
    返回 (width, height), 解析不出来返回 None。
    """
    if not edid or len(edid) < 126 or edid[:8] != EDID_HEADER:
        return None

    for i in range(4):
        off = 54 + i * 18
        d = edid[off:off + 18]
        if len(d) < 18:
            break
        if d[0] == 0 and d[1] == 0:
            continue  # 监视器描述符, 不是时序
        pixel_clock = d[0] | (d[1] << 8)
        if pixel_clock == 0:
            continue
        h_active = d[2] | ((d[4] & 0xF0) << 4)
        v_active = d[5] | ((d[7] & 0xF0) << 4)
        if h_active >= 320 and v_active >= 200:
            return h_active, v_active
    return None


def describe_edid(edid):
    """取出 EDID 里的产品名/序列号, 方便人认出"这块屏是哪台"。"""
    if not edid or len(edid) < 128 or edid[:8] != EDID_HEADER:
        return ""
    name = ""
    serial = ""
    for i in range(4):
        off = 54 + i * 18
        d = edid[off:off + 18]
        if len(d) < 18 or d[0] != 0 or d[1] != 0:
            continue
        # 描述符里: [0:2]=00 00, [2]=类型标签(FC=产品名 / FF=序列号),
        # [3]=标志位, [4:18]=文本(以 0x0A 结束或用空格填满)
        if d[2] == 0xFC:
            name = d[4:18].split(b"\x0a")[0].decode("latin-1", "replace").strip()
        elif d[2] == 0xFF:
            serial = d[4:18].split(b"\x0a")[0].decode("latin-1", "replace").strip()
    return name or serial


# ------------------------------------------------------------ xrandr 输出解析

OUT_RE = re.compile(r"^(\S+)\s+(connected|disconnected)(.*)$")
MODE_RE = re.compile(r"\b(\d+)x(\d+)(?:i)?(?:[+-]\d+[+-]\d+)?(?:\s+(\d+(?:\.\d+)?))?")


def parse_xrandr(text):
    """解析 `xrandr --query` 的输出。

    返回 {"outputs": {name: {...}}, "primary": name|None}
    每个 output:
        connected   是否已连接
        primary     是否主屏
        current     (w,h,rate) 当前模式
        modes       [(w,h,rate,label), ...]  该屏支持的所有模式
        resolution  xrandr 报的头部尺寸串(仅供显示)
    """
    outputs = {}
    primary = None
    current_output = None

    for raw in text.splitlines():
        line = raw.rstrip()
        if not line:
            continue
        m = OUT_RE.match(line)
        if m:
            name, state, rest = m.group(1), m.group(2), m.group(3)
            if name == "Screen" and current_output is not None:
                continue
            cur = None
            res = None
            cm = MODE_RE.search(rest)
            if cm:
                res = (int(cm.group(1)), int(cm.group(2)))
                cur = (int(cm.group(1)), int(cm.group(2)),
                       float(cm.group(3)) if cm.group(3) else None)
            outputs[name] = {
                "connected": state == "connected",
                "primary": "primary" in rest.split(),
                "current": cur,
                "modes": [],
                "resolution": res,
            }
            if "primary" in rest.split():
                primary = name
            current_output = name
            continue

        if current_output is None:
            continue
        s = line.strip()
        if s.startswith("Screen 0:"):
            continue
        mm = MODE_RE.match(s)
        if mm and outputs[current_output]["connected"]:
            w, h = int(mm.group(1)), int(mm.group(2))
            rate = float(mm.group(3)) if mm.group(3) else None
            outputs[current_output]["modes"].append((w, h, rate, s))

    return {"outputs": outputs, "primary": primary}


HEX_LINE_RE = re.compile(r"^\s+([0-9a-fA-F]{2,32})\s*$")


def parse_edids(text):
    """从 `xrandr --verbose` 的输出里抠出每个输出的 EDID 字节串。"""
    edids = {}
    current = None
    collecting = False
    for raw in text.splitlines():
        m = OUT_RE.match(raw.rstrip())
        if m:
            current = m.group(1)
            collecting = False
            continue
        if current is None:
            continue
        if re.match(r"^\s*EDID:\s*$", raw):
            collecting = True
            edids.setdefault(current, b"")
            continue
        if collecting:
            hm = HEX_LINE_RE.match(raw)
            if hm:
                hexs = hm.group(1)
                if len(hexs) % 2 == 0:      # 奇数长度不是合法字节串, 防御性跳过
                    edids[current] += bytes.fromhex(hexs)
            elif raw.strip() and not raw.startswith(("\t", "  ")):
                collecting = False
    return edids


# ---------------------------------------------------------------- 选模式

def pick_native(modes, target):
    """在 modes 里找与 (target_w, target_h) 一致的模式, 取刷新率最高的那个。"""
    if not target:
        return None
    tw, th = target
    cands = [m for m in modes if m[0] == tw and m[1] == th]
    if not cands:
        return None
    return max(cands, key=lambda m: (m[2] if m[2] is not None else 0.0))


def pick_fallback(modes):
    """没有 EDID 时的兜底: 合理尺寸范围内, 优先 >=60Hz, 再取面积最大的。"""
    valid = [m for m in modes
             if 800 <= m[0] <= 7680 and 600 <= m[1] <= 4320 and m[0] >= m[1]]
    if not valid:
        valid = [m for m in modes if m[0] >= 640 and m[1] >= 480]
    if not valid:
        return None
    hi = [m for m in valid if m[2] is not None and m[2] >= 59.5]
    pool = hi or valid
    return max(pool, key=lambda m: (m[0] * m[1], m[2] or 0.0))


def build_plan(query_text, verbose_text, force_fallback=False):
    """综合 xrandr --query 和 --verbose, 生成"每块屏该设成什么"的方案。"""
    info = parse_xrandr(query_text)
    edids = parse_edids(verbose_text) if verbose_text else {}
    plan = []
    for name, o in info["outputs"].items():
        if not o["connected"]:
            continue
        edid = edids.get(name, b"")
        native = None if force_fallback else parse_edid_preferred(edid)
        mode = pick_native(o["modes"], native) if native else None
        origin = "edid"
        if mode is None:
            mode = pick_fallback(o["modes"])
            origin = "fallback"
        plan.append({
            "output": name,
            "primary": o["primary"],
            "current": o["current"],
            "current_label": current_label(o),
            "target": mode,
            "origin": origin,
            "edid_name": describe_edid(edid),
            "has_edid": bool(native),
        })
    return plan


def current_label(o):
    cur = o.get("current")
    if not cur:
        return ""
    for m in o["modes"]:
        if m[0] == cur[0] and m[1] == cur[1]:
            if cur[2] is None or m[2] is None:
                return m[3]
            if abs(m[2] - cur[2]) < 0.01:
                return m[3]
    return f"{cur[0]}x{cur[1]}"


def mode_cmd(item):
    w, h, rate, label = item["target"]
    cmd = ["xrandr", "--output", item["output"], "--mode", label]
    if rate is not None:
        cmd += ["--rate", f"{rate:g}"]
    return cmd


# ---------------------------------------------------------------- 运行时

def run(cmd, capture=True):
    try:
        return subprocess.run(
            cmd,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.STDOUT if capture else None,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None


def resolve_display(explicit):
    d = explicit or os.environ.get("DISPLAY")
    if d:
        return d
    # Xfce 自动登录后 Xauthority 一般在 ~/.Xauthority, DISPLAY 通常是 :0
    for cand in (":0", ":1"):
        if os.path.exists("/tmp/.X11-unix/X%s" % cand.lstrip(":")):
            return cand
    return None


RED = "\033[1;31m"; GRN = "\033[1;32m"; YEL = "\033[1;33m"
BLU = "\033[1;34m"; DIM = "\033[2m"; RST = "\033[0m"
if not sys.stdout.isatty() or os.environ.get("NO_COLOR"):
    RED = GRN = YEL = BLU = DIM = RST = ""


def human_mode(item):
    if not item["target"]:
        return "无"
    w, h, rate, label = item["target"]
    return f"{w}x{h}@{rate:g}Hz" if rate is not None else f"{w}x{h}"


def main(argv):
    args = argv[1:]
    state_dir = os.path.join(os.environ.get("HOME", "/root"), ".config", "screen-fit")
    state_file = os.path.join(state_dir, "enabled")

    if "--help" in args or "-h" in args:
        print(__doc__.strip())
        print("\n用法: screen-fit [--list|--dry-run|--enable|--disable|--no-edid|--json]")
        return 0

    if "--self-test" in args:
        return self_test()

    do_list = "--list" in args
    dry = "--dry-run" in args or "--dryrun" in args
    as_json = "--json" in args
    want_enable = "--enable" in args
    want_disable = "--disable" in args
    want_restore = "--restore" in args
    force_fallback = "--no-edid" in args

    if want_disable:
        if os.path.exists(state_file):
            os.remove(state_file)
            print(f"{GRN}[screen-fit]{RST} 已关闭开机自动匹配(想恢复: screen-fit --enable)")
        else:
            print(f"{DIM}[screen-fit]{RST} 本来就没开开机自动匹配")
        return 0

    if want_enable:
        os.makedirs(state_dir, exist_ok=True)
        with open(state_file, "w", encoding="utf-8") as f:
            f.write("1\n")
        print(f"{GRN}[screen-fit]{RST} 已开启开机自动匹配")
        return 0

    if want_restore:
        if not os.path.exists(state_file):
            return 0          # 用户没开, 安静退出, 不打扰
        args = [a for a in args if a != "--restore"]
        try:
            log = os.path.join(state_dir, "last.log")
            with open(log, "a", encoding="utf-8") as f:
                f.write("--- 自动匹配 ---\n")
                rc = main(["screen-fit"] + [a for a in args if a in ("--dry-run", "--no-edid", "--list", "--json")])
                f.write(f"exit={rc}\n")
            return rc
        except OSError:
            pass
        return main(["screen-fit"] + [a for a in args if a in ("--dry-run", "--no-edid", "--list", "--json")])

    disp = resolve_display(None)
    if not disp:
        print(f"{RED}[screen-fit]{RST} 找不到 X 显示(没有 DISPLAY)。")
        print(f"  这个脚本要在图形界面里跑: 先登录桌面, 再从终端执行 screen-fit")
        return 1
    os.environ["DISPLAY"] = disp

    if run(["xrandr", "--version"]) is None:
        print(f"{RED}[screen-fit]{RST} 没装 xrandr 命令。装它: sudo apt-get install -y x11-xserver-utils")
        return 1

    q = run(["xrandr", "--query"])
    v = run(["xrandr", "--verbose"])
    if q is None or q.returncode != 0:
        out = (q.stdout if q else "") or ""
        print(f"{RED}[screen-fit]{RST} xrandr 读不到显示 {disp}: {out.strip()[:200]}")
        return 1

    plan = build_plan(q.stdout, v.stdout if v else "", force_fallback)
    if not plan:
        print(f"{YEL}[screen-fit]{RST} 没有检测到任何已连接的显示器。")
        return 1

    if as_json:
        print(json.dumps(plan, ensure_ascii=False, indent=2))
        return 0

    if not do_list:
        print(f"{BLU}[screen-fit]{RST} 检测到 {len(plan)} 块屏幕:")
    for item in plan:
        mark = f" {DIM}(主屏){RST}" if item["primary"] else ""
        who = f" {DIM}[{item['edid_name']}]{RST}" if item["edid_name"] else ""
        how = {True: "", False: f" {YEL}(没读到 EDID, 用的推测值){RST}"}[item["origin"] == "edid"]
        if do_list:
            print(f"  {BLU}{item['output']}{RST}{mark}{who}")
            print(f"      当前: {item['current_label'] or '无'}")
            print(f"      建议: {human_mode(item)}{how}")
            continue

        if not item["target"]:
            print(f"  {YEL}⚠{RST}  {item['output']}: 这块屏没有可用模式, 跳过")
            continue

        if item["current_label"] == item["target"][3]:
            print(f"  {GRN}✅{RST}  {item['output']}{mark} 已经是 {human_mode(item)}, 不用改{who}")
            continue

        cmd = mode_cmd(item)
        if dry:
            print(f"  {DIM}(试运行){RST} {' '.join(cmd)}")
            continue

        r = run(cmd)
        if r is not None and r.returncode == 0:
            print(f"  {GRN}✅{RST}  {item['output']}{mark} {item['current_label'] or '未知'} → {human_mode(item)}{who}")
        else:
            detail = (r.stdout if r else "") or "xrandr 执行失败"
            print(f"  {RED}❌{RST}  {item['output']} 设置失败: {detail.strip()[:200]}")

    if not do_list and not dry:
        print()
        print(f"{DIM}提示: screen-fit --enable 可以开机自动匹配; --disable 关掉{RST}")
    return 0


def self_test():
    """不依赖 X 的纯逻辑自测: 构造一段 EDID, 验证能否解析出正确的原生分辨率。"""
    cases = []

    def make_edid(h_active, v_active):
        e = bytearray(EDID_HEADER + b"\x00" * (128 - 8))
        d = bytearray(18)
        d[0:2] = (148500 // 10).to_bytes(2, "little")   # 像素时钟 148.5MHz
        d[2] = h_active & 0xFF
        d[4] = ((h_active >> 8) & 0x0F) << 4      # 高 4 位存在 byte4 的上半字节
        d[5] = v_active & 0xFF
        d[7] = ((v_active >> 8) & 0x0F) << 4
        e[54:72] = d
        return bytes(e)

    for wh, expect in [((1920, 1080), (1920, 1080)),
                       ((2560, 1440), (2560, 1440)),
                       ((3840, 2160), (3840, 2160)),
                       ((1366, 768), (1366, 768)),
                       ((1280, 1024), (1280, 1024))]:
        got = parse_edid_preferred(make_edid(*wh))
        cases.append((f"解析原生分辨率 {wh[0]}x{wh[1]}", got == expect, got))

    # 第一个描述符是监视器文本(0x0000)时, 应该跳过它去看第二个 DTD
    e = bytearray(make_edid(1920, 1080))
    txt = bytearray(18)
    txt[0:2] = b"\x00\x00"
    txt[2] = 0xFC          # 描述符类型标签在第 2 字节, 文本从第 4 字节开始
    txt[4:4 + 5] = b"TEST\x0a"
    d2 = bytearray(18)
    d2[0:2] = (74250 // 10).to_bytes(2, "little")
    d2[2] = 1280 & 0xFF
    d2[4] = ((1280 >> 8) & 0x0F) << 4
    d2[5] = 720 & 0xFF
    d2[7] = ((720 >> 8) & 0x0F) << 4
    e[54:72] = txt
    e[72:90] = d2
    got = parse_edid_preferred(bytes(e))
    cases.append(("跳过监视器描述符取第二个 DTD", got == (1280, 720), got))

    cases.append(("空数据返回 None",
                  parse_edid_preferred(b"") is None, None))
    cases.append(("坏头返回 None",
                  parse_edid_preferred(b"\x11" * 128) is None, None))

    modes = [(1920, 1080, 60.0, "1920x1080     60.00*"),
             (1920, 1080, 144.0, "1920x1080    144.00"),
             (1280, 1024, 60.0, "1280x1024     60.00")]
    m = pick_native(modes, (1920, 1080))
    cases.append(("同分辨率取最高刷新率",
                  m is not None and m[2] == 144.0, m[3] if m else None))
    cases.append(("找不到匹配时返回 None",
                  pick_native(modes, (800, 600)) is None, None))

    fb = pick_fallback([(1024, 768, 60.0, "1024x768"),
                        (1920, 1080, 60.0, "1920x1080"),
                        (1920, 1080, 30.0, "1920x1080i")])
    cases.append(("兜底取最大分辨率",
                  fb is not None and fb[0] == 1920 and fb[1] == 1080,
                  fb[3] if fb else None))

    qtext = (
        "Screen 0: minimum 320 x 200, current 1920 x 1080, maximum 16384 x 16384\n"
        "eDP-1 connected primary 1920x1080+0+0 (normal left inverted right x axis y axis) 344mm x 194mm\n"
        "   1920x1080     60.00*+\n"
        "   1920x1080     59.94  \n"
        "   1680x1050     59.95  \n"
        "HDMI-1 connected 1280x1024+1920+0 (normal left inverted right x axis y axis) 376mm x 301mm\n"
        "   1280x1024     60.00*+\n"
        "   1024x768      60.00  \n"
        "DP-1 disconnected (normal left inverted right x axis y axis)\n"
        "   1920x1080     60.00  \n"
    )
    info = parse_xrandr(qtext)
    cases.append(("解析出 2 块已连接屏",
                  len([o for o in info["outputs"].values() if o["connected"]]) == 2, None))
    cases.append(("识别主屏 eDP-1", info["primary"] == "eDP-1", info["primary"]))
    cases.append(("eDP-1 有 3 个模式",
                  len(info["outputs"]["eDP-1"]["modes"]) == 3,
                  len(info["outputs"]["eDP-1"]["modes"])))
    cases.append(("断开屏被标记 disconnected",
                  info["outputs"]["DP-1"]["connected"] is False, None))
    cases.append(("模式带刷新率",
                  info["outputs"]["HDMI-1"]["modes"][0][2] == 60.0,
                  info["outputs"]["HDMI-1"]["modes"][0][2]))

    # 真实 EDID 片段: 第 1 个描述符是产品名 "LARI"(0x0000FC..),
    # 第 2 个才是详细时序 DTD(像素时钟 148.5MHz / 1920x1080)
    vtext = (
        "eDP-1 connected primary 1920x1080+0+0 (normal left inverted) 344mm x 194mm\n"
        "\tIdentifier: 0x44\n"
        "\tTimestamp:  120000\n"
        "\tEDID:\n"
        "\t\t00ffffffffffff0006af3d5700000000\n"
        "\t\t00100103802000000000000000000000\n"
        "\t\t000000fc00544c4152490a2020202020\n"
        "\t\t0000000000000000fc004c4152490a20\n"
        "\t\t2020202020202020023a805870384040\n"
        "\t\t3020030c13021d010000000000000000\n"
        "\t\t00000000000000000000000000000000\n"
        "\t\t00000000000000000000000000000000\n"
    )
    eids = parse_edids(vtext)
    parsed = parse_edid_preferred(eids.get("eDP-1", b""))
    cases.append(("从 xrandr --verbose 抠出 EDID 并解析",
                  parsed == (1920, 1080), parsed))
    cases.append(("读出 EDID 产品名",
                  describe_edid(eids.get("eDP-1", b"")) == "LARI", describe_edid(eids.get("eDP-1", b""))))

    plan = build_plan(qtext, vtext)
    by_out = {p["output"]: p for p in plan}
    cases.append(("方案只含已连接的屏",
                  sorted(by_out) == ["HDMI-1", "eDP-1"], sorted(by_out)))
    cases.append(("eDP-1 取到 EDID 原生 1920x1080 并取最高刷新率 60Hz",
                  by_out["eDP-1"]["target"][0] == 1920
                  and by_out["eDP-1"]["target"][2] == 60.0,
                  by_out["eDP-1"]["target"][3] if by_out["eDP-1"]["target"] else None))
    cases.append(("HDMI-1 没 EDID 时走兜底 1280x1024",
                  by_out["HDMI-1"]["origin"] == "fallback"
                  and by_out["HDMI-1"]["target"][0] == 1280,
                  by_out["HDMI-1"]["target"][3] if by_out["HDMI-1"]["target"] else None))

    failed = 0
    for name, good, got in cases:
        if good:
            print(f"  \033[1;32m✅\033[0m {name}")
        else:
            print(f"  \033[1;31m❌\033[0m {name}  (实际: {got!r})")
            failed += 1
    print(f"\n{'✅' if failed == 0 else '❌'} {len(cases) - failed}/{len(cases)} 项通过")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except KeyboardInterrupt:
        sys.exit(130)