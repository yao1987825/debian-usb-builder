import argparse
import json
import sys

from . import VERSION, auth, catalog, config, download


def cmd_login(args) -> int:
    if args.token:
        try:
            token, path = auth.import_token(args.token)
        except auth.LoginError as e:
            print(f"导入失败: {e}", file=sys.stderr)
            return 1
        print(f"token 已保存到: {path}")
        probe = auth.probe_token(token)
        if probe == "valid":
            print("token 验证通过，可以开始下载")
        else:
            print(f"token 验证结果: {probe}（可稍后用 tch status 复查）")
        return 0

    if args.scan:
        try:
            token, path = auth.login(timeout=args.timeout)
        except auth.LoginError as e:
            print(f"登录失败: {e}", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            print("\n已取消登录", file=sys.stderr)
            return 130
        print(f"登录成功，token 已保存到: {path}")
        probe = auth.probe_token(token)
        if probe == "valid":
            print("token 验证通过，可以开始下载")
        elif probe == "invalid":
            print("警告: token 已保存但验证未通过，请稍后重试 login", file=sys.stderr)
        return 0

    try:
        token, path = auth.guest_login()
    except auth.LoginError as e:
        print(f"游客登录失败: {e}", file=sys.stderr)
        print("提示: 可改用扫码登录: tch login --scan", file=sys.stderr)
        return 1
    print(f"游客模式登录成功，token 已保存到: {path}")
    probe = auth.probe_token(token)
    if probe == "valid":
        print("token 验证通过，可以开始下载")
    elif probe == "invalid":
        print("警告: token 验证未通过，可改用扫码登录: tch login --scan", file=sys.stderr)
        return 1
    else:
        print(f"token 验证结果: {probe}")
    return 0


def cmd_logout(args) -> int:
    if config.clear_token():
        print("已退出登录，本地 token 已删除")
    else:
        print("当前未登录")
    return 0


def cmd_status(args) -> int:
    token = config.load_token()
    if not token:
        print("未登录（运行 tch login 扫码登录）")
        return 1
    age = config.token_age(token)
    saved = token.get("saved_at")
    print(f"已登录，token 文件: {config.token_file()}")
    if saved:
        print(f"保存于: {saved}（{age // 3600} 小时 {age % 3600 // 60} 分钟前）")
    for field in ("account_id", "user_id"):
        if token.get(field):
            print(f"{field}: {token[field]}")
    probe = auth.probe_token(token)
    if probe == "valid":
        print("连接验证: 通过")
    elif probe == "invalid":
        print("连接验证: 失效（请重新 tch login）")
        return 1
    else:
        print(f"连接验证: 无法确定（{probe}）")
    return 0


def _print_results(results: list, as_json: bool, heading: bool = True) -> None:
    if as_json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
        return
    if not results:
        print("没有匹配的教材")
        return
    if heading:
        print(f"共找到 {len(results)} 本教材：\n")
    for i, item in enumerate(results, 1):
        path = " / ".join(p for p in item["path"] if p and p != "?")
        print(f"  {i:>3}. {item['title']}")
        print(f"       分类: {path}")
        print(f"       ID:   {item['id']}")
    print("\n下载命令示例: tch download --id <ID>")


def cmd_search(args) -> int:
    try:
        results = catalog.search(
            grade=args.grade,
            subject=args.subject,
            term=args.term,
            edition=args.edition,
            keyword=args.keyword,
        )
    except ValueError as e:
        print(f"参数错误: {e}", file=sys.stderr)
        return 2
    except Exception as e:
        print(f"获取教材目录失败: {e}", file=sys.stderr)
        return 1
    if args.limit:
        results = results[: args.limit]
    _print_results(results, args.json)
    return 0 if results else 3


def cmd_download(args) -> int:
    content_id = args.id
    content_type = "assets_document"
    source_url = ""

    if args.url:
        source_url = args.url
        content_id, content_type = download.extract_params(args.url)
        if not content_id:
            print("无法从 URL 中解析 contentId", file=sys.stderr)
            return 2

    if not content_id:
        if not any([args.grade, args.subject, args.term, args.edition, args.keyword]):
            print("请指定 --id / --url，或提供筛选条件（如 -g 四年级 -s 语文 -t 下册）", file=sys.stderr)
            return 2
        try:
            results = catalog.search(
                grade=args.grade,
                subject=args.subject,
                term=args.term,
                edition=args.edition,
                keyword=args.keyword,
            )
        except ValueError as e:
            print(f"参数错误: {e}", file=sys.stderr)
            print("请指定 --id / --url，或提供筛选条件（如 -g 四年级 -s 语文 -t 下册）", file=sys.stderr)
            return 2
        except Exception as e:
            print(f"获取教材目录失败: {e}", file=sys.stderr)
            return 1
        if not results:
            print("没有匹配的教材", file=sys.stderr)
            return 3
        if args.pick:
            if args.pick < 1 or args.pick > len(results):
                print(f"--pick 取值超出范围（1-{len(results)}）", file=sys.stderr)
                return 2
            selected = results[args.pick - 1]
        elif len(results) > 1:
            print(f"匹配到 {len(results)} 本教材，请用 --pick N 选择或指定 --id：\n", file=sys.stderr)
            _print_results(results[:20], False, heading=False)
            return 2
        else:
            selected = results[0]
        content_id = selected["id"]
        content_type = selected["resource_type"]
        print(f"选定教材: {selected['title']}")

    if not content_id:
        print("缺少资源 ID", file=sys.stderr)
        return 2

    try:
        save_path = download.download(
            content_id,
            content_type=content_type,
            source_url=source_url,
            out_dir=args.out,
            bookmarks=not args.no_bookmarks,
        )
    except PermissionError as e:
        print(f"下载失败: {e}", file=sys.stderr)
        return 1
    except FileNotFoundError as e:
        print(f"下载失败: {e}", file=sys.stderr)
        return 3
    except Exception as e:
        print(f"下载失败: {e}", file=sys.stderr)
        return 1

    print(f"下载完成: {save_path}")
    return 0


def cmd_link(args) -> int:
    try:
        resolved = download.resolve_download(
            args.id, content_type="assets_document", bookmarks=False
        )
    except PermissionError as e:
        print(f"获取链接失败: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"获取链接失败: {e}", file=sys.stderr)
        return 1
    resource_url, title, _, _, _ = resolved
    print(f"# {title}")
    print(resource_url)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="tch",
        description="国家中小学智慧教育平台 教材下载命令行工具",
    )
    parser.add_argument("--version", action="version", version=f"tch {VERSION}")
    sub = parser.add_subparsers(dest="command")

    p_login = sub.add_parser("login", help="登录并保存 token（默认游客模式，无需扫码）")
    p_login.add_argument("--timeout", type=int, default=300, help="等待扫码的秒数（默认 300）")
    p_login.add_argument("--scan", action="store_true", help="使用手机扫码登录（真实账号）")
    p_login.add_argument("--token", help="手动导入 access_token")
    p_login.set_defaults(func=cmd_login)

    p_logout = sub.add_parser("logout", help="删除本地 token")
    p_logout.set_defaults(func=cmd_logout)

    p_status = sub.add_parser("status", help="查看登录状态")
    p_status.set_defaults(func=cmd_status)

    def add_filters(p):
        p.add_argument("-g", "--grade", help="年级，如 四年级")
        p.add_argument("-s", "--subject", help="学科，如 语文")
        p.add_argument("-t", "--term", help="册次，如 上册 / 下册")
        p.add_argument("-e", "--edition", help="版本，如 统编版 / 人教版")
        p.add_argument("-k", "--keyword", help="标题关键词")

    p_search = sub.add_parser("search", help="按年级/学科查询教材列表")
    add_filters(p_search)
    p_search.add_argument("--limit", type=int, help="最多显示条数")
    p_search.add_argument("--json", action="store_true", help="以 JSON 输出")
    p_search.set_defaults(func=cmd_search)

    p_download = sub.add_parser("download", help="下载教材到临时目录")
    add_filters(p_download)
    p_download.add_argument("--id", help="教材 contentId")
    p_download.add_argument("--url", help="教材详情页 URL")
    p_download.add_argument("--pick", type=int, help="从候选列表中选择第 N 本")
    p_download.add_argument("-o", "--out", help="保存目录（默认系统临时目录）")
    p_download.add_argument("--no-bookmarks", action="store_true", help="不添加 PDF 书签")
    p_download.set_defaults(func=cmd_download)

    p_link = sub.add_parser("link", help="仅输出资源直链（需登录）")
    p_link.add_argument("--id", required=True, help="教材 contentId")
    p_link.set_defaults(func=cmd_link)

    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not getattr(args, "func", None):
        parser.print_help()
        return 0
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
