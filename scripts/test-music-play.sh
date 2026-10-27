#!/usr/bin/env bash
#
# test-music-play.sh —— music play(终端播放器)的接线与构建期安装
#
# 背景(2026-10-27): 用户要把 music-shell 的播放功能放进镜像。
# 实测前提: 上游预编译产物 v0.5.0 在 Debian 12 上最高只要 GLIBC_2.34,
# 直接能跑(真机: "音频已连接", 正常播放), 所以构建期下载二进制即可。
#
# 这里守三件事:
#   1) music / music-health / 构建脚本的接线别被改坏;
#   2) 构建期必须下载 + 校验和验证 + 装 ALSA 运行库 + 写乐库配置;
#   3) 配置 JSON 模板本身合法(heredoc 打错字要在这里死, 不要到真机才发现)。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

echo "== 语法 =="
for f in overlay/usr/local/bin/music overlay/usr/local/bin/music-health \
         scripts/build-image.sh scripts/verify-image.sh; do
  bash -n "$f" && ok "bash -n $f" || fail "bash -n $f"
done

echo "== music 接线 =="
if grep -q '^cmd_play()' overlay/usr/local/bin/music; then
  ok "music 里有 cmd_play"
else
  fail "music 里没有 cmd_play"
fi
if grep -qE '^\s+play\|播放\|player\)' overlay/usr/local/bin/music; then
  ok "music 分发里接了 play/播放/player"
else
  fail "music 分发里没接 play"
fi
if grep -q 'exec music-shell "\$@"' overlay/usr/local/bin/music; then
  ok "cmd_play 用 exec 移交控制权(TUI 要占住终端)"
else
  fail "cmd_play 没有 exec music-shell"
fi
if grep -q 'songdisk_check || return 1' overlay/usr/local/bin/music; then
  ok "cmd_play 先检查歌曲分区(空库别开播放器)"
else
  fail "cmd_play 没有 songdisk_check 前置检查"
fi
if grep -q 'music play' overlay/usr/local/bin/music; then
  ok "用法里写了 music play"
else
  fail "用法里没有 music play"
fi

echo "== music-health 接线 =="
if grep -q 'sect "7. 播放器 (music play)"' overlay/usr/local/bin/music-health; then
  ok "music-health 有播放器体检节"
else
  fail "music-health 缺播放器体检节"
fi
if grep -q 'audio 组' overlay/usr/local/bin/music-health; then
  ok "music-health 检查 audio 组(声卡权限)"
else
  fail "music-health 不检查 audio 组"
fi

echo "== 构建期安装 =="
if grep -q '^MUSIC_SHELL_VERSION=' scripts/build-image.sh; then
  ok "build-image.sh 固定了 MUSIC_SHELL_VERSION"
else
  fail "build-image.sh 没固定 music-shell 版本"
fi
if grep -q 'releases/download/v${MUSIC_SHELL_VERSION}/checksums.txt' scripts/build-image.sh; then
  ok "build-image.sh 会拉 checksums.txt"
else
  fail "build-image.sh 不拉 checksums.txt(供应链裸奔)"
fi
if grep -q 'sha256sum -c' scripts/build-image.sh; then
  ok "build-image.sh 校验 sha256"
else
  fail "build-image.sh 不做 sha256 校验"
fi
if grep -q 'install -m755 .*music-shell" "${ROOTFS}/usr/local/bin/music-shell"' scripts/build-image.sh; then
  ok "产物装到 /usr/local/bin/music-shell"
else
  fail "没把 music-shell 装进镜像的 /usr/local/bin"
fi
if grep -qE '^\s+libasound2 alsa-utils$' scripts/build-image.sh; then
  ok "apt 清单里有 libasound2(rodio 的运行库)"
else
  fail "apt 清单里缺 libasound2"
fi
if grep -q 'die "缺 /usr/local/bin/music-shell' scripts/build-image.sh; then
  ok "build-image.sh 有缺失断言"
else
  fail "build-image.sh 没有 music-shell 缺失断言"
fi

echo "== 乐库配置 =="
if grep -q '"library_path": "/mnt/songdisk"' scripts/build-image.sh; then
  ok "乐库指向歌曲分区"
else
  fail "乐库没指向 /mnt/songdisk"
fi
# 把 heredoc 里的 JSON 抠出来做语法检查 —— 打错字要死在这里
_ms_json="$(awk '/cat > .*music-shell\/config.json.*<<EOF/{f=1;next} f&&/^EOF$/{exit} f' scripts/build-image.sh)"
if [[ -n "$_ms_json" ]] && printf '%s\n' "$_ms_json" | python3 -m json.tool >/dev/null 2>&1; then
  ok "config.json 模板是合法 JSON"
else
  fail "config.json 模板不是合法 JSON"
  printf '%s\n' "$_ms_json" | sed 's/^/       /'
fi

echo "== verify-image 断言 =="
for pat in 'music-shell' 'libasound.so.2' 'cmd_play' '/mnt/songdisk'; do
  if grep -q "$pat" scripts/verify-image.sh; then
    ok "verify-image.sh 检查了 $pat"
  else
    fail "verify-image.sh 不检查 $pat"
  fi
done

echo "== 功能 =="
if command -v music-shell >/dev/null 2>&1; then
  # 构建机上恰好装了: 只验证能跑, 不启动 TUI(会占终端)
  music-shell --version >/dev/null 2>&1 \
    && ok "music-shell --version 可执行" \
    || fail "music-shell --version 跑不起来"
else
  # 没装: music play 必须干净地报错, 而不是静默失败或误启动别的东西。
  # 注意用 bash 起: overlay 里的文件在 git 里是 0644, 构建时才 chmod 0755。
  OUT="$(bash overlay/usr/local/bin/music play 2>&1)"
  RC=$?
  if [[ $RC -ne 0 && "$OUT" == *"找不到 music-shell"* ]]; then
    ok "music play 在缺播放器时给出明确错误(rc=$RC)"
  else
    fail "music play 缺播放器时的行为不对 (rc=$RC)"
    printf '%s\n' "$OUT" | sed 's/^/       /'
  fi
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
