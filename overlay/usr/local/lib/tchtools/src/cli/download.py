import re
import sys
import tempfile
import time
from pathlib import Path

from .common import (
    EBOOK_TREE_URL,
    PRIVATE_CDN,
    SPECIAL_DETAIL_URL,
    SPECIAL_LIST_URL,
    TCH_DETAIL_URL,
    UA,
    fmt_bytes,
    make_session,
    sanitize_filename,
)
from . import config


def extract_params(url: str) -> tuple[str | None, str]:
    content_id = None
    content_type = None
    query = url[url.find("?") + 1:] if "?" in url else ""
    for part in query.split("&"):
        key = part.split("=", 1)[0]
        if key == "contentId" and "=" in part:
            content_id = part.split("=", 1)[1]
        elif key == "contentType" and "=" in part:
            content_type = part.split("=", 1)[1]
    return content_id, content_type or "assets_document"


def fetch_detail(sess, content_id: str, content_type: str, source_url: str = "") -> dict | None:
    if (
        re.search(r"^https?://([^/]+)/syncClassroom/basicWork/detail", source_url)
        or content_type == "thematic_course"
    ):
        detail_url = SPECIAL_DETAIL_URL.format(content_id=content_id)
    else:
        detail_url = TCH_DETAIL_URL.format(content_id=content_id)
    resp = sess.get(detail_url, timeout=30)
    if resp.status_code != 200:
        return None
    return resp.json()


def pick_resource_url(detail: dict) -> str | None:
    for item in detail.get("ti_items") or []:
        if not item.get("ti_is_source_file"):
            continue
        storage = item.get("ti_storage")
        if storage:
            return storage.replace("cs_path:${ref-path}", PRIVATE_CDN)
        storages = [u for u in (item.get("ti_storages") or []) if u]
        if storages:
            return storages[0]
    return None


def pick_resource_url_from_list(detail: dict) -> str | None:
    for resource in detail.get("resources") or []:
        if resource.get("resource_type_code") != "assets_document":
            continue
        url = pick_resource_url(resource)
        if url:
            return url
    return None


def fetch_chapters(sess, detail: dict, auth: dict) -> list:
    chapters = []
    mapping_url = None
    for item in detail.get("ti_items") or []:
        if item.get("ti_file_flag") == "ebook_mapping":
            storage = item.get("ti_storage")
            if storage:
                mapping_url = storage.replace("cs_path:${ref-path}", PRIVATE_CDN)
            else:
                storages = [u for u in (item.get("ti_storages") or []) if u]
                mapping_url = storages[0] if storages else None
            break
    if not mapping_url:
        return chapters
    try:
        resp = sess.get(mapping_url, headers={**UA_headers(), **auth}, timeout=30)
        resp.raise_for_status()
        map_data = resp.json()
        ebook_id = map_data.get("ebook_id")
        page_map = [
            {"node_id": m["node_id"], "page_number": m.get("page_number", 1)}
            for m in map_data.get("mappings") or []
        ]
        if ebook_id:
            tree_resp = sess.get(
                EBOOK_TREE_URL.format(ebook_id=ebook_id), headers=auth, timeout=30
            )
            tree_resp.raise_for_status()
            tree_data = tree_resp.json()

            def process(nodes):
                result = []
                for node in nodes:
                    page_num = next(
                        (m["page_number"] for m in page_map if m["node_id"] == node["id"]),
                        None,
                    )
                    item = {"title": node["title"], "page_index": page_num}
                    if node.get("child_nodes"):
                        item["children"] = process(node["child_nodes"])
                    result.append(item)
                return result

            if isinstance(tree_data, list):
                chapters = process(tree_data)
            elif isinstance(tree_data, dict) and tree_data.get("child_nodes"):
                chapters = process(tree_data["child_nodes"])
        if not chapters:
            page_map.sort(key=lambda x: x["page_number"])
            chapters = [
                {"title": f"第 {i + 1} 节 (P{m['page_number']})", "page_index": m["page_number"]}
                for i, m in enumerate(page_map)
            ]
    except Exception as e:
        print(f"获取章节目录失败（不影响下载）: {e}", file=sys.stderr)
        chapters = []
    return chapters


def UA_headers() -> dict:
    return {"User-Agent": UA}


