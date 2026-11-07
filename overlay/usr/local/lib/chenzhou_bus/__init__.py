"""郴州实时公交 —— 郴州公交行客户端非公开接口的 Python 绑定。

接口逆向自「郴州公交行」安卓客户端（``com.chenzhou.bus``）。该客户端是
uni-app 应用，业务代码位于 ``assets/apps/__UNI__0AF95B5/www/`` 下的 js 中。

基本用法::

    >>> from chenzhou_bus import ChenzhouBus
    >>> lines = ChenzhouBus.get_all_lines()
    >>> lines[:3]
    [<Line: 1路(长冲铺-兴义粮油市场)>, ...]
    >>> line = ChenzhouBus.search_lines('2路')[0]
    >>> line.name, line.fst_name, line.lst_name
    ('2路', '长冲铺', '首末站5')
    >>> station = line.stations[0]
    >>> station.name, station.lat, station.lon
    ('长冲铺', 25.865..., 113.038...)
    >>> line.get_realtime_data(1)
    [{'id': '18975571524', 'lat': 25.77, 'lon': 113.0, ...}]
"""

from . import coords
from .client import BusAPIError, BusClient, DEFAULT_BASE_URL, DEFAULT_TENANT_ID
from .models import (
    CONGESTION_LEVELS,
    Line,
    NearbyStation,
    RouteSummary,
    Station,
    Timetable,
    Vehicle,
)

__version__ = "1.0.0"

__all__ = [
    "ChenzhouBus",
    "Line",
    "Station",
    "Vehicle",
    "Timetable",
    "NearbyStation",
    "RouteSummary",
    "BusClient",
    "BusAPIError",
    "CONGESTION_LEVELS",
    "DEFAULT_BASE_URL",
    "DEFAULT_TENANT_ID",
    "__version__",
]


class ChenzhouBus:
    """郴州公交查询入口（所有方法均为静态方法）。"""

    #: 默认客户端，可替换以指向其它租户/网关
    client = BusClient()

    #: 线路表缓存（线路列表基本不变）
    _lines_cache = None

    # ------------------------------------------------------------------ 线路

    @staticmethod
    def get_all_lines(up_down=0, refresh=False):
        """全部线路。

        返回 ``Line`` 列表。``up_down``：0 去程、1 返程（线路表本身不含
        方向信息，方向在查询站点时才生效）。
        """
        if refresh or ChenzhouBus._lines_cache is None:
            ChenzhouBus._lines_cache = [
                Line(
                    ChenzhouBus.client,
                    route_code=r.get("routeCode"),
                    name=r.get("routeName"),
                    fst_name=r.get("fstName"),
                    lst_name=r.get("lstName"),
                    up_down=0,
                    min_ticket_price=r.get("minTicketPrice"),
                    max_ticket_price=r.get("maxTicketPrice"),
                    raw=r,
                )
                for r in ChenzhouBus.client.get_routes()
            ]
        if up_down == 0:
            return list(ChenzhouBus._lines_cache)
        return [
            Line(ChenzhouBus.client, l.id, l.name, l.fst_name, l.lst_name, up_down,
                 l.min_ticket_price, l.max_ticket_price, l.raw)
            for l in ChenzhouBus._lines_cache
        ]

    @staticmethod
    def get_line(route_code, up_down=0):
        """按线路 id（``routeCode``）获取线路对象。"""
        wanted = str(route_code)
        for line in ChenzhouBus.get_all_lines():
            if line.id == wanted:
                if up_down == line.up_down:
                    return line
                return Line(ChenzhouBus.client, line.id, line.name, line.fst_name,
                            line.lst_name, up_down, line.min_ticket_price,
                            line.max_ticket_price, line.raw)
        raise KeyError("没有找到线路: {}".format(route_code))

    @staticmethod
    def search_lines(keyword):
        """按关键字搜索线路。

        返回 ``Line`` 列表，同一线路的去/返程会分别返回（与客户端一致）。
        """
        lines = []
        for item in ChenzhouBus.client.search(keyword):
            if item.get("type") != 0:
                continue
            lines.append(Line(
                ChenzhouBus.client,
                route_code=item.get("rid"),
                name=item.get("name"),
                fst_name=item.get("fstName"),
                lst_name=item.get("lstName"),
                up_down=item.get("upDown") or 0,
                raw=item,
            ))
        return lines

    @staticmethod
    def search_stations(keyword):
        """按关键字搜索公交站点，返回 ``Station`` 列表。"""
        stations = []
        for item in ChenzhouBus.client.search(keyword):
            if item.get("type") != 1:
                continue
            wgs_lat, wgs_lon = item.get("lat"), item.get("lng")
            lat, lon = coords.wgs84_to_gcj02(wgs_lat, wgs_lon) if wgs_lat is not None else (None, None)
            stations.append(Station(
                id=item.get("staId"),
                name=item.get("name"),
                lat=lat,
                lon=lon,
                wgs_lat=wgs_lat,
                wgs_lon=wgs_lon,
                raw=item,
            ))
        return stations

    @staticmethod
    def search_places(keyword):
        """按关键字搜索地标（火车站、汽车站等），返回原始字典列表。"""
        return [i for i in ChenzhouBus.client.search(keyword) if i.get("type") == 2]

    # ------------------------------------------------------------------ 站点

    @staticmethod
    def get_nearby_stations(lat, lng, radius=1000):
        """查询附近站点。

        ``lat``/``lng`` 必须是 **GCJ-02** 坐标（服务端会转成 WGS-84 再计算
        距离），与安卓客户端保持一致。若拿到的是 GPS 原始坐标，请先用
        :func:`chenzhou_bus.coords.wgs84_to_gcj02` 转换。

        返回 ``NearbyStation`` 列表。
        """
        result = []
        for item in ChenzhouBus.client.get_nearby_stations(lat, lng, radius):
            platforms = [Station.from_platform(p) for p in (item.get("staList") or [])]
            routes = [RouteSummary(r) for r in (item.get("stationRoutes") or [])]
            result.append(NearbyStation(
                name=item.get("name"),
                sta_id=item.get("staId"),
                distance=item.get("distance"),
                platforms=platforms,
                routes=routes,
                raw=item,
            ))
        return result

    @staticmethod
    def get_station_routes(sta_id, lat=None, lng=None, sta_id_list=None):
        """查询站点详情：各站台、经过线路及实时车辆。

        返回 ``{"name", "staId", "distance", "platforms", "routes"}``。
        """
        data = ChenzhouBus.client.get_station_routes(sta_id, lat, lng, sta_id_list)
        return {
            "name": data.get("name"),
            "sta_id": data.get("staId"),
            "distance": data.get("distance"),
            "platforms": [Station.from_platform(p) for p in (data.get("staList") or [])],
            "routes": [RouteSummary(r) for r in (data.get("stationRoutes") or [])],
            "raw": data,
        }
