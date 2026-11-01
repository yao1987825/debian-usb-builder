import base64
import json
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .common import QR_H5, SDP_APP_ID, SSO_HOST, UC_GATEWAY, UC_HEADERS, build_device_id, make_session
from . import config


class LoginError(Exception):
    pass


def create_uc_session(sess, max_attempts: int = 40, workers: int = 4) -> dict:
    last_error = None
    deadline = time.time() + max_attempts * 3
    attempt = 0
    while time.time() < deadline:
        attempt += 1
        results = []
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(_create_session_once) for _ in range(workers)]
            for future in futures:
                try:
                    results.append(future.result())
                except Exception as e:
                    results.append((None, None, str(e), None))
        for status, body, error, cookies in results:
            if status in (200, 201) and isinstance(body, dict) and body.get("session_id"):
                print(
                    f"创建会话成功（第 {attempt} 轮尝试，共 {attempt * workers} 次请求）",
                    file=sys.stderr,
                )
                if cookies:
                    sess.cookies.update(cookies)
                device_id = body.pop("__device_id", "")
                config.save_session(device_id, body, sess.cookies.get_dict())
                body["__device_id"] = device_id
                return body
            if error:
                last_error = error
            elif status is not None:
                last_error = _short_error(status, body)
        print(
            f"创建会话被拒（第 {attempt}/{max_attempts} 轮，服务端偶发 UC/INVALID_DEVICE_ID）: {last_error}",
            file=sys.stderr,
        )
        time.sleep(1.0)
    raise LoginError(
        f"创建会话失败（{max_attempts} 轮尝试）：{last_error}\n"
        f"提示：网关接口不稳定时可稍后重试，或用 tch login --token <access_token> 手动导入"
    )


def _short_error(status, body) -> str:
    if isinstance(body, dict):
        body = json.dumps(body, ensure_ascii=False)
    text = str(body)
    match = re.search(r'"code"\s*:\s*"([^"]+)"', text)
    if match:
        return f"HTTP {status} {match.group(1)}"
    return f"HTTP {status} {text[:80]}"


def _create_session_once() -> tuple:
    device_id = build_device_id()
    sess = make_session()
    try:
        resp = sess.post(
            f"{UC_GATEWAY}/v1.1/sessions",
            headers=UC_HEADERS,
            json={"device_id": device_id},
            timeout=20,
        )
    except Exception as e:
        return None, None, f"连接失败: {e}", None
    cookies = sess.cookies.get_dict()
    if resp.status_code in (200, 201):
        try:
            body = resp.json()
        except ValueError:
            return resp.status_code, {"raw": resp.text[:160]}, None, cookies
        body["__device_id"] = device_id
        return resp.status_code, body, None, cookies
    return resp.status_code, resp.text[:160], None, cookies


def get_or_create_session(sess) -> dict:
    cached = config.load_session()
    if cached:
        sess.cookies.update(cached.get("cookies") or {})
        session = {
            "session_id": cached["session_id"],
            "session_key": cached.get("session_key", ""),
            "device_id": cached.get("device_id", ""),
        }
        try:
            create_qr_ticket(sess, session["session_id"])
            print("复用近期会话", file=sys.stderr)
            return session
        except LoginError:
            config.clear_session()
            sess.cookies.clear()
    session = create_uc_session(sess)
    return {
        "session_id": session["session_id"],
        "session_key": session.get("session_key", ""),
        "device_id": session.get("__device_id", ""),
    }


def create_qr_ticket(sess, session_id: str) -> dict:
    for payload in ({}, {"session_id": session_id}, None):
        kwargs = {"json": payload} if payload is not None else {}
        resp = sess.post(
            f"{UC_GATEWAY}/v1.1/qr_tickets",
            headers=UC_HEADERS,
            timeout=20,
            **kwargs,
        )
        if resp.status_code == 200:
            body = resp.json()
            if body.get("ticket"):
                return body
            raise LoginError(f"二维码票据响应异常: {body}")
        if resp.status_code >= 500:
            continue
    raise LoginError(f"获取二维码失败: HTTP {resp.status_code}: {resp.text[:200]}")


