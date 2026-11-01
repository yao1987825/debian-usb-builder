#!/usr/bin/env bash
#
# test-usb-version.sh —— 版本查询命令(usb-version)的回归测试
#
# 背景(2026-10-31): 用户刷完盘以后无从知道"这是哪一版、这版修了什么" ——
# BUILDER_VERSION 以前只打印在构建日志里。现在构建期把版本元数据、组件清单、
# CHANGELOG 写进镜像, 用 usb-version 查。
#
# 这里守:
#   1) 构建脚本真的写了这三个文件(否则刷完盘查不到);
#   2) 组件清单是**按镜像里实际存在的东西**生成的(不写死, 少装一个就说少一个);
#   3) 命令的四个子命令都在, 且能从 CHANGELOG 里切出对应版本段;
#   4) 缺文件时给出人话提示(而不是一堆报错)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

CMD="overlay/usr/local/bin/usb-version"

echo "== 语法 =="
bash -n "$CMD" && ok "bash -n $CMD" || fail "bash -n $CMD"

echo "== 构建脚本接线 =="
grep -q 'version.txt' scripts/build-image.sh && ok "构建期写 version.txt" || fail "构建期没写 version.txt"
grep -q 'components.txt' scripts/build-image.sh && ok "构建期写 components.txt" || fail "构建期没写 components.txt"
grep -q 'CHANGELOG.md" "\${ROOTFS}/usr/local/share/debian-usb' scripts/build-image.sh \
  && ok "构建期把 CHANGELOG 拷进镜像" || fail "构建期没拷 CHANGELOG"
# 组件清单必须"按实际存在的东西"生成, 不能写死
if grep -q 'if \[\[ -x "\${ROOTFS}/usr/local/bin/music-shell" \]\]' scripts/build-image.sh; then
  ok "组件清单按镜像实际内容生成(有存在性判断)"
else
  fail "组件清单看起来是写死的 —— 少装组件时这张表会骗人"
fi
grep -q 'BUILDER_VERSION' scripts/build-image.sh && ok "版本号取自 BUILDER_VERSION" || fail "没用到 BUILDER_VERSION"

echo "== 子命令 =="
for m in --changelog --all --tools --json; do
  if grep -q -- "$m" "$CMD"; then
    ok "有子命令 $m"
  else
    fail "缺子命令 $m"
  fi
done

echo "== 缺文件时的提示 =="
if grep -q '镜像里没有版本信息' "$CMD"; then
  ok "缺版本文件时给的是人话提示"
else
  fail "缺版本文件时没有友好提示"
fi

echo "== 真跑一次(用临时的 share 目录模拟镜像) =="
if command -v python3 >/dev/null 2>&1; then
  TMP="$(mktemp -d)"
  mkdir -p "${TMP}/share"
  cat > "${TMP}/share/version.txt" <<'VEOF'
version=v1.6.2-3-gabcdef1
git_sha=abcdef1
built_at=2026-10-31 05:00:00 UTC
suite=bookworm
hostname=debian-usb
image_mb=8192
VEOF
  printf 'music-shell|0.5.0|终端播放器\nnetkit|1.1.0|局域网诊断\n' > "${TMP}/share/components.txt"
  cat > "${TMP}/CHANGELOG.md" <<'CEOF'
# 更新日志

## v1.6.2 (2026-10-31)

- 这一版修了 A

## v1.6.1 (2026-10-31)

- 这一版修了 B
CEOF
  # 命令支持 USB_VERSION_SHARE 覆盖目录 -> 测试用临时目录, 不碰系统目录
  export USB_VERSION_SHARE="${TMP}/share"
  cp "${TMP}/CHANGELOG.md" "${TMP}/share/CHANGELOG.md"
  if true; then
    OUT="$(bash "$CMD" 2>&1 || true)"
    if grep -q "v1.6.2-3-gabcdef1" <<<"$OUT"; then
      ok "usb-version 输出了版本号"
    else
      fail "usb-version 没输出版本号: ${OUT:0:120}"
    fi
    if grep -q "netkit" <<<"$OUT"; then
      ok "usb-version 列出了组件"
    else
      fail "usb-version 没列出组件"
    fi
    OUT2="$(bash "$CMD" --changelog 2>&1 || true)"
    if grep -q "这一版修了 A" <<<"$OUT2" && ! grep -q "这一版修了 B" <<<"$OUT2"; then
      ok "--changelog 切出了对应版本段(没串到别的版本)"
    else
      fail "--changelog 没切对版本段"
    fi
    OUT3="$(bash "$CMD" --json 2>&1 || true)"
    if grep -q '"base_version": "v1.6.2"' <<<"$OUT3"; then
      ok "--json 输出了基线版本"
    else
      fail "--json 没输出基线版本"
    fi
  else
    printf '  --   没有权限写 /usr/local/share, 跳过真跑部分\n'
  fi
  rm -rf "$TMP"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
