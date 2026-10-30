# Debian 12 U 盘系统镜像构建器

用 **GitHub Actions** 在云端构建一个可以直接写进 U 盘的 Debian 12 系统镜像：
`Xfce 轻量桌面 + Fcitx5/Rime 中文输入 + 独立歌曲分区 + 预装两个 Python 下载器`。
**本地零占用**，构建全程发生在 GitHub 的 runner 上，你只需要下载产物、写入 U 盘。

> 本仓库同时支持两条产线：
> - **x86_64 通用镜像**（第一～七章）：自建 debootstrap 根文件系统，GPT + GRUB/EFI，写 U 盘。
> - **Phicomm N1 电视盒子镜像**（第九章）：Amlogic S905D / ARM64，基于 ophub 的
>   `amlogic-s9xxx-armbian` 板级支持重打包，写 SD 卡 / U 盘。

---

## 一、这个镜像是什么

| 项目 | 说明 |
| --- | --- |
| 系统 | Debian 12 (bookworm)，UEFI 启动（写入 shim 签名，传统 BIOS 可选开启） |
| 桌面 | Xfce4（极轻量，够用就跑 PyQt6 图形下载器） |
| 中文输入 | Fcitx5 + Rime，默认 `Ctrl+Space` 切换，简体拼音，已预置歌手/歌名词库 |
| 音乐分区 | 独立 ext4 分区 `MUSIC`，挂载到 `/mnt/songdisk`，等同你的"盘符" |
| 预装项目 | `gequhai-downloader`（PyQt6 图形版）、`gequhai-playlist-downloader`（CLI 版）+ 各自的 venv |
| 预装浏览器 | Playwright Chromium（歌单版的搜索回退需要，已离线装好） |
| 账号 | 用户 `user` / 密码 `user`，Xfce 自动登录，sudo 免密 |

分区表（GPT）：

```
p1  BIOS-BOOT   1MiB    ef02   仅传统 BIOS 需要
p2  EFI         512MiB  ef00   UEFI 启动 (shim + grubx64 + 引导链)
p3  DEBIAN_ROOT 6GiB    ext4   系统根分区 /
p4  MUSIC       剩余     ext4   歌曲盘 → /mnt/songdisk
```

> **不碰你的内置硬盘**：镜像里不会写入任何 efibootmgr 启动项，不改主板 NVRAM，
> 不生成指向宿主机磁盘的 fstab 条目。插上 U 盘从启动菜单（F12 / F11 / Esc）选它启动即可。

---

## 二、三分钟跑通

### 1. 把这个目录推到你自己的 GitHub 仓库

```bash
cd debian-usb-builder
git init
git add -A
git commit -m "feat: Debian USB image builder"
git remote add origin https://github.com/<你的用户名>/debian-usb-builder.git
git push -u origin main
```

> **关于仓库可见性**：本仓库是 **Public**，公开仓库的 GitHub Actions 免费额度不限，
> 构建多少次都不消耗私有仓库那 2000 分钟/月的配额（私有仓库其实也够用，只是要注意额度）。

### 2. 触发构建

- 仓库页面 → **Actions** → 左侧 **Build Debian USB Image** → 右侧 **Run workflow**
- 默认参数即可（`bookworm` / `8192` MiB / 预装项目 = 1）
- 大约 **20～40 分钟**（装 Debian + Xfce + Chromium 是大头）

### 3. 下载产物

构建结束 → 页面底部 **Artifacts** → 下载 `debian-usb-image-bookworm`，得到

```
debian-usb-bookworm.img.xz      # 压缩镜像
SHA256SUMS.txt                   # 校验和
BUILD-INFO.txt                   # 版本/UUID/分区信息
```

### 3b. 或者直接用正式发布的版本（推荐）

