#!/usr/bin/env bash
#
# test-wifi-cli.sh —— wifi 命令的回归测试
#
# 用户反馈(2026-10-27): "有线网络没问题, wifi 无法使用"。
# 修完之后必须保证 wifi 这个入口一直能用, 所以用假的 nmcli 把各条分支
# 都跑一遍: 没网卡 / 没扫到网 / 已保存的配置 / 新连(输密码) / 断开 /
# 忘掉 / 开关无线 / 解锁。
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WIFI="${SCRIPT_DIR}/../overlay/usr/local/bin/wifi"

PASS=0
FAIL=0
ok()  { printf '  \033[1;32m✅\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[1;31m❌\033[0m %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- 假的 nmcli: 按 NMCLI_FAKE 里的场景返回不同结果 ----
cat > "${TMP}/nmcli" <<'FAKE'
#!/usr/bin/env bash
case "${NMCLI_FAKE:-normal}" in
  no_dev)
    # 没有任何无线网卡
    if [[ "$*" == *"device status"* ]]; then echo "enp5s0:ethernet:connected"; fi
    exit 0
    ;;
  no_net)
    if [[ "$*" == *"device status"* ]]; then echo "wlp3s0:wifi:disconnected"; fi
    if [[ "$*" == *"device wifi list"* ]]; then exit 0; fi
    exit 0
    ;;
  saved)
    if [[ "$*" == *"device status"* ]]; then echo "wlp3s0:wifi:disconnected"; fi
    if [[ "$*" == *"con show"* && "$*" != *"--active"* ]]; then echo "Yao-Router:"; fi
    if [[ "$*" == *"con up"* ]]; then echo "连接已成功激活"; exit 0; fi
    if [[ "$*" == *"device wifi list"* ]]; then echo "Yao-Router:WPA2:54:*"; fi
    exit 0
    ;;
  normal)
    if [[ "$*" == *"device status"* ]]; then echo "wlp3s0:wifi:disconnected"; fi
    if [[ "$*" == *"device wifi list"* ]]; then
      echo "Yao-Router:WPA2:54:"
      echo "OpenNet:--:40:"
    fi
    if [[ "$*" == *"dev wifi connect"* ]]; then echo "Device 'wlp3s0' successfully activated"; exit 0; fi
    if [[ "$*" == *"radio wifi"* ]]; then echo "enabled"; fi
    if [[ "$*" == *"con up"* ]]; then echo "连接已成功激活"; exit 0; fi
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "${TMP}/nmcli"

# 假的 sudo: 直接执行(不带密码的), 并把 HOME 之类原样传下去
cat > "${TMP}/sudo" <<'SUDO'
#!/usr/bin/env bash
exec "$@"
SUDO
chmod +x "${TMP}/sudo"

run_wifi() {
  PATH="${TMP}:${PATH}" NMCLI_FAKE="$1" bash "$WIFI" "${@:2}" 2>&1
}

# 1) 没有无线网卡时, 要说清楚原因, 而不是干巴巴报错
out="$(run_wifi no_dev list)"
if grep -q "没找到无线网卡" <<<"$out" && grep -q "firmware" <<<"$out"; then
  ok "没有无线网卡时给出固件/解锁/无网卡三种原因"
else
  bad "没有无线网卡时的提示不对: ${out}"
fi

# 2) 扫不到网时给出下一步
out="$(run_wifi no_net scan)"
if grep -q "没扫到任何无线网" <<<"$out"; then
  ok "扫不到网络时给出提示"
else
  bad "扫不到网络时的提示不对: ${out}"
fi

# 3) 正常情况: 列出网络, 给出连接命令
out="$(run_wifi normal list)"
if grep -q "Yao-Router" <<<"$out" && grep -q 'wifi connect' <<<"$out"; then
  ok "能列出周围的无线网并提示怎么连"
else
  bad "列网络的结果不对: ${out}"
fi

# 4) 已保存的配置: 直接 up, 不该再问密码
out="$(run_wifi saved connect "Yao-Router")"
if grep -q "已有保存的连接" <<<"$out" && grep -q "已连上" <<<"$out"; then
  ok "已保存的连接直接启用"
else
  bad "已保存的连接处理不对: ${out}"
fi

# 5) 新连接: 成功提示
out="$(run_wifi normal connect "OpenNet")"
if grep -q "已连上" <<<"$out"; then
  ok "新连接成功有提示"
else
  bad "新连接的结果不对: ${out}"
fi

# 6) 断开
out="$(run_wifi normal disconnect)"
if grep -qE "已断开|没连无线网" <<<"$out"; then
  ok "断开有明确反馈"
else
  bad "断开的结果不对: ${out}"
fi

# 7) 开关无线
out="$(run_wifi normal on)"
grep -q "无线已打开" <<<"$out" && ok "wifi on 有反馈" || bad "wifi on 没反馈: ${out}"
out="$(run_wifi normal off)"
grep -q "无线已关闭" <<<"$out" && ok "wifi off 有反馈" || bad "wifi off 没反馈: ${out}"

# 8) 解锁
out="$(run_wifi normal unblock)"
grep -qE "解锁|没装 rfkill" <<<"$out" && ok "wifi unblock 有反馈" || bad "wifi unblock 没反馈: ${out}"

# 9) 状态
out="$(run_wifi normal status)"
grep -q "无线网卡" <<<"$out" && ok "wifi status 显示网卡" || bad "wifi status 不对: ${out}"

# 10) 忘掉
out="$(run_wifi normal forget "Yao-Router")"
grep -qE "已忘掉|没有这个连接配置" <<<"$out" && ok "wifi forget 有反馈" || bad "wifi forget 没反馈: ${out}"

# 11) 帮助
out="$(run_wifi normal help)"
grep -q "wifi connect" <<<"$out" && ok "help 里有用法" || bad "help 不对: ${out}"

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[1;32m✅ 全部 %d 项通过\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[1;31m❌ %d 项失败\033[0m\n' "$FAIL" >&2
exit 1
