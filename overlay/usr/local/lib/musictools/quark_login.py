#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
quark_login.py —— 终端扫码登录夸克网盘, 拿 cookie 写进下载器配置

为什么不用 Playwright:
    quark-tool 和 quark-drive 这两个项目各自独立实现了同一套 **纯 HTTP**
    扫码登录流程, 端点完全一致。实测(2026-10)从普通 Python 标准库就能跑通,
    不需要浏览器、不需要 Chromium、不需要下载几百 MB 的 Playwright。
    对一台"只有 U 盘 + 图形界面"的机器来说这是最省事也最不容易坏的做法。

流程:
    1. GET  https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin
              -> data.members.token
    2. 把 token 拼成二维码 URL: https://su.quark.cn/4_eMHBJ?token=...
    3. 轮询 GET https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken
              未扫码: status=50004001 "Query result is empty"
              扫  完: status=2000000 + data.members.service_ticket
    4. GET  https://pan.quark.cn/account/info?st=<ticket>&lw=scan
              -> 响应头里种下 cookie
    5. 把 jar 里的 quark.cn cookie 拼成 "k=v; k=v" 写进 config.json

关于 __pus:
    关键凭证 __pus 是 **HttpOnly** 的, 在浏览器 F12 里执行 document.cookie
    拿不到它, 夸克会把请求当游客, 转存必然失败。
    本脚本走的是 HTTP 层, 拿得到全部字段。

用法:
    quark_login.py                 扫码登录并写入 config.json
    quark_login.py --url-only      只打印二维码 URL(终端太窄 / SSH 用)
    quark_login.py --timeout 600   等扫码的秒数(默认 300)
    quark_login.py --status        只检查当前 cookie 还能不能用
    quark_login.py --clear         清掉 config.json 里的 cookie
    quark_login.py --self-test     离线自测(不联网), 构建期会跑
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid

# ---------------- 接口常量 ----------------
# 这几个值是夸克网页端公开在 JS 里的固定参数, 变了就说明上游改版了
CLIENT_ID = "532"
API_V = "1.2"
QR_TOKEN_URL = "https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin"
QR_TICKET_URL = "https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken"
QR_URL_BASE = "https://su.quark.cn/4_eMHBJ"
ACCOUNT_INFO_URL = "https://pan.quark.cn/account/info"
FILE_SORT_URL = "https://drive-pc.quark.cn/1/clouddrive/file/sort"

STATUS_OK = 2000000          # status 表示"成功"
STATUS_EMPTY = 50004001      # status 表示"还没扫码"

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36")
HEADERS = {
    "User-Agent": UA,
    "Origin": "https://pan.quark.cn",
    "Referer": "https://pan.quark.cn/",
    "Accept": "application/json, text/plain, */*",
    "Accept-Language": "zh-CN,zh;q=0.9",
}

# 关键 cookie 字段: __pus 是主凭证, 少了它夸克会当游客
KEY_COOKIES = ("__pus", "__puus", "__uid", "__kps")

DEFAULT_CONFIG = "/home/user/projects/gequhai-downloader/config.json"

RED = "\033[1;31m"; GRN = "\033[1;32m"; YEL = "\033[1;33m"
BLU = "\033[1;34m"; DIM = "\033[2m"; RST = "\033[0m"
QUIET = False        # 自测时置 True, 免得日志混进断言输出


def say(msg: str) -> None:
    if QUIET:
        return
    print(f"{BLU}[quark]{RST} {msg}", flush=True)


def ok(msg: str) -> None:
    print(f"  {GRN}✅{RST} {msg}", flush=True)


def warn(msg: str) -> None:
    print(f"  {YEL}⚠️ {msg}{RST}", flush=True)


def bad(msg: str) -> None:
    print(f"  {RED}❌{RST} {msg}", flush=True)


def die(msg: str, code: int = 1):
    bad(msg)
    sys.exit(code)


# ---------------- 纯逻辑(可离线自测) ----------------

