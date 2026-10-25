#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fix-keyboard-shortcuts.py —— 清理 XFCE 默认快捷键里"指向镜像里根本没有的程序"的绑定

背景(用户实测反馈, 2026-10-25):
    "无法打开 print 快捷键这样的警告提示"

真因: 这个镜像故意极简(不要面板/桌面图标/文件管理器/浏览器), 但 XFCE 的
默认快捷键文件里还绑着一堆没装的可执行文件:

    Print / Shift+Print / Alt+Print  -> xfce4-screenshooter   (没装)
    Super+e / Ctrl+Alt+F              -> thunar                (没装)
    Super+r / Alt+F2 / Alt+F3         -> xfce4-appfinder       (没装)
    Alt+F1                            -> xfce4-popup-applicationsmenu (没装)
    Ctrl+Shift+Escape                 -> xfce4-taskmanager     (没装)
    Ctrl+Escape                       -> xfdesktop --menu      (没装)
    Alt+Super+s                       -> orca                  (没装)
    XF86WWW / HomePage                -> exo-open --launch WebBrowser  (没浏览器)
    XF86Mail                          -> exo-open --launch MailReader  (没邮件客户端)

按这些键, xfce4-keyboard-shortcuts 会去执行一个不存在的命令, XFCE 随即
弹出"无法打开…"的警告框 —— 用户看到的就是"系统好像坏了"。

做法:
  1) 逐条检查默认绑定, 目标程序在镜像里不存在(或 exo-open 要启动的应用
     根本没有对应程序)就把这条绑定**删掉** —— 按了没反应, 但不再弹警告。
  2) 截图键例外: 镜像里已经有 scrot(依赖极小), 给它套一层 /usr/local/bin/screenshot,
     于是 Print=全屏 / Shift+Print=框选 / Alt+Print=当前窗口, 截图键真正可用。
  3) 顺手把用户自己要的窗口快捷键写进用户级 xfconf 覆盖文件:
     Super+←/→  左右平铺, Super+↑ 最大化, Super+↓ 还原/下移;
     Ctrl+Alt+T 直接跑 terminal-new(当前窗口加标签页, 不盖屏幕)。
  4) 生成的只是"用户级 xfconf 覆盖文件"(~/.config/xfce4/xfconf/xfce-perchannel-xml/),
     xfconf 启动时会读它, 覆盖同名默认绑定。

用法:
    fix-keyboard-shortcuts.py <rootfs 目录> [--quiet]
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

DEFAULT_XML = "/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
USER_XML = ".config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml"
DEFAULT_HOME = "home/user"

# 镜像里可能放可执行文件的地方(相对 rootfs)
BIN_DIRS = (
    "usr/bin", "bin", "usr/sbin", "sbin", "usr/local/bin", "usr/local/sbin", "usr/games",
)

# exo-open --launch <App> 需要哪个程序才算真的能用
EXO_APP_NEEDS = {
    "TerminalEmulator": ("xfce4-terminal",),
    "WebBrowser": ("firefox", "firefox-esr", "chromium", "chromium-browser",
                   "x-www-browser", "epiphany", "midori"),
    "MailReader": ("thunderbird", "evolution", "kmail", "mail"),
}

# 用户级覆盖: 命令类
CUSTOM_COMMANDS = (
    ("Print", "/usr/local/bin/screenshot"),
    ("&lt;Shift&gt;Print", "/usr/local/bin/screenshot -r"),
    ("&lt;Alt&gt;Print", "/usr/local/bin/screenshot -w"),
    ("&lt;Primary&gt;&lt;Alt&gt;t", "/usr/local/bin/terminal-new"),
    # 下面这些在极简镜像里对应的程序根本没装(XFCE 默认表自带的绑定),
    # 改绑 /bin/true: 按了什么都不发生, 但不再弹"无法打开…"的警告框。
    ("&lt;Alt&gt;F1", "/bin/true"),
    ("&lt;Alt&gt;F2", "/bin/true"),
    ("&lt;Alt&gt;F3", "/bin/true"),
    ("&lt;Alt&gt;&lt;Super&gt;s", "/bin/true"),
    ("&lt;Primary&gt;&lt;Alt&gt;f", "/bin/true"),
    ("&lt;Primary&gt;&lt;Alt&gt;l", "/bin/true"),
    ("&lt;Primary&gt;Escape", "/bin/true"),
    ("&lt;Primary&gt;&lt;Shift&gt;Escape", "/bin/true"),
    ("&lt;Super&gt;e", "/bin/true"),
    ("&lt;Super&gt;r", "/bin/true"),
    ("XF86WWW", "/bin/true"),
    ("HomePage", "/bin/true"),
    ("XF86Mail", "/bin/true"),
)

# 用户级覆盖: 窗口管理器(xfwm4)动作类
CUSTOM_XFWM4 = (
    ("&lt;Super&gt;Left", "tile_left_key"),
    ("&lt;Super&gt;Right", "tile_right_key"),
    ("&lt;Super&gt;Up", "maximize_window_key"),
    ("&lt;Super&gt;Down", "tile_down_key"),
)


