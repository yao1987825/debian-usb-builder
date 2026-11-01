---
name: textbook-fetch
description: 查并下载国家中小学智慧教育平台(basic.smartedu.cn)的电子课本 PDF —— 按年级/学科/册次/版本找教材, 下载后自动命名并加 PDF 书签。Use when the user asks 小学课本/初中课本/高中课本/电子课本/教材/教科书/PEP/统编版/人教版/教辅, or asks to find/download a school textbook PDF by grade, subject, or edition.
---

# 电子课本查找与下载

这台机器上装了 `tch` 命令(国家中小学智慧教育平台), 小学到高中、统编版/人教版等
电子课本都能查、能下。**游客模式, 不用登录** ✓。

## 查教材

```bash
tch search -g 四年级 -s 语文 -t 下册
tch search -g 五年级 -s 数学 --limit 5
tch search -g 九年级 -s 物理 -e 人教版
tch search -k 生活语文 --json
```

参数:

| 参数 | 含义 | 例 |
| --- | --- | --- |
| `-g` | 年级 | 四年级 |
| `-s` | 学科 | 语文 / 数学 / 道德与法治 |
| `-t` | 册次 | 上册 / 下册 |
| `-e` | 版本 | 统编版 / 人教版 |
| `-k` | 标题关键词 | 生活语文 |
| `--limit N` | 最多显示几条 | 5 |
| `--json` | JSON 输出 | |

输出里每本教材都有一个 **ID**(contentId)✓, 下载要用。

## 下载

```bash
# 按 ID(最准)
tch download --id 53d6315e-5f90-42c4-904f-2d4e95fe99ed -o ~/textbooks

# 按条件(多本候选时会列出来, 用 --pick N 选第 N 本)
tch download -g 四年级 -s 语文 -t 下册 --pick 1 -o ~/textbooks
```

- **一定要加 `-o`** —— 默认落在系统临时目录, **重启就没了** ✓
  (建议 `~/textbooks`, 那是歌曲分区之外的普通目录; 想放到歌曲分区也行: `-o /mnt/songdisk/教材`)
- 下载完自动按书名命名 ✓, 并给 PDF 加**书签**(可用 `--no-bookmarks` 关掉)
- 只要直链不下文件: `tch link --id <ID>`
- 登录状态: `tch status` / `tch logout`(游客模式一般不用管)

## 会遇到的情况

| 现象 | 原因 / 怎么办 |
| --- | --- |
| "创建会话被拒(N/40 轮)" | 平台网关偶发拒绝, 工具会自动重试(实测第 7 轮成功 ✓); 等它重试完 |
| HTTP 401 | token 过期了: `tch logout && tch login` |
| 查不到教材 | 年级/学科写得不对(要"四年级"不是"4年级"), 或该册还没上线; 去掉 `-t` 再查 |
| 下载很慢 | 教材 PDF 十几 MB 很正常; 大文件给点耐心 |

## 汇报给用户时

- 说清楚**下载到了哪个文件**(给绝对路径)和**多少页**;
- 同一本有多个版本时(比如"统编版"和"五·四学制"), 说明你选了哪本、为什么;
- 提醒用户: 教材仅供个人学习使用, 版权属于出版社/教育部 ✓
