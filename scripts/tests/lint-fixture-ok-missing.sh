#!/usr/bin/env bash
# 最小复现: 2026-10-22 那次构建事故的**真实形态**。
#
# 当时 scripts/build-image.sh 里定义了 log/warn/die/step, 却直接调用了 ok,
# 结果一路跑到第 4/9 步才 "ok: command not found"(exit 127),
# 白白浪费一次 20 分钟的构建。bash -n 和 shellcheck 都查不出来。
#
# 这个文件不会被 build-image.sh 打包进镜像, 也不参与 lint-helpers.sh 的
# 默认扫描(scripts/tests 目录被排除), 只给 lint-helpers.sh 的自测当用例。

log()  { printf '[build] %s\n' "$*"; }
warn() { printf '[warn ] %s\n' "$*" >&2; }
die()  { printf '[fatal] %s\n' "$*" >&2; exit 1; }

# 事故原样: ok 没定义
if true; then
  ok "music 虚拟环境: requests 可用(music single 能用)"
else
  die "music 虚拟环境里没有 requests"
fi
