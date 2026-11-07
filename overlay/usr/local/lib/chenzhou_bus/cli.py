"""命令行查询工具。

交互式使用::

    python gongjiao.py cli

单次执行::

    python gongjiao.py lines
    python gongjiao.py search 2路
    python gongjiao.py line 20000002
    python gongjiao.py realtime 20000002 30
    python gongjiao.py nearby 25.7936 113.0176 800
    python gongjiao.py schedule 20000002

加 ``--json`` 出结构化输出(集成进 U 盘镜像时加的, 给脚本和 AI 用)::

    python gongjiao.py search 2路 --json
"""

import json
import sys

from . import ChenzhouBus
from .models import CONGESTION_LEVELS

#: 本次调用要不要出 JSON。由 main() 解析 --json 后置位。
_JSON = False


def _fmt_coord(lat, lon):
    if lat is None or lon is None:
        return "-"
    return "{:.6f},{:.6f}".format(lat, lon)


def _emit(payload):
    """按当前模式输出: --json 出结构化, 否则由调用方自己打印人类可读的。"""
    if _JSON:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return True
    return False


def _line_json(line):
    return {
        "id": line.id,
        "name": line.name,
        "fst_name": line.fst_name,
        "lst_name": line.lst_name,
        "up_down": line.up_down,
        "min_ticket_price": line.min_ticket_price,
        "max_ticket_price": line.max_ticket_price,
    }


def _station_json(st):
    return {
        "num": st.num,
        "name": st.name,
        "lat": st.lat,
        "lon": st.lon,
        "wgs_lat": st.wgs_lat,
        "wgs_lon": st.wgs_lon,
        "distance": st.distance,
    }


def _print_lines(lines, limit=None):
    if not lines:
        print("没有找到线路。")
        return
    show = lines if limit is None else lines[:limit]
    print("{:<12} {:<24} {:<28} {}".format("线路ID", "线路", "去程", "返程"))
    print("-" * 100)
    for line in show:
        print("{:<12} {:<24} {:<28} {}".format(
            line.id, line.name or "-", line.fst_name or "-", line.lst_name or "-"))
    if limit is not None and len(lines) > limit:
        print("... 共 {} 条线路，仅显示前 {} 条（输入 lines all 查看全部）".format(len(lines), limit))


def cmd_lines(args):
    limit = None
    if args and args[0].lower() == "all":
        limit = None
    else:
        limit = 50
    lines = ChenzhouBus.get_all_lines()
    if _emit([_line_json(x) for x in lines]):
        return 0
    _print_lines(lines, limit)
    return 0


def cmd_search(args):
    if not args:
        print("用法: search <关键字>")
        return 1
    keyword = " ".join(args)
    lines = ChenzhouBus.search_lines(keyword)
    stations = ChenzhouBus.search_stations(keyword)
    places = ChenzhouBus.search_places(keyword)

    if _emit({
        "keyword": keyword,
        "lines": [_line_json(x) for x in lines],
        "stations": [{
            "id": s.id,
            "name": s.name,
            "lat": s.lat,
            "lon": s.lon,
        } for s in stations],
        "places": [{"name": p.get("name"), "lat": p.get("lat"), "lng": p.get("lng")}
                   for p in places],
    }):
        return 0

    if lines:
        print("== 线路 ==")
        for line in lines:
            print("  {:<12} {:<20} {}-{}  方向:{}".format(
                line.id, line.name or "-", line.fst_name or "-", line.lst_name or "-",
                "去程" if line.up_down == 0 else "返程"))
    if stations:
        print("== 公交站点 ==")
        for st in stations:
            print("  {:<24} {}".format(st.name or "-", _fmt_coord(st.lat, st.lon)))
    if places:
        print("== 地标 ==")
        for p in places:
            print("  {:<24} {}".format(p.get("name") or "-", _fmt_coord(p.get("lat"), p.get("lng"))))
    if not (lines or stations or places):
        print("没有找到与「{}」相关的结果。".format(keyword))
    return 0


