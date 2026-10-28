"""netkit.devclass —— 把 MAC/主机名/端口线索翻译成"这是什么东西"。

判定依据有三层, 越靠前越可信:
1. **角色线索**: 是不是默认网关 / LLDP 里是不是交换机路由器(最准);
2. **服务线索**: 开了 445 的像 NAS, 开了 9100 的像打印机, 开了 62078 的像 iPhone;
3. **厂商线索**: MAC 的 OUI(前 3 字节)查内置小表。

OUI 表是**离线内置**的一小张(常见家用/商用设备), 不是完整库 ——
完整库几十 MB, 对 U 盘系统不划算。查不到的厂商显示成 "未知厂商"。
真实厂商可以在报告里用 `net topo --oui` 去在线查。
"""

from __future__ import annotations

from . import util

# MAC 前 3 字节 -> 厂商。只收常见品牌, 够认设备类型。
OUI = {
    "00:02:1d": "Hewlett Packard",
    "00:03:8a": "Sun",
    "00:03:93": "Apple",
    "00:04:4c": "Realtek",
    "00:04:4f": "Sonos",
    "00:04:7f": "Hewlett Packard",
    "00:07:ab": "Samsung",
    "00:08:74": "Sun",
    "00:08:9a": "QNAP",
    "00:08:9b": "Synology",
    "00:0a:95": "SUN",
    "00:0b:57": "Signify(飞利浦Hue)",
    "00:0c:29": "VMware",
    "00:0e:58": "Sonos",
    "00:0f:b0": "Netgear",
    "00:11:32": "Synology",
    "00:11:42": "AVM(FRITZ!)",
    "00:13:01": "AzureWave",
    "00:14:6c": "Netgear",
    "00:14:a5": "Hewlett Packard",
    "00:15:0d": "AVM(FRITZ!)",
    "00:15:5d": "Microsoft",
    "00:16:0d": "Hewlett Packard",
    "00:16:32": "Samsung",
    "00:16:3e": "Xen",
    "00:16:6c": "Samsung",
    "00:17:88": "Signify(飞利浦Hue)",
    "00:17:9e": "D-Link",
    "00:18:0a": "D-Link",
    "00:1a:11": "Google",
    "00:1a:2b": "Ayecom",
    "00:1a:4b": "AVM(FRITZ!)",
    "00:1a:4d": "Synology",
    "00:1b:63": "Apple",
    "00:1b:78": "Hewlett Packard",
    "00:1b:9c": "Hewlett Packard",
    "00:1b:9d": "Hewlett Packard",
    "00:1c:14": "VMware",
    "00:1c:42": "Parallels",
    "00:1c:b3": "Apple",
    "00:1c:bf": "AzureWave",
    "00:1d:08": "LG",
    "00:1d:0f": "TP-Link",
    "00:1e:0b": "Hewlett Packard",
    "00:1e:4f": "Hewlett Packard",
    "00:1e:58": "D-Link",
    "00:1e:68": "Apple",
    "00:1e:75": "Samsung",
    "00:1e:9e": "Huawei",
    "00:1f:1f": "D-Link",
    "00:1f:33": "Netgear",
    "00:22:48": "Microsoft",
    "00:23:9d": "Hewlett Packard",
    "00:24:01": "D-Link",
    "00:25:00": "Apple",
    "00:26:5a": "D-Link",
    "00:26:9e": "Hewlett Packard",
    "00:26:cc": "AzureWave",
    "00:26:f2": "Netgear",
    "00:50:56": "VMware",
    "00:80:63": "Hewlett Packard",
    "00:80:77": "Hewlett Packard",
    "00:80:f0": "Panasonic",
    "00:e0:4c": "Realtek",
    "04:4b:8a": "Xiaomi",
    "04:bd:3b": "Xiaomi",
    "04:c1:3c": "Huawei",
    "04:cf:8c": "Xiaomi",
    "04:f9:f8": "Huawei",
    "08:00:27": "VirtualBox",
    "0a:00:27": "Microsoft Hyper-V",
    "0c:1c:bf": "Xiaomi",
    "0c:29:fb": "Hewlett Packard",
    "0c:37:dc": "Huawei",
    "0c:59:9c": "Zyxel",
    "0c:80:63": "TP-Link",
    "0c:e0:e4": "Huawei",
    "10:7f:9b": "Hewlett Packard",
    "10:c6:1e": "Huawei",
    "10:ce:2e": "Xiaomi",
    "14:7d:da": "Xiaomi",
    "18:52:2c": "Hewlett Packard",
    "18:b4:30": "Nest Labs",
    "1c:28:ea": "Huawei",
    "1c:33:28": "Huawei",
    "1c:61:b4": "TP-Link",
    "1c:af:f7": "D-Link",
    "20:4e:7f": "Netgear",
    "24:0a:c4": "Xiaomi",
    "24:5a:4c": "Synology",
    "24:5e:be": "QNAP",
    "24:6f:28": "Espressif",
    "24:a4:3c": "Hewlett Packard",
    "24:b2:17": "Huawei",
    "24:da:39": "Xiaomi",
    "28:0f:fa": "Huawei",
    "28:6c:07": "Xiaomi",
    "2c:0d:b0": "AVM(FRITZ!)",
    "2c:30:33": "Netgear",
    "2c:cc:14": "Xiaomi",
    "2c:cd:9c": "Xiaomi",
    "2c:cf:67": "Raspberry Pi",
    "30:ae:a4": "Espressif",
    "34:78:6a": "Huawei",
    "34:85:18": "Xiaomi",
    "34:ce:00": "Xiaomi",
    "38:10:d5": "AVM(FRITZ!)",
    "38:5d:60": "Huawei",
    "3c:11:bf": "Huawei",
    "3c:15:c2": "Apple",
    "3c:1e:cc": "Xiaomi",
    "3c:37:86": "Netgear",
    "3c:52:a1": "TP-Link",
    "3c:61:05": "Espressif",
    "3c:71:bf": "Xiaomi",
    "3c:7c:3f": "Xiaomi",
    "3c:84:6a": "Xiaomi",
    "3c:d9:2b": "Hewlett Packard",
    "3c:e0:8b": "AVM(FRITZ!)",
    "3d:f2:cd": "Huawei",
    "3e:1a:bf": "Huawei",
    "40:4c:ca": "Huawei",
    "40:9f:38": "AzureWave",
    "44:19:b6": "Huawei",
    "44:22:70": "Xiaomi",
    "44:47:cc": "Huawei",
    "48:22:54": "AVM(FRITZ!)",
    "48:3f:da": "Huawei",
    "48:7c:2d": "Huawei",
    "48:8a:2a": "Xiaomi",
    "48:a6:b8": "Sonos",
    "48:ba:5e": "Hewlett Packard",
    "48:db:50": "Huawei",
    "4c:1f:cc": "Xiaomi",
    "50:06:1d": "Xiaomi",
    "50:54:ea": "Xiaomi",
    "50:8d:21": "Xiaomi",
    "50:c7:bf": "TP-Link",
    "50:ec:50": "Xiaomi",
    "52:54:00": "QEMU",
    "52:54:4f": "QEMU",
    "54:b8:2a": "Xiaomi",
    "54:ef:44": "Xiaomi",
    "54:ef:c7": "Xiaomi",
    "58:1f:4b": "Xiaomi",
    "58:2f:b6": "Hewlett Packard",
    "58:45:0f": "Xiaomi",
    "58:63:cf": "Huawei",
    "58:96:5a": "Xiaomi",
    "58:97:58": "Huawei",
    "58:bf:25": "Huawei",
    "5c:0a:5b": "Samsung",
    "5c:4d:bf": "Huawei",
    "5c:64:82": "Xiaomi",
    "5c:aa:fd": "Sonos",
    "5c:cd:5f": "Huawei",
    "5c:cf:7f": "Xiaomi",
    "5c:e9:1e": "Apple",
    "60:1d:bd": "Huawei",
    "60:4c:1d": "Huawei",
    "60:64:70": "Xiaomi",
    "60:7c:9e": "Xiaomi",
    "64:09:80": "Huawei",
    "64:6b:0b": "Xiaomi",
    "64:b4:73": "Xiaomi",
    "64:b6:7c": "Xiaomi",
    "68:54:fd": "Amazon",
    "68:64:7c": "Xiaomi",
    "6c:2b:59": "Espressif",
    "6c:3b:6b": "Xiaomi",
    "6c:5b:f8": "Hewlett Packard",
    "6c:ad:f8": "Amazon",
    "6c:b1:33": "Huawei",
    "6c:bb:3d": "Xiaomi",
    "70:66:66": "Xiaomi",
    "70:72:3c": "Huawei",
    "70:7c:03": "Xiaomi",
    "74:23:44": "Xiaomi",
    "74:27:1f": "Huawei",
    "74:83:c2": "Ubiquiti",
    "74:da:88": "AzureWave",
    "78:11:da": "Xiaomi",
    "78:11:dc": "Xiaomi",
    "78:21:84": "Espressif",
    "78:47:1d": "Samsung",
    "78:54:2e": "D-Link",
    "78:6b:2b": "Xiaomi",
    "78:8a:20": "Ubiquiti",
    "78:cb:8a": "Huawei",
    "7c:49:eb": "Xiaomi",
    "7c:a9:a3": "Xiaomi",
    "7c:df:a1": "Espressif",
    "80:45:56": "Huawei",
    "84:18:88": "Xiaomi",
    "84:2b:2b": "Xiaomi",
    "84:9c:8c": "Zyxel",
    "84:d1:69": "Huawei",
    "88:86:94": "Huawei",
    "8c:1f:64": "Xiaomi",
    "8c:3b:a0": "Espressif",
    "8c:85:90": "Apple",
    "8c:a2:aa": "Xiaomi",
    "8c:ab:8e": "Xiaomi",
    "8c:cd:e8": "Xiaomi",
    "8c:de:52": "Xiaomi",
    "8c:de:8a": "Xiaomi",
    "90:09:d0": "Synology",
    "90:53:22": "Huawei",
    "94:65:2d": "Huawei",
    "94:65:9d": "Hewlett Packard",
    "98:41:5c": "Xiaomi",
    "9c:3d:cf": "Netgear",
    "9c:53:22": "TP-Link",
    "9c:5c:8e": "Sonos",
    "9c:8e:cd": "Espressif",
    "9c:9d:7b": "Xiaomi",
    "9c:ae:db": "Huawei",
    "9c:b6:54": "Hewlett Packard",
    "a0:40:a0": "Netgear",
    "a0:86:c6": "Xiaomi",
    "a0:b1:4a": "Xiaomi",
    "a4:2b:b0": "TP-Link",
    "a4:56:33": "Huawei",
    "a4:5d:36": "Hewlett Packard",
    "a4:5e:60": "Apple",
    "a4:cf:12": "Espressif",
    "a8:20:a6": "Xiaomi",
    "ac:db:48": "Xiaomi",
    "b0:4e:26": "TP-Link",
    "b0:5f:94": "Hewlett Packard",
    "b0:71:5e": "Xiaomi",
    "b0:7f:46": "Netgear",
    "b0:d5:d8": "Huawei",
    "b0:e0:bd": "Xiaomi",
    "b0:e5:9c": "Huawei",
    "b4:1b:2b": "Huawei",
    "b4:2e:99": "Xiaomi",
    "b4:6f:33": "Xiaomi",
    "b4:b6:86": "Hewlett Packard",
    "b4:e6:2d": "Espressif",
    "b8:03:8b": "Huawei",
    "b8:27:35": "Hewlett Packard",
    "b8:27:eb": "Raspberry Pi",
    "b8:2a:72": "Hewlett Packard",
    "b8:2a:e6": "Xiaomi",
    "b8:32:75": "AVM(FRITZ!)",
    "b8:ce:6b": "Xiaomi",
    "b8:e8:56": "Apple",
    "bc:2c:6a": "Xiaomi",
    "bc:ad:28": "TP-Link",
    "c0:21:0d": "AVM(FRITZ!)",
    "c0:25:e9": "TP-Link",
    "c0:48:e7": "Huawei",
    "c0:ee:fb": "Xiaomi",
    "c4:2f:90": "Huawei",
    "c4:6a:92": "Xiaomi",
    "c8:0a:a6": "Xiaomi",
    "c8:bb:26": "Xiaomi",
    "cc:32:e5": "Xiaomi",
    "cc:9b:9c": "Huawei",
    "d0:3d:7c": "Xiaomi",
    "d0:76:8f": "Huawei",
    "d0:81:7a": "Apple",
    "d4:6a:a8": "Huawei",
    "d4:bd:90": "Xiaomi",
    "d8:63:96": "Xiaomi",
    "d8:9e:f3": "Xiaomi",
    "d8:a0:1d": "Espressif",
    "dc:14:4d": "Xiaomi",
    "dc:2c:26": "Xiaomi",
    "dc:2c:6e": "Xiaomi",
    "dc:a6:32": "Raspberry Pi",
    "dc:a9:04": "Apple",
    "e0:24:7f": "Huawei",
    "e0:63:da": "Ubiquiti",
    "e0:9c:33": "Huawei",
    "e0:9d:13": "Xiaomi",
    "e0:da:9c": "Huawei",
    "e4:2a:d2": "Huawei",
    "e4:5f:01": "Raspberry Pi",
    "e4:7d:8b": "Xiaomi",
    "e4:87:42": "Huawei",
    "e4:8d:8c": "TP-Link",
    "e4:e1:50": "Zyxel",
    "e4:f1:fb": "Huawei",
    "e4:fa:fc": "Xiaomi",
    "e8:33:4a": "AVM(FRITZ!)",
    "e8:50:8b": "Samsung",
    "e8:94:f6": "Xiaomi",
    "e8:9f:6d": "AzureWave",
    "ec:b5:fa": "Signify(飞利浦Hue)",
    "ec:fa:bc": "Apple",
    "f0:11:22": "Xiaomi",
    "f0:18:98": "Apple",
    "f0:27:2d": "Amazon",
    "f0:8d:ca": "Xiaomi",
    "f0:b4:29": "Xiaomi",
    "f4:5e:ab": "Xiaomi",
    "f4:9f:54": "Huawei",
    "f4:b4:6a": "Hewlett Packard",
    "f4:c1:13": "Huawei",
    "f8:a4:5f": "Xiaomi",
    "f8:e1:fb": "Huawei",
    "fc:65:de": "Amazon",
    "fc:ec:da": "Ubiquiti",
}

