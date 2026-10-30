#!/usr/bin/env bash
#
# test-travel-skill.sh —— travel-planner 技能(旅游攻略/高德导航/天气)的回归测试
#
# 背景(2026-10): 用户要求把 travel-planner 项目接进 opencode, 并给了高德 Key。
# 集成过程中发现这个项目**本身有两个会导致结果完全错**的 bug(真机实测):
#   1) --city 默认"上海"且被无条件套在起终点地理编码上 -> 跨城查询坐标全错,
#      路线接口报 30001;
#   2) 目的地不做城市限定时, 高德把"岳麓山"匹配到乌鲁木齐的岳麓山,
#      长沙市内 3.8km 的路算出 3823 公里。
# 这类 bug 单测抓不到(要联网), 所以把"策略"本身钉进断言里。
set -uo pipefail
cd "$(dirname "$0")/.."

FAIL=0
ok()   { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

SK="overlay/home/user/.config/opencode/skills/travel-planner"

echo "== 技能结构 =="
[[ -f "${SK}/SKILL.md" ]] && ok "有 SKILL.md" || fail "缺 SKILL.md"
for f in scripts/amap_nav.py scripts/generate_plan.py scripts/food_price_scraper.py; do
  [[ -f "${SK}/${f}" ]] && ok "有 ${f}" || fail "缺 ${f}"
done
[[ -d "${SK}/references" ]] && ok "有 references/" || fail "缺 references/"
[[ -f "${SK}/.env" ]] && ok "有 .env(高德 Key)" || fail "缺 .env"
grep -q "^AMAP_KEY=..\{20,\}" "${SK}/.env" && ok ".env 里配了 AMAP_KEY" || fail ".env 里没配 AMAP_KEY"

echo "== SKILL.md 的 frontmatter(opencode 只认 name + description) =="
head -3 "${SK}/SKILL.md" | grep -q "^name: travel-planner" && ok "name 与目录名一致" || fail "frontmatter 的 name 不对"
if head -12 "${SK}/SKILL.md" | grep -q "^description:"; then
  ok "有 description(否则技能不会暴露给模型)"
else
  fail "缺 description"
fi
# 触发词必须出现在 description 里(技能靠它被选中)
if sed -n '/^description:/,/^---/p' "${SK}/SKILL.md" | grep -qE "旅游攻略|行程安排|景点推荐"; then
  ok "description 里有触发词"
else
  fail "description 里没有触发词"
fi

echo "== 脚本语法与依赖处理 =="
if command -v python3 >/dev/null 2>&1; then
  for f in "${SK}"/scripts/*.py; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1], encoding='utf-8').read())" "$f" \
      && ok "python 语法 ${f##*/}" || fail "python 语法 ${f##*/}"
  done
else
  fail "没有 python3"
fi
# 不许依赖 python-dotenv(镜像不装它); 必须自己解析 .env
if grep -q "_load_env_file" "${SK}/scripts/amap_nav.py"; then
  ok "amap_nav.py 自己解析 .env(不依赖 python-dotenv)"
else
  fail "amap_nav.py 依赖 python-dotenv —— 镜像里没装, 从别的目录跑会读不到 key"
fi

echo "== 地理编码策略(错一次结果就差 3800 公里) =="
# 起点: 不带 city 查(带 city 反而报 ENGINE_RESPONSE_DATA_ERROR)
if grep -q "origin = amap.geocode(args.origin_raw)" "${SK}/scripts/amap_nav.py"; then
  ok "起点不带城市限定"
else
  fail "起点地理编码策略变了(带 city 会查不到)"
fi
# 目的地: 用起点的城市限定
if grep -q "dest_city = origin.city if origin else" "${SK}/scripts/amap_nav.py"; then
  ok "目的地用起点城市限定(否则'岳麓山'会串到乌鲁木齐)"
else
  fail "目的地没有用起点城市限定"
fi
# 探测性请求必须静默, 失败就退回
if grep -q "quiet=True" "${SK}/scripts/amap_nav.py"; then
  ok "探测性请求静默(跨城查不到不该刷红字)"
else
  fail "探测性请求没有静默"
fi
if grep -q 'default=""' "${SK}/scripts/amap_nav.py"; then
  ok "--city 默认不再写死"
else
  fail "--city 默认值可能还写死着"
fi

echo "== 接线 =="
# 注意用"存在"而不是"可执行": overlay 里的文件在 git 里是 0644,
# 构建时统一 chmod 0755(见 build-image.sh)。
[[ -f overlay/usr/local/bin/travel ]] && ok "有 travel 命令" || fail "缺 travel 命令"
grep -q "travel-planner" overlay/usr/local/bin/travel && ok "travel 指向技能目录" || fail "travel 没指向技能目录"
if grep -q "travel-planner" scripts/build-image.sh; then
  ok "构建脚本里有 travel-planner 断言"
else
  fail "构建脚本里没有 travel-planner 断言"
fi
grep -q "python3-requests" scripts/build-image.sh && ok "构建脚本装了 python3-requests" || fail "构建脚本没装 python3-requests"

echo
if [[ $FAIL -eq 0 ]]; then
  echo "全部通过 ✅"
else
  echo "有失败 ❌"
  exit 1
fi
