# 逆向笔记：郴州公交行（com.chenzhou.bus）

## 1. 目标

逆向安卓客户端「郴州公交行」（`com.chenzhou.bus`，版本 `1.1.0.260717`，
minSdk 21 / targetSdk 33），找出其查询实时公交所调用的非公开接口。

## 2. 定位 APK

```bash
adb shell pm list packages -f | grep chenzhou
# package:/data/app/~~GMPzn7uRbPcfxa1isT3fuA==/com.chenzhou.bus-.../base.apk
adb pull /data/app/~~GMPzn7uRbPcfxa1isT3fuA==/com.chenzhou.bus-.../base.apk
```

APK 约 51 MB。

## 3. 关键发现：这是 uni-app 应用

`unzip -l` 后发现 `assets/apps/__UNI__0AF95B5/www/` 目录，包含
`app-service.js`（662 KB）以及各页面的 js。这说明客户端是 **DCloud uni-app**
应用，业务逻辑（包含全部接口地址与参数）都在 JS 里，**不需要**去分析 dex 或
so。

```bash
unzip -q chenzhou_bus.apk 'assets/apps/__UNI__0AF95B5/www/*' -d extracted/
```

目录结构（节选）：

```
assets/apps/__UNI__0AF95B5/www/
├── app-service.js          # 主逻辑，含全局配置与 API 封装
├── app-config-service.js
├── pages-bus/route/detail.js   # 线路详情（含实时车辆）
├── pages-bus/route/map.js
├── pages-bus/picker/index.js   # 搜索页
├── pages-bus/station/detail.js # 站点详情
├── pages-bus/station/map.js
├── pages-common/routePlan/routePlanDetail/index.js
└── pages/index/index.js        # 首页（附近站点）
```

用 jadx 只能反出壳工程，真正的逻辑在 JS 里，因此直接用 Python 对
`app-service.js` / 各页面 js 做文本分析即可。

## 4. 接口地址

### 4.1 网关与租户

从 `app-service.js` 的配置对象中直接拿到（`Co`）：

```js
VITE_TITLE: "郴州公交行",
VITE_BASE_API: "http://211.143.37.50:30618",
VITE_BUS_API: "http://211.143.37.50:30618",
VITE_TENANT_ID: "zh00002",
VITE_BUS_TENANT_ID: "zh00002",
VITE_TENANT_CODE: "czgj",
VITE_CITY_ADCODE: "431000",     // 郴州市
```

```js
var ut = "http://211.143.37.50:30618";
var Fe = "zh00002";
```

请求路径前缀：

```js
Oe = "/api-mygo/{TenantId}/api"
```

### 4.2 公交相关接口清单

在 `pages-bus/route/detail.js` 等文件中可直接看到 API 封装（变量名 `Yt`）：

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `getRoutes` | `POST /routesV2` | 全部线路 |
| `searchRoutes` | `POST /SearchRoutes` | 某线路某方向的站点列表 |
| `routePoint` | `POST /RoutePoint` | 线路走向点 |
| `routeWork` | `POST /RouteWorkV2` | 关键字搜索（线路/站点/地标） |
| `routeStationVehicles` | `POST /routeStationVehicles` | 线路上的实时车辆 |
| `nearbyStations` | `POST /nearbyStations` | 附近站点及其线路、实时车辆 |
| `peakTimetable` | `POST /peakTimetable` | 发车时刻表 |
| `pointTravelScheme` | `POST /PointTravelScheme` | 点位出行方案 |
| `stationRouteVehicle` | `POST /stationRouteVehicle` | 站点详情（在 `pages-bus/station/detail.js`） |

另外在 `app-service.js` 里还有 `POST /api-mygo/{TenantId}/v1/api/appUse`
（客户端使用统计上报）与 `/v1/api/appInstall`，与查询无关。

## 5. 请求格式

### 5.1 请求体

所有公交接口都是 POST + JSON。客户端用 `ue()` 统一封装：

```js
ue = e => {
  let t = {};
  let i = m.getValue("phone");
  i && (t.Token = i);
  let n = m.getValue("app_city");
  let a = (n?.tenants || []).find(r => r.bisType === "1");
  a && a.additionalJson && (t.accessParam = JSON.parse(a.additionalJson));
  e && (t.Data = e);
  return t;
}
```

再由 axios 拦截器补上：

```js
e.data.appVersion = "2.5.0";
```

因此实际请求体形如：

```json
{
  "Token": "15211774480",
  "appVersion": "2.5.0",
  "Data": { "...具体参数..." }
}
```

`Token` 为登录用户手机号；未登录时客户端不发送该字段，实测**不登录也能拿到
完整数据**。`accessParam` 来自城市配置的 `additionalJson`，郴州为
`""`（空），故实际也不会出现。

### 5.2 请求头

```js
e.headers["content-type"] = "application/json;charset=utf-8";
e.headers["X-maas-TenantId"] = Fe;          // zh00002
e.headers.TimeZone = new Date().getTimezoneOffset();   // 中国为 -480
e.headers["Login-Client-Type"] = "Mini-APP";
e.headers["Accept-Language"] = "zh-CN";
// 有登录态时: e.headers.Authorization = "Bearer " + token
```