# 端口 -> 设备类型线索
PORT_HINTS = {
    22: ("SSH", "linux/服务器"),
    23: ("Telnet", "网络设备"),
    53: ("DNS", "DNS 服务器"),
    80: ("HTTP", "网页设备"),
    139: ("NetBIOS", "Windows/共享设备"),
    443: ("HTTPS", "网页设备"),
    445: ("SMB", "Windows/NAS"),
    515: ("LPD", "打印机"),
    554: ("RTSP", "摄像头/NVR"),
    631: ("IPP", "打印机"),
    1883: ("MQTT", "智能家居"),
    32400: ("Plex", "媒体服务器"),
    3389: ("RDP", "Windows 电脑"),
    5000: ("HTTP-alt", "摄像头/群晖"),
    8000: ("HTTP-alt", "摄像头/路由器"),
    8080: ("HTTP-alt", "路由器管理口/摄像头"),
    8443: ("HTTPS-alt", "路由器管理口"),
    9100: ("JetDirect", "打印机"),
    9200: ("Elasticsearch", "服务器"),
    32400: ("Plex", "媒体服务器"),
    5060: ("SIP", "VoIP"),
    62078: ("iPhoneSync", "iPhone"),
    6443: ("K8s API", "服务器"),
    27017: ("MongoDB", "服务器"),
    49152: ("Android-USB", "Android 手机"),
    49152: ("Android-USB", "Android 手机"),
}

