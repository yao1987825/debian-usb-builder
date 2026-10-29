"""traintools.format —— 余票表格渲染(不依赖 prettytable/colorama)。

终端里用 ANSI 颜色; 输出到管道/文件时自动去掉颜色。
中英文混排时按**显示宽度**对齐(中文算两列), 不然表格会歪。
"""

from __future__ import annotations

import os
import re
import unicodedata

RESET = "\033[0m"
GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
CYAN = "\033[36m"
BOLD = "\033[1m"

# 展示的座位列: (表头, 字段名)。顺序跟 12306 网页一致。
SEAT_COLUMNS = [
    ("商务", "swz_num"),
    ("特等", "tz_num"),
    ("一等", "zy_num"),
    ("二等", "ze_num"),
    ("高软", "gr_num"),
    ("软卧", "rw_num"),
    ("动卧", "srrb_num"),
    ("硬卧", "yw_num"),
    ("软座", "rz_num"),
    ("硬座", "yz_num"),
    ("无座", "wz_num"),
]


def _color_enabled():
    if os.environ.get("NO_COLOR"):
        return False
    try:
        return os.stdout.isatty()
    except Exception:
        return False


def width(text):
    """显示宽度: 中文/全角算 2 列。"""
    w = 0
    for ch in str(text):
        if unicodedata.combining(ch):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def pad(text, target, align="left"):
    text = str(text)
    gap = max(0, target - width(text))
    if align == "right":
        return " " * gap + text
    if align == "center":
        left = gap // 2
        return " " * left + text + " " * (gap - left)
    return text + " " * gap


def seat_text(value):
    """余票数字 -> 展示文本。"""
    value = (value or "").strip()
    if not value or value == "--":
        return "-"
    if value == "有":
        return "有"
    if value.isdigit():
        return value
    return value


def seat_color(value, enabled):
    if not enabled:
        return seat_text(value)
    text = seat_text(value)
    if text == "有":
        return f"{GREEN}{text}{RESET}"
    if text.isdigit():
        return f"{GREEN}{text}{RESET}"
    if text == "无" or text == "-":
        return f"{RED}{text}{RESET}"
    return text


def render(trains, code2name=None, show_color=None):
    """渲染成对齐的表格文本。"""
    if show_color is None:
        show_color = _color_enabled()
    code2name = code2name or {}

    headers = ["车次", "出发 → 到达", "时间", "历时"]
    rows = []
    for t in trains:
        from_st = code2name.get(t.get("from_station", ""), t.get("from_station", ""))
        to_st = code2name.get(t.get("to_station", ""), t.get("to_station", ""))
        seats = []
        for _, field in SEAT_COLUMNS:
            raw = t.get(field, "")
            seats.append(seat_color(raw, show_color))
        rows.append(
            [
                t.get("train_no", ""),
                f"{from_st} → {to_st}",
                f"{t.get('from_time', '')} → {t.get('to_time', '')}",
                t.get("duration", ""),
            ]
            + seats
        )

    widths = []
    for i, h in enumerate(headers):
        w = width(h)
        for r in rows:
            w = max(w, width(_strip_ansi(r[i])))
        widths.append(w)

    lines = []
    head = "  ".join(pad(h, widths[i]) for i, h in enumerate(headers))
    lines.append(f"{BOLD}{head}{RESET}" if show_color else head)
    lines.append("  ".join("-" * w for w in widths))
    for r in rows:
        cells = []
        for i, cell in enumerate(r):
            if i >= len(widths):
                cells.append(cell)
                continue
            # 颜色码不参与宽度计算: 先按纯文本补齐, 再套色
            plain = _strip_ansi(cell)
            gap = max(0, widths[i] - width(plain))
            if show_color and cell != plain:
                cells.append(cell + " " * gap)
            else:
                cells.append(pad(cell, widths[i]))
        lines.append("  ".join(cells))
    return "\n".join(lines)


_ANSI_RE = re.compile(r"\033\[[0-9;]*m")


def _strip_ansi(text):
    return _ANSI_RE.sub("", str(text))
