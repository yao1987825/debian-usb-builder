#!/usr/bin/env bash
#
# test-net-kit.sh —— 局域网诊断工具(netkit)与 opencode 集成的回归测试
#
# 背景(2026-10-28): 用户要求这个 U 盘系统不只是"下载听歌机", 还要能当
# 网络急救包 —— 局域网网段变了/网关换了/IP 冲突/DNS 被劫持/无线掉线时,
# 插上 U 盘就能扫拓扑、跑检测、执行修复, 最好还能让 opencode 带着技能一起查。
#
# 这里守五件事:
#   1) netkit 各模块语法正确, 关键函数真的存在(别改着改着 import 就炸);
#   2) net 命令的子命令接线完整(topo/probe/doctor/fix/ai/report);
#   3) 构建脚本装了 opencode、钉了校验和、写进了 skills 和权限配置;
#   4) opencode 配置与 5 个 skill 的 frontmatter 合法(名字/目录名对得上,
#      因为 opencode 挑不出 frontmatter 不对的 skill, 少了就静默失效);
#   5) 音频直通的接线(音频修复和本版一起发, 顺手守住)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

NETKIT="overlay/usr/local/lib/netkit"

echo "== 语法 =="
for f in overlay/usr/local/bin/net overlay/usr/local/bin/audio-setup \
         scripts/build-image.sh scripts/verify-image.sh; do
  bash -n "$f" && ok "bash -n $f" || fail "bash -n $f"
done
if command -v python3 >/dev/null 2>&1; then
  for f in "${NETKIT}"/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
      && ok "python 语法 ${f##*/}" || fail "python 语法 ${f##*/}"
  done
else
  fail "构建机没有 python3, 没法做语法检查"
fi

echo "== netkit 模块齐全 =="
for m in __init__ util netinfo devclass discover topo probe cli; do
  [[ -f "${NETKIT}/${m}.py" ]] && ok "有 ${m}.py" || fail "缺 ${m}.py"
done

echo "== netkit 关键能力(函数真的存在) =="
check_fn() {
  local file="$1" fn="$2" desc="$3"
  if grep -qE "^(def|class) ${fn}\b" "${NETKIT}/${file}.py"; then
    ok "${desc}"
  else
    fail "${desc}"
  fi
}
check_fn util cidr_of "util.cidr_of: IP+掩码算网段"
check_fn util in_same_subnet "util.in_same_subnet: 同网段判断"
check_fn util host_range "util.host_range: 网段展开成主机列表"
check_fn netinfo identity "netinfo.identity: 本机网络身份"
check_fn netinfo compare_with_history "netinfo.compare_with_history: 网段变化检测"
check_fn netinfo record_snapshot "netinfo.record_snapshot: 历史快照落盘"
check_fn discover arp_scan "discover.arp_scan: 二层 ARP 扫描"
check_fn discover mdns_hosts "discover.mdns_hosts: mDNS 发现"
check_fn discover lldp_neighbors "discover.lldp_neighbors: 交换机 LLDP"
check_fn discover _detect_proxy_arp "discover._detect_proxy_arp: 代理 ARP 过滤"
check_fn topo build "topo.build: 拓扑组装"
check_fn topo render "topo.render: ASCII 树渲染"
check_fn probe check_conflicts "probe.check_conflicts: IP 冲突检测"
check_fn probe check_mtu "probe.check_mtu: MTU 探测"
check_fn probe check_loop "probe.check_loop: 路由环路检测"
check_fn probe check_dns "probe.check_dns: DNS 检测"
check_fn probe check_wifi "probe.check_wifi: 无线检测"
check_fn devclass classify "devclass.classify: 设备类型判定"

echo "== 代理 ARP 必须有过滤(否则拓扑全是假设备) =="
if grep -q "_detect_proxy_arp" "${NETKIT}/discover.py" \
   && grep -q "已过滤代理ARP假设备" "${NETKIT}/discover.py"; then
  ok "代理 ARP 假设备会被剔除"
else
  fail "没处理代理 ARP —— 开了 Proxy ARP 的路由机会把整个网段报成在线"
fi

echo "== net 命令接线 =="
if grep -q 'python3 -m netkit.cli' overlay/usr/local/bin/net; then
  ok "net 调用 netkit.cli"