# mDNS 服务类型 -> 设备类型
MDNS_HINTS = {
    "_ipp._tcp": "打印机",
    "_ipps._tcp": "打印机",
    "_printer._tcp": "打印机",
    "_pdl-datastream._tcp": "打印机",
    "_smb._tcp": "NAS/共享",
    "_afpovertcp._tcp": "Apple 设备",
    "_airplay._tcp": "AirPlay 音箱/电视",
    "_raop._tcp": "AirPlay 音箱",
    "_googlecast._tcp": "Chromecast",
    "_spotify-connect._tcp": "Spotify 音箱",
    "_workstation._tcp": "电脑",
    "_device-info._tcp": "设备",
    "_homekit._tcp": "HomeKit 设备",
    "_hap._tcp": "HomeKit 设备",
    "_axis-video._tcp": "摄像头",
    "_onvif._tcp": "摄像头",
    "_rtsp._tcp": "摄像头/NVR",
    "_mqtt._tcp": "智能家居网关",
    "_hue._tcp": "智能灯",
    "_esphomelib._tcp": "智能家居",
    "_companion-link._tcp": "设备",
}

# 主机名关键字 -> 设备类型
NAME_HINTS = [
    (("router", "gateway", "gw", "路由", "网关"), "路由器/网关"),
    (("switch", "sw-", "交换"), "交换机"),
    (("ap-", "accesspoint", "wap", "无线"), "无线接入点"),
    (("print", "printer", "hp-", "epson", "brother", "canon", "打印"), "打印机"),
    (("nas", "synology", "qnap", "diskstation", "storage"), "NAS"),
    (("cam", "hikvision", "dahua", "ezviz", "摄像头", "nvr", "dvr"), "摄像头/NVR"),
    (("tv", "smart-tv", "bravia", "mi-tv", "电视"), "电视"),
    (("iphone", "ipad", "macbook", "imac", "apple", "iphone"), "Apple 设备"),
    (("android", "phone", "pixel", "手机", "oneplus", "oppo", "vivo", "realme", "honor",
      "huawei", "xiaomi", "redmi", "galaxy", "samsung", "meizu", "zte", "nubia"), "手机"),
    (("watch", "手环", "band"), "穿戴设备"),
    (("server", "srv", "nas", "esxi", "proxmox"), "服务器"),
    (("pc", "desktop", "laptop", "workstation", "win", "thinkpad", "台式", "笔记本"), "电脑"),
    (("esp", "shelly", "sonoff", "tuya", "plug", "插座"), "智能家居设备"),
    (("chromecast", "fecast", "tv-", "客厅", "卧室"), "投屏/智能屏"),
]

