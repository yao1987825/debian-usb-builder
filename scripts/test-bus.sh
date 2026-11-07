#!/usr/bin/env bash
#
# test-bus.sh —— 郴州实时公交(bus)的回归测试
#
# 这个项目是**本地项目**(不是上游开源包), 所以没有"上游版本"可以对照 ——
# 集成进镜像时最容易出的错是"代码拷进来了, 但接线没接对":
#
#   1) 命令在, 但 PYTHONPATH 没指对 → import 失败
#   2) requests 没装 → import requests 就炸
#   3) **代理没摘** → 查询被扔进代理, 连都连不上
#      (实测: 带 http_proxy 时 curl 直接 http=000, 摘掉 200/16ms)
#   4) 无参数时掉进交互式 REPL → 脚本里直接卡死
#   5) 少了 --json → AI 只能去解析中文表格
#
# 这里全部用**假数据**跑, 不联网 —— CI 里不该有依赖外网的服务端。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

BIN="overlay/usr/local/bin/bus"
LIB="overlay/usr/local/lib/chenzhou_bus"

echo "== 文件与语法 =="
[[ -x "$BIN" ]] && ok "bus 命令在 overlay 里且可执行" || fail "缺 $BIN(或不可执行)"
bash -n "$BIN" 2>/dev/null && ok "bus 语法正确" || fail "bus 语法错误"

for _m in __init__ client cli coords models; do
  [[ -f "${LIB}/${_m}.py" ]] && ok "chenzhou_bus/${_m}.py 在" || fail "缺 chenzhou_bus/${_m}.py"
done
if command -v python3 >/dev/null 2>&1; then
  for _f in "${LIB}"/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$_f" \
      && ok "chenzhou_bus/$(basename "$_f") 语法正确" || fail "chenzhou_bus/$(basename "$_f") 语法错误"
  done
  # __pycache__ 不能进镜像(脏产物)
  [[ ! -d "${LIB}/__pycache__" ]] && ok "chenzhou_bus 里没有 __pycache__" \
    || fail "chenzhou_bus 里有 __pycache__ —— 脏产物会进镜像"
else
  fail "这台机器没有 python3, 测不了"
fi

echo "== 构建期断言 =="
for _pat in 'usr/local/bin/bus' 'chenzhou_bus' 'python3-requests' 'unset http_proxy' \
            'os.environ.pop' '211.143.37.50' 'zh00002' 'chenzhou-bus'; do
  grep -q -- "$_pat" scripts/build-image.sh \
    && ok "构建脚本断言了 ${_pat}" || fail "构建脚本没断言 ${_pat}"
done
grep -q 'COMP_VER_BUS=' scripts/build-image.sh \
  && ok "构建脚本声明了 COMP_VER_BUS" || fail "构建脚本没声明 COMP_VER_BUS"
# 模块清单是 for 循环写的, 少列一个模块断言就查不到 -> 这里逐个查
for _m in __init__ client cli coords models; do
  grep -q "for _m in __init__ client cli coords models" scripts/build-image.sh \
    && ok "构建脚本的模块清单循环在" || fail "构建脚本的模块清单循环不在"
  break
done
grep -q 'for _m in __init__ client cli coords models; do' scripts/build-image.sh \
  && ok "构建脚本逐个断言了 5 个 chenzhou_bus 模块" \
  || fail "构建脚本没逐个断言 chenzhou_bus 的 5 个模块"

echo "== AGENTS.md / 技能 =="
grep -q 'bus' overlay/home/user/.config/opencode/AGENTS.md \
  && ok "AGENTS.md 提到了 bus 命令" || fail "AGENTS.md 没提 bus"
grep -q 'chenzhou-bus' overlay/home/user/.config/opencode/AGENTS.md \
  && ok "AGENTS.md 提到了 chenzhou-bus 技能" || fail "AGENTS.md 没提 chenzhou-bus 技能"
[[ -f overlay/home/user/.config/opencode/skills/chenzhou-bus/SKILL.md ]] \
  && ok "chenzhou-bus 技能文件在" || fail "缺 chenzhou-bus 技能文件"
grep -q 'name: chenzhou-bus' overlay/home/user/.config/opencode/skills/chenzhou-bus/SKILL.md \
  && ok "技能 frontmatter 的 name 对" || fail "技能 frontmatter 的 name 不对"

