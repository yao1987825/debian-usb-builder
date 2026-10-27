#!/usr/bin/env bash
#
# test-music-proxy.sh —— 音乐工具必须绕开环境代理
#
# 背景(真机实测): 站点/夸克/封面直连全是 200, 走 LAN 代理反而全断 ——
# gequhai 回 403 反爬页(解析出 0 条 -> "没有搜到"), 夸克/酷我 SSL 失败。
# 而登录 shell 会经 /etc/profile.d/99-proxy.sh 自动导出 http_proxy,
# requests 即使拿到空代理配置也会去读它, 于是"浏览器能看, music search 搜不到"。
#
# 这里用一个假项目验证: single.py 跑起来后, 环境里的代理变量必须已经没了。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== 语法 =="
bash -n overlay/usr/local/bin/music && ok "music 语法" || fail "music 语法"
python3 -m py_compile overlay/usr/local/lib/musictools/single.py && ok "single.py 语法" || fail "single.py 语法"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 假项目: search_songs 会先检查环境代理, 泄漏就直接退出 —— 说明 single.py 没摘干净
cat > "$TMP/gequhai.py" <<'PY'
import os

_PROXY_VARS = ("http_proxy", "https_proxy", "all_proxy",
               "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY")


def search_songs(keyword):
    leaked = [k for k in _PROXY_VARS if os.environ.get(k)]
    if leaked:
        raise SystemExit(f"FAIL: 环境代理没被摘掉 -> {leaked}")
    return [{"id": "1", "title": keyword, "artist": "测试歌手",
             "play_url": "/play/1"}]


def parse_play_page(song_id):
    return {}


def get_low_quality_url(play_id, mp3_type):
    return ""
PY

cat > "$TMP/quark.py" <<'PY'
def download_from_quark(*args, **kwargs):
    return False, "", "stub"
PY

cat > "$TMP/utils.py" <<'PY'
def load_config():
    return {}


def safe_filename(name):
    return name


def download_file(*args, **kwargs):
    pass


def get_proxies():
    return None
PY

echo "== 功能 =="
OUT="$(http_proxy='http://127.0.0.1:9' https_proxy='http://127.0.0.1:9' \
      HTTP_PROXY='http://127.0.0.1:9' HTTPS_PROXY='http://127.0.0.1:9' \
      python3 overlay/usr/local/lib/musictools/single.py "测试歌" --list \
      --project "$TMP" 2>&1)"
RC=$?
if [[ $RC -eq 0 && "$OUT" == *"测试歌手"* ]]; then
  ok "single.py 摘掉环境代理后能搜到(设了必死的代理 127.0.0.1:9)"
else
  fail "single.py 没能绕开环境代理 (rc=$RC)"
  printf '%s\n' "$OUT" | sed 's/^/       /'
fi

# 对照组: 不经 single.py 直接跑假项目, 代理必须泄漏出来 ——
# 否则上面那条断言就是形同虚设(假项目根本没在检查)。
CTRL="$(http_proxy='http://127.0.0.1:9' python3 -c "
import sys
sys.path.insert(0, sys.argv[1])
import gequhai
gequhai.search_songs('x')
" "$TMP" 2>&1)"
if printf '%s' "$CTRL" | grep -q "环境代理没被摘掉"; then
  ok "对照组: 不经 single.py 时代理确实泄漏(断言有效)"
else
  fail "对照组没触发泄漏检查, 断言形同虚设"
  printf '%s\n' "$CTRL" | sed 's/^/       /'
fi

echo "== 接线 =="
if grep -q 'os.environ.pop(_proxy_var, None)' overlay/usr/local/lib/musictools/single.py; then
  ok "single.py 里有摘环境代理的代码"
else
  fail "single.py 里找不到摘环境代理的代码"
fi

N="$(grep -c 'env "\${PROXY_OFF\[@\]}"' overlay/usr/local/bin/music || true)"
if [[ "$N" == "3" ]]; then
  ok "music 的 single/gui/playlist 三处都套了 PROXY_OFF"
else
  fail "music 里 PROXY_OFF 用了 $N 处(应为 3 处)"
fi

if grep -q '^PROXY_OFF=' overlay/usr/local/bin/music; then
  ok "music 定义了 PROXY_OFF"
else
  fail "music 没定义 PROXY_OFF"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