KIND_ICON = {
    "路由器/网关": "🌐",
    "交换机": "🔀",
    "无线接入点": "📡",
    "打印机": "🖨",
    "NAS/共享": "🗄",
    "NAS": "🗄",
    "摄像头/NVR": "📷",
    "摄像头": "📷",
    "电视": "📺",
    "Apple 设备": "🍎",
    "手机": "📱",
    "电脑": "💻",
    "Windows 电脑": "💻",
    "服务器": "🖥",
    "智能家居设备": "🔌",
    "穿戴设备": "⌚",
    "投屏/智能屏": "📺",
    "unknown": "❓",
}


def oui_of(mac: str) -> str:
    """按 MAC 前 3 字节查厂商, 查不到返回空串。"""
    mac = util.normalize_mac(mac)
    if len(mac) < 8:
        return ""
    return OUI.get(mac[:8], "")


def kind_from_name(name: str) -> str:
    """主机名关键字 -> 设备类型。"""
    low = (name or "").lower()
    if not low:
        return ""
    for keys, kind in NAME_HINTS:
        for k in keys:
            if k in low:
                return kind
    return ""


def kind_from_ports(ports: list) -> str:
    """开放端口 -> 设备类型(取最像的那个)。"""
    if not ports:
        return ""
    kinds = []
    for p in ports:
        info = PORT_HINTS.get(int(p))
        if info:
            kinds.append(info[1])
    for want in ("打印机", "摄像头/NVR", "NAS/共享", "手机", "电脑", "路由器/网关", "智能家居"):
        if want in kinds:
            return want
    return kinds[0] if kinds else ""


