"""郴州公交行服务端接口客户端。

接口逆向自「郴州公交行」安卓客户端（包名 ``com.chenzhou.bus``），
该客户端是一个 uni-app(DCloud) 应用，业务逻辑位于
``assets/apps/__UNI__0AF95B5/www/app-service.js`` 与各页面 js 中。
"""

import json
import os
import time

import requests

# ---- 必须绕开环境代理(集成进 U 盘镜像时加的) ----
# 这个接口是**国内 IP 上的纯 HTTP**(http://211.143.37.50:30618), 走代理必坏:
# 实测带 http_proxy 时 curl 直接 http=000(连都连不上), 摘掉就 200/16ms。
# requests 会去读环境里的 http_proxy —— 于是公交查询被扔进代理就连不上了。
# 镜像 v1.9.0 起不再预置代理(99-proxy.sh 删了), 但用户自己 export 的话照样中招,
# 所以这里在模块级把代理变量摘干净(和音乐工具 single.py 同一个道理)。
for _proxy_var in ("http_proxy", "https_proxy", "all_proxy",
                   "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
    os.environ.pop(_proxy_var, None)

DEFAULT_BASE_URL = "http://211.143.37.50:30618"
DEFAULT_TENANT_ID = "zh00002"
DEFAULT_APP_VERSION = "2.5.0"

#: 客户端固定使用的请求头
DEFAULT_HEADERS = {
    "Content-Type": "application/json;charset=utf-8",
    "X-maas-TenantId": DEFAULT_TENANT_ID,
    "Login-Client-Type": "Mini-APP",
    "Form-type": "app",
    "Accept-Language": "zh-CN",
    "Accept": "application/json, text/plain, */*",
    # 中国时区
    "TimeZone": "-480",
}


class BusAPIError(Exception):
    """接口返回了非成功状态。"""

    def __init__(self, info, state=None, payload=None):
        super().__init__(info)
        self.info = info
        self.state = state
        self.payload = payload


def _is_transient(error):
    """判断错误是否为可以重试的临时性错误。"""
    if not isinstance(error, BusAPIError):
        return False
    if error.state in (500, "500"):
        return True
    return (error.info or "").strip().lower() == "failure"


class BusClient:
    """对 ``/api-mygo/{TenantId}/api`` 下各接口的薄封装。

    所有接口均为 POST + JSON，请求体形如::

        {"appVersion": "2.5.0", "Data": {...}}
    """

    def __init__(self, base_url=DEFAULT_BASE_URL, tenant_id=DEFAULT_TENANT_ID,
                 timeout=20, session=None, token=None, retries=5, backoff=0.4,
                 search_cache_ttl=20):
        self.base_url = base_url.rstrip("/")
        self.tenant_id = tenant_id
        self.timeout = timeout
        self.token = token
        self.retries = retries
        self.backoff = backoff
        self.search_cache_ttl = search_cache_ttl
        self.session = session or requests.Session()
        self.api_root = "{}/api-mygo/{}/api".format(self.base_url, self.tenant_id)
        self._search_cache = {}

    # ------------------------------------------------------------------ 内部

    def _headers(self):
        headers = dict(DEFAULT_HEADERS)
        headers["X-maas-TenantId"] = self.tenant_id
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        return headers

    def post(self, path, data=None, raw=False):
        """向 ``path`` 发送 POST 请求并返回解析后的 JSON。

        网络异常与服务端偶发的 ``State=500/failure`` 都会自动重试。
        """
        body = {"appVersion": DEFAULT_APP_VERSION}
        if data is not None:
            body["Data"] = data
        url = self.api_root + path
        payload_bytes = json.dumps(body, ensure_ascii=False).encode("utf-8")

        last_error = None
        for attempt in range(self.retries + 1):
            try:
                resp = self.session.post(
                    url, data=payload_bytes, headers=self._headers(), timeout=self.timeout,
                )
            except requests.RequestException as exc:
                last_error = exc
                if attempt >= self.retries:
                    raise
                time.sleep(self.backoff * (2 ** attempt))
                continue

            text = resp.text
            if raw:
                return text
            try:
                payload = resp.json()
            except ValueError:
                last_error = BusAPIError(
                    "接口返回的不是合法 JSON: {}".format(text[:200]), payload=text)
            else:
                # 服务端在出错时会返回 200 + State != 0，或者直接返回一段 Jackson
                # 的反序列化异常说明（此时 payload 是字符串）。
                if isinstance(payload, str):
                    last_error = BusAPIError(payload.strip()[:300], payload=payload)
                else:
                    state = payload.get("State")
                    if state in (0, "0", None):
                        return payload.get("Result")
                    last_error = BusAPIError(
                        payload.get("Info") or "未知错误", state=state, payload=payload)
                    # 搜索等接口偶发返回 State=500/failure，属于临时性错误，重试即可
                    if not _is_transient(last_error):
                        raise last_error
            if attempt >= self.retries:
                raise last_error
            time.sleep(self.backoff * (2 ** attempt))
        raise last_error  # pragma: no cover

    # ------------------------------------------------------------------ 接口

    def get_routes(self):
        """全部线路。返回 ``[{routeCode, routeName, fstName, lstName, ...}]``。"""
        return self.post("/routesV2") or []

    def search(self, keyword):
        """按关键字搜索线路/站点/地标。

        返回 ``{"result": [{type, name, lat, lng, rid, upDown, staId, ...}]}``，
        其中 ``type``：0 线路、1 公交站点、2 地标。

        搜索接口在服务端偶发返回 ``failure``，且相同关键字的重复请求没有
        额外收益，因此这里做了短时间缓存。
        """
        key = keyword
        now = time.monotonic()
        cached = self._search_cache.get(key)
        if cached and now - cached[0] < self.search_cache_ttl:
            return cached[1]
        result = self.post("/RouteWorkV2", {"Content": keyword}) or {}
        items = result.get("result") or []
        self._search_cache[key] = (now, items)
        return items

    def get_line_stations(self, route_code, up_down=0):
        """某线路某方向的全部站点。

        ``up_down``：0 去程、1 返程。
        """
        result = self.post("/SearchRoutes", {"Rid": route_code, "UpDown": int(up_down)}) or {}
        return result

    def get_line_shape(self, route_code, up_down=0):
        """某线路某方向的走向点，返回 ``[{'lat':..,'lng':..}, ...]``。"""
        result = self.post("/RoutePoint", {"Rid": route_code, "UpDown": int(up_down)}) or {}
        return result.get("points") or []

    def get_timetable(self, route_code, up_down=0):
        """某线路某方向的发车时刻表（按平峰/高峰分组）。"""
        return self.post("/peakTimetable", {"Rid": route_code, "UpDown": int(up_down)}) or []

    def get_line_vehicles(self, route_code, up_down=0, station_no=None, limit=999):
        """某线路某方向上的实时车辆。

        ``station_no`` 对应站序（从 1 开始）。
        """
        route_station = {"routeCode": route_code, "upDown": int(up_down)}
        if station_no is not None:
            route_station["staNO"] = int(station_no)
        data = {"beforeInStation": 1, "num": limit, "routeStation": [route_station]}
        return self.post("/routeStationVehicles", data) or []

    def get_nearby_stations(self, lat, lng, radius=1000):
        """附近站点及其经过的线路、实时车辆。

        注意：``lat``/``lng`` 必须是 **GCJ-02** 坐标（服务端会先转成 WGS-84
        再计算距离），与安卓客户端一致。
        """
        data = {"Lat": float(lat), "Lng": float(lng), "Range": int(radius)}
        return self.post("/nearbyStations", data) or []

    def get_station_routes(self, sta_id, lat=None, lng=None, sta_id_list=None):
        """某站点的详细信息：站点各站台 + 经过线路 + 实时车辆。"""
        data = {}
        if lat is not None:
            data["Lat"] = float(lat)
        if lng is not None:
            data["Lng"] = float(lng)
        if sta_id:
            data["staId"] = sta_id
        if sta_id_list:
            data["staIdList"] = list(sta_id_list)
        return self.post("/stationRouteVehicle", data) or {}