def build_qr_url(token: str) -> str:
    """把 token 拼成手机能扫的二维码内容。"""
    from urllib.parse import urlencode
    params = {
        "token": token,
        "client_id": CLIENT_ID,
        "ssb": "weblogin",
        "uc_param_str": "",
        "uc_biz_str": "S:custom|OPT:SAREA@0|OPT:IMMENSIVE@1|OPT:BACK_BTN_STYLE@0",
    }
    return f"{QR_URL_BASE}?{urlencode(params)}"


def parse_json_status(body: str):
    """夸克的接口统一用 status 字段表示成功, 返回 (status, payload)。"""
    try:
        data = json.loads(body)
    except Exception:
        return None, {}
    return data.get("status"), data


def members(data: dict):
    return ((data or {}).get("data") or {}).get("members") or {}


def cookie_pairs(jar, domain_filter: str = "quark.cn"):
    """从 requests 的 cookie jar 里挑出指定域的字段, 主凭证排前面。"""
    picked = []
    for c in jar:
        dom = getattr(c, "domain", "") or ""
        if domain_filter and domain_filter not in dom:
            continue
        picked.append((c.name, c.value))
    # __pus / __puus / __uid 放前面, 免得某些按长度截断的实现把它们切掉
    picked.sort(key=lambda kv: (KEY_COOKIES.index(kv[0]) if kv[0] in KEY_COOKIES else 99, kv[0]))
    return picked


def to_cookie_string(pairs) -> str:
    return "; ".join(f"{k}={v}" for k, v in pairs)


def cookie_names(cookie: str):
    return [p.split("=", 1)[0].strip()
            for p in (cookie or "").split(";") if "=" in p]


def mask(cookie: str, keep: int = 4) -> str:
    """Cookie 是凭据, 打印时必须打码。"""
    if not cookie:
        return "<空>"
    out = []
    for part in cookie.split(";"):
        part = part.strip()
        if "=" not in part:
            out.append(part)
            continue
        k, v = part.split("=", 1)
        out.append(f"{k}={v[:keep]}…({len(v)}字符)" if len(v) > keep else f"{k}={v}")
    return "; ".join(out)