def add_bookmarks(pdf_path: Path, chapters: list) -> None:
    try:
        from pypdf import PdfReader, PdfWriter
    except ImportError:
        print("未安装 pypdf，跳过书签添加", file=sys.stderr)
        return
    if not chapters:
        return
    try:
        reader = PdfReader(str(pdf_path))
        writer = PdfWriter()
        writer.append_pages_from_reader(reader)

        def walk(chapter_list, parent=None):
            for chapter in chapter_list:
                title = chapter.get("title", "未知章节")
                page_index = chapter.get("page_index")
                if page_index is None:
                    continue
                try:
                    page_num = int(page_index) - 1
                except (ValueError, TypeError):
                    continue
                if page_num < 0 or page_num >= len(writer.pages):
                    continue
                bookmark = writer.add_outline_item(title, page_num, parent=parent)
                if chapter.get("children"):
                    walk(chapter["children"], parent=bookmark)

        walk(chapters)
        with open(pdf_path, "wb") as f:
            writer.write(f)
    except Exception as e:
        print(f"添加书签失败（不影响文件）: {e}", file=sys.stderr)


def download_file(sess, url: str, save_path: Path, auth: dict) -> None:
    resp = sess.get(url, headers={**UA_headers(), **auth}, stream=True, timeout=60)
    if resp.status_code in (401, 403):
        raise PermissionError(
            f"HTTP {resp.status_code}：Access Token 已过期或无效，请重新运行 login"
        )
    if not resp.ok:
        raise RuntimeError(f"服务器返回 HTTP {resp.status_code}")

    total = int(resp.headers.get("Content-Length", 0))
    chunk_size = 131072 if total < 20971520 else 262144 if total < 52428800 else 524288
    done = 0
    last_print = 0.0
    with open(save_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=chunk_size):
            f.write(chunk)
            done += len(chunk)
            now = time.time()
            if now - last_print >= 0.5:
                last_print = now
                if total:
                    pct = done / total * 100
                    print(
                        f"\r  下载中 {fmt_bytes(done)}/{fmt_bytes(total)} ({pct:.1f}%)",
                        end="",
                        file=sys.stderr,
                        flush=True,
                    )
                else:
                    print(f"\r  已下载 {fmt_bytes(done)}", end="", file=sys.stderr, flush=True)
    if total:
        print(file=sys.stderr)


def resolve_download(content_id: str, content_type: str, source_url: str = "",
                     bookmarks: bool = True) -> tuple[dict | None, ...]:
    token = config.load_token()
    if not token:
        from . import auth as auth_mod

        print("未检测到 token，尝试自动游客登录...", file=sys.stderr)
        try:
            token, _ = auth_mod.guest_login()
        except auth_mod.LoginError as e:
            raise PermissionError(
                f"尚未登录且游客登录失败（{e}），请运行: tch login 或 tch login --scan"
            )
    sess = make_session()
    auth = config.auth_header(token)

    detail = fetch_detail(sess, content_id, content_type, source_url)
    if not detail:
        raise FileNotFoundError(f"未找到资源详情: {content_id}")

    resource_url = pick_resource_url(detail)
    title = detail.get("title") or content_id

    if not resource_url and content_type == "thematic_course":
        resp = sess.get(SPECIAL_LIST_URL.format(content_id=content_id), timeout=30)
        if resp.status_code == 200:
            resource_url = pick_resource_url_from_list({"resources": resp.json()})

    if not resource_url:
        raise FileNotFoundError("未找到可下载的资源文件")

    chapters = fetch_chapters(sess, detail, auth) if bookmarks else []
    return resource_url, title, chapters, auth, sess


def default_download_dir() -> Path:
    path = Path(tempfile.gettempdir()) / "tchMaterial-parser"
    path.mkdir(parents=True, exist_ok=True)
    return path


def download(content_id: str, content_type: str = "assets_document", source_url: str = "",
             out_dir: Path | None = None, bookmarks: bool = True) -> Path:
    resolved = resolve_download(content_id, content_type, source_url, bookmarks)
    resource_url, title, chapters, auth, sess = resolved

    target_dir = Path(out_dir) if out_dir else default_download_dir()
    target_dir.mkdir(parents=True, exist_ok=True)
    filename = sanitize_filename(title)
    if not filename.lower().endswith((".pdf", ".doc", ".docx", ".ppt", ".pptx", ".wps", ".xls", ".xlsx")):
        filename += ".pdf"
    save_path = target_dir / filename

    print(f"开始下载: {title}", file=sys.stderr)
    try:
        download_file(sess, resource_url, save_path, auth)
    except PermissionError:
        from . import auth as auth_mod

        current = config.load_token()
        refreshed = auth_mod.refresh_token(current) if current else None
        if not refreshed:
            raise
        print("token 已刷新，重试下载...", file=sys.stderr)
        auth = config.auth_header(refreshed)
        download_file(sess, resource_url, save_path, auth)
    if chapters and filename.lower().endswith(".pdf"):
        print("正在添加书签...", file=sys.stderr)
        add_bookmarks(save_path, chapters)
    return save_path