def poll_status(sess, ticket: str, session_id: str) -> dict:
    resp = sess.get(
        f"{SSO_HOST}/v1.1/qr_tickets/{ticket}/sessions/{session_id}/status_info",
        headers=UC_HEADERS,
        timeout=20,
    )
    if resp.status_code != 200:
        try:
            body = resp.json()
        except ValueError:
            body = {"raw": resp.text[:200]}
        return {"error": True, "http_status": resp.status_code, "body": body}
    try:
        body = resp.json()
    except ValueError:
        return {"error": True, "http_status": resp.status_code, "body": resp.text[:200]}
    for _ in range(3):
        if isinstance(body, str):
            try:
                body = json.loads(body)
            except ValueError:
                break
        else:
            break
    if isinstance(body, dict):
        return body
    return {"error": True, "http_status": resp.status_code, "body": body}


def des_decrypt(cipher_b64: str, key: str) -> str | None:
    try:
        from Cryptodome.Cipher import DES
        from Cryptodome.Util.Padding import unpad
    except ImportError:
        try:
            from Crypto.Cipher import DES
            from Crypto.Util.Padding import unpad
        except ImportError:
            return None
    try:
        raw = base64.b64decode(cipher_b64)
    except Exception:
        return None
    key_bytes = key.encode("utf-8")
    variants = []
    if len(key_bytes) >= 8:
        variants.append(key_bytes[:8])
    if len(key_bytes) < 8:
        variants.append(key_bytes.ljust(8, b"\0"))
    if len(key_bytes) > 8:
        variants.append(key_bytes.ljust(8, b"\0")[:8])
    for candidate in variants:
        try:
            plain = DES.new(candidate, DES.MODE_ECB).decrypt(raw)
            return unpad(plain, 8).decode("utf-8")
        except Exception:
            continue
    return None


def decrypt_token_fields(token: dict, session_key: str) -> dict:
    for field in ("account_id", "user_id", "mac_key"):
        value = token.get(field)
        if not isinstance(value, str) or not value:
            continue
        if field != "mac_key" and value.isdigit():
            continue
        decrypted = des_decrypt(value, session_key)
        if decrypted is not None:
            token[field] = decrypted
    return token


def render_qr(text: str) -> None:
    try:
        import qrcode

        qr = qrcode.QRCode(border=1)
        qr.add_data(text)
        qr.make(fit=True)
        qr.print_ascii(sys.stdout, invert=True)
        print()
    except Exception:
        try:
            import qrcode
            from pathlib import Path
            import tempfile

            img = qrcode.make(text)
            path = Path(tempfile.gettempdir()) / "tchMaterial-parser-login-qr.png"
            img.save(path)
            print(f"终端渲染二维码失败，已保存图片: {path}")
        except Exception as e:
            raise LoginError(f"无法生成二维码: {e}")


def login(timeout: int = 300, quiet: bool = False) -> dict:
    sess = make_session()
    session = get_or_create_session(sess)
    session_id = session["session_id"]
    session_key = session.get("session_key", "")

    ticket_info = create_qr_ticket(sess, session_id)
    ticket = ticket_info["ticket"]
    qr_url = f"{QR_H5}?ticket={ticket}"

    if not quiet:
        print("请使用智慧教育平台 App 或已登录的手机扫码：\n", flush=True)
        render_qr(qr_url)
        print(f"\n二维码地址: {qr_url}")
        print(f"等待扫码（最多 {timeout} 秒，Ctrl+C 取消）...", flush=True)

    deadline = time.time() + timeout
    expire_at = ticket_info.get("expire_at")
    if isinstance(expire_at, (int, float)):
        if expire_at > 1e12:
            expire_at /= 1000.0
        elif expire_at < 1e6:
            expire_at = None
        if expire_at:
            deadline = min(deadline, float(expire_at))

    while time.time() < deadline:
        time.sleep(1)
        try:
            status_body = poll_status(sess, ticket, session_id)
        except Exception as e:
            print(f"轮询出错，重试中: {e}", file=sys.stderr)
            continue

        if status_body.get("error"):
            code = (status_body.get("body") or {}).get("code", "")
            if code == "UC/INVALID_TICKET":
                raise LoginError("二维码已过期，请重新运行 login")
            if code == "UCSDK/SESSION_ERROR":
                session = create_uc_session(sess)
                session_id = session["session_id"]
                session_key = session.get("session_key", "")
                continue
            print(f"轮询返回异常: {status_body}", file=sys.stderr)
            continue

        status = status_body.get("status")
        data = status_body.get("data")

        if status in (0, 1):
            continue
        if status == 3:
            raise LoginError("用户拒绝授权，登录取消")
        if status in (2, 4):
            if not isinstance(data, dict) or not data.get("access_token"):
                raise LoginError(f"扫码状态返回 {status} 但未获得有效 token: {data}")
            token = decrypt_token_fields(data, session_key)
            path = config.save_token(token)
            return token, path
        raise LoginError(f"未知扫码状态: {status_body}")

    raise LoginError(f"等待扫码超时（{timeout} 秒）")