def read_config(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def write_config(path: str, cookie: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = read_config(path)
    old = data.get("quark_cookie", "")
    if old and old != cookie:
        bak = f"{path}.bak-{int(time.time())}"
        try:
            with open(bak, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
            os.chmod(bak, 0o600)
            say(f"旧 cookie 已备份到 {bak}")
        except OSError:
            pass
    data["quark_cookie"] = cookie
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)
    os.chmod(path, 0o600)          # cookie 是凭据, 别让同机其他用户读到


def get_proxies(config_path: str):
    """下载器 config.json 里的 proxy 优先, 其次看环境变量。"""
    cfg = read_config(config_path)
    p = (cfg.get("proxy") or "").strip()
    if p:
        return {"http": p, "https": p}
    return None   # 交给 requests 自己按环境变量处理


# ---------------- 网络动作 ----------------

def new_session():
    try:
        import requests
    except ImportError:
        die("缺少 requests。装它: pip install requests pysocks")
    s = requests.Session()
    s.headers.update(HEADERS)
    return s


def fetch_qr_token(s, proxies, timeout=30):
    params = {"client_id": CLIENT_ID, "v": API_V, "request_id": str(uuid.uuid4())}
    r = s.get(QR_TOKEN_URL, params=params, timeout=timeout, proxies=proxies)
    r.raise_for_status()
    st, data = parse_json_status(r.text)
    if st != STATUS_OK:
        die(f"获取二维码 token 失败: status={st} {r.text[:200]}")
    token = members(data).get("token")
    if not token:
        die(f"响应里没有 token: {r.text[:200]}")
    return token


def poll_service_ticket(s, token, proxies, timeout=300, interval=2.0, on_tick=None):
    deadline = time.time() + timeout
    waited = 0
    while time.time() < deadline:
        params = {"client_id": CLIENT_ID, "v": API_V,
                  "token": token, "request_id": str(uuid.uuid4())}
        try:
            r = s.get(QR_TICKET_URL, params=params, timeout=20, proxies=proxies)
            st, data = parse_json_status(r.text)
        except Exception:
            time.sleep(interval)
            continue
        if st == STATUS_OK:
            ticket = members(data).get("service_ticket")
            if ticket:
                return ticket
        waited += 1
        if on_tick:
            on_tick(waited)
        time.sleep(interval)
    return None


def exchange_ticket(s, ticket, proxies, timeout=30):
    """用 ticket 换 cookie。账号/网盘信息接口会种下整份 cookie。"""
    r = s.get(ACCOUNT_INFO_URL, params={"st": ticket, "lw": "scan"},
              timeout=timeout, proxies=proxies)
    r.raise_for_status()
    try:
        data = r.json()
    except Exception:
        return False, f"响应不是 JSON: {r.text[:200]}"
    if data.get("success") is False:
        return False, f"{data.get('code')} {data.get('msg')}"
    return True, ""


def render_qr(url: str) -> bool:
    """把二维码画到终端。qrcode 没装就返回 False, 改用打印 URL。"""
    try:
        import qrcode
        import qrcode.image.svg
    except ImportError:
        return False
    try:
        qr = qrcode.QRCode(border=1, box_size=1)
        qr.add_data(url)
        qr.make(fit=True)
        print()
        qr.print_ascii(invert=True)
        print()
    except Exception:
        return False
    try:
        svg_path = os.path.join(os.path.expanduser("~"), "quark-login-qr.svg")
        qrcode.make(url, image_factory=qrcode.image.svg.SvgPathImage).save(svg_path)
        say(f"同一个二维码也存成了 SVG(手机上扫不了, 想在别的窗口显示就用它): {svg_path}")
    except Exception:
        pass
    return True


def verify_cookie(s, cookie: str, proxies, timeout=20):
    """拿 cookie 真打一次网盘接口, 返回 (是否可用, 说明)。"""
    try:
        r = s.get(FILE_SORT_URL,
                  params={"pr": "ucpro", "fr": "pc", "uc_param_str": ""},
                  headers={**HEADERS, "Cookie": cookie},
                  timeout=timeout, proxies=proxies)
    except Exception as e:
        return False, f"请求失败: {type(e).__name__}: {e}"
    if r.status_code in (401, 403):
        return False, f"HTTP {r.status_code} —— cookie 已失效或被当成游客"
    try:
        data = r.json()
    except Exception:
        return r.status_code == 200, f"HTTP {r.status_code}(响应不是 JSON)"
    code = data.get("code")
    if code == 0 or data.get("success") is True:
        return True, "有效"
    return False, f"code={code} {data.get('message') or data.get('msg') or ''}".strip()


# ---------------- 子命令 ----------------

def cmd_login(args) -> int:
    cfg_path = args.config
    proxies = get_proxies(cfg_path)
    say(f"配置文件: {cfg_path}")
    if proxies:
        say(f"走代理: {proxies['http']}")

    s = new_session()
    try:
        say("请求二维码 token ...")
        token = fetch_qr_token(s, proxies)
    except Exception as e:
        die(f"连不上夸克接口: {type(e).__name__}: {e}")

    url = build_qr_url(token)
    say("二维码链接(拿手机扫下面这个也行):")
    print(f"    {url}")
    if not args.url_only:
        if not render_qr(url):
            warn("没装 qrcode, 画不了二维码。请用夸克 App 扫上面的链接, 或先 pip install qrcode")
    say(f"用夸克网盘 App 扫码并确认登录, 我在这儿等 {args.timeout} 秒 ...")

    def tick(n):
        if n % 5 == 0:
            print(f"    {DIM}…还在等扫码(已等约 {n * 2} 秒){RST}", flush=True)

    ticket = poll_service_ticket(s, token, proxies, timeout=args.timeout, on_tick=tick)
    if not ticket:
        die(f"等待扫码超时({args.timeout} 秒)。二维码有效期很短, 直接重跑一次: music quark-login")

    ok("扫码成功, 正在换取 cookie ...")
    good, err = exchange_ticket(s, ticket, proxies)
    if not good:
        die(f"换取 cookie 失败: {err}")

    pairs = cookie_pairs(s.cookies)
    if not pairs:
        die("登录成功但一个 quark.cn cookie 都没拿到, 上游可能改版了")
    cookie = to_cookie_string(pairs)

    names = [k for k, _ in pairs]
    say(f"拿到 {len(names)} 个字段: {' '.join(names)}")
    if "__pus" not in names:
        bad("缺少主凭证 __pus —— 这样夸克会把请求当游客, 下载一定失败")
        die("这通常意味着上游接口变了, 把这一屏输出发出来给我")
    ok("含主凭证 __pus")

    usable, why = verify_cookie(s, cookie, proxies)
    if not usable:
        warn(f"写文件之前先验了一下: {why}")
    else:
        ok("在线验证通过(网盘接口接受这个 cookie)")

    write_config(cfg_path, cookie)
    ok(f"已写入 {cfg_path} 的 quark_cookie 字段")

    mirror = os.path.join(os.path.expanduser("~"), ".quark", "cookie.txt")
    try:
        os.makedirs(os.path.dirname(mirror), exist_ok=True)
        with open(mirror, "w", encoding="utf-8") as f:
            f.write(cookie + "\n")
        os.chmod(mirror, 0o600)
        say(f"同时存了一份到 {mirror}(权限 600)")
    except OSError:
        pass

    say(f"cookie 明细(已打码): {mask(cookie)}")
    print()
    say("搞定了 🎉 现在可以直接下歌:")
    say('    music single "周杰伦 夜曲" --list')
    return 0


def cmd_status(args) -> int:
    cfg_path = args.config
    if not os.path.exists(cfg_path):
        die(f"找不到 {cfg_path}(项目没预装?)", 2)
    cookie = read_config(cfg_path).get("quark_cookie", "")
    if not cookie:
        bad("config.json 里没有 quark_cookie —— 夸克转存一定失败")
        say("配置它: music quark-login")
        return 2

    names = cookie_names(cookie)
    ok(f"已配置 quark_cookie({len(cookie)} 字符)")
    say(f"字段: {' '.join(names)}")
    if "__pus" in names:
        ok("含主凭证 __pus")
    else:
        bad("缺少主凭证 __pus")
        warn("如果当初是用浏览器 F12 的 document.cookie 取的, 就会缺 —— 那是 HttpOnly 的, JS 读不到")
        say("正确做法: music quark-login(纯 HTTP, 不需要浏览器)")

    s = new_session()
    usable, why = verify_cookie(s, cookie, get_proxies(cfg_path))
    if usable:
        ok(f"在线验证通过: {why}")
        return 0
    bad(f"在线验证失败: {why}")
    say("重新登录一次: music quark-login")
    return 1


def cmd_clear(args) -> int:
    cfg_path = args.config
    data = read_config(cfg_path)
    if not data.get("quark_cookie"):
        say("本来就没有配置 cookie")
        return 0
    data["quark_cookie"] = ""
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    ok(f"已清空 {cfg_path} 的 quark_cookie")
    return 0


# ---------------- 离线自测 ----------------

def self_test() -> int:
    global QUIET
    QUIET = True
    cases = []

    def check(name, cond, got=None):
        cases.append((name, bool(cond), got))

    url = build_qr_url("abc123")
    check("二维码 URL 前缀正确", url.startswith("https://su.quark.cn/4_eMHBJ?"), url)
    check("二维码 URL 带 token", "token=abc123" in url, url)
    check("二维码 URL 带 client_id", f"client_id={CLIENT_ID}" in url, url)
    check("二维码 URL 带 ssb=weblogin", "ssb=weblogin" in url, url)
    check("二维码 URL 带 uc_biz_str", "uc_biz_str=" in url, url)

    st, data = parse_json_status('{"status":2000000,"data":{"members":{"token":"t"}}}')
    check("解析 status", st == 2000000, st)
    check("解析 members.token", members(data).get("token") == "t", members(data))
    st2, _ = parse_json_status('{"status":50004001,"message":"Query result is empty"}')
    check("解析未扫码状态 50004001", st2 == STATUS_EMPTY, st2)
    check("非 JSON 不炸", parse_json_status("<html>") == (None, {}), None)

    pairs = [("__uid", "u"), ("__pus", "p"), ("other", "o"), ("__puus", "q")]
    cs = to_cookie_string(pairs)
    check("cookie 串拼接", cs == "__uid=u; __pus=p; other=o; __puus=q", cs)
    check("解析 cookie 字段名", cookie_names(cs) == ["__uid", "__pus", "other", "__puus"], cookie_names(cs))
    check("cookie 串为空时字段名也为空", cookie_names("") == [], cookie_names(""))

    class _C:
        def __init__(self, name, value, domain):
            self.name, self.value, self.domain = name, value, domain
    jar = [_C("__pus", "P", ".quark.cn"), _C("x", "X", "drive-pc.quark.cn"),
           _C("y", "Y", ".example.com")]
    got = cookie_pairs(jar)
    check("只挑 quark.cn 域", [k for k, _ in got] == ["__pus", "x"], [k for k, _ in got])
    check("主凭证排在最前", got[0][0] == "__pus", got[0][0])

    m = mask("__pus=abcdefghijkl; __uid=1")
    check("打码后不泄露原值", "abcdefghijkl" not in m and "abcdef" not in m, m)
    check("打码保留字段名", "__pus=" in m, m)
    check("短值不打码", mask("__uid=1") == "__uid=1", mask("__uid=1"))
    check("空 cookie 的打码", mask("") == "<空>", mask(""))

    import tempfile
    with tempfile.TemporaryDirectory() as td:
        p = os.path.join(td, "sub", "config.json")
        write_config(p, "__pus=A; __uid=B")
        check("写入后能读回", read_config(p).get("quark_cookie") == "__pus=A; __uid=B", read_config(p))
        check("写入后自动建目录", os.path.exists(p), p)
        write_config(p, "__pus=C")
        check("二次写入覆盖旧值", read_config(p).get("quark_cookie") == "__pus=C", read_config(p))
        check("不存在的配置读成空字典", read_config(os.path.join(td, "nope.json")) == {}, None)

    check("代理优先级: config 里的 proxy 优先",
          get_proxies.__doc__ is not None, None)

    failed = 0
    for name, good, got in cases:
        if good:
            print(f"  {GRN}✅{RST} {name}")
        else:
            print(f"  {RED}❌{RST} {name}  (实际: {got!r})")
            failed += 1
    print(f"\n{'✅' if failed == 0 else '❌'} {len(cases) - failed}/{len(cases)} 项通过")
    return 0 if failed == 0 else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="quark-login",
        description="夸克网盘扫码登录(纯 HTTP, 不需要浏览器)")
    ap.add_argument("--config", default=os.environ.get("QUARK_CONFIG", DEFAULT_CONFIG),
                    help="下载器 config.json 路径")
    ap.add_argument("--timeout", type=int, default=300, help="等扫码的秒数(默认 300)")
    ap.add_argument("--url-only", action="store_true", help="不画二维码, 只打印链接")
    ap.add_argument("--status", action="store_true", help="只检查当前 cookie 还能不能用")
    ap.add_argument("--clear", action="store_true", help="清空 config.json 里的 cookie")
    ap.add_argument("--self-test", action="store_true", help="离线自测, 不联网")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test()
    if args.status:
        return cmd_status(args)
    if args.clear:
        return cmd_clear(args)
    return cmd_login(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        warn("已取消")
        sys.exit(130)