"""坐标转换工具。

郴州公交行服务端返回的坐标为 WGS-84，客户端在其内部使用 GCJ-02（火星坐标，
与高德/腾讯地图一致）。本模块实现两者的互换，算法与安卓客户端中
``common/lib/GpsTransformer.js`` 保持完全一致。
"""

import math

PI = math.pi
X_PI = PI * 3000.0 / 180.0

# 特殊区域：这些地区直接使用 WGS-84，不做偏移
_SP_AREA = (113.52472994246176, 113.60013385191158, 22.110302229904562, 22.21149949230103)


def _transform_lat(x, y):
    ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(y * PI) + 40.0 * math.sin(y / 3.0 * PI)) * 2.0 / 3.0
    ret += (160.0 * math.sin(y / 12.0 * PI) + 320.0 * math.sin(y * PI / 30.0)) * 2.0 / 3.0
    return ret


def _transform_lon(x, y):
    ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * math.sqrt(abs(x))
    ret += (20.0 * math.sin(6.0 * x * PI) + 20.0 * math.sin(2.0 * x * PI)) * 2.0 / 3.0
    ret += (20.0 * math.sin(x * PI) + 40.0 * math.sin(x / 3.0 * PI)) * 2.0 / 3.0
    ret += (150.0 * math.sin(x / 12.0 * PI) + 300.0 * math.sin(x / 30.0 * PI)) * 2.0 / 3.0
    return ret


def _delta(lat, lng):
    d_lat = _transform_lat(lng - 105.0, lat - 35.0)
    d_lng = _transform_lon(lng - 105.0, lat - 35.0)
    rad_lat = lat / 180.0 * PI
    magic = math.sin(rad_lat)
    magic = 1 - 0.006693421622965943 * magic * magic
    sqrt_magic = math.sqrt(magic)
    d_lat = (d_lat * 180.0) / ((6378245.0 * (1 - 0.006693421622965943)) / (magic * sqrt_magic) * PI)
    d_lng = (d_lng * 180.0) / (6378245.0 / sqrt_magic * math.cos(rad_lat) * PI)
    return d_lat, d_lng


def out_of_china(lat, lng):
    """经纬度是否位于中国境外。"""
    if 116.59 < lng < 130 and 5 < lat < 18.64:
        return True
    return lng < 72.004 or lng > 137.8347 or lat < 0.8293 or lat > 55.8271


def is_sp_area(lat, lng):
    """是否位于使用特殊坐标系的区域。"""
    lng_min, lng_max, lat_min, lat_max = _SP_AREA
    return lng_min < lng < lng_max and lat_min < lat < lat_max


def wgs84_to_gcj02(lat, lng):
    """WGS-84 -> GCJ-02（火星坐标）。"""
    lat, lng = float(lat), float(lng)
    if out_of_china(lat, lng) or is_sp_area(lat, lng):
        return lat, lng
    d_lat, d_lng = _delta(lat, lng)
    return lat + d_lat, lng + d_lng


def gcj02_to_wgs84(lat, lng):
    """GCJ-02（火星坐标）-> WGS-84。"""
    lat, lng = float(lat), float(lng)
    if out_of_china(lat, lng) or is_sp_area(lat, lng):
        return lat, lng
    d_lat, d_lng = _delta(lat, lng)
    return lat - d_lat, lng - d_lng


def gcj02_to_bd09(lat, lng):
    """GCJ-02 -> BD-09（百度坐标）。"""
    x, y = lng, lat
    z = math.sqrt(x * x + y * y) + 0.00002 * math.sin(y * X_PI)
    theta = math.atan2(y, x) + 0.000003 * math.cos(x * X_PI)
    return z * math.sin(theta) + 0.006, z * math.cos(theta) + 0.0065


def bd09_to_gcj02(lat, lng):
    """BD-09（百度坐标）-> GCJ-02。"""
    x, y = lng - 0.0065, lat - 0.006
    z = math.sqrt(x * x + y * y) - 0.00002 * math.sin(y * X_PI)
    theta = math.atan2(y, x) - 0.000003 * math.cos(x * X_PI)
    return z * math.sin(theta), z * math.cos(theta)


def haversine(lat1, lng1, lat2, lng2):
    """两点间的球面距离，单位：米。"""
    radius = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    x = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lng2 - lng1) / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(x))
