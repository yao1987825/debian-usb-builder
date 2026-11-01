#!/usr/bin/env bash
#
# test-tch.sh —— 电子课本下载(tch)的集成回归测试
#
# 背景(2026-11-01): 用户要把 tchMaterial-parser 项目接进 U 盘系统。
# 真机实测: 平台还能用 —— 游客模式登录第 7 轮成功(服务端偶发拒绝, 工具自己重试),
# 查教材正常, 下载的 PDF 151 页 + 16 个书签 ✓。所以代码本身不用改, 直接集成。
#
# 这里守:
#   1) 命令与模块齐全(装在 /usr/local, 不依赖任何第三方运行时);
#   2) 依赖包三个都在(qrcode 画二维码 / pypdf 加书签 / pycryptodome 登录加密);
#   3) opencode 技能在(AI 才会自己找教材);
#   4) 文档里写清"下载要加 -o"(默认落临时目录, 重启就没了 —— 这是最容易踩的坑)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== 命令与模块 =="
[[ -f overlay/usr/local/bin/tch ]] && ok "有 tch 命令" || fail "缺 tch 命令"
bash -n overlay/usr/local/bin/tch && ok "bash -n tch" || fail "bash -n tch"
for m in __main__ auth catalog common config download; do
  [[ -f "overlay/usr/local/lib/tchtools/src/cli/${m}.py" ]] && ok "有 ${m}.py" || fail "缺 ${m}.py"
done
if command -v python3 >/dev/null 2>&1; then
  for f in overlay/usr/local/lib/tchtools/src/cli/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
      && ok "python 语法 ${f##*/}" || fail "python 语法 ${f##*/}"
  done
fi

echo "== 依赖包 =="
for p in python3-qrcode python3-pypdf python3-pycryptodome; do
  if grep -qE "(^|[[:space:]\\])${p}([[:space:]\\]|$)" scripts/build-image.sh; then
    ok "构建脚本装了 ${p}"
  else
    fail "构建脚本没装 ${p}"
  fi
done
grep -q "python3-requests" scripts/build-image.sh && ok "requests 已在(之前给 travel-planner 装的)" || fail "缺 requests"

echo "== opencode 技能 =="
SK="overlay/home/user/.config/opencode/skills/textbook-fetch/SKILL.md"
[[ -f "$SK" ]] && ok "有 textbook-fetch 技能" || fail "缺 textbook-fetch 技能"
head -3 "$SK" | grep -q "^name: textbook-fetch" && ok "frontmatter 的 name 与目录名一致" || fail "frontmatter 的 name 不对"
head -12 "$SK" | grep -q "^description:" && ok "有 description" || fail "缺 description"
grep -q "tch search" "$SK" && ok "技能里写了查询命令" || fail "技能里没写查询命令"
grep -q "\-o" "$SK" && ok "技能里强调了下载要加 -o" || fail "技能里没强调 -o"

echo "== 构建/镜像断言 =="
grep -q "usr/local/bin/tch" scripts/build-image.sh && ok "构建脚本断言了 tch" || fail "构建脚本没断言 tch"
grep -q "usr/local/bin/tch" scripts/verify-image.sh && ok "verify-image.sh 断言了 tch" || fail "verify-image.sh 没断言"
grep -q "tch-material" scripts/build-image.sh && ok "组件清单里有 tch-material(usb-version 能列出来)" || fail "组件清单里没有 tch-material"

echo "== 文档 =="
grep -q "tch search" README.md && ok "README 写了用法" || fail "README 没写用法"
grep -q "textbooks" README.md && ok "README 提醒了下载目录要指定" || fail "README 没提醒下载目录"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