def kind_from_mdns(services: list) -> str:
    """mDNS 服务类型 -> 设备类型。"""
    for svc in services or []:
        low = svc.lower()
        for key, kind in MDNS_HINTS.items():
            if key in low:
                return kind
    return ""


def classify(host: dict) -> dict:
    """综合所有线索给设备定型。

    host 里的字段: mac/hostname/services/ports/is_gateway/is_switch
    """
    mac = util.normalize_mac(host.get("mac", ""))
    vendor = oui_of(mac)
    name = host.get("hostname", "")
    services = host.get("services", []) or []
    ports = host.get("ports", []) or []

    kind = ""
    reason = ""

    if host.get("is_gateway"):
        kind, reason = "路由器/网关", "本机默认网关"
    if not kind and host.get("is_switch"):
        kind, reason = "交换机", "LLDP 邻居(交换机/路由器通告)"
    if not kind:
        k = kind_from_mdns(services)
        if k:
            kind, reason = k, f"mDNS 服务 {services[0]}"
    if not kind:
        k = kind_from_ports(ports)
        if k:
            kind, reason = k, "开放端口特征"
    if not kind:
        k = kind_from_name(name)
        if k:
            kind, reason = k, f"主机名 '{name}'"
    if not kind:
        if vendor in ("Ubiquiti", "H3C", "Ruijie", "Cisco", "TP-Link", "AVM(FRITZ!)", "Netgear"):
            kind, reason = "路由器/网关", f"厂商 {vendor}"
        elif vendor == "Raspberry Pi":
            kind, reason = "树莓派/单板机", "厂商 Raspberry Pi"
        elif vendor in ("Espressif",):
            kind, reason = "智能家居设备", "厂商 Espressif(乐鑫)"
    if not kind:
        kind = "unknown"

    # 厂商没查到时, 用主机名/服务再补一点信息
    if not vendor:
        blob = (name + " " + " ".join(services)).lower()
        for keys, v in (
            (("synology", "diskstation"), "Synology"),
            (("qnap",), "QNAP"),
            (("kwrt", "miwifi", "xiaomi", "redmi"), "Xiaomi"),
            (("huawei", "hilink"), "Huawei"),
            (("apple", "imac", "macbook", "iphone"), "Apple"),
            (("openwrt", "immortalwrt"), "OpenWrt"),
            (("iKuai", "ikuai"), "爱快"),
            (("ruijie", "h3c", "huawei-"), "H3C/锐捷"),
            (("esphome", "tasmota", "sonoff"), "ESPHome"),
            (("shelly",), "Shelly"),
        ):
            if any(k in blob for k in keys):
                vendor = v
                break

    return {
        "kind": kind,
        "vendor": vendor,
        "reason": reason,
        "icon": KIND_ICON.get(kind, "•"),
    }