def xml_escape(text):
    """把字符串转成 XML 属性里该有的样子(值里带 & < > 时要用)。"""
    return (text.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;").replace('"', "&quot;"))


def has_binary(rootfs, exe):
    for d in BIN_DIRS:
        p = os.path.join(rootfs, d, exe)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return True
    return False


def exo_app_usable(rootfs, app):
    needs = EXO_APP_NEEDS.get(app)
    if needs is None:
        return False
    return any(has_binary(rootfs, exe) for exe in needs)


def judge_binding(rootfs, value):
    """这条绑定还有效吗? 返回 None 表示有效, 否则返回"为什么无效"。"""
    parts = value.split()
    exe = parts[0]
    if exe == "exo-open":
        app = ""
        if "--launch" in parts:
            idx = parts.index("--launch")
            if idx + 1 < len(parts):
                app = parts[idx + 1]
        if exo_app_usable(rootfs, app):
            return None
        return "exo-open 要启动的应用 %s 在镜像里没有" % (app or "?")
    if has_binary(rootfs, exe):
        return None
    return "%s 没装" % exe


def collect_broken(rootfs):
    """找出 commands/default 段里失效的绑定名(返回 [(name, value, reason)])。

    重要: 只看 commands/default 段。xfwm4 段里那些值( tile_left_key /
    maximize_window_key 之类)是**窗口管理器的动作名**, 不是可执行文件 ——
    当成程序去查会全部判定为"没装"然后被误删, 窗口快捷键就全废了。
    """
    path = os.path.join(rootfs, DEFAULT_XML.lstrip("/"))
    broken = []
    if not os.path.isfile(path):
        return broken
    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise SystemExit("默认快捷键文件解析失败: %s (%s)" % (path, exc))
    cmds = root.find("./property[@name='commands']/property[@name='default']")
    if cmds is None:
        return broken
    for prop in cmds:
        value = prop.get("value")
        if not value:
            continue
        reason = judge_binding(rootfs, value)
        if reason is not None:
            broken.append((prop.get("name") or "", value, reason))
    return broken


def strip_broken_defaults(rootfs, quiet=False):
    """把默认快捷键里指向"镜像里没有的程序"的绑定删掉(保留原文件排版)。"""
    path = os.path.join(rootfs, DEFAULT_XML.lstrip("/"))
    broken = collect_broken(rootfs)
    if not broken:
        return []
    # 按**命令值**匹配, 不按键名: 键名在文件里是 XML 转义过的(&lt;Super&gt;e),
    # 解析出来却是原样(<Super>e), 对不上; 命令值没这个问题。
    want = {xml_escape(value) for _name, value, _reason in broken}
    with open(path, encoding="utf-8") as fp:
        lines = fp.read().splitlines(keepends=True)
    out = []
    removed = []
    i = 0
    total = len(lines)
    while i < total:
        line = lines[i]
        m = re.search(r'<property name="([^"]*)" type="string" value="([^"]*)"', line)
        if not m or m.group(2) not in want:
            out.append(line)
            i += 1
            continue
        name, value = m.group(1), m.group(2)
        if line.rstrip().endswith("/>"):
            block = [line]
            nxt = i + 1
        else:
            block = [line]
            indent = len(line) - len(line.lstrip())
            nxt = i + 1
            while nxt < total:
                block.append(lines[nxt])
                cur = lines[nxt]
                if cur.strip() == "</property>" and (len(cur) - len(cur.lstrip())) == indent:
                    nxt += 1
                    break
                nxt += 1
        reason = dict((v, r) for _n, v, r in broken).get(value, "失效绑定")
        removed.append((name, value, reason))
        i = nxt
    if removed:
        with open(path, "w", encoding="utf-8") as fp:
            fp.write("".join(out))
    if not quiet:
        for name, value, reason in removed:
            print("  摘掉失效快捷键 %s -> %s (%s)" % (name, value, reason))
    return removed


def write_user_overrides(rootfs, home=DEFAULT_HOME, quiet=False):
    """写用户级 xfconf 覆盖文件(截图键 / 窗口快捷键 / Ctrl+Alt+T)。"""
    path = os.path.join(rootfs, home.lstrip("/"), USER_XML)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "",
             '<channel name="xfce4-keyboard-shortcuts" version="1.0">',
             '  <property name="commands" type="empty">',
             '    <property name="custom" type="empty">']
    for name, value in CUSTOM_COMMANDS:
        lines.append('      <property name="%s" type="string" value="%s"/>' % (name, value))
    lines += ['    </property>', '  </property>',
              '  <property name="xfwm4" type="empty">',
              '    <property name="custom" type="empty">']
    for name, value in CUSTOM_XFWM4:
        lines.append('      <property name="%s" type="string" value="%s"/>' % (name, value))
    lines += ['    </property>', '  </property>', '</channel>', '']
    with open(path, "w", encoding="utf-8") as fp:
        fp.write("\n".join(lines))
    if not quiet:
        print("  已写用户级快捷键覆盖: %s" % path)


def main(argv):
    quiet = "--quiet" in argv
    home = DEFAULT_HOME
    args = []
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--home":
            i += 1
            if i >= len(argv):
                print("--home 后面要跟 home 目录(相对 rootfs)")
                return 2
            home = argv[i]
        elif arg.startswith("--"):
            pass
        else:
            args.append(arg)
        i += 1
    if len(args) != 1:
        print(__doc__)
        return 2
    rootfs = os.path.abspath(args[0])
    if not os.path.isdir(rootfs):
        print("rootfs 目录不存在: %s" % rootfs)
        return 2
    if not quiet:
        print("== 清理 XFCE 默认快捷键里指向缺失程序的绑定 ==")
    removed = strip_broken_defaults(rootfs, quiet=quiet)
    write_user_overrides(rootfs, home=home, quiet=quiet)
    if not quiet:
        print("== 共摘掉 %d 条失效绑定 ==" % len(removed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