else
  fail "net 没有调用 netkit.cli"
fi
for sub in topo probe doctor fix ai report; do
  if grep -qE "sub\.add_parser\(\"${sub}\"" "${NETKIT}/cli.py"; then
    ok "net 有子命令 ${sub}"
  else
    fail "net 缺子命令 ${sub}"
  fi
done

echo "== 构建脚本接线 =="
if grep -q 'OPENCODE_VERSION=' scripts/build-image.sh; then
  ok "构建脚本定义了 OPENCODE_VERSION"
else
  fail "构建脚本没定义 OPENCODE_VERSION"
fi
if grep -q 'OPENCODE_SHA256=' scripts/build-image.sh; then
  ok "构建脚本钉了 opencode 校验和"
else
  fail "构建脚本没钉 opencode 校验和(从公网拉二进制必须校验)"
fi
if grep -q 'opencode-linux-x64.tar.gz' scripts/build-image.sh; then
  ok "构建脚本下载的是 linux-x64 产物"
else
  fail "构建脚本的 opencode 产物名不对"
fi
for p in iputils-arping arp-scan ethtool avahi-utils lldpd; do
  # 包名在 apt 清单里是空格分隔的, 后面可能跟续行符 \ 或行尾
  if grep -qE "(^|[[:space:]\\])${p}([[:space:]\\]|$)" scripts/build-image.sh; then
    ok "构建脚本装了 ${p}"
  else
    fail "构建脚本没装 ${p}"
  fi
done
if grep -q 'audio-direct.service' scripts/build-image.sh; then
  ok "构建脚本启用 audio-direct.service"
else
  fail "构建脚本没启用 audio-direct.service"
fi

echo "== opencode 配置 =="
OCFG="overlay/home/user/.config/opencode/opencode.json"
[[ -f "$OCFG" ]] && ok "有 opencode.json" || fail "缺 opencode.json"
if [[ -f "$OCFG" ]]; then
  if python3 -c "import json,sys; json.load(open(sys.argv[1], encoding='utf-8'))" "$OCFG"; then
    ok "opencode.json 是合法 JSON"
  else
    fail "opencode.json 不是合法 JSON —— opencode 会拒绝启动"
  fi
  for key in '"bash": "allow"' '"edit": "allow"' '"read": "allow"'; do
    grep -q "$key" "$OCFG" && ok "权限已放开 ${key}" || fail "权限没放开 ${key}"
  done
  grep -q 'AGENTS.md' "$OCFG" && ok "opencode.json 引用了 AGENTS.md" || fail "opencode.json 没引用 AGENTS.md"
fi
[[ -f overlay/home/user/.config/opencode/AGENTS.md ]] \
  && ok "有 AGENTS.md(告诉 AI 这台机器是干什么的)" || fail "缺 AGENTS.md"

echo "== 网络排障 skills =="
for sk in lan-topology lan-triage lan-repair lan-capture wifi-triage; do
  f="overlay/home/user/.config/opencode/skills/${sk}/SKILL.md"
  if [[ -f "$f" ]]; then
    ok "有技能 ${sk}"
    # frontmatter: name 必须是目录名, 否则 opencode 挑不出来(静默失效)
    if head -5 "$f" | grep -q "^name: ${sk}$"; then
      ok "  ${sk} 的 name 与目录名一致"
    else
      fail "  ${sk} 的 frontmatter name 不是 ${sk}"
    fi
    if head -5 "$f" | grep -q "^description:"; then
      ok "  ${sk} 有 description"
    else
      fail "  ${sk} 缺 description(没有它的技能不会暴露给模型)"
    fi
  else
    fail "缺技能 ${sk}"
  fi
done

echo "== 音频直通 =="
if grep -q 'type hw' overlay/usr/local/bin/audio-setup; then
  ok "audio-setup 会写 type hw(绕开 dmix)"
else
  fail "audio-setup 没写 type hw —— dmix 下 rodio 写不进声卡"
fi
if grep -q 'audio-setup --apply' overlay/usr/local/bin/music; then
  ok "music 播放前会自动配音频通路"
else
  fail "music 播放前没调 audio-setup"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