抓包实测（见第 8 节）请求头完全一致，额外还有 `Form-type: app`。

### 5.3 响应体

```json
{ "State": 0, "Info": "success", "Result": ... }
```

`State != 0` 表示失败。**注意**：搜索接口 `/RouteWorkV2` 在服务端负载较高时
会偶发返回 `{"State": 500, "Info": "failure"}`，客户端没有重试，需要自行处理。

## 6. 各接口的参数与返回

### 6.1 `POST /routesV2`

`Data` 为空。返回：

```json
[{"routeCode": "30000002", "routeName": "1路", "fstName": "长冲铺",
  "lstName": "兴义粮油市场", "minTicketPrice": 20, "maxTicketPrice": 20}]
```

共 191 条线路（每条线路的去/返程由 `routeCode` + `upDown` 区分）。

### 6.2 `POST /SearchRoutes`

```json
{ "Rid": "20000002", "UpDown": 0 }
```

`UpDown`：`0` 去程、`1` 返程。返回：

```json
{"Rname": "2路",
 "Stations": [{"StaId": "...", "StaNO": 1, "StaLat": 25.862932,
               "StaLng": 113.035157, "StaName": "长冲铺",
               "StaDis": 1912, "StaHrt": null}]}
```

`StaNO` 从 1 开始，即站序。

### 6.3 `POST /routeStationVehicles` —— 实时车辆

```json
{"beforeInStation": 1, "num": 999,
 "routeStation": [{"routeCode": "20000002", "upDown": 0, "staNO": 30}]}
```

- `beforeInStation` 必须 >= 1，传 0 返回空数组。
- `staNO` 可选；传了才会计算 `dest*` 字段。
- `num` 为返回车辆数上限。

返回：

```json
[{"routeCode": "20000002", "upDown": 0, "routeName": "2路",
  "fstName": "长冲铺", "lstName": "首末站5",
  "fdTime": "06:40", "ldTime": "21:54", "nextTime": "21:54",
  "minTicketPrice": 20, "maxTicketPrice": 20,
  "vehicles": [
    {"plateNum": "湘LA0037", "onlineNo": "18975571524",
     "inOut": 0, "staIndex": 38,
     "lat": 25.768712, "lng": 113.006157,
     "nextStaName": "首末站5", "congLeve": 1,
     "destNum": 1, "destDistance": 524, "destRunTime": 2,
     "arriveText": "2分钟", "distanceText": "1站/524米"}]}]
```

**字段语义**（从客户端 `pages-bus/route/detail.js` 推断确认）：

- `staIndex` —— 车辆当前所在（或刚离开）的站点序号。
- `inOut` —— `0` 表示车辆正停靠在该站（已到站），`1` 表示车辆已驶离该站、
  正开往下一站。
- `nextStaName` —— 车辆正在前往的下一站，即序号 `staIndex + 1` 的站。
- `destNum` / `destDistance` / `destRunTime` / `arriveText` / `distanceText`
  —— 相对**请求中传入的 `staNO`** 计算：还剩几站、还有多少米、还有多少分钟、
  以及展示用的文案。只有尚未经过目标站的车才有值，已经开过目标站的车为 null。
- `congLeve` —— 拥堵等级，1 畅通 / 2 缓行 / 3 拥堵。

客户端判定「到达某站」的方式（`stationLinePanel.js`）：

```js
stationVehicles[StaNO].filter(v => v.inOut === 0)   // 已到达本站
stationVehicles[StaNO - 1].filter(v => v.inOut === 1) // 正开往本站
```

### 6.4 `POST /RouteWorkV2` —— 搜索

```json
{ "Content": "火车站" }
```

返回 `Result.result[]`，`type` 含义：

- `0` 线路：`{rid, upDown, name, fstName, lstName}`
- `1` 公交站点：`{staId, name, lat, lng}`
- `2` 地标：`{name, lat, lng}`

同一线路的去程与返程会分别返回（`upDown` 0/1）。

### 6.5 `POST /nearbyStations` —— 附近站点

```json
{ "Lat": 25.747064431574895, "Lng": 112.98552284017872, "Range": 500 }
```

返回：

```json
[{"name": "香麓山花园", "staId": "89_25.74962_112.98008",
  "distance": 53,
  "staList": [{"id": "89_25.75047_112.98108", "name": "香麓山花园",
               "lat": 25.7504667, "lng": 112.9810833}],
  "stationRoutes": [{"routeCode": "...", "upDown": 0, "routeName": "29路",
                     "fstName": "...", "lstName": "...",
                     "fdTime": "06:22", "ldTime": "22:15", "nextTime": "21:55",
                     "vehicles": [ ... 同上结构 ... ]}]}]
```

- 站台 `id` 有两种格式：雪花 id（`1867135268973129802`）或
  `序号_纬度_经度`（`89_25.74962_112.98008`）。
