import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .common import TCH_VERSION_URL, TAG_URL, make_session
from . import config


def fetch_data_version(sess) -> dict:
    resp = sess.get(TCH_VERSION_URL, timeout=30)
    resp.raise_for_status()
    return resp.json()


def shard_urls(version_data: dict) -> list[str]:
    urls = version_data.get("urls", "")
    if isinstance(urls, str):
        urls = [u.strip() for u in urls.split(",") if u.strip()]
    return list(urls)


def _shard_cache_path(version_data: dict, url: str) -> Path:
    version = str(version_data.get("module_version", "unknown"))
    folder = config.cache_dir() / "shards" / version
    folder.mkdir(parents=True, exist_ok=True)
    return folder / url.rsplit("/", 1)[-1]


def load_shards(version_data: dict, sess=None) -> list[dict]:
    urls = shard_urls(version_data)
    sess = sess or make_session()
    paths = [_shard_cache_path(version_data, u) for u in urls]
    if paths and all(p.exists() for p in paths):
        items = []
        for p in paths:
            with open(p, "r", encoding="utf-8") as f:
                items.extend(json.load(f))
        return items

    def fetch(pair):
        url, path = pair
        resp = sess.get(url, timeout=60)
        resp.raise_for_status()
        data = resp.json()
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        return data

    items = []
    with ThreadPoolExecutor(max_workers=4) as pool:
        for data in pool.map(fetch, list(zip(urls, paths))):
            items.extend(data)
    _prune_old_shards(version_data)
    return items


def _prune_old_shards(version_data: dict) -> None:
    keep = str(version_data.get("module_version", "unknown"))
    root = config.cache_dir() / "shards"
    if not root.exists():
        return
    for child in root.iterdir():
        if child.is_dir() and child.name != keep:
            for f in child.iterdir():
                try:
                    f.unlink()
                except OSError:
                    pass
            try:
                child.rmdir()
            except OSError:
                pass


def load_tag_names(sess) -> dict:
    resp = sess.get(TAG_URL, timeout=30)
    resp.raise_for_status()
    names: dict = {}

    def walk(nodes):
        for node in nodes or []:
            for child in node.get("children") or []:
                names[child["tag_id"]] = child.get("tag_name", "")
                walk(child.get("hierarchies"))

    walk(resp.json().get("hierarchies"))
    return names


def resolve_path(tag_paths: list, names: dict) -> list[str]:
    if not tag_paths:
        return []
    segments = tag_paths[0].split("/")
    return [names.get(seg, "?") for seg in segments[1:]]


def filter_books(books: list, names: dict, grade=None, subject=None,
                 term=None, edition=None, keyword=None) -> list[dict]:
    def match_one(path_names, wanted, title):
        if not wanted:
            return True
        if wanted in path_names:
            return True
        return wanted in title

    results = []
    for book in books:
        tag_paths = book.get("tag_paths")
        if not tag_paths:
            continue
        path_names = resolve_path(tag_paths, names)
        title = book.get("title") or book.get("name") or ""
        if not title:
            title = (book.get("global_title") or {}).get("zh-CN", "")
        if not match_one(path_names, grade, title):
            continue
        if not match_one(path_names, subject, title):
            continue
        if not match_one(path_names, term, title):
            continue
        if not match_one(path_names, edition, title):
            continue
        if keyword and keyword not in title:
            continue
        results.append({
            "id": book.get("id"),
            "title": title or f"(未知电子课本 {book.get('id')})",
            "path": [p for p in path_names if p and p != "?"],
            "resource_type": book.get("resource_type_code") or "assets_document",
        })
    return results


def search(grade=None, subject=None, term=None, edition=None, keyword=None) -> list[dict]:
    if not any([grade, subject, term, edition, keyword]):
        raise ValueError("至少需要一个筛选条件（如 -g 四年级 -s 语文）")
    sess = make_session()
    print("正在获取教材目录...", file=sys.stderr)
    version_data = fetch_data_version(sess)
    books = load_shards(version_data, sess)
    names = load_tag_names(sess)
    results = filter_books(books, names, grade, subject, term, edition, keyword)
    results.sort(key=lambda b: (b["path"], b["title"]))
    return results
