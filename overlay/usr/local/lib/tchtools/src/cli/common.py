import base64
import hashlib
import uuid

import requests

CONFUSE = "£¬¡£fdjf,jkgfkl"
SDP_APP_ID = "e5649925-441d-4a53-b525-51a2f1c4e0a8"
UC_GATEWAY = "https://uc-gateway.ykt.eduyun.cn"
SSO_HOST = "https://sso.basic.smartedu.cn"
QR_H5 = "https://uc-h5.ykt.eduyun.cn/uc11/qrcode-login/index.html"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

FILE_HOST = "https://s-file-1.ykt.cbern.com.cn"
FILE_HOST_2 = "https://s-file-2.ykt.cbern.com.cn"
PRIVATE_CDN = "https://r1-ndr-private.ykt.cbern.com.cn"

TAG_URL = f"{FILE_HOST}/zxx/ndrs/tags/tch_material_tag.json"
TCH_VERSION_URL = f"{FILE_HOST}/zxx/ndrs/resources/tch_material/version/data_version.json"
TCH_DETAIL_URL = f"{FILE_HOST}/zxx/ndrv2/resources/tch_material/details/{{content_id}}.json"
SPECIAL_DETAIL_URL = f"{FILE_HOST}/zxx/ndrs/special_edu/resources/details/{{content_id}}.json"
SPECIAL_LIST_URL = f"{FILE_HOST}/zxx/ndrs/special_edu/thematic_course/{{content_id}}/resources/list.json"
EBOOK_TREE_URL = f"{FILE_HOST}/zxx/ndrv2/national_lesson/trees/{{ebook_id}}.json"

UC_HEADERS = {
    "Accept": "application/json, text/plain, */*",
    "Content-Type": "application/json",
    "SDP-APP-ID": SDP_APP_ID,
    "User-Agent": UA,
    "Origin": "https://auth.smartedu.cn",
    "Referer": "https://auth.smartedu.cn/uias/login",
}


def make_session() -> requests.Session:
    sess = requests.Session()
    sess.trust_env = False
    sess.proxies = {}
    sess.headers.update({"User-Agent": UA})
    return sess


def build_device_id() -> str:
    rest = f"Linux/Chrome148/{uuid.uuid4()}"
    digest_hex = hashlib.md5((rest + CONFUSE).encode("utf-8")).hexdigest()
    check_char = base64.b64encode(digest_hex.encode("ascii")).decode("ascii")[2]
    return f"{check_char}w{rest}"


def fmt_bytes(size: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if size < 1024.0:
            return f"{size:.1f} {unit}"
        size /= 1024.0
    return f"{size:.1f} PB"


def sanitize_filename(name: str) -> str:
    for ch in '\\/:*?"<>|\r\n\t':
        name = name.replace(ch, " ")
    name = " ".join(name.split()).strip(" .")
    return name or "download"
