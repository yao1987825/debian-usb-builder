"""traintools.api —— 12306 接口访问(只用标准库)。

要点(都是踩出来的):
- 12306 的余票接口要求**先有会话 Cookie**: 直接 GET 接口会拿到一个 HTML 页面
  (反爬提示), 于是上游代码 JSONDecodeError。正确姿势是:
      1) GET https://kyfw.12306.cn/otn/leftTicket/init  (拿 cookie)
      2) 带 Referer / X-Requested-With / User-Agent 再 GET query 接口
- 请求头里**不能带 Accept-Encoding 之外的自定义头**过多, 否则可能被重定向到验证页;
- 车站名 -> 车站码的对照表官方在 station_name.js, 定期变, 所以:
  本地用内置表(离线可用), 查不到时再联网刷新并缓存。
"""

from __future__ import annotations

import gzip
import http.cookiejar
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0 Safari/537.36"
)

INIT_URL = "https://kyfw.12306.cn/otn/leftTicket/init?linktypeid=dc"
QUERY_URL = "https://kyfw.12306.cn/otn/leftTicket/query"
STATION_JS = "https://kyfw.12306.cn/otn/resources/js/framework/station_name.js"

# 余票接口返回的 `|` 分隔字段, 按当前接口布局对齐(上游代码整体错位了一格)
# 座位字段的下标是固定的(12306 的返回格式这几年没变), 但**很容易写错**:
# 上游项目就是整体错位了一格, 表现为"二等座"那一列全是空的。
# 下面是拿真车次逐个核对过的结果(2026-10 真机实测):
#   G1   复兴号: [30]=有 二等 / [31]=有 一等 / [32]=13 商务 / [26]=有 无座
#   K545 普速  : [29]=有 硬座 / [28]=无 硬卧 / [26]=有 无座 / [23]=无 软卧
#   D17  动车  : [30]=17 二等 / [23]=有 软卧 / [26]=有 无座
FIELDS = {
    "train_no": 3,       # 车次
    "start_station": 4,  # 始发站
    "end_station": 5,    # 终点站
    "from_station": 6,   # 出发站(实际上车的站)
    "to_station": 7,     # 到达站
    "from_time": 8,      # 出发时间
    "to_time": 9,        # 到达时间
    "duration": 10,      # 历时
    "can_buy": 11,
    "start_date": 13,
    "gr_num": 21,        # 高级软卧
    "qt_num": 22,        # 其他
    "rw_num": 23,        # 软卧
    "rz_num": 24,        # 软座
    "tz_num": 25,        # 特等座
    "wz_num": 26,        # 无座
    "yw_num": 28,        # 硬卧
    "yz_num": 29,        # 硬座
    "ze_num": 30,        # 二等座
    "zy_num": 31,        # 一等座
    "swz_num": 32,       # 商务座
    "srrb_num": 33,      # 动卧
}


class TrainError(Exception):
    """给用户看的错误(不是堆栈)。"""


# ---------------------------------------------------------------- 会话


def _opener():
    cj = http.cookiejar.CookieJar()
    op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    op.addheaders = [
        ("User-Agent", UA),
        ("Accept", "application/json, text/javascript, */*; q=0.01"),
        ("Accept-Language", "zh-CN,zh;q=0.9"),
        ("Connection", "keep-alive"),
    ]
    return op


