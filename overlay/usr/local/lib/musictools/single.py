#!/usr/bin/env python3
"""
single.py —— 命令行单曲搜索 / 下载

刻意不依赖 PyQt6: 只用 gequhai-downloader 项目里的 gequhai.py / quark.py / utils.py,
这三个模块只依赖 requests, 因此轻量镜像(不装 PyQt6)也能正常单曲下载。

用法:
  single.py "周杰伦 夜曲"                 搜索并下载最佳匹配
  single.py "夜曲" --list                 只列出候选, 不下载
  single.py "夜曲" --index 2              下载第 2 条候选
  single.py "夜曲" --out /mnt/songdisk    指定输出目录
  single.py "夜曲" --no-quark             强制只用低品质直链(不需要夸克 Cookie)
"""
import argparse
import base64
import os
import re
import sys
import time

DEFAULT_PROJECT = os.path.expanduser("~/projects/gequhai-downloader")
DEFAULT_OUT = os.environ.get("SONG_DIR", "/mnt/songdisk")

# 站点/夸克/封面直连才通, 走 LAN 代理反而全断(gequhai 回 403 反爬页、
# 夸克/酷我 SSL 失败); 而登录 shell 会经 /etc/profile.d/99-proxy.sh 自动导出
# http_proxy, requests 即使拿到空代理配置也会去读它 —— 症状就是
# "浏览器能打开站点, music search 却一条都搜不到"。
# 这里先把环境代理摘掉, 直接 python3 single.py 跑也一样直连;
# config.json 里显式配的 proxy 仍然有效(utils.get_proxies 优先读它)。
for _proxy_var in ("http_proxy", "https_proxy", "all_proxy",
                   "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"):
    os.environ.pop(_proxy_var, None)

_UA = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
}


def log(msg):
    print(f"[single] {msg}", flush=True)


