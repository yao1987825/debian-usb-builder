#!/usr/bin/env bash
#
# test-wifit3.sh —— wifit3(USB 无线网卡审计)的集成回归测试
#
# 背景(2026-10-30): 用户要把 wifit3 项目接进 U 盘系统, 但手里没有 USB 无线网卡。
# 上游发的是单个预编译二进制(PyInstaller), 所以集成方式是"构建期下载 + 钉校验和 +
# 装进 /usr/local/bin", 跟 music-shell/opencode 一个套路。
#
# 这里守:
#   1) 构建脚本钉了版本与 sha256(上游不发 checksums, 校验值必须自己钉死);
#   2) 装的是 linux-x64 产物(别的平台在这个镜像里没用);
#   3) 提权前提: user 在 sudo 组里 —— wifit3 装 udev/modprobe 规则时优先用免密 sudo,
#      没有 sudo 组它会退回 pkexec, 而无头环境里没有认证代理, 提权会卡在授权框;
#   4) 文档里有选卡指南(用户还没买卡, 这是他真正的卡点)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== 构建脚本接线 =="
grep -q 'WIFIT3_VERSION=' scripts/build-image.sh && ok "定义了 WIFIT3_VERSION" || fail "没定义 WIFIT3_VERSION"
grep -q 'WIFIT3_SHA256=' scripts/build-image.sh && ok "钉了 sha256(上游不发 checksums)" || fail "没钉 sha256"
grep -q 'WIFIT3_BINARY="wifit3-linux-x64"' scripts/build-image.sh && ok "用的是 linux-x64 产物" || fail "产物平台不对"
grep -q 'derv82/wifit3' scripts/build-image.sh && ok "下载地址指向上游 release" || fail "下载地址不对"
if grep -qE 'WIFIT3_SHA256:-[0-9a-f]{64}' scripts/build-image.sh \
   && grep -q 'sha256sum "${_w3_tmp}' scripts/build-image.sh \
   && grep -q '校验和不匹配' scripts/build-image.sh; then
  ok "下载后真的做了 sha256 校验"
else
  fail "下载后没有 sha256 校验"
fi
grep -q '/usr/local/bin/wifit3' scripts/build-image.sh && ok "装到 /usr/local/bin/wifit3" || fail "没装到 /usr/local/bin"
grep -q 'libusb-1.0-0' scripts/build-image.sh && ok "装了 libusb-1.0-0" || fail "没装 libusb-1.0-0"
grep -q '"^sudo:"' scripts/build-image.sh && ok "断言了 sudo 组存在(提权前提)" || fail "没断言 sudo 组"

echo "== 镜像级断言 =="
grep -q '缺 /usr/local/bin/wifit3' scripts/build-image.sh && ok "构建期断言了 wifit3 存在" || fail "构建期没断言"
grep -q '缺 /usr/local/bin/wifit3' scripts/verify-image.sh && ok "verify-image.sh 也断言了" || fail "verify-image.sh 没断言"

echo "== 文档(用户还没买卡, 选卡指南是刚需) =="
grep -q 'wifit3' README.md && ok "README 里有 wifit3" || fail "README 里没有 wifit3"
grep -q 'AWUS036' README.md && ok "README 给了具体型号建议" || fail "README 没给型号建议"
grep -q 'TL-WN722N' README.md && ok "README 提到了常见型号" || fail "README 没提常见型号"
grep -q '授权' README.md && ok "README 有授权使用提示" || fail "README 缺授权使用提示"
grep -q 'wifit3' overlay/usr/local/bin/terminal-keys && ok "开机速查表里列了 wifit3" || fail "开机速查表里没有 wifit3"

echo "== 边界: 不能替用户确认的东西 =="
# 网卡型号/芯片支持是上游的事, 我们只能把清单抄对 —— 这里守"别把型号写错"
if grep -q 'AR9271' README.md && grep -q 'MT7612U' README.md; then
  ok "README 里的芯片清单覆盖主流型号"
else
  fail "README 里的芯片清单不全"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