def des_encrypt(text: str, key: str) -> str:
    try:
        from Cryptodome.Cipher import DES
        from Cryptodome.Util.Padding import pad
    except ImportError:
        try:
            from Crypto.Cipher import DES
            from Crypto.Util.Padding import pad
        except ImportError:
            raise LoginError("缺少 pycryptodomex 依赖")
    raw = DES.new(key.encode("utf-8"), DES.MODE_ECB).encrypt(pad(text.encode("utf-8"), 8))
    return base64.b64encode(raw).decode("ascii")


def guest_login(sess=None) -> tuple[dict, Path]:
    sess = sess or make_session()
    for attempt in (1, 2):
        session = get_or_create_session(sess)
        session_id = session["session_id"]
        session_key = session.get("session_key", "")
        device_id = session.get("device_id", "")
        if not device_id or not session_key:
            raise LoginError("缺少 device_id / session_key，无法游客登录")

        resp = sess.post(
            f"{UC_GATEWAY}/v1.1/guest_tokens",
            headers=UC_HEADERS,
            json={"session_id": session_id, "device_id": des_encrypt(device_id, session_key)},
            timeout=20,
        )
        if resp.status_code in (200, 201):
            body = resp.json()
            token = body.get("access_token")
            if not token:
                raise LoginError(f"游客登录响应缺少 access_token: {body}")
            token = decrypt_token_fields(body, session_key)
            token.setdefault("account_type", "guest")
            token["guest"] = True
            path = config.save_token(token)
            return token, path
        if attempt == 1:
            config.clear_session()
            sess.cookies.clear()
            print("游客登录被拒，重建会话后重试...", file=sys.stderr)
            continue
        raise LoginError(f"游客登录失败: HTTP {resp.status_code}: {resp.text[:200]}")
    raise LoginError("游客登录失败")


def refresh_token(token: dict) -> dict | None:
    refresh = token.get("refresh_token")
    if not refresh:
        return None
    sess = make_session()
    try:
        resp = sess.post(
            f"{UC_GATEWAY}/v1.1/tokens/{refresh}/actions/refresh",
            headers=UC_HEADERS,
            json={"sdp_app_id": SDP_APP_ID},
            timeout=20,
        )
    except Exception:
        return None
    if resp.status_code not in (200, 201):
        return None
    try:
        body = resp.json()
    except ValueError:
        return None
    if not body.get("access_token"):
        return None
    body.setdefault("refresh_token", refresh)
    body.setdefault("saved_at", int(time.time()))
    config.save_token(body)
    return body


def import_token(access_token: str) -> tuple[dict, Path]:
    access_token = access_token.strip()
    if not access_token:
        raise LoginError("token 为空")
    token = {"access_token": access_token, "source": "manual"}
    probe = probe_token(token)
    if probe == "invalid":
        raise LoginError("token 无效或已过期，请重新获取")
    path = config.save_token(token)
    return token, path


def probe_token(token: dict) -> str:
    sess = make_session()
    headers = {
        "X-ND-AUTH": f'MAC id="{token["access_token"]}",nonce="0",mac="0"',
        "Range": "bytes=0-1",
    }
    probe_url = (
        "https://r1-ndr-private.ykt.cbern.com.cn/edu_product/esp/assets/"
        "bdc00134-465d-454b-a541-dcd0cec4d86e.pkg/"
        "9787107382369_义务教育教科书•道德与法治_一年级_上册_人民教育出版社三科办_1787020693303.pdf"
    )
    try:
        resp = sess.get(probe_url, headers=headers, stream=True, timeout=30)
        resp.close()
    except Exception as e:
        return f"unknown:{e}"
    if resp.status_code in (200, 206, 302):
        return "valid"
    if resp.status_code in (401, 403):
        return "invalid"
    return f"unknown:{resp.status_code}"
