"""数据模型：线路、站点、车辆、时刻表。"""

from . import coords

#: 拥堵等级对应的含义（服务端 ``congLeve`` 字段）
CONGESTION_LEVELS = {1: "畅通", 2: "缓行", 3: "拥堵"}


class Station:
    """公交站点。

    坐标系说明：服务端返回 WGS-84，``lat``/``lon`` 为 GCJ-02（火星坐标，
    与安卓客户端显示、且与高德/腾讯地图一致），``wgs_lat``/``wgs_lon``
    为服务端原始的 WGS-84 坐标。
    """

    __slots__ = ("id", "name", "num", "lat", "lon", "wgs_lat", "wgs_lon",
                 "distance", "hour", "raw")

    def __init__(self, id=None, name=None, num=None, lat=None, lon=None,
                 wgs_lat=None, wgs_lon=None, distance=None, hour=None, raw=None):
        self.id = id
        self.name = name
        self.num = num
        self.lat = lat
        self.lon = lon
        self.wgs_lat = wgs_lat
        self.wgs_lon = wgs_lon
        #: 与上一站之间的米数
        self.distance = distance
        #: 首末班车时间（部分线路返回）
        self.hour = hour
        self.raw = raw or {}

    @classmethod
    def from_raw(cls, data):
        wgs_lat = data.get("StaLat")
        wgs_lon = data.get("StaLng")
        lat, lon = coords.wgs84_to_gcj02(wgs_lat, wgs_lon) if wgs_lat is not None else (None, None)
        return cls(
            id=data.get("StaId"),
            name=data.get("StaName"),
            num=data.get("StaNO"),
            lat=lat,
            lon=lon,
            wgs_lat=wgs_lat,
            wgs_lon=wgs_lon,
            distance=data.get("StaDis"),
            hour=data.get("StaHrt"),
            raw=data,
        )

    @classmethod
    def from_platform(cls, data):
        """由 ``staList`` 中的站台记录构造。"""
        wgs_lat = data.get("lat")
        wgs_lon = data.get("lng")
        lat, lon = coords.wgs84_to_gcj02(wgs_lat, wgs_lon) if wgs_lat is not None else (None, None)
        return cls(id=data.get("id"), name=data.get("name"), lat=lat, lon=lon,
                   wgs_lat=wgs_lat, wgs_lon=wgs_lon, raw=data)

    def __repr__(self):
        return "<Station {}>".format(self.name)

    def __eq__(self, other):
        return isinstance(other, Station) and other.name == self.name and other.num == self.num

    def __hash__(self):
        return hash((self.name, self.num))


class Vehicle:
    """实时公交车。

    ``in_out``：0 表示车辆已停靠在该站（已到站），1 表示车辆已驶离该站、
    正开往下一站。``station_index`` 为车辆当前（刚离开的）站点序号。
    """

    __slots__ = ("id", "plate_num", "lat", "lon", "wgs_lat", "wgs_lon",
                 "in_out", "station_index", "next_station_name", "congestion_level",
                 "dest_num", "dest_distance", "dest_run_time",
                 "arrive_text", "distance_text", "raw")

    def __init__(self, **kw):
        for key in self.__slots__:
            setattr(self, key, kw.get(key))
        self.raw = kw.get("raw") or {}

    @classmethod
    def from_raw(cls, data):
        wgs_lat = data.get("lat")
        wgs_lon = data.get("lng")
        lat, lon = coords.wgs84_to_gcj02(wgs_lat, wgs_lon) if wgs_lat is not None else (None, None)
        return cls(
            id=data.get("onlineNo"),
            plate_num=data.get("plateNum"),
            lat=lat,
            lon=lon,
            wgs_lat=wgs_lat,
            wgs_lon=wgs_lon,
            in_out=data.get("inOut"),
            station_index=data.get("staIndex"),
            next_station_name=data.get("nextStaName"),
            congestion_level=data.get("congLeve"),
            dest_num=data.get("destNum"),
            dest_distance=data.get("destDistance"),
            dest_run_time=data.get("destRunTime"),
            arrive_text=data.get("arriveText"),
            distance_text=data.get("distanceText"),
            raw=data,
        )

    @property
    def arrived(self):
        """车辆是否已停靠在当前站。"""
        return self.in_out == 0

    @property
    def congestion(self):
        return CONGESTION_LEVELS.get(self.congestion_level)

    def dict(self):
        return {
            "id": self.id,
            "plate_num": self.plate_num,
            "lat": self.lat,
            "lon": self.lon,
            "wgs_lat": self.wgs_lat,
            "wgs_lon": self.wgs_lon,
            "current_station_num": self.station_index,
            "next_station_name": self.next_station_name,
            "next_station_num": None if self.station_index is None else self.station_index + 1,
            "arrived": self.arrived,
            "congestion_level": self.congestion_level,
            "station_distance": self.dest_distance,
            "station_arriving_time": self.dest_run_time,
            "station_arriving_text": self.arrive_text,
            "station_distance_text": self.distance_text,
            "destination_distance": self.dest_distance,
            "destination_run_time": self.dest_run_time,
        }

    def __repr__(self):
        return "<Vehicle {} ({}站)>".format(self.plate_num, self.station_index)


class Timetable:
    """一个时段的班次表。"""

    __slots__ = ("start_time", "end_time", "type_name", "depart_times", "raw")

    def __init__(self, start_time, end_time, type_name, depart_times, raw=None):
        self.start_time = start_time
        self.end_time = end_time
        self.type_name = type_name
        self.depart_times = depart_times
        self.raw = raw or {}

    @classmethod
    def from_raw(cls, data):
        return cls(
            start_time=data.get("startTime"),
            end_time=data.get("endTime"),
            type_name=data.get("TypeName"),
            depart_times=data.get("DepartTimeList") or [],
            raw=data,
        )

    def __repr__(self):
        return "<Timetable {}-{} {} ({}班)>".format(
            self.start_time, self.end_time, self.type_name, len(self.depart_times))


