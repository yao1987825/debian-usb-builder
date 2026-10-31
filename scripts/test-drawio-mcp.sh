#!/usr/bin/env bash
#
# test-drawio-mcp.sh —— draw.io MCP 服务(AI 画图)的集成回归测试
#
# 背景(2026-10-31): 用户要把 next-ai-draw-io 接进 opencode 当 MCP 服务用。
# 上游把 MCP server 单独发成 npm 包 @next-ai-drawio/mcp-server, 自带 draw.io
# 编辑器和预览服务, 所以不需要整套 Next.js 应用 —— 这是集成能保持轻量的关键。
#
# 这里守:
#   1) 构建脚本装了 nodejs(>=18)并钉了 MCP 包版本;
#   2) opencode.json 里的 mcp.drawio 段写对了(type/command/env) ——
#      写错的话 opencode 要么拒绝启动, 要么连不上;
#   3) 技能 diagram-drawio 在(AI 不知道正确用法就会自己手写 XML, 图全是错的);
#   4) PNG/SVG 导出的限制写进文档(镜像里没有浏览器, 免得用户以为坏了)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

OCFG="overlay/home/user/.config/opencode/opencode.json"

echo "== 构建脚本接线 =="
grep -q 'DRAWIO_MCP_VERSION=' scripts/build-image.sh && ok "钉了 MCP 包版本" || fail "没钉版本"
grep -q '@next-ai-drawio/mcp-server' scripts/build-image.sh && ok "装的是官方 MCP 包" || fail "装包名不对"
grep -qE '^\s+nodejs npm' scripts/build-image.sh && ok "装了 nodejs + npm" || fail "没装 nodejs/npm"
grep -q 'next-ai-drawio-mcp' scripts/build-image.sh && ok "断言了 MCP 可执行文件" || fail "没断言 MCP 可执行文件"

echo "== opencode 配置 =="
[[ -f "$OCFG" ]] && ok "有 opencode.json" || fail "缺 opencode.json"
if command -v python3 >/dev/null 2>&1 && [[ -f "$OCFG" ]]; then
  if python3 - "$OCFG" <<'PYEOF' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
m = d.get("mcp", {}).get("drawio", {})
assert m.get("type") == "local", m
assert m.get("enabled") is True, m
assert m.get("command") == ["next-ai-drawio-mcp"], m
env = m.get("environment", {})
assert env.get("BROWSER") == "none", env   # 镜像里没浏览器, 别让它去开
assert env.get("DRAWIO_LANG") == "zh", env  # 界面中文
PYEOF
  then
    ok "mcp.drawio 段写法正确(type/command/env)"
  else
    fail "mcp.drawio 段写法不对(opencode 会连不上)"
  fi
  if python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$OCFG" 2>/dev/null; then
    ok "opencode.json 是合法 JSON"
  else
    fail "opencode.json 不是合法 JSON —— opencode 会拒绝启动"
  fi
fi

echo "== 技能 =="
SK="overlay/home/user/.config/opencode/skills/diagram-drawio/SKILL.md"
[[ -f "$SK" ]] && ok "有 diagram-drawio 技能" || fail "缺 diagram-drawio 技能"
head -3 "$SK" | grep -q "^name: diagram-drawio" && ok "frontmatter 的 name 与目录名一致" || fail "frontmatter 的 name 不对"
if head -12 "$SK" | grep -q "^description:"; then
  ok "有 description(否则技能不会被加载)"
else
  fail "缺 description"
fi
grep -q "start_session" "$SK" && ok "技能里写了正确用法(start_session 起步)" || fail "技能里没写用法"
grep -q "mxCell" "$SK" && ok "技能里强调了别手写 XML" || fail "技能里没强调别手写 XML"

echo "== 文档里的限制说明 =="
grep -q 'PNG/SVG' README.md && ok "README 说明了 PNG/SVG 导出的限制" || fail "README 没写导出限制"
grep -q 'chromium' README.md && ok "README 给了补浏览器的方法" || fail "README 没给补浏览器的方法"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
