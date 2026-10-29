"""traintools.cli —— `train` 命令的实现。

    train 北京 上海                # 今天
    train 北京 上海 2026-10-30     # 指定日期
    train 北京 上海 明天           # 也支持 明天/后天/今天/+3
    train -g 北京 上海             # 只看高铁(和城际)
    train --json 北京 上海         # JSON 输出
    train --stations 北京         # 查车站名/车站码
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys

from . import api, format as fmt

# 车次首字母 -> 类型
TRAIN_TYPES = {
    "G": "高铁",
    "C": "城际",
    "D": "动车",
    "Z": "直达",
    "T": "特快",
    "K": "快速",
    "1": "临客",
}


def parse_date(text):
    """把用户写的日期解析成 YYYY-MM-DD。支持 明天/后天/今天/+N。"""
    if not text:
        return datetime.date.today()
    text = text.strip()
    today = datetime.date.today()
    if text in ("今天", "today"):
        return today
    if text == "明天":
        return today + datetime.timedelta(days=1)
    if text == "后天":
        return today + datetime.timedelta(days=2)
    if text == "大后天":
        return today + datetime.timedelta(days=3)
    if text.startswith("+"):
        try:
            return today + datetime.timedelta(days=int(text[1:]))
        except ValueError:
            raise api.TrainError(f"看不懂的日期: {text}")
    for fmt_str in ("%Y-%m-%d", "%Y/%m/%d", "%m-%d", "%m/%d"):
        try:
            d = datetime.datetime.strptime(text, fmt_str).date()
        except ValueError:
            continue
        if fmt_str in ("%m-%d", "%m/%d"):
            d = d.replace(year=today.year)
            if d < today:
                d = d.replace(year=today.year + 1)
        return d
    raise api.TrainError(f"看不懂的日期: {text}(用 2026-10-30 / 明天 / +3 这种写法)")


def cmd_query(args):
    date = parse_date(args.date)
    date_str = date.isoformat()
    earliest, latest = api.booking_window(date_str)
    if date < earliest:
        raise api.TrainError(f"日期 {date_str} 已经过去了(今天才 {earliest})")
    if date > latest:
        raise api.TrainError(
            f"日期 {date_str} 超出预售期 —— 12306 一般只放票到 {latest}(今天起 15 天内)"
        )

    from_code = api.resolve_station(args.origin)
    to_code = api.resolve_station(args.destination)
    result = api.query(date_str, from_code, to_code)
    trains = result["trains"]

    wanted = set()
    for flag, letters in (
        ("g", "GC"),
        ("d", "D"),
        ("t", "T"),
        ("k", "K"),
        ("z", "Z"),
    ):
        if getattr(args, flag):
            wanted.update(letters)
    if wanted:
        trains = [t for t in trains if (t.get("train_no", "")[:1] or "").upper() in wanted]

    code2name = {}
    for table in (api.cached_stations(), api.local_stations()):
        if table:
            code2name = {v: k for k, v in table.items()}
            break

    if args.json:
        payload = {
            "date": date_str,
            "from": args.origin,
            "to": args.destination,
            "count": len(trains),
            "trains": [
                {
                    "no": t.get("train_no"),
                    "type": TRAIN_TYPES.get((t.get("train_no") or "")[:1].upper(), "其他"),
                    "from": code2name.get(t.get("from_station"), t.get("from_station")),
                    "to": code2name.get(t.get("to_station"), t.get("to_station")),
                    "depart": t.get("from_time"),
                    "arrive": t.get("to_time"),
                    "duration": t.get("duration"),
                    "seats": {name: fmt.seat_text(t.get(field, "")) for name, field in fmt.SEAT_COLUMNS},
                }
                for t in trains
            ],
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    if not trains:
        print(f"{date_str} {args.origin} → {args.destination} 没有可显示的车次")
        print("  (可能是: 没车/没票、筛选条件太窄、或这个日期还没放票)")
        return 1

    print(f"{date_str}  {args.origin} → {args.destination}   共 {len(trains)} 趟")
    print()
    print(fmt.render(trains, code2name))
    print()
    print("提示: 余票随时变, 要买票请去 12306 官网/App 确认")
    return 0


def cmd_stations(args):
    # 注意: argparse 里 --stations 的 dest 是 "stations"(不是 "keyword")
    keyword = args.stations
    hits = api.search_stations(keyword, limit=args.limit)
    if not hits:
        print(f"没找到含「{keyword}」的车站")
        return 1
    print(f"含「{keyword}」的车站({len(hits)} 个):")
    for name, code in hits:
        print(f"  {name:<12} {code}")
    return 0


def build_parser():
    p = argparse.ArgumentParser(
        prog="train",
        description="查 12306 火车票余票(命令行版)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""例子:
  train 北京 上海                 # 今天
  train 北京 上海 2026-10-30      # 指定日期(也支持 明天/后天/+3)
  train -g 北京 上海              # 只看高铁/城际
  train --json 北京 上海          # JSON 输出(给脚本用)
  train --stations 北京           # 查车站名/车站码""",
    )
    p.add_argument("-g", action="store_true", help="只看高铁/城际(G/C)")
    p.add_argument("-d", action="store_true", help="只看动车(D)")
    p.add_argument("-t", action="store_true", help="只看特快(T)")
    p.add_argument("-k", action="store_true", help="只看快速(K)")
    p.add_argument("-z", action="store_true", help="只看直达(Z)")
    p.add_argument("--json", action="store_true", help="输出 JSON")
    p.add_argument("--stations", metavar="关键字", help="按关键字查车站名/车站码")
    p.add_argument("--limit", type=int, default=20, help="--stations 最多显示几个(默认 20)")
    p.add_argument("origin", nargs="?", help="出发站")
    p.add_argument("destination", nargs="?", help="到达站")
    p.add_argument("date", nargs="?", help="日期(默认今天)")
    return p


def main(argv=None):
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.stations:
        try:
            return cmd_stations(args)
        except api.TrainError as exc:
            print(f"错误: {exc}", file=sys.stderr)
            return 2

    if not args.origin or not args.destination:
        parser.print_help()
        return 2

    try:
        return cmd_query(args)
    except api.TrainError as exc:
        print(f"错误: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())