class Line:
    """公交线路。"""

    def __init__(self, client, route_code, name=None, fst_name=None, lst_name=None,
                 up_down=0, min_ticket_price=None, max_ticket_price=None, raw=None):
        self._client = client
        #: 线路 id（``routeCode``），统一为字符串
        self.id = None if route_code is None else str(route_code)
        self.name = name
        self.fst_name = fst_name
        self.lst_name = lst_name
        #: 0 去程、1 返程
        self.up_down = up_down
        self.min_ticket_price = min_ticket_price
        self.max_ticket_price = max_ticket_price
        self.raw = raw or {}
        self._stations = None
        #: 服务端返回的线路全名（可能与 name 略有差异）
        self.route_name = name

    # ------------------------------------------------------------------ 基础

    def __repr__(self):
        return "<Line: {}({})>".format(self.name, self.fst_name)

    @property
    def stations(self):
        """该线路该方向的全部站点（``Station`` 列表）。"""
        if self._stations is None:
            result = self._client.get_line_stations(self.id, self.up_down)
            self._stations = [Station.from_raw(s) for s in (result.get("Stations") or [])]
            self.route_name = result.get("Rname") or self.name
        return self._stations

    @property
    def full_name(self):
        """形如 ``1路(长冲铺-兴义粮油市场)`` 的线路全名。"""
        return "{}({}-{})".format(self.name, self.fst_name, self.lst_name)

    def shape(self):
        """线路走向点列表（GCJ-02 坐标的 ``(lat, lon)``）。"""
        points = self._client.get_line_shape(self.id, self.up_down)
        out = []
        for p in points:
            lat, lon = coords.wgs84_to_gcj02(p.get("lat"), p.get("lng"))
            out.append((lat, lon))
        return out

    def timetable(self):
        """发车时刻表（``Timetable`` 列表）。"""
        return [Timetable.from_raw(t) for t in self._client.get_timetable(self.id, self.up_down)]

    # ------------------------------------------------------------------ 实时

    def get_vehicles(self, station_num=None, limit=999):
        """该线路该方向上的全部实时车辆（``Vehicle`` 列表）。

        ``station_num`` 不为 ``None`` 时，同时向服务端请求到目标站的
        距离/时间估算（``dest_*`` 字段）。
        """
        result = self._client.get_line_vehicles(self.id, self.up_down, station_num, limit)
        vehicles = []
        for route in result:
            for v in (route.get("vehicles") or []):
                vehicles.append(Vehicle.from_raw(v))
        return vehicles

    def get_realtime_data(self, station_num=1, limit=999):
        """指定站点附近的实时车辆信息。

        ``station_num`` 为站点序号（从 1 开始）。返回车辆字典列表：

        * ``id``               车辆 id
        * ``plate_num``        车牌号
        * ``lat`` / ``lon``    车辆位置（GCJ-02）
        * ``next_station_name`` 下一站名字
        * ``next_station_num`` 下一站序号
        * ``station_distance``  距离本站还有多少米
        * ``station_arriving_time`` 预计多少分钟后到达本站
        * ``arrived``          是否已停靠本站
        """
        return [v.dict() for v in self.vehicles_at_station(station_num, limit)]

    def vehicles_at_station(self, station_num=1, limit=999):
        """实时车辆列表中过滤出与 ``station_num`` 相关的车辆。

        包括两种情况：已经停靠本站的车（``inOut == 0``），以及已离开上一站、
        正开往本站的车（``inOut == 1``）。
        """
        selected = []
        for v in self.get_vehicles(station_num, limit):
            if v.station_index is None:
                continue
            # 已到站：车辆正停靠在本站
            if v.station_index == station_num and v.in_out == 0:
                selected.append(v)
            # 正在开来：车辆已离开上一站，正开往本站
            elif v.station_index == station_num - 1 and v.in_out == 1:
                selected.append(v)
        return selected


class NearbyStation:
    """附近站点：站点本身 + 经过的线路 + 实时车辆。"""

    def __init__(self, name, sta_id, distance, platforms, routes, raw=None):
        self.name = name
        self.sta_id = sta_id
        #: 距离（米，GCJ-02 坐标系下计算）
        self.distance = distance
        #: 该站点的各站台（``Station`` 列表）
        self.platforms = platforms
        #: 经过该站点的线路（``RouteSummary`` 列表）
        self.routes = routes
        self.raw = raw or {}

    def __repr__(self):
        return "<NearbyStation {} ({}m)>".format(self.name, self.distance)


class RouteSummary:
    """经过某站点的线路概要（含实时车辆）。"""

    def __init__(self, data):
        self.route_code = data.get("routeCode")
        self.route_name = data.get("routeName")
        self.up_down = data.get("upDown")
        self.fst_name = data.get("fstName")
        self.lst_name = data.get("lstName")
        self.first_time = data.get("fdTime")
        self.last_time = data.get("ldTime")
        self.next_time = data.get("nextTime")
        self.min_ticket_price = data.get("minTicketPrice")
        self.max_ticket_price = data.get("maxTicketPrice")
        self.vehicles = [Vehicle.from_raw(v) for v in (data.get("vehicles") or [])]
        self.raw = data

    def __repr__(self):
        return "<RouteSummary {}>".format(self.route_name)