def cmd_line(args):
    if not args:
        print("用法: line <线路ID> [方向 0|1]")
        return 1
    route_code = args[0]
    up_down = int(args[1]) if len(args) > 1 and args[1] in ("0", "1") else 0
    try:
        line = ChenzhouBus.get_line(route_code, up_down)
    except KeyError:
        print("没有找到线路: {}".format(route_code))
        return 1
    stations = line.stations
    if _emit({
        "id": line.id,
        "name": line.name,
        "fst_name": line.fst_name,
        "lst_name": line.lst_name,
        "up_down": line.up_down,
        "min_ticket_price": line.min_ticket_price,
        "max_ticket_price": line.max_ticket_price,
        "stations": [_station_json(s) for s in stations],
    }):
        return 0
    print("线路: {}  ({}-{})  方向: {}".format(
        line.name, line.fst_name, line.lst_name, "去程" if up_down == 0 else "返程"))
    if line.min_ticket_price:
        print("票价: {} - {} 元".format(line.min_ticket_price, line.max_ticket_price))
    print("站点 ({} 个):".format(len(stations)))
    for st in stations:
        print("  {:>3}. {:<24} {}  距上一站 {}m".format(
            st.num, st.name or "-", _fmt_coord(st.lat, st.lon), st.distance))
    return 0


def cmd_realtime(args):
    if len(args) < 2:
        print("用法: realtime <线路ID> <站点序号> [方向 0|1]")
        return 1
    route_code = args[0]
    station_num = int(args[1])
    up_down = int(args[2]) if len(args) > 2 and args[2] in ("0", "1") else 0
    try:
        line = ChenzhouBus.get_line(route_code, up_down)
    except KeyError:
        print("没有找到线路: {}".format(route_code))
        return 1
    stations = line.stations
    name = ""
    if 1 <= station_num <= len(stations):
        name = stations[station_num - 1].name
    data = line.get_realtime_data(station_num)
    if _emit({
        "line_id": line.id,
        "line_name": line.name,
        "station_num": station_num,
        "station_name": name,
        "vehicles": [{
            "plate_num": v.get("plate_num"),
            "lat": v.get("lat"),
            "lon": v.get("lon"),
            "next_station_name": v.get("next_station_name"),
            "next_station_num": v.get("next_station_num"),
            "arrived": v.get("arrived"),
            "congestion_level": v.get("congestion_level"),
            "congestion": CONGESTION_LEVELS.get(v.get("congestion_level"), "-"),
            "station_distance": v.get("station_distance"),
            "station_arriving_time": v.get("station_arriving_time"),
            "station_arriving_text": v.get("station_arriving_text"),
        } for v in data],
    }):
        return 0
    print("{} ({}站{}) 实时车辆:".format(line.name, station_num, name))
    if not data:
        print("  当前没有车辆接近该站。")
        return 0
    print("  {:<12} {:<12} {:<12} {:<10} {:<8} {:<16} {}".format(
        "车牌", "位置", "下一站", "状态", "距离", "预计到达", "拥堵"))
    for v in data:
        print("  {:<12} {:<12} {:<12} {:<10} {:<8} {:<16} {}".format(
            v["plate_num"] or "-",
            _fmt_coord(v["lat"], v["lon"]),
            v["next_station_name"] or "-",
            "已到站" if v["arrived"] else "在途中",
            "{}m".format(v["station_distance"]) if v["station_distance"] is not None else "-",
            v["station_arriving_text"] or "-",
            CONGESTION_LEVELS.get(v["congestion_level"], "-")))
    return 0


def cmd_schedule(args):
    if not args:
        print("用法: schedule <线路ID> [方向 0|1]")
        return 1
    route_code = args[0]
    up_down = int(args[1]) if len(args) > 1 and args[1] in ("0", "1") else 0
    try:
        line = ChenzhouBus.get_line(route_code, up_down)
    except KeyError:
        print("没有找到线路: {}".format(route_code))
        return 1
    tables = line.timetable()
    if _emit({
        "id": line.id,
        "name": line.name,
        "up_down": line.up_down,
        "timetables": [{
            "type_name": tt.type_name,
            "start_time": tt.start_time,
            "end_time": tt.end_time,
            "depart_times": list(tt.depart_times),
        } for tt in tables],
    }):
        return 0
    print("{} 发车时刻表:".format(line.name))
    for tt in tables:
        print("  [{}] {}-{}  ({} 班)".format(tt.type_name, tt.start_time, tt.end_time, len(tt.depart_times)))
        for i in range(0, len(tt.depart_times), 10):
            print("    " + "  ".join(tt.depart_times[i:i + 10]))
    return 0


