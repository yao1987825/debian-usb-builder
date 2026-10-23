#!/usr/bin/env python3
"""给 gequhai-downloader/quark.py 打 __puus 补丁 (幂等)。

背景: 夸克 CDN 直链必须带新鲜 __puus cookie (约 3 小时有效), 但扫码登录
拿到的 cookie 没有这个字段; 取直链的 /file/download API 响应的 Set-Cookie
里会首发 __puus —— 取走它、合回 cookie 再交给 download_file, 412 就消失。
(alist issue #830 / vela 直链文档都记录了这一限制)
"""
import sys
from pathlib import Path

MARKER = "_refresh_puus"

target = Path(sys.argv[1] if len(sys.argv) > 1 else "quark.py")
src = target.read_text(encoding="utf-8")
if MARKER in src:
    print("already patched")
    sys.exit(0)

helper = '''
def _refresh_puus(cookie: str, resp) -> str:
    """从 API 响应的 Set-Cookie 里抓新鲜 __puus 合回 cookie (CDN 412 补救)"""
    import re as _re
    _m = _re.search(r"__puus=([^;]+)", (resp.headers.get("Set-Cookie") or ""))
    if not _m:
        return cookie
    _val = f"__puus={_m.group(1)}"
    if "__puus=" in cookie:
        return _re.sub(r"__puus=[^;]*", _val, cookie)
    return (cookie.rstrip("; ") + "; " + _val) if cookie else _val


def get_account_download_url('''
old_def = "\ndef get_account_download_url("
assert old_def in src, "get_account_download_url not found"
src = src.replace(old_def, helper, 1)

old_ret = "    return download_url\n\n\ndef"
new_ret = "    return download_url, _refresh_puus(cookie, resp)\n\n\ndef"
assert old_ret in src, "return statement not found"
src = src.replace(old_ret, new_ret, 1)

old_call = '''        download_url = get_account_download_url(account_fid, cookie)
        file_path = os.path.join(save_path, safe_filename(audio['file_name']))
        download_file(download_url, file_path, cookie, progress_callback)'''
new_call = '''        download_url, cookie = get_account_download_url(account_fid, cookie)
        file_path = os.path.join(save_path, safe_filename(audio['file_name']))
        download_file(download_url, file_path, cookie, progress_callback)'''
assert old_call in src, "call site not found"
src = src.replace(old_call, new_call, 1)

target.write_text(src, encoding="utf-8")
import py_compile
py_compile.compile(str(target), doraise=True)
print("patched OK")