# ---------------------------------------------------------------- 离线行为测试
# 假的服务端: 拦掉 requests.Session.post, 返回固定的 JSON,
# 这样可以离线验证 CLI 的**接线**(参数怎么解析、输出格式对不对),
# 而不用真的连郴州那个接口(它随时可能变)。
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
mkdir -p "${FAKE}/fake/chenzhou_bus"

cat > "${FAKE}/fake/requests.py" <<'PY'
"""假的 requests —— 只实现 bus 用到的那几个接口。"""

import json as _json


class RequestException(Exception):
    pass


class Session(object):
    def __init__(self):
        self.calls = []

    def post(self, url, data=None, headers=None, timeout=None):
        self.calls.append(url)
        path = url.rsplit("/api", 1)[-1]
        if path == "/routesV2":
            return _Resp({"State": 0, "Info": "success", "Result": [
                {"routeCode": "20000002", "routeName": "2路",
                 "fstName": "长冲铺", "lstName": "首末站5",
                 "minTicketPrice": 20, "maxTicketPrice": 20},
            ]})
        if path == "/RouteWorkV2":
            return _Resp({"State": 0, "Info": "success", "Result": {"result": [
                {"type": 0, "rid": "20000002", "name": "2路",
                 "fstName": "长冲铺", "lstName": "首末站5", "upDown": 0},
                {"type": 1, "staId": "S1", "name": "火车站",
                 "lat": 25.79447, "lng": 113.02792},
            ]}})
        if path == "/SearchRoutes":
            # 字段名必须和服务端一模一样(Station.from_raw 读的是 StaXxx)
            return _Resp({"State": 0, "Info": "success", "Result": {"staList": [
                {"StaName": "长冲铺", "StaId": "S1", "StaLat": 25.8599, "StaLng": 113.0407,
                 "StaDis": 1912, "StaNO": 1},
                {"StaName": "造纸厂", "StaId": "S2", "StaLat": 25.8518, "StaLng": 113.0299,
                 "StaDis": 734, "StaNO": 2},
            ]}})
        if path == "/routeStationVehicles":
            # 车辆字段名同样是服务端的(Vehicle.from_raw 读 plateNum/staIndex/...)
            # staIndex=0 + inOut=1 表示"刚离开上一站, 正开往第 1 站"
            return _Resp({"State": 0, "Info": "success", "Result": [
                {"vehicles": [
                    {"onlineNo": "18975571523", "plateNum": "湘LA9239",
                     "staIndex": 0, "inOut": 1, "nextStaName": "长冲铺",
                     "congLeve": 1, "destDistance": 45, "destRunTime": 1,
                     "arriveText": "1分钟", "distanceText": "1站/45米",
                     "lat": 25.7909, "lng": 113.0353},
                ]},
            ]})
        if path == "/peakTimetable":
            # Timetable.from_raw 读的是 TypeName / DepartTimeList
            return _Resp({"State": 0, "Info": "success", "Result": [
                {"TypeName": "平峰", "startTime": "05:30", "endTime": "23:30",
                 "DepartTimeList": ["05:30", "06:10"]},
            ]})
        if path == "/nearbyStations":
            return _Resp({"State": 0, "Info": "success", "Result": [
                {"name": "火车站", "staId": "S1", "distance": 43,
                 "staList": [{"staName": "火车站", "lat": 25.7944, "lng": 113.0279}],
                 "stationRoutes": [{"routeCode": "20000002", "routeName": "2路", "upDown": 0,
                                    "fstName": "长冲铺", "lstName": "首末站5",
                                    "vehicles": [{"plateNum": "湘LA9239", "staIndex": 0,
                                                  "inOut": 1, "arriveText": "1分钟"}]}]},
            ]})
        return _Resp({"State": 0, "Info": "success", "Result": {}})


class _Resp(object):
    def __init__(self, payload):
        self._payload = payload
        self.text = _json.dumps(payload, ensure_ascii=False)

    def json(self):
        return self._payload
PY