给仓库打个 `v*` tag 推上去，Actions 会构建完自动发布到
[**Releases**](https://github.com/yao1987825/debian-usb-builder/releases)：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Release 页面上除了镜像文件，还有自动生成的说明：镜像信息（`BUILD-INFO.txt`）、
SHA256 校验、写盘命令，以及本次改动（从 `CHANGELOG.md` 对应版本的小节摘出来的）。
版本号规则和每个版本改了什么见 [CHANGELOG.md](CHANGELOG.md)。

### 4. 写入 U 盘

**Windows（推荐 Rufus）**：Rufus 选设备 → 引导类型选 `DD 模式` → 选 `debian-usb-bookworm.img.xz` → 开始。
**balenaEtcher**：直接选 `.img.xz` 即可，它会自动解压。

**Linux**：

```bash
xz -dk debian-usb-bookworm.img.xz
sudo dd if=debian-usb-bookworm.img of=/dev/sdX bs=4M status=progress conv=fsync
```

⚠️ `sdX` 一定要确认是 U 盘，写错会毁掉内置硬盘。写完拔插一次，从启动菜单选 U 盘启动。

---

## 三、第一次开机后

登录用户 `user` / 密码 `user`（Xfce 会自动登录，直接进桌面）。

桌面是**精简过的**：没有面板、没有桌面图标，登录进去**直接就是一个终端**。
这是刻意的设计（面板和桌面图标用户明确说不需要），但也带来一个必须解决的问题——
**终端窗口全关掉之后，屏幕上就真的什么都不剩了**。下面这一节就是解决它的。

### 0. 终端：只有一个窗口，标签页自己管

开机自动弹出的那个终端里，已经预先打好了**键位速查表**，不知道能干什么的话看一眼就知道。

| 想做什么 | 怎么做 |
| --- | --- |
| 新建一个标签页 | `Ctrl+Shift+T`（或 `Ctrl+Alt+T`，同窗口加标签页） |
| 切到下一个 / 上一个标签页 | `Ctrl+Page_Down` / `Ctrl+Page_Up` |
| 关闭当前标签页 | `Ctrl+Shift+W`（直接敲 `exit` 也一样） |
| 切回刚才那个标签页 | 标签栏上直接点，或用上面的切换键 |
| 终端不见了 / 黑屏了 | `Ctrl+Alt+T`；等几秒也会自己回来（见下） |

几个刻意做出来的决定：

- **终端窗口全没了会自动拉起**。`terminal-keepalive` 每 3 秒查一次，
  没有终端窗口就重新开一个。因为这个桌面既没有面板也没有桌面图标，
  守护进程是**唯一**的兜底 —— 不会再出现"关光之后黑乎乎一片不知道怎么办"。
  不想被拉起（比如想省资源）：`music terminal off`；恢复：`music terminal on`。
- **`Ctrl+Alt+T` 不再开新窗口**。原来的行为是弹一个独立窗口把整个屏幕盖住，
  之前的终端被压到后面。现在改成「在当前窗口里加一个标签页」。
  实现方式是开机时用 `xfconf-query` 找出 XFCE 里所有指向终端的快捷键，
  把命令换成 `/usr/local/bin/terminal-new`（`xfce4-terminal --tab`），
  改完复查一遍；兜底再把桌面项的 `Exec` 换掉（**只换 Exec，Name 一个字不改** ——
  `exo-open --launch TerminalEmulator` 是按 Name 匹配的，改了名就找不到）。
- **标签页标题 = 当前目录**。标签上显示 `user@deb: Downloads` 这种，
  一眼就知道哪个标签在干什么，不用靠编号猜。
- **标签页的快捷键是显式写死的**（`~/.config/xfce4/terminal/terminalrc`），
  不依赖"默认值碰巧是什么"。

随时想再看一遍键位表：

```bash
music keys
```

<details>
<summary>进阶：tmux（可选，默认不启用）</summary>

镜像里预装了 `tmux` 和一份配置（`~/.tmux.conf`），但**默认不启用** ——
xfce4-terminal 的标签页对日常已经够了。直接敲 `tmux` 就会进，
好处是状态栏常驻显示所有标签页和快捷键提示，适合跑长任务。
前缀键 `Ctrl+b`，之后 `c` 新标签、`n`/`p` 切换、数字直达、`x` 关闭、`d` 脱离。

</details>

### 1. 把 U 盘剩余空间用起来 —— 不用你动手

镜像只有 8GiB，U 盘通常是 64G / 128G。**开机时 `usb-grow.service` 会自动把剩下的
空间分给 root 和 MUSIC 两条分区并扩展文件系统，你什么都不用做**：写完镜像插上，
第一次开机进桌面时它已经在后台做完了（第一次会拷 1.5GiB 的歌曲盘数据，走 USB 大约
1~2 分钟）。

想确认它干了什么：

```bash
systemctl status usb-grow       # 看这次开机有没有跑成功
journalctl -u usb-grow -n 50    # 看它具体做了什么
music health                    # 一并体检: 磁盘/分区/输入法/分辨率
```

**万一自动那一步没生效**（比如内核当时不接受新的分区大小），它会在下次开机自动
补齐，不需要你记得再跑一次。仍然想手动控制的话：

```bash
usb-grow.sh --check            # 先看诊断(不需要 root): 磁盘多大、现有分区、剩多少可用
usb-grow.sh                    # 默认 root 拿 30%, MUSIC 拿 70%
usb-grow.sh --root-percent 50  # 自己分配比例
usb-grow.sh --dry-run          # 打印将执行的改动但不动分区表
usb-grow.sh --auto             # 开机自启调用的模式(幂等, 随时可重跑)
usb-grow.sh --self-test        # 认分区逻辑自测(构建期也会自动跑一遍)
```

不用自己加 `sudo` —— 脚本会自己提权。跑之前它会先把环境全打印出来：

```
==> 环境诊断
[grow]   根分区      : /dev/sda3  (挂载点 /)
[grow]   物理磁盘    : /dev/sda
[grow]   磁盘容量    : 64.00 GiB
[grow]   当前分区表: ...
[grow]   未分配空间: 30.00 GiB
==> 扩容方案
[grow] root   : 6.00 GiB  ->  15.00 GiB
[grow] MUSIC  : 1.50 GiB  ->  25.50 GiB
```

完整输出同时写到 `/var/log/usb-grow.log`（普通用户跑时若没权限写 `/var/log`，会自动退到
`~/.local/state/usb-grow.log`，并在输出里告诉你写到哪儿了）。改分区表前会用
`sgdisk --backup` 备份一份 GPT。

分区号识别**不依赖 `lsblk`**：`lsblk` 认分区靠 `PARTN/PARTLABEL/FSTYPE` 这些列名，
不同发行版/版本认得的列不一样，一旦不认，它会返回非零；再叠加脚本的 `set -e` +
`pipefail`，整个扩容脚本就会在半路自己消失（而且报的"失败命令"是管道里的 `awk`，
极具误导性）。现在的做法是：

| 信息 | 来源 | 理由 |
| --- | --- | --- |
| 分区号 / 设备节点 | `/sys/block/<盘>/*/partition` | 内核给的，最可靠 |
| 扇区范围 / GPT 分区名 | `sgdisk -p` | 自己写进去的分区表 |
| 文件系统标签 / 类型 | `/run/udev/data/<主>:<次>` | udev 已经识别好了，普通用户也读得到 |

识别顺序还有多层兜底：GPT 分区名 / 文件系统标签 → 挂载点（`/` 与 `/mnt/songdisk`）
→ 文件系统类型 → 磁盘最后一个分区。任何一步失败都只是"这一条线索没用上"，
不会再把整个脚本带走。

扩容后 `df -h` 就能看到 `/mnt/songdisk` 变成几十 G，**不需要重装**。

### 2. 中文输入法

- 默认已配置好 Fcitx5 + Rime 简体拼音，`Ctrl+Space` 切换输入法，`Shift` 切中英文。
- 镜像里已经预置了 70 多条歌手/歌名词库（`周杰伦`、`五月天`、`夜曲`…），
  打 `zhoujielun` 就能出「周杰伦」。
- 想加自己的词：编辑 `~/.local/share/fcitx5/rime/user.dict.yaml`，格式是
  `词语<TAB>拼音编码`（编码用空格分音节）：

  ```yaml
  entries:
    - 我的歌单	m wo ge dan
  ```

  保存后 Fcitx5 的 Rime 插件会自动重新部署（一般 1 秒内生效）；
  想手动触发可以执行 `rime_deployer --build`。
- 改了输入法配置完全没反应时：`im-config -n fcitx5` 然后注销重登。

> ⚠️ **Rime 的配置目录是 `~/.local/share/fcitx5/rime/`，不是 `~/.config/fcitx5/rime/`。**
> 放错目录 Rime 根本不会读，症状是"Shift 按了没反应"，而构建期断言查的也是
> 那个错路径，于是**一直绿灯自欺**。老镜像按下面修：

> ```bash
> mkdir -p ~/.local/share/fcitx5/rime
> mv ~/.config/fcitx5/rime/* ~/.local/share/fcitx5/rime/ 2>/dev/null
> music im-fix     # 让 fcitx5 重新部署
> ```

#### 「按 Shift 没反应 / 偶尔失灵」到底是怎么回事

真机反馈里说过"偶尔出现使用 shift 键切换失灵"。这里把原因说清楚，
免得以为是配置坏了反复折腾。**有两个独立的原因**：

**原因一：状态不对。** Rime 的 `ascii_composer` 只在**输入法接管按键**的时候才管用。
fcitx5 有三种状态：`关闭(0)` / `英文态 Inactive(1)` / `中文态 Active(2)`。
处于**英文态**时按键根本不经过输入法，Rime 自然收不到 Shift —— 表现就是
"按了没反应"。而中文态下按 Shift 一切正常，合起来看就成了"偶尔失灵"。

镜像里已经用一个自启项在开机时把输入法切到 rime（中文态），所以开机就是对的；
但运行中切到英文态之后，Shift 就会"失灵"。

**原因二：正在打拼音。** Rime 的 `ascii_composer` 只在**没有预编辑**时才处理 Shift。
正在打拼音想临时切英文，先按 `Esc` 清掉预编辑再按 Shift。

所以真正的开关是这几个，按可靠性从高到低：

| 方式 | 可靠性 | 说明 |
| --- | --- | --- |
| `Ctrl+Space` | ★★★ 永远有效 | fcitx5 的触发键，英文态/中文态都能切 |
| `music im-toggle` | ★★★ 永远有效 | 命令行开关，先读状态再决定动作，不看当前态 |
| `Shift` | ★★ 看状态 | 中文态下快速切；英文态下无效 |
| `CapsLock` | ★★ 看状态 | 第二条快速切换路（比 Shift 少一类误判） |

```bash
music im-toggle     # 中英切换, 不看你当前是什么状态
music health        # 体检时会直接告诉你现在是中文态还是英文态
```

`music health` 现在会明确报出状态：如果是英文态，它会直接告诉你
"此时按 Shift/CapsLock 都不会切换，因为按键不经过输入法"。

> 顺带一提：Rime 的切换键必须写成**扁平键映射**
> （`"ascii_composer/switch_key/Shift_L": inline_ascii`），
> 写成 `"ascii_composer/switch_key": "Shift_L"` 是给键赋了个字符串，Shift 永远不会生效。
> 这个坑踩过一次，构建校验里现在会断言写法是否正确。

> **打不出中文自查**：fcitx5 图标亮着但哪里都输不了中文？多半是拼音词库
> `rime-data-luna-pinyin` 没装（Debian 里它只是 fcitx5-rime 的推荐依赖，
> 不用 `--no-install-recommends` 覆盖装不出来）。老镜像提前一行修好：
>
> ```bash
> sudo apt-get install -y rime-data-luna-pinyin
> music im-fix     # 清掉失败的部署产物并让 fcitx5 重新部署
> ```
>
> `music-health` 会直接点名这个问题。

### 3. 下载歌曲

**连不上网？先跑这个：**

```bash
music net          # 逐层诊断：网卡 → IP → 路由 → DNS → 外网
music net --fix    # 诊断 + 自动修复（重启 NetworkManager / 重建 resolv.conf）
```

它会指出是哪一层断了，并给出对应的修复命令。最常见的三种：

| 现象 | 原因 | 修复 |
| --- | --- | --- |
| `NetworkManager 没在运行` | 服务没起来 | `sudo systemctl enable --now NetworkManager` |
| `没有任何网卡拿到 IPv4` | 没插网线 / 没连 WiFi / DHCP 没成功 | 插好网线；WiFi 用 `nmcli dev wifi list` 扫描 |
| `域名解析失败` | systemd-resolved 没运行或 resolv.conf 是坏链接 | `music net --fix` |

> 镜像里已经预装并开机自启了 **NetworkManager**（早期版本漏装，导致开机完全没网），
> 构建校验里也会断言它在，避免再回归。

```bash
# ★ 单曲搜索下载(最常用, 纯命令行, 只需要 requests)
music single "周杰伦 夜曲"
music single "五月天 突然好想你"

# 只看候选不下载
music search "夜曲"
music single "夜曲" --list

# 指定下载第 N 条候选
music single "夜曲" --index 2

# 歌单批量下载(CSV 放 ~/projects/gequhai-playlist-downloader/playlist.csv)
music playlist playlist.csv

# 终端播放器(乐库就是歌曲分区, 下载完直接听) ★
music play

# 图形界面: 搜索并下载单曲(夸克网盘转存, 需 PyQt6)
music gui

# 设/清代理(便携 U 盘上通常没跑 Clash, 直接清空)
music setup-proxy
# 看歌曲目录 / 已下载列表 / 环境自检
music out
music ls
music doctor
```

所有下载默认写到歌曲分区 `/mnt/songdisk`。下载前会自动检查该分区是否已挂载、是否可写，
没挂载会尝试自动挂载并给出明确提示，而不是直接报错。

`music play` 打开的是终端播放器 **music-shell**（Rust + ALSA，镜像预装，上游
[yao1987825/music-shell](https://github.com/yao1987825/music-shell)），乐库固定指向歌曲分区，
所以「下载 → 立刻能听」是连着的。它是全屏 TUI，会占住当前终端标签页；键位在界面里按 `?` 看，
`q` 退出。没有声音时先跑 `music health`（第 7 节会查播放器、乐库挂载、`audio` 组和声卡）。

也可以直接用原生命令：

```bash
cd ~/projects/gequhai-downloader
~/.venvs/music/bin/python /usr/local/lib/musictools/single.py "夜曲" --out /mnt/songdisk

cd ~/projects/gequhai-playlist-downloader
~/.venvs/playlist/bin/python gequhai_downloader.py --csv playlist.csv --out /mnt/songdisk
~/.venvs/playlist/bin/python convert_aac_to_mp3.py --dir /mnt/songdisk
```

> **为什么 `music single` 不需要 PyQt6？**
> `gequhai-downloader` 里的 `gequhai.py` / `quark.py` / `utils.py` 只依赖 `requests`，
> 只有 `manager.py` / `gui.py` 依赖 PyQt6（那是给图形界面用的）。
> 所以命令行单曲下载是独立的一条轻量链路，**slim 档镜像照样能用**。

### 3.1 夸克网盘扫码登录（下载前必做一次）

站点的低品质直链接口目前被限流（403），**夸克网盘转存是唯一能拿到完整音频的路**，
而转存必须带自己账号的 cookie。镜像里已经内置了扫码登录：

```bash
music quark-login     # 终端里显示二维码 → 用夸克 App 扫码 → 自动写好 cookie
music quark-status    # 检查这个 cookie 还能不能用 / 缺不缺主凭证
music quark-clear     # 清掉
```

**不需要浏览器，也不需要 Playwright/Chromium。** 走的是夸克网页端同一套纯 HTTP 接口：

```
GET https://uop.quark.cn/cas/ajax/getTokenForQrcodeLogin   → 二维码 token
扫码
GET https://uop.quark.cn/cas/ajax/getServiceTicketByQrcodeToken → service_ticket
GET https://pan.quark.cn/account/info?st=<ticket>&lw=scan   → 写入 cookie
```

这个做法来自 `quark-tool` 与 `quark-drive` 两个项目，它们各自独立实现了同一套流程、
端点完全一致。选它而不是 Playwright 的原因很实际：一台只有 U 盘 + 图形界面的机器，
少几百 MB 依赖、少一个容易坏掉的浏览器。

**⚠️ 千万别再用浏览器 F12 的 `document.cookie` 取 cookie。**
主凭证 `__pus` 是 **HttpOnly** 的，JavaScript 读不到，浏览器控制台拿到的 cookie 缺这一项，
夸克会把请求当游客，转存一定失败。`music quark-login` 走 HTTP 层，字段是全的。
`music quark-status` 会直接告诉你缺没缺 `__pus`。

其他细节：
- cookie 落盘前会**在线验签**（真打一次网盘接口），失败会明说，不会假装成功
- 写 `config.json` 前自动备份旧的，写完 `chmod 600`（cookie 是凭据）
- 终端上打印一律**打码**，只显示前 4 个字符和长度
- `qrcode` 没装也能用，只是二维码会退化成打印链接（终端太窄时用 `--url-only` 也行）

### 4. 两个下载器的分工（注意差别）

| | `gequhai-downloader` | `gequhai-playlist-downloader` |
| --- | --- | --- |
| 形态 | PyQt6 **图形界面**（`music gui`）+ 我们封装的**命令行单曲下载**（`music single`） | **纯命令行**（`music playlist`） |
| 输入 | 搜索框里打字 / 命令行传中文关键词 | 歌单 CSV（歌名+歌手） |
| 输出 | 直接下音频 + 歌词 + 封面 | 音频；**夸克网盘链接只存成 `.link.txt`，不会自动下载** |
| 额外依赖 | 图形界面需 PyQt6；命令行单曲下载只需 requests | Playwright Chromium（slim 档可选） |

`music single` 的下载链路和图形界面完全一致（夸克高品质 → 失败降级低品质直链 → 存歌词封面，
文件名 `标题-歌手.ext`），只是把 Qt 信号换成了终端输出。

图形版默认代理指向 Clash，但 U 盘机器上通常没跑 Clash → 直接在图形界面里把代理清空即可
（配置文件 `~/projects/gequhai-downloader/config.json`，镜像预置的是空代理版本）。
`music single` 读的是同一份 config，所以夸克 Cookie 配一次两边都能用。

### 4b. 无线网：插上就能连（`wifi` 命令）

插网线最省事, 但有些场合(比如插着 U 盘给笔记本用)只能走无线。
这套系统**没有面板也没有托盘图标**, 所以没有"点一下就连 WiFi"的图标 ——
用命令:

```bash
wifi                    # 列出周围的无线网
wifi scan               # 重新扫描
wifi connect "你的WiFi"  # 连接(会问你密码, 输入不回显)
wifi status             # 看当前状态(网卡/开关/连上了哪个)
wifi disconnect         # 断开
wifi forget "你的WiFi"  # 忘掉一个保存的连接(密码换了就用这个)
```

连过一次就记住了, 以后开机自动连; 也可以 `music wifi` 等同 `wifi`。

连不上时按这个顺序查:

| 现象 | 原因 / 怎么办 |
| --- | --- |
| `wifi` 说"没找到无线网卡" | 这台机器的网卡缺固件: Intel 装 `firmware-iwlwifi`, Realtek 装 `firmware-realtek`, Broadcom 装 `firmware-brcm80211`(镜像里已经预装了这几家的常用固件) |
| 网卡在但扫不到网 | 跑 `wifi unblock`(无线电被 rfkill 软锁), 开机也会自动解锁 |
| 提示"没有权限 / Not authorized" | 镜像已经给 netdev 组放行了, 仍报错就跑 `sudo wifi connect "名字"` |
| 连上但没网 | 跑 `music net` 看是 DHCP 还是 DNS 的问题 |

### 4c. 局域网急救包（`net` 命令）

这个 U 盘不只是一台"下载听歌机"。**局域网出问题时, 它是一套现场维修工具**:
网段被路由器改了、网关换了、IP 冲突、DNS 被劫持、无线掉线、交换机不转发 ——
插上 U 盘就能扫拓扑、跑检测、执行修复。

```bash
net topo      # 扫描局域网, 打印拓扑图
net probe     # 深度检测: 丢包/MTU/IP冲突/环路/DNS/无线/代理
net doctor    # 本机网络栈自检(NM/网卡/IP/路由/DNS)
net fix       # 安全自动修复(--renew/--flush-arp/--dns/--restart-nm)
net report    # 看历史报告(都在 ~/net-reports/)
```

#### `net topo` —— 局域网拓扑图

```
=== 局域网拓扑 · 2026-10-28 11:22 · 本机 debian-usb ===

本机网络身份
  · enp5s0   192.168.6.133   192.168.6.0/24   网关 192.168.6.1   DNS 192.168.6.1

拓扑结构
├── 🌐 路由器/网关  192.168.6.1
│       · MAC ca:79:f8:00:17:77 · 厂商 Xiaomi · 主机名 kwrt.lan · 延迟 1.1ms
├── 📱 手机  192.168.6.182
│       · MAC 06:e2:7f:49:f9:6f · 主机名 OnePlus-Ace-6T.lan · 延迟 113.4ms
│       · 判定依据: 主机名 'OnePlus-Ace-6T.lan'
└── 💻 电脑  192.168.6.186
        · MAC 00:e0:66:c8:37:91 · 主机名 debian.lan · 端口 22,445
```

设备类型是**推断**出来的, 依据三条线索(mDNS 服务 → 开放端口 → 主机名关键字),
判定依据会写在设备下面那一行。发现手段有四层: 内核邻居表 → ARP 二层扫描 →
ICMP 扫描 → mDNS/LLDP 广播, 少一层就少一类设备。

> ⚠️ **代理 ARP 陷阱**: 有些路由器会替整个网段应答 ARP。这时 ping 扫描会把
> 整个 /24 报成"在线"(实测报出 70+ 台假设备)。`net topo` 会识别并过滤,
> 提示"路由器开启了 Proxy ARP" —— 这种网段里**只有带 MAC 的才算真设备**。

**网段变更是能查出来的**: 每次扫描都会把网段/网关/DNS 记进
`~/.local/state/netkit/history.json`, 下次自动对比, 网段一变就报出来。
这解决了最常见的一类故障: 路由器把 192.168.1.0/24 改成了 192.168.6.0/24,
而某台设备还停在旧网段, 于是"能连路由器但连不上别的设备"。

#### `net probe` —— 哪里坏了

逐层检查, **每条结论后面都跟着可以直接执行的修复命令**:

```
==> 2. 网关与上游
  ✅ 网关可达 192.168.6.1
      平均 0.5ms · 抖动 0.2ms · 丢包 0%
==> 5. MTU
  ✅ MTU 正常(1500 字节)
==> 6. IP 冲突与设备盘点
  ✅ 没发现 IP 冲突
      扫到 5 个有 MAC 的地址
```

检查项: 网关可达性与丢包抖动、公网可达、路由环路(traceroute 重复跳)、
DNS 解析与劫持对比、MTU 探测、IP 冲突(同 IP 多 MAC)、设备盘点与同名设备、
无线信号强度与频段、IPv6、代理干扰。

#### `net fix` —— 安全修复

```bash
net fix --renew            # 重新申请 DHCP 地址(换网段后最常用)
net fix --flush-arp        # 清 ARP 表(网关换了、老设备"看不见"了)
net fix --dns 223.5.5.5    # 换 DNS
net fix --restart-nm       # 重启 NetworkManager
net fix --rebuild-resolv   # 重建 /etc/resolv.conf
```

### 4d. AI 排障助手（opencode + 网络排障技能）

镜像里预装了 **opencode**（约 205MB，离线可用），并配好了 5 个网络排障技能:
`lan-topology`（看拓扑）、`lan-triage`（分层定位）、`lan-repair`（执行修复）、
`lan-capture`（抓包）、`wifi-triage`（无线专项）。还有一份 `AGENTS.md`
告诉它"这台机器是干什么的"。

```bash
net ai                                    # 交互模式
net ai "家里网突然变慢了, 帮我查一下"      # 直接问
```

它会自己跑 `net probe` / `net topo` 定位问题, 然后给出可执行的修复步骤。

**第一次用要先配模型凭据**（镜像里不预置任何 API key，安全）：

```bash
opencode auth login        # 或 opencode providers
```

**如果开着代理报 `unsupported proxy protocol`**：那是代理协议的问题，不是 opencode 坏了。
opencode 是 Bun 写的，**只认 http/https 代理**，而 `proxy` 命令默认导出的是 `socks5://`，
Bun 碰上就抛 `UnsupportedProxyProtocol`。镜像里的 `/usr/local/bin/opencode` 是个包装脚本，
启动前会自己处理：能直连就直连，否则找同一台机器上的 HTTP 代理端口，都不行才报错。
想看当前代理状况：`opencode --net-check`。

> ⚠️ 权限说明: 按你的要求, opencode.json 里把 `bash`/`edit`/`read` 等权限**全部放开**了,
> 而且这台机器上 `sudo` 免密 —— 也就是说 AI 能以管理员身份执行任何命令。
> 这台 U 盘本来就是拿来现场救网络的, 风险可控; 但**别在存有重要资料的日常机器上
> 用这个镜像开 AI**, 或者把 `~/.config/opencode/opencode.json` 里的权限改回 `ask`。

两个实测踩过的坑(配置里已经处理好了, 别改回去):

| 坑 | 表现 | 现在怎么做的 |
| --- | --- | --- |
| `external_directory` 写成字符串 `"allow"` | **不生效**, 实际还是内置的 `ask` —— AI 一访问项目目录外的文件(比如 `~/net-reports/`)就卡在授权上 | 必须写成对象 `{"*": "allow"}`(这条权限只认对象) |
| `sudo opencode` 读不到配置 | opencode 的全局配置按 `$HOME` 找, root 的 HOME 是 `/root` | 构建期把整套配置复制一份到 `/root/.config/opencode/`, 包装脚本再导出 `OPENCODE_CONFIG` 兜底 |

另外 `read` 对 `*.env` 这类文件仍然要人工确认(那是 opencode 内置的安全默认, 没去动它)。

### 4e. 查火车票（`train` 命令）

出门前不用掏手机，插着 U 盘敲一行就知道有没有票：

```bash
train 北京 上海              # 今天
train 北京 上海 明天         # 也支持 后天 / +3 / 2026-10-30
train -g 北京 上海           # 只看高铁/城际（-d 动车 -t 特快 -k 快速 -z 直达）
train --json 北京 上海       # JSON 输出（给脚本或 AI 用）
train --stations 北京        # 查车站名/车站码
```

输出长这样：

```
2026-10-30  北京 → 上海   共 55 趟

车次   出发 → 到达        时间           历时
G531   北京南 → 上海虹桥  06:08 → 12:04  05:56  4  -  17  无  ...  有
G547   北京南 → 上海虹桥  06:18 → 12:11  05:53  17  -  有  有  ...  有
```

**关于来源**：集成的是 [train-tickets](https://github.com/yao1987825/train-tickets) 这个项目，
但上游代码在 12306 改过接口之后**已经跑不动了**（直接查接口只会拿到 HTML 反爬页，
抛 `JSONDecodeError`），而且座位字段下标整体错位了一格（"二等座"那列永远是空的）。

镜像里用的是**重写版**：

- 只用 Python 标准库（`urllib` + `http.cookiejar`），**不装 requests / docopt / prettytable / colorama**；
- 先访问余票首页拿会话 Cookie，再带正确请求头查接口（这是能跑通的关键）；
- 座位字段按真实车次逐个核对过（G1 `[30]=有 二等 / [31]=有 一等 / [32]=13 商务`，
  K545 `[29]=有 硬座 / [28]=无 硬卧`）；
- 车站表内置一份离线可用，查不到的新站会联网刷新并缓存；
- 错误是人话：日期没放票、车站名写错、网络不通，都会说清怎么办。

原项目本身也修了并推回 GitHub（会话 Cookie / 座位字段 / 新版 prettytable 的 API 三处）。

### 4f. 旅游攻略与行程规划（`travel` 命令 + opencode 技能）

接入了 [travel-planner](https://github.com/yao1987825/travel-planner) 项目：
**郴州 / 长沙 / 衡阳 / 上海 / 清远**五城的景点库、美食价格手册、小红书攻略，
景点之间的高德地图路线，以及实时天气 + 未来 3 天预报 + 穿衣/紫外线/舒适度指数。

对 AI 来说它是一个 **opencode 技能**（`travel-planner`），你直接说
"帮我规划郴州 3 天行程"它就会用；对人也有命令行：

```bash
travel weather 郴州                          # 天气(实时 + 3 天预报 + 生活指数)
travel nav --from 长沙橘子洲 --to 岳麓山 --mode transit   # 公交/地铁路线
travel nav --from 郴州西 --to 衡阳东 --mode driving       # 驾车路线
travel plan                                   # 交互式生成行程
travel plan --profile profile.json            # 按偏好 JSON 生成
```

高德 Key 已经配在技能目录的 `.env` 里
（`~/.config/opencode/skills/travel-planner/.env`），要换成自己的改那个文件即可。

> ⚠️ **这个 Key 会随镜像一起公开**（GitHub Release 是公开的）。建议在高德控制台
> 给它加「域名/IP 白名单」，或者自己换一个 Key 覆盖掉。
> 另外**公交路线**需要 Key 开通「公交地铁」服务权限，没开通会报
> `INSUFFICIENT_PRIVILEGES (10012)`；驾车/步行/地理编码/天气不需要额外权限。

集成时顺手修掉了这个项目两个**会导致结果完全错**的 bug（真机实测发现）：

| bug | 后果 | 修法 |
| --- | --- | --- |
| `--city` 默认写死"上海"且无条件套在起终点上 | 查"郴州西"会拿到上海去找，坐标全错 → 路线接口报 30001 | 默认空，不再无条件套 |
| 目的地不做城市限定 | 高德把"岳麓山"匹配到**乌鲁木齐**的岳麓山，长沙市内 3.8km 的路算出 **3823 公里** | 目的地用起点的城市限定；跨城查不到就静默退回 |

### 5. 基础命令行工具（以后往里加新功能用）

需求是"以后会再这个 u 盘系统中添加各种新功能，主要是终端命令方面，
所以基础的命令行工具需要具备"。所以镜像里预装了这几类：

| 类别 | 命令 |
| --- | --- |
| 找文件 | `rg`(ripgrep) `fd` `bat` `fzf` `tree` `locate` |
| 看内容 | `less` `cat` `head` `tail` `jq` `column` `diff` `patch` `file` |
| 跑起来 | `tmux` `screen` `htop` `btop` `ncdu` `watch` `time` |
| 打包解压 | `tar` `zip` `unzip` `7z` `xz` `zstd` `bzip2` `rsync` |
| 磁盘分区 | `lsblk` `blkid` `fdisk` `sfdisk` `sgdisk` `parted` `wipefs` `mount` `fsck` |
| 硬件状态 | `lspci` `lsusb` `lsmod` `lsof` `dmesg` `smartctl` `hdparm` `sensors` |
| 网络 | `ip` `ss` `ping` `dig` `nslookup` `traceroute` `mtr` `whois` `tcpdump` `netstat` `arp` |
| 出行 | `train`（火车票余票，纯标准库实现，零额外依赖） |
| 写脚本 | `bash` `python3` `pip` `vim` `nano` `shellcheck` `git` `curl` `wget` |

两个便利处理，以及一个**要知道的例外**：

- Debian 把 `fd` / `bat` 装成了 `fdfind` / `batcat`（避免和别的包撞名），
  镜像里补了软链，**你直接敲 `fd` / `bat` 就行**，不用记 Debian 的怪名字。
- 终端字体用 `Monospace`，中文靠 Pango 自动回退到文泉驿正黑，
  slim 档没装 Noto CJK 也不会出现方块字。
- **没有 `man`**。镜像为了省空间在构建第 8 步把 `/usr/share/man` 整个删了
  （几十 MB 起步，而日常几乎不查手册页），所以 `man` 这个命令也一起没装 ——
  装一个查不到东西的命令比不装更误导。**统一用 `--help`**：
  `music --help`、`usb-grow.sh --help`、`screen-fit --help` 都有。

> 想在 U 盘里加自己的东西，直接往 `~/projects/` 放脚本，再在
> `/usr/local/bin/` 放个软链就能全局调用；改完 `bash -n` 一下再用。

---

## 四、想改构建参数

在 Actions 页面点 **Run workflow** 就能改：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `suite` | `bookworm` | `bookworm`=Debian12，`trixie`=Debian13 |
| `profile` | `full` | **`slim` = 纯命令行档**：不装 PyQt6 / Playwright Chromium / Noto CJK，**省约 1.3GB**。`music single` 与 `music playlist`（静态搜索）照常可用，图形界面和浏览器回退启动后按需补装 |
| `img_size_mb` | `8192` | 镜像总大小。**填大只是让压缩包变大**，真正的大小写盘后用 `usb-grow.sh` 扩 |
| `root_size_mb` | `6144` | 根分区大小，装大量 Python 包时可以调大 |
| `with_bios_grub` | `0` | 传统 BIOS 的 GRUB（现代 UEFI 机器不需要） |
| `with_projects` | `1` | 是否预装两个下载器 + Playwright Chromium |
| `apt_mirror` | 清华 TUNA | 镜像里的 apt 源，**填 `off` 保持官方源** |
| `pip_index` | 清华 TUNA | 镜像里的 pip 源，**填 `off` 用默认 PyPI** |
| `proxy_url` | `socks5://192.168.6.1:1070` | 预置代理。**只是写好配置，不会强制打开** —— `/etc/profile.d/99-proxy.sh` 每次登录先探端口，通了才用 |

> 换源为什么放在构建的**最后**：`debootstrap` 和那一大堆 apt 安装要跑在 GitHub 的美国节点上，
> 走 `deb.debian.org` 反而更快更稳；成品拿到国内再用清华源才划算。所以脚本是
> 「先用官方源装完 → 再把 `sources.list` 换成清华源 → 验一次 `apt-get update`」。
> 万一构建机拉不动清华源，会自动回退官方源并在 `BUILD-INFO.txt` 里标注，不会假装成功。

### 两个档位差在哪

| 组件 | `full` | `slim` | 缺失后怎么办 |
| --- | --- | --- | --- |
| `music single`（命令行单曲下载） | ✅ | ✅ | 只依赖 requests，两档都可用 |
| `music playlist`（歌单批量） | ✅ | ✅ | slim 档只有静态搜索，搜不到时 `music setup-playwright` |
| `music gui`（图形界面） | ✅ | ❌ | `music setup-gui`（约 250MB） |
| Chromium 浏览器回退 | ✅ | ❌ | `music setup-playwright`（约 500MB） |
| Noto CJK 字体 | ✅ | ❌ | slim 档只保留文泉驿正黑（15MB），字形少一些 |

镜像大小写盘后用 `usb-grow.sh` 扩，**填大 `img_size_mb` 只是让压缩包变大**，不划算。

> `slim` 档仍然保留 **Xfce + Fcitx5/Rime**：纯 TTY 下中文输入法没法工作，
> 这是你"要中文输入"和"不要大桌面"之间唯一可行的折中。Xfce 本身（`--no-install-recommends`）
> 只占约 300MB，远小于完整桌面。

镜像越大，GitHub Actions 的磁盘占用和压缩耗时也越大（runner 只有约 14G 临时空间，
`img_size_mb` 建议不超过 `12288`）。

### 构建时会自动瘦身的部分

母盘打完包前，构建脚本会删掉这些"装了但用不上"的内容并记录释放量
（只是删静态文件，`/var/lib/dpkg` 包数据库不动，apt 状态不会坏）：

| 删什么 | 说明 |
| --- | --- |
| `/usr/share/doc` 里包的 README/changelog | 每包只留 `copyright`，文档在官网都有 |
| `/usr/share/man` `/usr/share/info` `/usr/share/groff` | 手册页，镜像里压根没有 man 工作流 |
| `/usr/share/locale` 除 `zh_CN`/`en_US`/`C*` 外的翻译 | 镜像是给中文用户用的 |
| `/var/lib/apt/lists` `/var/cache/apt` | apt 索引和下载缓存；运行时再装包先 `apt-get update` 即可 |

---

## 五、常见问题

**Q：开机进不去 / "no bootable device"**
1. 确认是从 U 盘启动（启动菜单里选 U 盘，别选内置硬盘）。
2. Secure Boot：镜像里带 Debian 官方 shim 签名，一般能过；如果固件还是拦截，
   进 BIOS 把 `Secure Boot` 关掉即可。
3. 传统 BIOS 老机器：在 Actions 里把 `with_bios_grub` 设为 `1` 重新构建。
4. 部分老主板只认 `Legacy/USB-HDD` 模式，需要在 BIOS 里关掉 UEFI 启动。

**Q：写盘后 Windows 提示需要格式化**
正常。Windows 不认识 ext4/EFI 结构的 Linux 盘，别在 Windows 上给它分配盘符。

**Q：构建中途失败**
把 Actions 里失败步骤的日志贴出来即可。绝大多数失败来自网络（debootstrap / apt / pip 源），
重跑一次通常就好。

**Q：下载下来的歌是 `.link.txt` 而不是音频**
说明站点只给了夸克网盘分享链接，CLI 版不会自动转存。用图形版（`music gui`）配合夸克 Cookie 才会真正下载。

**Q：命令行下载提示"夸克转存与低品质直链都不可用"**
2026-10 实测：站点的低品质直链接口 `/api/music` 已返回 `{"code":403,"msg":"访问异常"}`
（加 Referer / session 均无效），**所以夸克 Cookie 目前是下载成功的必要条件**，图形版也一样。
配置一次即可，图形界面和命令行共用同一份 `~/projects/gequhai-downloader/config.json`：

```json
{ "proxy": "", "quark_cookie": "这里粘贴 F12 Console 里 document.cookie 的值" }
```

**Q：搜某个歌名提示"没有搜到"**
站点的搜索对**词序敏感**：`五月天 突然好想你` 搜不到，但 `突然好想你 五月天` 有结果。
`music single` 已经内置了这个兜底（自动反转词序 / 拆词重试），仍然搜不到时建议只输入歌名。

**Q：开机连不上网**
先跑 `music net`（或 `net-doctor`），它会逐层告诉你是网卡、IP、路由还是 DNS 的问题，并给出修复命令。

已知的历史坑：早期版本的 x86 镜像**没有安装任何网卡配置服务**（Debian 12 + Xfce 默认不带
NetworkManager/ifupdown/dhcpcd），开机后没人给网卡做 DHCP，表现为"完全没网络"。
现已预装并开机自启 NetworkManager，且结构校验里会断言它在。

手动修：
```bash
sudo apt-get install -y network-manager wpasupplicant
sudo systemctl enable --now NetworkManager
music net --fix
```

**Q：连上网都做不到（连 `apt-get install` 都跑不了）**
用 `net-rescue`。它不需要联网、不需要 iproute2，只用 systemd 自带的能力：
```bash
sudo net-rescue
```
流程是：先启用 `systemd-networkd` 做自动 DHCP（这个二进制就在 systemd 包里，一定存在），
20 秒内拿不到 IP 再退回手工配静态地址。老版本镜像没有 NetworkManager 时，这是唯一能救的路。
联网之后补装长期方案：
```bash
sudo apt-get install -y network-manager
sudo systemctl enable --now NetworkManager
sudo systemctl disable --now systemd-networkd   # 别让两个一起管网卡
```

**Q：`usb-grow.sh` 跑起来没反应 / 不知道它做了什么**
新版脚本会先打印完整的环境诊断再动手，输出同时写 `/var/log/usb-grow.log`。
先用 `usb-grow.sh --check` 看诊断（不需要 root），确认它认出了正确的磁盘和分区再执行。
普通用户看到"读不到分区扇区范围"是正常的 —— 读整块磁盘要 root，重新用 `sudo usb-grow.sh --check` 跑一遍。
认分区这段逻辑可以脱离磁盘单测：`usb-grow.sh --self-test`。

**Q：插到不同显示器上分辨率不对（画面拉伸 / 字糊 / 字特别小）**
Xorg 开机经常随便挑一个模式（比如 1024x768），而不是这块屏自己的原生分辨率。
镜像里已经装好 `screen-fit`，**每次图形登录会自动按 EDID 匹配每一块屏**：

```bash
screen-fit            # 立刻检测并应用
screen-fit --list     # 只看不改：每块屏"当前 / 建议"
screen-fit --dry-run  # 打印会执行的 xrandr 命令
screen-fit --disable  # 不想要开机自动匹配时关掉（手动调过分辨率就用它）
```

原理是从 `xrandr --verbose` 里抠出每块屏的 EDID 原始数据，按 EDID 规范解析
时序描述符（**基础块的 DTD + CTA-861 扩展块里的 DTD 都扫** —— 非 16:9 的面板，
比如 1440x900，原生模式常常只写在扩展块里），再在 xrandr 列出的模式里挑，逐块屏单独设置。

挑选顺序（`screen-fit --list` 会标明用的是哪一条）：

1. EDID 里的原生尺寸，驱动确实给这个模式 → 用它，取该尺寸下最高刷新率
2. EDID 里的其他原生尺寸，哪个被驱动给了用哪个
3. **离 EDID 原生最近的那个**（按面积接近度 + 宽高比接近度）—— 驱动没给原生
   模式时的正解。旧版这里是直接"取面积最大"，于是不管接什么屏都被拉到同一个
   大分辨率（1440x900 的屏被设成 1920x1080 就是这么来的）
4. 完全没有 EDID 才退回"刷新率 ≥60 的面积最大"，输出里会标明是推测值

`screen-fit --list` 还会显示这块屏的 EDID 原生尺寸和物理尺寸（mm），方便核对。

两个容易踩的细节：
- `--mode` 只能给**模式名**（`640x480`），不能把 `xrandr --query` 打印的那一整行
  （`640x480       73.00*`）塞进去 —— 塞了 xrandr 就报 `cannot find mode`，
  一块屏都设不成。刷新率走单独的 `--rate`。
- "当前模式"以 xrandr 打在模式后面的 `*` 为准，而不是输出头部那行
  （`640x480+0+0` 带不出刷新率）。同一分辨率挂着好几个刷新率时，
  用头部那行判断会把"已经是了"误判成"需要设置"，对着当前模式白设一次。
- 有一块屏没设成功时 `screen-fit` 返回**非零**退出码（开机自启的 `--restore` 与
  `music-health` 都靠这个判断）。

**Q：代理怎么用（默认 socks5://192.168.6.1:1070）**
```bash
proxy                 # 等同 proxy status
proxy status          # 地址 / 端口通不通 / apt / 下载器 / PySocks 各是什么状态
proxy on              # 开启：apt + 下载器 + 终端环境变量
proxy on 192.168.1.9:7890
proxy off             # 全部关掉
proxy test            # 实测：真发一个请求看能不能出去
```

镜像里预置了 `/etc/profile.d/99-proxy.sh`，它**先探测端口通不通，通了才 export `http_proxy`**。
这一步是刻意的：代理没跑的时候如果还硬设 `http_proxy`，症状是"所有下载全部失败"，
比压根没有代理更难查。`music proxy` 是同一个命令。

注意 `/etc/profile.d` 只有**登录 shell** 才读，而 `xfce4-terminal` 开出来的是非登录 shell
（只读 `~/.bashrc`）。所以镜像里同时在 `user` 与 `root` 的 `~/.bashrc` 里 source 了同一份脚本，
两条路都通 —— 在桌面终端里新开一个窗口就能拿到 `http_proxy`。

两个容易踩的点已经处理好了：
- `apt` 用不了"先探后用"的写法，所以 apt 的代理由 `proxy on` / `off` 显式开关，
  并且自动把 `socks5://` 转成 apt 认的 `socks5h://`。
- Python 的 `requests` 默认**不支持** `socks5://` 代理（会报 `ProxySchemeUnknown`），
  所以镜像里预装了几个 venv 都带 `PySocks`，`proxy on` 也会顺手补装。

第三点：**音乐工具（`music search` / `single` / `gui` / `playlist`）会主动绕开环境代理**。
同一时刻实测三个目标：

| 目标 | 直连 | 走 LAN 代理 |
| --- | --- | --- |
| `www.gequhai.com`（搜歌 / 播放页） | **200**，能解析出全部候选 | **403** 反爬挑战页 → 搜到 0 条 |
| `pan.quark.cn`（夸克转存） | **200** | SSL 失败 |
| `img2.kuwo.cn`（封面） | **200** | SSL 失败 |

所以 `music` 在跑这几个下载命令前会 `env -u http_proxy ...` 把环境代理摘掉 ——
症状"浏览器能打开站点、`music search` 却一条都搜不到"就是这么来的（浏览器不读
`http_proxy`，走的本来就是直连）。`git` / `pip` 这类真需要代理的命令不受影响；
`config.json` 里显式配的 `proxy` 仍然有效。

**Q：QEMU 冒烟测试报"没捕获到 GRUB 输出"**
这只是警告，不是失败。OVMF 可能没走 UEFI 可移动介质路径，或串口输出没打开；结构校验通过就说明镜像结构没问题。

**Q：`music single` 报"项目源码的接口和本脚本对不上"**
`gequhai-downloader` 上游改了接口（比如 `search_songs` 改名、删了 `safe_filename`）。
本脚本在调用前会做 `hasattr` 预检，缺哪个接口会直接列出来，而不是甩一屏 traceback。
处理办法：`cd ~/projects/gequhai-downloader && git pull` 看是不是上游变了；
如果确实变了，同步改 `single.py` 里的 `REQUIRED_API`，或者先用 `music gui` 走图形界面。

---

## 六、也可以不用 GitHub Actions，在本地 Linux 上直接构建

任何有 root 的 Linux（虚拟机 / 容器 + `--privileged`）都行：

```bash
sudo apt install debootstrap e2fsprogs dosfstools mtools gdisk xz-utils
sudo bash scripts/build-image.sh
# 产物: out/debian-usb-bookworm.img
```

本地构建会占用约 8~10GB 磁盘 —— 这正是我们把这件事搬到 CI 上的原因。

---

## 七、仓库结构

```
debian-usb-builder/
├── .github/workflows/
│   ├── build-usb-image.yml                   # x86 镜像 CI 流水线
│   └── build-n1-image.yml                    # Phicomm N1 镜像 CI 流水线(ARM64 runner)
├── scripts/
│   ├── build-image.sh                        # x86: debootstrap → 分区 → GRUB → 预装
│   ├── verify-image.sh                       # x86: 结构校验 + QEMU 启动冒烟测试
│   ├── build-n1-image.sh                     # N1: ophub rebuild → 追加 MUSIC 分区 → 预装
│   ├── n1-customize-rootfs.sh                # N1: ARM64 chroot 装软件栈 + 中文输入法
│   ├── verify-n1-image.sh                    # N1: 分区表/引导码/内核/fstab 结构校验
│   ├── lint-helpers.sh                       # 静态扫描: 未定义的函数 / 定义晚于调用(见下)
│   ├── test-lint-helpers.sh                  # 上一个的自测(8 项)
│   ├── test-music-cli.sh                     # music 命令行回归测试(见下)
│   ├── test-music-play.sh                    # music play 播放器接线回归测试
│   ├── test-net-kit.sh                       # 局域网诊断 netkit + opencode 集成回归测试
│   └── tests/                                # lint 的**故意写错**的测试夹具
│       └── lint-fixture-bad.sh
├── overlay/                                  # x86 与 N1 共用, 直接覆盖到镜像 rootfs 里
│   ├── usr/local/bin/
│   │   ├── usb-grow.sh                       # x86: 一键扩展分区到整盘(GPT)
│   │   ├── net-doctor                       # 网络逐层自检 + 自动修复
│   │   ├── net-rescue                       # 没网时的应急联网(只用 systemd 自带能力)
│   │   ├── net                              # 局域网急救包入口(topo/probe/doctor/fix/ai/report)
│   │   ├── audio-setup                      # 把 ALSA 默认输出直通声卡(修"播放器没声音")
│   │   ├── opencode                         # AI 排障助手(离线可用, 需自配 API key)
│   │   ├── screen-fit                       # 按 EDID 自动匹配每块显示器的原生分辨率
│   │   ├── proxy                            # 代理开关(status/on/off/test)
│   │   ├── music-health                     # 一次性体检(会话/输入法/终端/分辨率/分区/网络/夸克)
│   │   ├── music-im-fix                     # 输入法一条命令修好(装包→im-config→自启→拉起)
│   │   ├── terminal-keepalive               # 终端窗口全没了自动拉起(桌面没面板没图标, 唯一的兜底)
│   │   ├── terminal-new                     # 在当前终端窗口加一个标签页(xfce4-terminal --tab)
│   │   ├── terminal-keys                    # 键位速查表
│   │   ├── terminal-setup                   # 改 Ctrl+Alt+T 键位 + 桌面项 Exec
│   │   ├── terminal-welcome                 # 开机那个终端: 先打键位速查表再进 shell
│   │   └── music                             # 下载器快捷入口(single/playlist/gui/doctor/net/screen/proxy/keys/im-toggle/terminal)
│   ├── usr/local/lib/musictools/
│   │   ├── single.py                         # 命令行单曲搜索下载(纯 requests, 不用 PyQt6)
│   │   └── quark_login.py                    # 夸克网盘纯 HTTP 扫码登录(不需要浏览器)
│   ├── usr/local/lib/screentools/
│   │   └── fit.py                            # EDID/xrandr 解析 + 分辨率方案(support --self-test)
│   ├── usr/local/lib/netkit/                 # 局域网诊断实现(Python3, 无额外依赖)
│   │   ├── netinfo.py                        # 本机网络身份 + 历史快照(网段变化检测)
│   │   ├── devclass.py                       # MAC/端口/mDNS 线索 -> 设备类型
│   │   ├── discover.py                       # 设备发现(ARP/ping/mDNS/LLDP 多源合并 + 代理ARP过滤)
│   │   ├── topo.py                           # 拓扑组装 + ASCII 树渲染
│   │   ├── probe.py                          # 丢包/MTU/IP冲突/环路/DNS/无线 检测
│   │   └── cli.py                            # net 子命令分发
│   ├── home/user/.config/opencode/           # AI 排障助手(全局配置 + 技能)
│   │   ├── opencode.json                     # 权限配置(全放开) + skills 路径
│   │   ├── AGENTS.md                         # 告诉 AI 这台机器是干什么的
│   │   └── skills/                           # lan-topology/lan-triage/lan-repair/lan-capture/wifi-triage
│   ├── home/user/.local/share/fcitx5/rime/   # Rime 配置(注意: 必须在 Rime 用户目录里)
│   ├── home/user/.config/xfce4/terminal/     # 终端配置(字体/滚动/标签页快捷键)
│   ├── home/user/.config/autostart/          # 开机自启: 终端守护/键位设置
│   └── home/user/.tmux.conf                  # tmux 预置配置(进阶用, 默认不启用)
├── overlay-n1/                               # 仅 N1 使用
│   └── usr/local/bin/n1-grow.sh              # N1: 把卡的剩余空间扩给歌曲分区(只改 MBR 4 字节)
├── .gitattributes                            # 强制 LF 换行(CRLF 会让 Linux 跑不了脚本)
└── README.md
```

镜像是怎么造出来的（关键技术点）：

- `mke2fs -d` 把 rootfs 目录直接灌进 ext4 镜像文件，**全程不需要 loop 设备或挂载**，
  所以在 Actions 这种普通容器/VM 环境里也能稳定构建；
- EFI 分区用 `mkfs.vfat` + `mtools` 写入，同样不用挂载；
- fstab 与 GRUB 里用到的 UUID 在建文件系统**之前**就生成好，因此不需要事后回填；
- EFI 分区里的 `grub.cfg` 只做一件事：`search.fs_uuid` 找到根分区 → `configfile` 加载真正的
  `/boot/grub/grub.cfg`，和 Debian 官方安装器的 `--removable` 引导方式完全一致。

---

## 八、命令行回归测试

`music` 这层壳子（子命令分发 + 参数透传）出过一次很隐蔽的 bug：
`case` 分支已经 `shift` 掉子命令名，`cmd_single` 内部又 `shift` 了一次，
结果 `music single "周杰伦 夜曲" --list` 变成 `music single --list` ——
**关键词被吃掉，而且不报任何错**，只是搜不到东西。

所以加了一个不依赖网络、不依赖真实站点的回归测试：

```bash
bash scripts/test-music-cli.sh
```

它用假的 `mountpoint` 和假的 venv python 拦住真实下载，只检查参数有没有原样传下去，
覆盖 `single` / `search` / `download` / `--index` / 缺关键词 / `doctor` / `out` / `which`。

这个测试在 CI 里跑两道：
- 流水线开始时对仓库里的脚本跑一遍；
- 结构校验阶段，对**镜像里安装的那份** `music` 再跑一遍
  （x86 用 `debugfs` 把 `/usr/local/bin/music` 抠出来跑，N1 直接在挂载的 rootfs 里跑）。

也就是说，**参数透传类的 bug 没法再混进产物**。

局域网诊断工具（`net` / netkit）和 opencode 集成也有自己的回归测试：

```bash
bash scripts/test-net-kit.sh
```

它守住这些容易悄悄坏掉的地方：

- netkit 各模块语法正确、关键函数还在（改着改着 `import` 就炸）；
- `net` 的六个子命令都接得上；
- 构建脚本装了 opencode、**钉了 sha256 校验和**、装齐了局域网发现工具；
- `opencode.json` 是合法 JSON（opencode 对配置严格校验，字段写错直接拒绝启动），
  权限确实是放开的；
- 5 个 skill 的 frontmatter 里 `name` 与目录名一致、都有 `description`
  —— 这两条不满足时 opencode 会**静默地**不加载那个技能，不测就发现不了；
- 代理 ARP 过滤逻辑还在（这是拓扑图不变成"70+ 台假设备"的关键）；
- 音频直通的接线还在（`dmix` 插件链会让播放器写不进声卡）。

---

## 八之二、构建脚本的静态检查（lint-helpers）

2026-10-22 有一次构建在第 4/9 步失败：

```
scripts/build-image.sh: line 496: ok: command not found
```

原因是 `build-image.sh` 定义了 `log/warn/die/step`，却直接调用了 `ok`。
**`bash -n` 和 shellcheck 都查不出这类错误**（语法完全合法），
而 `set -e` 要等运行到那一行才炸 —— 也就是白白浪费一次 20 分钟的构建。

同类错误还有第二个形态：**函数定义写在调用后面**。bash 是先定义后使用，
`selftest_count` 定义在第 495 行、第 460 行就在用它，同样是 `command not found`。

所以加了 `scripts/lint-helpers.sh`，专门抓这两类：

```bash
bash scripts/lint-helpers.sh        # 扫全仓库(约 1 秒)
bash scripts/test-lint-helpers.sh    # linter 自己的自测(8 项)
```

判定「命令位置」的规则很保守：只认**行首缩进**和**紧跟在 `&&` `||` `;` `|`
`(` `{` `!` 之后**的调用；整行注释和 heredoc 正文整段跳过，中文提示语里的
英文单词不会被误判。常见外部命令走白名单。

linter 自己也有自测（`test-lint-helpers.sh`），因为 linter 一旦坏了是
**静默失效**——它会报「一切正常」，真正的错误又得等 20 分钟才炸。
自测里有一条用**历史上真正炸掉过的那份 `build-image.sh`** 做回归用例，
必须报出第 496 行；CI 是浅克隆拿不到历史版本，所以另有一份等价的固定夹具
（`scripts/tests/lint-fixture-ok-missing.sh`）保证任何环境下都能跑到。

CI 里这两步是**阻塞**的：有问题几秒内就失败，不会再浪费构建机。

---

## 九、Phicomm N1（Amlogic S905D）电视盒子镜像

x86 的 Debian 镜像在 N1 上跑不起来（CPU 架构、引导方式、内核全都不同）。
N1 这条产线走的是社区成熟方案 **[ophub/amlogic-s9xxx-armbian](https://github.com/ophub/amlogic-s9xxx-armbian)**：
拿官方发布的 arm64 基线镜像，用它的 `rebuild` 脚本重打包成 N1 板型
（正确的 dtb `meson-gxl-s905d-phicomm-n1.dtb` + u-boot `u-boot-2015-phicomm-n1.bin`），
再叠加我们的软件栈与歌曲分区。

### 1. 触发构建

Actions 页面 → **Build Phicomm N1 Armbian Image** → **Run workflow**。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `board` | `s905d` | ophub 板型库里的 **BOARD 列**（不是型号名）。`Phicomm-N1` = `s905d`；以太网流控关掉时用 `Phicomm-N1(DMA-thresh)` = `s905d-n1-thresh`。填型号名 `Phicomm-N1` 也可以，脚本会自动翻译 |
| `distro` | `trixie` | 基线发行版：`trixie` / `bookworm` / `noble` / `resolute` |
| `profile` | `desktop` | `desktop` = Xfce 图形桌面；`cli` = 纯命令行（X11 + xterm，也能用中文输入法） |
| `rootfs_size_mb` | `4096` | 根分区大小，Xfce + Python 环境建议 ≥ 4096 |
| `bootfs_size_mb` | `512` | 内核 + dtb 分区，最小 256 |
| `music_size_mb` | `2048` | 歌曲分区大小，写卡后可用 `n1-grow.sh` 扩到整卡 |
| `with_pyqt` | `0` | 预装 PyQt6 图形版。N1 的 Mali-450 无 3D 加速，Qt 走软件渲染很慢，默认不装 |
| `with_playwright` | `0` | 预装 Playwright Chromium。官方没有 arm64 内核包，默认不装 |

产物：`armbian-n1-image-s905d-trixie-desktop`，里面有 `*.img.gz`（约 1.5GB）+ `SHA256SUMS-N1.txt` + `BUILD-INFO-N1.txt`。

> 镜像里有**两个账号**：Armbian 自带的 `root` / `1234`，以及我们创建的 `user` / `user`（sudo 免密）。

### 2. 分区布局

N1 用的是 **MBR(msdos)** 分区表（社区惯例），分区：

```
p1  BOOT     fat32   512MiB   内核 + dtb + u-boot overload
p2  ROOTFS   ext4    4096MiB  系统根 /            (标签 ROOTFS)
p3  MUSIC    ext4    2048MiB  歌曲盘 → /mnt/songdisk (标签 MUSIC)
```

### 3. 写卡与启动

```bash
# Linux
gzip -dc Armbian_*.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

**Windows**：Rufus → 选 SD 卡 / U 盘 → **DD 模式** → 选 `*.img.gz` → 开始。

插好后从盒子的启动菜单（多数 N1 是 U 盘口供电 + 按住遥控器电源键，或短接 eMMC 触点）启动。
第一次进系统用 `root` / `1234`（Armbian 默认，个别版本是 `root` / `armbian`），进去后改密码并建自己的账号。

### 4. 开机后

```bash
# 把卡的剩余空间全部给歌曲分区
sudo n1-grow.sh
sudo n1-grow.sh --dry-run    # 先看计划

# 改完密码后切换到普通用户
passwd root
adduser user && passwd user
```

其余（中文输入法、`music single` / `music playlist` / `music gui`、Rime 词库）跟 x86 镜像完全一样，
命令见第三章。

### 5. N1 这条产线上的关键坑（都已处理）

| 坑 | 处理方式 |
| --- | --- |
| **改分区表会把盒子改到起不来** | Amlogic 的引导链在 MBR 里：前 446 字节是引导区（`u-boot-2015-*.bin` 前 512 字节是空的引导头，所以这块本来就是 0），**真正的 u-boot 本体在扇区 1（偏移 512）**。用 `parted`/`sfdisk`/`sgdisk` 改表会冲掉它们。本仓库改为**手工写 MBR 里 p3 的 16 字节分区条目**，其余字节一个都不碰；改完还会逐字节比对 0..445 与 512..1023 两个区域确认没动过 |
| 判断"引导码在不在"也会踩坑 | 不能只看 MBR 前 64 字节是不是 0 —— 那样会把正常的镜像误判成"引导码丢失"。正确口径是：**扇区 1（偏移 512）必须有 u-boot 代码** |
| `n1-grow.sh` 扩容同理 | 只改 MBR 里"分区 3 扇区数"那 **4 个字节**（偏移 490），引导码零改动 |
| 站点低品质直链 403 | 与 x86 一致：夸克 Cookie 是下载成功的必要条件，`music single` 会给出明确提示 |
| Playwright 无 arm64 浏览器 | 默认不装浏览器；`playwright` / `imageio-ffmpeg` / `PyQt6` 三个 Python 包本身都有 aarch64 wheel，能正常装上 |
| PyQt6 需要 glibc ≥ 2.39 | `PyQt6 6.11.0` 是 `manylinux_2_39_aarch64`，**Debian 13 (trixie) 满足**；Debian 12 (bookworm, glibc 2.36) 装不上，所以 N1 默认用 trixie |
| ARM runner 磁盘紧张 | 构建过程中基线镜像、内核包、中间产物都用完即删；建议 `rootfs_size_mb` 不要超过 4096 |

### 6. 真机测试清单（交付前必须过一遍）

CI 只能保证镜像结构正确，**能不能在真 N1 上跑起来只能靠实机**。烧完卡后按下面逐项过：

**A. 烧录与引导**
- [ ] `dd` / Rufus(DD 模式) 写卡完成，重插后能被识别
- [ ] 盒子能启动：HDMI 有画面，或串口 `ttyAML0` 能看到内核日志
- [ ] 用 `root` / `1234` 登录（个别 Armbian 版本是 `root` / `armbian`）
- [ ] `cat /proc/cmdline` 里能看到 `root=UUID=...` 和 `meson-gxl-s905d-phicomm-n1.dtb`
- [ ] 重启 3 次，每次都能正常引导（u-boot 引导链是最容易出问题的地方）

**B. 分区与挂载**
- [ ] `df -h` 能看到 `/` (ROOTFS) 和 `/mnt/songdisk` (MUSIC) 两块，容量与预期一致
- [ ] `mount | grep songdisk` 正常，`touch /mnt/songdisk/x` 能建文件
- [ ] `sudo n1-grow.sh --dry-run` 显示的扩容计划正确，再 `sudo n1-grow.sh` 实跑一次

**C. 中文输入**
- [ ] `fcitx5 -v` 有版本号；`im-config -m` 显示 `fcitx5`
- [ ] 图形界面里 `Ctrl+Space` 能切出输入法，拼音 `zhoujielun` 出「周杰伦」
- [ ] `~/.config/fcitx5/rime/user.dict.yaml` 里 73 条词库生效（随便挑一个冷门歌手试试）
- [ ] 纯命令行模式下 `startx` 进 xterm，输入法同样能用

**D. 下载器**
- [ ] `music doctor` 各项状态正常
- [ ] `music single "周杰伦 夜曲" --list` 能列出候选（**这一步专门验参数没被吃掉**）
- [ ] `music single "夜曲" --index 2` 能下载到 `/mnt/songdisk`
- [ ] `music playlist playlist.csv` 能跑完整批次
- [ ] 配了夸克 Cookie 后能下到真正的音频文件（而不是 `.link.txt`）

**E. 性能与稳定性**
- [ ] `free -h` 看内存余量（N1 只有 2GB，Xfce + 浏览器比较吃紧）
- [ ] `music gui` 能不能起来（默认没装 PyQt6，要 `music setup-gui` 补装）
- [ ] 连续下载 10 首歌不崩

### 7. 还没验证 / 可能需要另行处理的部分

| 项目 | 现状 |
| --- | --- |
| 板型是否匹配 | 板型库只有 **S905D** 的 N1 条目。如果你的盒子是 S905X 或魔改版，dtb 不对会黑屏，需要另找 dtb |
| HDMI 输出 | ophub 的 uEnv.txt 默认 `video=HDMI-A-1:1920x1080@60e`。你的显示器/线材如果不同步，改这个参数 |
| WiFi | 板型描述里写的是 `brcm43455-wifi`。主线内核用 `brcmfmac`，固件由 ophub 的 firmware 仓库提供，需在设备上实测能否出热点 |
| eMMC 写入 | 镜像只做到"从卡启动"。装进 eMMC 要另外跑 `armbian-install`（脚本已把该命令删掉，需要时从官方镜像里取） |
| 遥控器 | N1 靠红外遥控开机，USB 键盘鼠标只能进系统后用 |

---

## 免责声明

镜像里预置的下载器仅供个人学习与技术实验使用。请自行确认你拥有相关内容的合法下载、
保存与格式转换权限，遵守著作权人的授权条件与目标站点的服务条款。
