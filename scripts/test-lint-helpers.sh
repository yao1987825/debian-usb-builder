#!/usr/bin/env bash
# lint-helpers.sh 的自测。
#
# 为什么需要: linter 本身也是有 bug 的, 而且是**静默失效**那种 ——
# 一旦 linter 坏了, 它会"报一切正常", 于是真正的错误又得等 20 分钟的构建
# 才炸。之前的 heredoc 跟踪就踩过: <<< 被误判成 heredoc, 文件后半段根本没扫,
# linter 依然报"干净"。
#
# 所以这里用**真实出过错的那份脚本**当回归用例, 断言 linter 必须报出那一行。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASS=0
FAIL=0
ok()  { printf '  \033[1;32m✅\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  \033[1;31m❌\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

LINT="scripts/lint-helpers.sh"
FIXTURE="scripts/tests/lint-fixture-bad.sh"

echo "== lint-helpers.sh 自测 =="

if [[ ! -f "$LINT" ]]; then
  bad "找不到 $LINT"
  printf '\n\033[1;31m失败\033[0m: %d 项通过, %d 项失败\n' "$PASS" "$FAIL"
  exit 1
fi

# 1) 坏夹具必须被报出来, 且退出码非 0
out="$(bash "$LINT" "$FIXTURE" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
  ok "坏夹具被检出(退出码 $rc)"
else
  bad "坏夹具居然通过了, linter 失效了"
fi

# 2) 必须报出"没定义的函数"
if grep -q 'missing_fn' <<<"$out"; then
  ok "报出了未定义的函数 missing_fn"
else
  bad "没报出 missing_fn"
  printf '     实际输出:\n%s\n' "$out"
fi

# 3) 必须报出"定义晚于调用"
if grep -q '先定义后使用' <<<"$out"; then
  ok "报出了定义晚于调用的问题"
else
  bad "没报出定义顺序问题"
  printf '     实际输出:\n%s\n' "$out"
fi

# 4) 注释 / heredoc / 常见命令 不该被误报
for noise in 'Some Config Value' '这里是正常的外部命令调用'; do
  if grep -qF "$noise" <<<"$out"; then
    bad "误报了: $noise"
  else
    ok "没有误报: $noise"
  fi
done

# 5) 全仓库必须是干净的(这一步同时保证 linter 没把正常脚本误判成坏的)
out2="$(bash "$LINT" 2>&1)"
rc2=$?
if [[ $rc2 -eq 0 ]]; then
  ok "全仓库检查通过"
else
  bad "全仓库检查没通过"
  printf '%s\n' "$out2"
fi

# 6) 回归: 真正炸掉过的那份 build-image.sh 必须被报出来
#    (2026-10-22 的构建事故: 第 496 行 ok 未定义, 跑到第 4/9 步才 exit 127)
BUGGY="${TMPDIR:-/tmp}/lint-regression-build-image.sh"
if git show c443e65:scripts/build-image.sh > "$BUGGY" 2>/dev/null; then
  out3="$(bash "$LINT" "$BUGGY" 2>&1)"
  if grep -q '第 496 行' <<<"$out3" && grep -q '\bok\b' <<<"$out3"; then
    ok "回归用例: 报出了历史事故那一行(第 496 行 ok 未定义)"
  else
    bad "回归用例没通过, linter 对真实事故不灵"
    printf '%s\n' "$out3"
  fi
  rm -f "$BUGGY"
else
  bad "拿不到历史版本的 build-image.sh 做回归用例"
fi

printf '\n'
if [[ $FAIL -eq 0 ]]; then
  printf '\033[1;32m✅ 全部 %d 项通过\033[0m\n' "$PASS"
  exit 0
fi
printf '\033[1;31m❌ %d 项通过, %d 项失败\033[0m\n' "$PASS" "$FAIL"
exit 1