def cmd_nearby(args):
    if len(args) < 2:
        print("用法: nearby <纬度> <经度> [半径(米)]")
        print("注意: 经纬度需要是 GCJ-02（火星）坐标")
        return 1
    lat = float(args[0])
    lng = float(args[1])
    radius = int(args[2]) if len(args) > 2 else 1000
    stations = ChenzhouBus.get_nearby_stations(lat, lng, radius)
    if _emit({
        "lat": lat,
        "lng": lng,
        "radius": radius,
        "stations": [{
            "name": st.name,
            "sta_id": st.sta_id,
            "distance": st.distance,
            "platforms": [{
                "name": p.name,
                "lat": p.lat,
                "lon": p.lon,
            } for p in st.platforms],
            "routes": [{
                "route_name": r.route_name,
                "up_down": r.up_down,
                "fst_name": r.fst_name,
                "lst_name": r.lst_name,
                "vehicles": [{
                    "plate_num": v.plate_num,
                    "arrived": v.arrived,
                    "arrive_text": v.arrive_text,
                    "next_station_name": v.next_station_name,
                } for v in r.vehicles],
            } for r in st.routes],
        } for st in stations],
    }):
        return 0
    if not stations:
        print("附近 {} 米内没有站点。".format(radius))
        return 0
    for st in stations:
        print("{}  ({}m)".format(st.name, st.distance))
        for route in st.routes:
            vehicles = " | ".join(
                "{}[{}] {}".format(v.plate_num,
                                   "已到站" if v.arrived else "在途中",
                                   v.arrive_text or v.next_station_name or "")
                for v in route.vehicles)
            print("    {:<16} {:<8} {}-{}  {}".format(
                route.route_name or "-",
                "去程" if route.up_down == 0 else "返程",
                route.fst_name or "-", route.lst_name or "-",
                vehicles))
    return 0


COMMANDS = {
    "lines": cmd_lines,
    "search": cmd_search,
    "line": cmd_line,
    "realtime": cmd_realtime,
    "schedule": cmd_schedule,
    "nearby": cmd_nearby,
}

HELP = """可用命令:
  lines [all]                       列出全部线路
  search <关键字>                   搜索线路 / 站点 / 地标
  line <线路ID> [方向 0|1]          查看线路站点
  realtime <线路ID> <站序> [方向]    查看某站的实时车辆
  schedule <线路ID> [方向 0|1]      查看发车时刻表
  nearby <纬度> <经度> [半径]       查看附近站点（GCJ-02 坐标）
  cli                               进入交互式查询
  help                              显示帮助
  quit / exit                       退出

任何子命令都可以加 --json 出结构化输出（给脚本或 AI 用）:
  bus search 2路 --json
"""


def run_cli():
    """进入交互式查询界面。"""
    print("郴州实时公交 —— 命令行查询工具")
    print(HELP)
    while True:
        try:
            line = input("bus> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break
        if not line:
            continue
        parts = line.split()
        cmd = parts[0].lower()
        if cmd in ("quit", "exit", "q"):
            break
        if cmd in ("help", "?"):
            print(HELP)
            continue
        func = COMMANDS.get(cmd)
        if func is None:
            print("未知命令: {}，输入 help 查看帮助。".format(cmd))
            continue
        try:
            func(parts[1:])
        except Exception as exc:  # noqa: BLE001 - 命令行里不希望直接崩掉
            print("出错了: {}".format(exc))
    return 0


def main(argv=None):
    global _JSON
    argv = list(sys.argv[1:] if argv is None else argv)

    # --json 是**全局**开关: 可以在子命令后面写(bus search 2路 --json),
    # 也可以写在前面(bus --json search 2路)
    if "--json" in argv:
        argv.remove("--json")
        _JSON = True

    # 没有参数 = 打帮助然后退出, **不是**掉进交互式 REPL。
    # (集成进 U 盘镜像时改的: 别的命令(train/tch/net)没参数都是打帮助,
    #  一个会卡住等输入的命令在脚本里就是灾难。)
    if not argv:
        print(HELP)
        return 0
    if argv[0] in ("cli", "shell", "repl"):
        return run_cli()
    cmd = argv[0].lower()
    if cmd in ("help", "-h", "--help"):
        print(HELP)
        return 0
    func = COMMANDS.get(cmd)
    if func is None:
        print("未知命令: {}".format(cmd))
        print(HELP)
        return 1
    try:
        return func(argv[1:])
    except Exception as exc:  # noqa: BLE001
        print("出错了: {}".format(exc))
        return 1


if __name__ == "__main__":
    sys.exit(main())