def _get(opener, url, headers=None, timeout=20):
    req = urllib.request.Request(url)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with opener.open(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding", "").lower() == "gzip":
                raw = gzip.decompress(raw)
            return raw, resp.headers
    except urllib.error.HTTPError as exc:
        raise TrainError(f"12306 返回 HTTP {exc.code}: {exc.reason}") from exc
    except urllib.error.URLError as exc:
        raise TrainError(f"连不上 12306: {exc.reason}(检查网络/代理)") from exc
    except TimeoutError as exc:
        raise TrainError("连 12306 超时(网络慢或被墙)") from exc
    except OSError as exc:
        raise TrainError(f"网络错误: {exc}") from exc


def warmup(opener):
    """先访问余票首页拿会话 Cookie。没有这一步, 接口只会回 HTML。"""
    try:
        _get(opener, INIT_URL, timeout=20)
        return True
    except TrainError:
        return False


# ---------------------------------------------------------------- 车站表


def _cache_path():
    d = os.path.join(os.path.expanduser("~"), ".cache", "traintools")
    try:
        os.makedirs(d, exist_ok=True)
    except OSError:
        d = "/tmp"
    return os.path.join(d, "stations.json")


def local_stations():
    """内置车站表(离线可用)。"""
    try:
        from .stations import stations

        return dict(stations)
    except Exception:
        return {}


def cached_stations(max_age_days=7):
    """联网刷新过的车站表(带缓存)。刷新失败就退回内置表。"""
    path = _cache_path()
    try:
        st = os.stat(path)
        if time.time() - st.st_mtime < max_age_days * 86400:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if data:
                return data
    except (OSError, ValueError):
        pass
    return {}


def refresh_stations():
    """从官方 station_name.js 拉最新车站表并存缓存。"""
    opener = _opener()
    raw, _ = _get(opener, STATION_JS, timeout=20)
    text = raw.decode("utf-8", "replace")
    pairs = re.findall(r"([一-龥]+)\|([A-Z]+)", text)
    if not pairs:
        raise TrainError("车站表解析失败(官方格式变了)")
    data = dict(pairs)
    try:
        with open(_cache_path(), "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
    except OSError:
        pass
    return data


def resolve_station(name):
    """车站名 -> 车站码。找不到就联网刷新一次再找。"""
    name = (name or "").strip()
    if not name:
        raise TrainError("车站名不能为空")
    table = cached_stations()
    if name in table:
        return table[name]
    table = local_stations()
    if name in table:
        return table[name]
    # 本地没有: 可能是新车站, 联网刷新一次
    try:
        fresh = refresh_stations()
    except TrainError:
        raise TrainError(f"车站名不认识: {name}(内置表和在线表里都没有)")
    if name in fresh:
        return fresh[name]
    # 再退一步: 允许用户直接给车站码(4 个大写字母)
    if re.fullmatch(r"[A-Za-z]{4}", name):
        return name.upper()
    raise TrainError(f"车站名不认识: {name}(联网刷新后仍没有, 是不是写错了?)")


def search_stations(keyword, limit=20):
    """按关键字搜车站(给交互式补全/排查拼写用)。"""
    table = cached_stations() or local_stations()
    out = []
    for name, code in table.items():
        if keyword in name:
            out.append((name, code))
    out.sort()
    return out[:limit]


# ---------------------------------------------------------------- 余票查询


def query(date_str, from_station, to_station, purpose="ADULT"):
    """查某天某两站之间的车次与余票。

    返回: {"trains": [ {字段...}, ... ], "raw_count": N}
    """
    opener = _opener()
    if not warmup(opener):
        raise TrainError("打不开 12306 余票页(网络不通或被拦截)")

    params = urllib.parse.urlencode(
        {
            "leftTicketDTO.train_date": date_str,
            "leftTicketDTO.from_station": from_station,
            "leftTicketDTO.to_station": to_station,
            "purpose_codes": purpose,
        }
    )
    url = f"{QUERY_URL}?{params}"
    headers = {
        "Referer": "https://kyfw.12306.cn/otn/leftTicket/init",
        "X-Requested-With": "XMLHttpRequest",
        "Accept": "application/json, text/javascript, */*; q=0.01",
    }
    raw, _ = _get(opener, url, headers=headers, timeout=25)
    text = raw.decode("utf-8", "replace").strip()

    if not text.startswith("{"):
        # 12306 对异常请求回 HTML(反爬/验证页)
        raise TrainError("12306 没返回 JSON(被反爬拦截了)。稍后再试, 或换个网络")

    try:
        data = json.loads(text)
    except ValueError as exc:
        raise TrainError(f"12306 返回的内容解析不了: {exc}") from exc

    if data.get("httpstatus") != 200 or data.get("status") is False:
        msg = (data.get("messages") or ["未知错误"])[0]
        raise TrainError(f"12306 说不行: {msg}")

    payload = data.get("data") or {}
    results = payload.get("result") or []
    trains = []
    for item in results:
        parts = item.split("|")
        if len(parts) < 34:
            continue
        rec = {k: parts[i] for k, i in FIELDS.items() if i < len(parts)}
        rec["raw"] = parts
        trains.append(rec)
    return {"trains": trains, "raw_count": len(results)}


def booking_window(date_str):
    """12306 预售期: 一般是当天起 15 天(含)。返回 (最早, 最晚)。"""
    import datetime

    d = datetime.date.fromisoformat(date_str)
    today = datetime.date.today()
    return today, today + datetime.timedelta(days=14)