def die(msg, code=1):
    print(f"[single] 错误: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


def load_project(project_dir):
    if not os.path.isdir(project_dir):
        die(f"找不到项目目录: {project_dir}\n"
            f"        请确认已 clone https://github.com/Yannick-Mo/gequhai-downloader")
    sys.path.insert(0, project_dir)
    # utils.load_config() 是按相对路径读 config.json 的, 所以先切到项目目录
    os.chdir(project_dir)
    try:
        import gequhai
        import quark
        import utils
    except ImportError as exc:
        die(f"导入项目模块失败: {exc}\n"
            f"        请执行: pip install requests")
    check_api(gequhai, quark, utils)
    return gequhai, quark, utils


# 本脚本依赖的项目接口。项目的 API 一旦变动, 这里要给出人话提示,
# 而不是让用户看一整屏 traceback。
# (模块名, 接口名, 这个接口是干什么的)
REQUIRED_API = (
    ("gequhai", "search_songs", "搜索歌曲"),
    ("quark", "download_from_quark", "夸克网盘转存"),
    ("utils", "load_config", "读取 config.json"),
    ("utils", "safe_filename", "文件名安全处理"),
    ("utils", "download_file", "下载文件"),
)


def check_api(gequhai, quark, utils):
    """检查项目模块是否提供本脚本要用到的接口, 缺了就给清晰的提示。"""
    mods = {"gequhai": gequhai, "quark": quark, "utils": utils}
    missing = []
    for mod_name, attr, desc in REQUIRED_API:
        mod = mods.get(mod_name)
        if mod is None or not hasattr(mod, attr):
            missing.append(f"{mod_name}.{attr}() ({desc})")
    if missing:
        die("项目源码的接口和本脚本对不上, 缺少:\n"
            + "".join(f"        - {m}\n" for m in missing)
            + "        这通常是因为 gequhai-downloader 仓库更新后改了接口。\n"
            f"        处理办法: cd {os.getcwd()} && git pull 后重新确认接口名,\n"
            "        或改用项目自带的图形界面: music gui")


def decode_quark_extra(raw):
    """站点的夸克链接做了简单混淆: '#'->'H', '%'->'S' 之后 base64"""
    if not raw:
        return ""
    try:
        cleaned = raw.replace("#", "H").replace("%", "S")
        return base64.b64decode(cleaned).decode("utf-8")
    except Exception:
        return ""


def fetch_quark_links(song_id, utils):
    """
    抓取播放页, 返回所有可用的夸克分享链接。
    项目里的 parse_play_page 只解了 mp3_extra_url, 这里把 mp3_extra_url2 也一起解出来备用。
    """
    import requests

    try:
        resp = requests.get(f"https://www.gequhai.com/play/{song_id}",
                            headers=_UA, timeout=15, proxies=utils.get_proxies())
        resp.encoding = "utf-8"
    except Exception:
        return []

    links = []
    for var in ("mp3_extra_url", "mp3_extra_url2"):
        m = re.search(rf"window\.{var}\s*=\s*'([^']*)'", resp.text)
        if not m:
            continue
        url = decode_quark_extra(m.group(1))
        if url and url not in links:
            links.append(url)
    return links


def search_with_fallback(keyword, gequhai):
    """
    站点搜索对关键词顺序很敏感:
      "五月天 突然好想你" -> 0 条
      "突然好想你 五月天" -> 有结果
    所以搜不到时自动换个顺序 / 拆词重试。
    """
    results = gequhai.search_songs(keyword)
    if results:
        return results, keyword

    tokens = [t for t in keyword.split() if t]
    if len(tokens) > 1:
        reversed_kw = " ".join(reversed(tokens))
        results = gequhai.search_songs(reversed_kw)
        if results:
            return results, reversed_kw
        for token in tokens:
            results = gequhai.search_songs(token)
            if results:
                return results, token
    return [], keyword


def show_results(results, limit=20):
    for idx, item in enumerate(results[:limit], 1):
        print(f"  {idx:2d}. {item['title']} - {item['artist']}", flush=True)
    if len(results) > limit:
        print(f"  ... 共 {len(results)} 条结果, 只显示前 {limit} 条", flush=True)


def pick_result(results, keyword, index):
    """决定下载哪一条: 显式 --index > 标题完全匹配 > 标题包含关键词 > 交互选择 > 第一条"""
    if index is not None:
        if index < 1 or index > len(results):
            die(f"--index {index} 超出范围 (1-{len(results)})")
        return results[index - 1]

    kw = keyword.strip().lower()
    for item in results:
        if item["title"].strip().lower() == kw:
            return item
    for item in results:
        if kw and kw in item["title"].strip().lower():
            return item

    if sys.stdin.isatty() and sys.stdout.isatty():
        print(f"\n[single] 没有完全匹配的结果, 请选择要下载的编号 (直接回车 = 1): ", end="", flush=True)
        try:
            answer = input().strip()
        except (EOFError, KeyboardInterrupt):
            answer = ""
        if answer.isdigit() and 1 <= int(answer) <= len(results):
            return results[int(answer) - 1]
    return results[0]


def progress_bar(label):
    state = {"last": -1}

    def callback(percent, speed):
        pct = int(percent * 100)
        if pct != state["last"]:
            state["last"] = pct
            print(f"\r[single] {label}: {pct:3d}%  {speed}", end="", flush=True)

    return callback


def main():
    parser = argparse.ArgumentParser(
        prog="single.py",
        description="命令行单曲搜索下载 (gequhai-downloader)",
    )
    parser.add_argument("keyword", help="歌名 / 歌名+歌手, 支持中文")
    parser.add_argument("--out", default=DEFAULT_OUT, help=f"输出目录 (默认 {DEFAULT_OUT})")
    parser.add_argument("--index", type=int, default=None, help="下载第 N 条搜索结果")
    parser.add_argument("--list", action="store_true", help="只列出搜索结果, 不下载")
    parser.add_argument("--cookie", default="", help="夸克 Cookie (默认读项目 config.json)")
    parser.add_argument("--no-quark", action="store_true", help="不走夸克网盘, 只用低品质直链")
    parser.add_argument("--project", default=DEFAULT_PROJECT, help="gequhai-downloader 项目目录")
    args = parser.parse_args()

    if not args.keyword.strip():
        die("关键词不能为空")

    gequhai, quark, utils = load_project(args.project)

    log(f"搜索: {args.keyword}")
    try:
        results, used_kw = search_with_fallback(args.keyword, gequhai)
    except Exception as exc:
        die(f"搜索失败: {exc}")

    if not results:
        die(f"没有搜到「{args.keyword}」\n"
            f"        提示: 站点搜索对词序敏感, 可以只输入歌名, 或用引号内只写一个关键词")

    if used_kw != args.keyword:
        log(f"「{args.keyword}」搜不到, 自动改用「{used_kw}」搜索")
    log(f"找到 {len(results)} 条结果:")
    show_results(results)

    if args.list:
        return 0

    song = pick_result(results, args.keyword, args.index)
    log(f"选中: {song['title']} - {song['artist']}")

    try:
        info = gequhai.parse_play_page(song["id"])
    except Exception as exc:
        die(f"解析播放页失败: {exc}")

    title = info.get("title") or song["title"]
    artist = info.get("author") or song["artist"]
    unified = utils.safe_filename(f"{title}-{artist}")

    try:
        os.makedirs(args.out, exist_ok=True)
    except OSError as exc:
        die(f"无法创建输出目录 {args.out}: {exc}")

    audio_path = ""
    cookie = args.cookie or (utils.load_config().get("quark_cookie", "") or "")

    # 夸克分享链接: 项目里只解了第一个, 这里把备用链接也带上
    quark_links = []
    if info.get("quark_url"):
        quark_links.append(info["quark_url"])
    if not args.no_quark:
        for link in fetch_quark_links(song["id"], utils):
            if link not in quark_links:
                quark_links.append(link)

    if quark_links and not args.no_quark:
        if cookie:
            for idx, link in enumerate(quark_links, 1):
                log(f"夸克网盘高品质下载中 (链接 {idx}/{len(quark_links)}) ...")
                try:
                    ok, path, err = quark.download_from_quark(
                        link, title, args.out, cookie, progress_bar("下载")
                    )
                except Exception as exc:
                    ok, path, err = False, "", str(exc)
                if ok:
                    audio_path = path
                    log("夸克高品质下载完成")
                    break
                log(f"夸克下载失败({err})")
        else:
            log("未配置夸克 Cookie, 尝试低品质直链(成功率较低)")
    elif not args.no_quark:
        log("该歌曲没有夸克链接, 尝试低品质直链")

    if not audio_path:
        play_id = info.get("play_id", "")
        mp3_type = info.get("mp3_type", 0)
        try:
            low_url = gequhai.get_low_quality_url(play_id, mp3_type)
        except Exception as exc:
            low_url = ""
            log(f"获取直链失败: {exc}")
        if low_url:
            audio_path = os.path.join(args.out, f"{unified}.mp3")
            log("低品质直链下载中 ...")
            try:
                utils.download_file(low_url, audio_path, progress_callback=progress_bar("下载"))
            except Exception as exc:
                die(f"下载失败: {exc}")
            log("下载完成")
        else:
            die("下载失败: 夸克转存与低品质直链都不可用。\n"
                f"        最可能的原因是没有夸克 Cookie —— 站点目前把低品质直链接口限流了(403)。\n"
                f"        配置方法(一次即可, 图形界面和命令行共用):\n"
                f"          编辑 {args.project}/config.json, 填入 quark_cookie 字段\n"
                f"          或运行 music gui, 在弹窗里粘贴 Cookie 并勾选记住")

    ext = os.path.splitext(audio_path)[1] or ".mp3"
    # 自动归类: /mnt/songdisk/<歌手>/<歌名-歌手>.mp3, 歌词/封面跟着同一目录,
    # 不再所有文件平铺在盘根(用户要求)。歌手目录名也走 safe_filename 防怪字符。
    artist_dirname = utils.safe_filename(artist) or "未知歌手"
    artist_dir = os.path.join(args.out, artist_dirname)
    try:
        os.makedirs(artist_dir, exist_ok=True)
    except OSError as exc:
        die(f"无法创建歌手目录 {artist_dir}: {exc}")
    final_audio = os.path.join(artist_dir, f"{unified}{ext}")
    if os.path.abspath(audio_path) != os.path.abspath(final_audio):
        os.replace(audio_path, final_audio)
    print()
    log(f"音频: {final_audio}")

    lrc_text = info.get("lrc_text", "")
    if lrc_text:
        lrc_path = os.path.join(artist_dir, f"{unified}.lrc")
        with open(lrc_path, "w", encoding="utf-8") as fh:
            fh.write(lrc_text)
        log(f"歌词: {lrc_path}")

    cover_url = info.get("cover_url", "")
    if cover_url:
        try:
            import requests
            resp = requests.get(cover_url, timeout=15, proxies=utils.get_proxies())
            if resp.ok:
                cover_path = os.path.join(artist_dir, f"{unified}.jpg")
                with open(cover_path, "wb") as fh:
                    fh.write(resp.content)
                log(f"封面: {cover_path}")
        except Exception:
            pass

    log("完成 ✅")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n[single] 已取消", file=sys.stderr)
        sys.exit(130)