- `stationRoutes[].vehicles[].dest*` 是**相对该站点**计算的，已经非常有用了：
  `arriveText` 就是「还有几分钟到站」，`distanceText` 是「几站/多少米」。

### 6.6 `POST /stationRouteVehicle` —— 站点详情

```json
{ "Lat": 25.747064431574895, "Lng": 112.98552284017872,
  "staId": "89_25.74962_112.98008",
  "staIdList": ["89_25.75047_112.98108", "..."] }
```

> `staIdList` 必须是 **JSON 数组**，传逗号分隔字符串会报 Jackson 反序列化错误。

返回 `{name, staId, distance, staList, stationRoutes}`，与 `nearbyStations`
的单个元素结构一致。

### 6.7 `POST /peakTimetable` —— 时刻表

```json
{ "Rid": "20000002", "UpDown": 0 }
```

返回：

```json
[{"startTime": "05:30", "endTime": "23:30", "Rid": 20000002, "UpDown": 0,
  "TypeName": "平峰",
  "DepartTimeList": ["06:40", "06:48", ...]}]
```

### 6.8 `POST /RoutePoint` —— 线路走向

```json
{ "Rid": "20000002", "UpDown": 0 }
```

返回 `{routeCode, upDown, modifyTime, points: [{lat, lng}, ...]}`（约 400 点）。

## 7. 坐标系（重点）

客户端内嵌了一个 `common/lib/GpsTransformer.js`，坐标处理如下：

- **服务端返回的坐标一律是 WGS-84**。
- 客户端对返回的站点/车辆坐标调用 `gcj_encrypt(lat, lng)` 转成 **GCJ-02**，
  再交给高德地图显示。
- `nearbyStations` / `stationRouteVehicle` 的**入参** `Lat`/`Lng` 是
  **GCJ-02**（来自 `uni.getLocation`）。

这个「入参 GCJ-02、返回 WGS-84」的组合一开始很难看出来：直接把返回坐标和
入参做球面距离计算会差 500~700 米。

验证方法：用客户端自己发的请求做基准。

```bash
adb reverse tcp:8888 tcp:8888
adb shell settings put global http_proxy 127.0.0.1:8888
```

客户端请求体：

```json
{"Token":"15211774480","Data":{"Lat":25.747064431574895,
 "Lng":112.98552284017872,"Range":500},"phone":"15211774480","appVersion":"2.5.0"}
```

响应中「香麓山花园」的 `distance` 为 53，其站台坐标为
`(25.7504667, 112.9810833)`。把**入参**做 `gcj_decrypt` 得到
`(25.7500965, 112.9801223)`（WGS-84），再与站台坐标算距离：

```
平台1: 105m   平台2: 95m   平台3: 53m  <-- 与 distance 完全吻合
平台4: 76m
```

结论成立：**服务端把入参当作 GCJ-02，内部转成 WGS-84 后再算距离**，而返回的
站台坐标是 WGS-84。

因此本项目对外统一暴露 GCJ-02（与客户端显示一致、可直接用于高德/腾讯地图），
并同时保留 `wgs_lat`/`wgs_lon` 原始值。

`gcj_encrypt` / `gcj_decrypt` 的实现见 `chenzhou_bus/coords.py`，与客户端
`GpsTransformer.js` 逐行对应（含 `isSpArea` 特殊区域判断）。

## 8. 抓包确认

客户端走的是**明文 HTTP**，用最简单的反向代理即可抓包，无需证书注入。

```python
# proxy.py —— 原样转发并记录
class Handler(http.server.BaseHTTPRequestHandler):
    def _handle(self):
        # 记录 method / url / headers / body，再转发到真实服务器
```

实测抓到的请求头：

```
Authorization: Bearer MTUyMTE3NzQ0ODB8emgwMDAwMnwyMDI2LTEwLTA1IDEzOjQ1OjE1
X-maas-TenantId: zh00002
TimeZone: -480
Form-type: app
Login-Client-Type: Mini-APP
Accept-Language: zh-CN
Content-Type: application/json;charset=utf-8
```

抓包时还发现了两个仅在运行时出现的接口：

- `POST /api-mygo/zh00002/v1/api/appUse` —— 上报使用情况（带 imei 等设备信息）。
- `POST /api-mygo/zh00002/api/stationRouteVehicle` —— 站点详情（静态 js 中也有）。

> 注意：抓包代理会让客户端的所有 HTTP 流量都走本机，抓完记得
> `adb shell settings put global http_proxy :0` 关闭。

## 9. 接口实测结论

- 所有查询接口**无需登录**即可返回完整数据（`Token` 可省略）。
- `/RouteWorkV2` 搜索接口不稳定，会返回 `{"State":500,"Info":"failure"}`，
  客户端无重试，调用方需要自行重试。
- 实时车辆数据随时间滚动更新（同一辆车 `staIndex` 每次请求都会前进）。
- 非运营时段（如 1 路 `ldTime` 为 16:40）返回 `vehicles: null`。
