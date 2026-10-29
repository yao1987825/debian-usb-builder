#!/usr/bin/env bash
#
# test-train.sh —— 火车票查询(train)的回归测试
#
# 背景(2026-10): 用户要把 train-tickets 项目接进 U 盘系统。上游代码在 12306
# 改过接口之后已经跑不动(直接 GET 查询接口只会拿到 HTML 反爬页 -> JSONDecodeError),
# 而且座位字段下标整体错位了一格(表现为"二等座"那一列永远是空的)。
# 镜像里用的是重写版(纯标准库, 不装 requests/docopt/prettytable/colorama)。
#
# 这里守:
#   1) 语法与模块齐全;
#   2) 座位字段下标不被改错(错一格整列就全错, 而且只有真机联网才看得出来);
#   3) 走会话 Cookie(先打首页再查接口), 不再裸查;
#   4) 日期解析/错误提示这些不需要联网就能验的部分;
#   5) 接线: 构建脚本装了 train, 镜像里有 traintools。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

TT="overlay/usr/local/lib/traintools"

echo "== 语法与模块 =="
bash -n overlay/usr/local/bin/train && ok "bash -n train" || fail "bash -n train"
if command -v python3 >/dev/null 2>&1; then
  for f in "${TT}"/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
      && ok "python 语法 ${f##*/}" || fail "python 语法 ${f##*/}"
  done
else
  fail "没有 python3, 没法做语法检查"
fi
for m in __init__ api format cli stations; do
  [[ -f "${TT}/${m}.py" ]] && ok "有 ${m}.py" || fail "缺 ${m}.py"
done

echo "== 座位字段下标(12306 固定位置, 错一格整列全错) =="
# 2026-10 真机核对: G1 [30]=有 二等 / [31]=有 一等 / [32]=13 商务
#                   K545 [29]=有 硬座 / [28]=无 硬卧 / [26]=有 无座
check_field() {
  local key="$1" idx="$2" desc="$3"
  if grep -q "\"${key}\": ${idx}," "${TT}/api.py"; then
    ok "${desc}"
  else
    fail "${desc}(下标不对)"
  fi
}
check_field gr_num 21 "高级软卧 = 21"
check_field rw_num 23 "软卧 = 23"
check_field tz_num 25 "特等座 = 25"
check_field wz_num 26 "无座 = 26"
check_field yw_num 28 "硬卧 = 28"
check_field yz_num 29 "硬座 = 29"
check_field ze_num 30 "二等座 = 30"
check_field zy_num 31 "一等座 = 31"
check_field swz_num 32 "商务座 = 32"
check_field srrb_num 33 "动卧 = 33"

echo "== 会话 Cookie(裸查接口只会拿到 HTML) =="
if grep -q 'leftTicket/init' "${TT}/api.py"; then
  ok "api.py 会先访问余票首页拿 cookie"
else
  fail "api.py 没有初始化会话 —— 查询会拿到 HTML 反爬页"
fi
if grep -q 'X-Requested-With' "${TT}/api.py"; then
  ok "api.py 带了 X-Requested-With 请求头"
else
  fail "api.py 少了 X-Requested-With 请求头"
fi
if grep -q 'verify=False' "${TT}/api.py"; then
  fail "api.py 里还有 verify=False"
else
  ok "api.py 没关证书校验"
fi

echo "== 不联网也能验的逻辑 =="
if command -v python3 >/dev/null 2>&1; then
  PYTHONPATH="$PWD/${TT%/*}" python3 - <<'PYEOF' && ok "日期解析/车站表/列定义" || fail "日期解析/车站表/列定义"
import sys
from datetime import date, timedelta
from traintools import cli, api, format as fmt

# 日期解析
assert cli.parse_date("今天") == date.today()
assert cli.parse_date("明天") == date.today() + timedelta(days=1)
assert cli.parse_date("后天") == date.today() + timedelta(days=2)
assert cli.parse_date("+3") == date.today() + timedelta(days=3)
assert cli.parse_date("2026-10-30").isoformat() == "2026-10-30"
try:
    cli.parse_date("乱写的")
    raise AssertionError("应该报错")
except api.TrainError:
    pass

# 车站表: 北京/上海 要能查到
st = api.local_stations()
assert st.get("北京") == "BJP", st.get("北京")
assert st.get("上海") == "SHH", st.get("上海")

# 预售期窗口
early, late = api.booking_window(date.today().isoformat())
assert late > early

# --stations 这条路径(argparse 的 dest 是 stations, 不是 keyword)
import io, contextlib
parser = cli.build_parser()
args = parser.parse_args(["--stations", "北京"])
buf = io.StringIO()
with contextlib.redirect_stdout(buf):
    rc = cli.cmd_stations(args)
assert rc == 0, rc
assert "北京" in buf.getvalue(), buf.getvalue()

# 表格渲染: 表头列数必须和行格数一致, 且没有值的座位列要自动隐藏
# (2026-10 用户实测发现: 表头只写了 4 列, 行有 15 格, 座位数字全是"对不上号"的)
trains = [
    {"train_no": "G2138", "from_station": "CZQ", "to_station": "HYQ",
     "from_time": "10:26", "to_time": "10:55", "duration": "00:29",
     "swz_num": "8", "zy_num": "有", "ze_num": "有", "wz_num": "有"},
    {"train_no": "Z138", "from_station": "CZQ", "to_station": "HYQ",
     "from_time": "12:15", "to_time": "13:54", "duration": "01:39",
     "rw_num": "有", "yw_num": "有", "yz_num": "有", "wz_num": "有"},
]
table = fmt.render(trains, {"CZQ": "郴州", "HYQ": "衡阳"}, show_color=False)
lines = [ln for ln in table.splitlines() if ln.strip()]
head_cells = lines[0].split()
row_cells = [c for c in lines[2].split("  ") if c.strip()]
assert len(lines) >= 3, table
assert "商务" in head_cells and "无座" in head_cells, head_cells
# 高铁+普速这批车里没有高级软卧 -> 该列应当被隐藏
assert "高软" not in head_cells, head_cells
# 每一列都必须在表头里出现(数据列数 == 表头列数)
for i, cell in enumerate(row_cells):
    assert i < len(head_cells), (i, cell, head_cells)
assert lines[1].count("-") > 10, "分隔线应该覆盖所有列"

# 表格列
names = [n for n, _ in fmt.SEAT_COLUMNS]
assert "二等" in names and "一等" in names and "商务" in names and "硬座" in names
assert fmt.seat_text("有") == "有"
assert fmt.seat_text("") == "-"
assert fmt.seat_text("12") == "12"
# 中英文对齐: 中文算两列
assert fmt.width("中文") == 4 and fmt.width("ab") == 2
PYEOF
fi

echo "== 接线 =="
if grep -q 'traintools' scripts/build-image.sh; then
  ok "构建脚本里有 traintools 断言"
else
  fail "构建脚本里没有 traintools 断言"
fi
if grep -q '/usr/local/bin/train' scripts/build-image.sh; then
  ok "构建脚本断言了 train 命令"
else
  fail "构建脚本没断言 train 命令"
fi
if grep -q 'train' overlay/usr/local/bin/terminal-keys; then
  ok "开机速查表里列了 train"
else
  fail "开机速查表里没有 train"
fi

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