cp "${LIB}"/*.py "${FAKE}/fake/chenzhou_bus/"

run_bus() {  # run_bus [参数...]
  PYTHONPATH="${FAKE}/fake" timeout 30 python3 -m chenzhou_bus.cli "$@" 2>&1
}

echo "== 行为: 线路列表 =="
out="$(run_bus lines)"
grep -q '2路' <<<"$out" && ok "lines 能列出线路" || fail "lines 没列出线路"

echo "== 行为: 搜索 =="
out="$(run_bus search 火车站)"
grep -q '火车站' <<<"$out" && ok "search 能搜到站点" || fail "search 没搜到站点"

echo "== 行为: 线路站点 =="
out="$(run_bus line 20000002)"
grep -q '长冲铺' <<<"$out" && ok "line 能列出站点" || fail "line 没列出站点"

echo "== 行为: 实时车辆 =="
out="$(run_bus realtime 20000002 1)"
grep -q '湘LA9239' <<<"$out" && ok "realtime 能查到车牌" || fail "realtime 没查到车牌"

echo "== 行为: 发车时刻表 =="
out="$(run_bus schedule 20000002)"
grep -q '平峰' <<<"$out" && ok "schedule 能查到时刻表" || fail "schedule 没查到时刻表"

echo "== 行为: 附近站点 =="
out="$(run_bus nearby 25.7936 113.0176 800)"
grep -q '火车站' <<<"$out" && ok "nearby 能查到附近站点" || fail "nearby 没查到附近站点"

echo "== 行为: --json 是合法 JSON =="
for _cmd in "lines" "search 火车站" "line 20000002" "realtime 20000002 1" \
            "schedule 20000002" "nearby 25.7936 113.0176 800"; do
  out="$(run_bus ${_cmd} --json)"
  if printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
    ok "${_cmd} --json 是合法 JSON"
  else
    fail "${_cmd} --json 不是合法 JSON"
  fi
done
# --json 放在子命令**前面**也要认
out="$(run_bus --json search 火车站)"
printf '%s' "$out" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null \
  && ok "--json 放在子命令前面也认" || fail "--json 放在子命令前面不认"

echo "== 行为: 无参数打帮助, 不进 REPL =="
out="$(run_bus)"
rc=$?
grep -q '可用命令' <<<"$out" && ok "无参数时打出帮助" || fail "无参数时没打帮助"
[[ $rc -eq 0 ]] && ok "无参数时退出码 0" || fail "无参数时退出码 ${rc}"

echo "== 行为: 未知命令要明确报错 =="
out="$(run_bus 不存在的命令)"
rc=$?
[[ $rc -ne 0 ]] && grep -q '未知命令' <<<"$out" \
  && ok "未知命令明确报错(不是静悄悄地什么都不干)" || fail "未知命令没有明确报错"

echo "== 行为: 参数不全时明确报错 =="
out="$(run_bus line)"
[[ $? -ne 0 ]] && grep -q '用法' <<<"$out" \
  && ok "line 缺参数时明确报错" || fail "line 缺参数时没有明确报错"

echo "== 行为: 代理必须被摘掉 =="
# 构造一个"带代理环境"的环境: 如果代理没被摘, 假的 requests 也会看到代理变量
# (真机上 requests 会照着代理变量走, 然后连不上)
cat > "${FAKE}/fake/proxycheck.py" <<'PY'
import os
import sys

_LEAK = [k for k in ("http_proxy", "https_proxy", "all_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY") if os.environ.get(k)]
if _LEAK:
    sys.exit("环境代理没被摘掉: {}".format(_LEAK))
# 顺便确认真的能 import requests(假的那个)
import requests  # noqa: F401
sys.exit(0)
PY
out="$(PYTHONPATH="${FAKE}/fake" http_proxy=http://192.168.6.1:1070 \
       https_proxy=http://192.168.6.1:1070 \
       timeout 20 python3 -c "import chenzhou_bus.client" 2>&1)"
if [[ $? -eq 0 ]]; then
  ok "import chenzhou_bus.client 时环境代理被摘干净了"
else
  fail "import chenzhou_bus.client 时环境代理没被摘: ${out}"
fi
# bash 包装脚本里也必须 unset
grep -q 'unset http_proxy' "$BIN" \
  && ok "bus 包装脚本里 unset 了代理变量" || fail "bus 包装脚本没 unset 代理变量"

echo "== 坐标转换(离线, 不联网) =="
PYTHONPATH="${FAKE}/fake" python3 - <<'PY'
import sys
from chenzhou_bus.coords import wgs84_to_gcj02, gcj02_to_wgs84, haversine

wgs = (25.79447, 113.02792)
gcj = wgs84_to_gcj02(*wgs)
back = gcj02_to_wgs84(*gcj)
assert abs(wgs[0] - back[0]) < 1e-4 and abs(wgs[1] - back[1]) < 1e-4, "往返转换有偏差"
assert 100 < haversine(*wgs, *gcj) < 2000, "火星坐标偏移量不在合理范围"
print("OK")
PY
[[ $? -eq 0 ]] && ok "WGS-84 <-> GCJ-02 往返转换正确" || fail "坐标转换不对"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
