import json
import os
import sys
import time
from pathlib import Path

APP_NAME = "tchMaterial-parser"


def config_dir() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    elif os.name == "nt":
        base = Path(os.environ.get("APPDATA", Path.home()))
    else:
        base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    path = base / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def cache_dir() -> Path:
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Caches"
    elif os.name == "nt":
        base = Path(os.environ.get("LOCALAPPDATA", config_dir()))
    else:
        base = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    path = base / APP_NAME
    path.mkdir(parents=True, exist_ok=True)
    return path


def token_file() -> Path:
    return config_dir() / "data.json"


def load_token() -> dict | None:
    path = token_file()
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if isinstance(data, dict) and data.get("access_token"):
        return data
    return None


def save_token(token: dict) -> Path:
    path = token_file()
    data = dict(token)
    data.setdefault("saved_at", int(time.time()))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=4)
    os.chmod(path, 0o600)
    return path


def clear_token() -> bool:
    path = token_file()
    if path.exists():
        path.unlink()
        return True
    return False


def auth_header(token: dict | None = None) -> dict:
    token = token or load_token()
    if not token:
        return {}
    return {"X-ND-AUTH": f'MAC id="{token["access_token"]}",nonce="0",mac="0"'}


def token_age(token: dict | None = None) -> int | None:
    token = token or load_token()
    if not token or not token.get("saved_at"):
        return None
    return int(time.time()) - int(token["saved_at"])


SESSION_MAX_AGE = 900


def session_file() -> Path:
    return config_dir() / "session.json"


def load_session() -> dict | None:
    path = session_file()
    if not path.exists():
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    created = data.get("created_at", 0)
    if int(time.time()) - int(created) > SESSION_MAX_AGE:
        return None
    if not data.get("session_id"):
        return None
    return data


def save_session(device_id: str, session: dict, cookies: dict) -> Path:
    path = session_file()
    data = {
        "device_id": device_id,
        "session_id": session["session_id"],
        "session_key": session.get("session_key", ""),
        "cookies": cookies,
        "created_at": int(time.time()),
    }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.chmod(path, 0o600)
    return path


def clear_session() -> bool:
    path = session_file()
    if path.exists():
        path.unlink()
        return True
    return False
