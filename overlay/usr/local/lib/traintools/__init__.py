"""traintools —— 12306 火车票查询(装在 /usr/local/lib/traintools)。

上游项目: https://github.com/travellerwjoe/train-tickets
上游代码已经跑不动了(2026-10 实测):
  1) 老的 `otn/leftTicket/query` 接口现在直接返回 HTML(不是 JSON) -> JSONDecodeError;
  2) 座位字段下标整体错位一格(高级软卧/其他/软卧... 展示对不上号);
  3) `verify=False` 会在终端刷一屏 InsecureRequestWarning;
  4) 依赖 docopt / prettytable / colorama 三个包, 对一个 U 盘系统不划算。

这一版重写为:
  - 标准库实现(urllib + http.cookiejar + json), **不装任何第三方包**;
  - 先访问余票首页拿 Cookie, 再带正确请求头查接口(12306 对无 Cookie 的请求返回 HTML);
  - 座位字段按当前接口布局对齐;
  - 车站表本地内置一份(离线可用), 也能联网刷新(新车站);
  - 错误给的是人话: 网络不通 / 日期超出预售期 / 没有车次 / 车站名写错。

用法:
    train 北京 上海                 # 今天
    train 北京 上海 2026-10-30      # 指定日期(也支持 明天/后天/+3)
    train -g 北京 上海              # 只看高铁/城际
    train --json 北京 上海          # JSON 输出(给脚本/AI 用)
"""

from __future__ import annotations

__version__ = "1.1.0"
