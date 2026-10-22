#!/usr/bin/env bash
# lint-helpers.sh 的**故意写错**的测试夹具。
#
# 这个文件本身是坏的, 故意保留, 用来验证 lint-helpers.sh 真的能抓到问题。
# 它不会被 build-image.sh 打包进镜像, 也不参与 lint-helpers.sh 的默认扫描
# (scripts/tests 目录被排除在外)。
#
# 期望 lint-helpers.sh 对本文件报出:
#   1) 第 21 行: missing_fn —— 调用了压根没定义的函数
#   2) 第 12 行: helper   —— 函数定义写在调用后面(bash 先定义后使用)

log() { printf '%s\n' "$*"; }

# 问题一: 调用在定义之前
if true; then
  helper "先调用后定义"
fi

helper() {
  echo "helper"
}

# 问题二: 压根没定义
if true; then
  missing_fn "压根没定义"
fi

# 下面这些是**不该**被报的:
#   - 注释里的英文单词
#   - heredoc 正文里的英文单词
#   - 常见外部命令
#   - 关键字
cat <<'EOF'
Some Config Value "quoted text" here
EOF
echo "这里是正常的外部命令调用"
