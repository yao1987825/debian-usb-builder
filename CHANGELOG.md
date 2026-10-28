# 更新日志

本文件记录每个发布版本的改动。发版方式：改完代码 → 打 `vX.Y.Z` tag 推上去 →
GitHub Actions 自动构建镜像并发布到 [Releases](https://github.com/yao1987825/debian-usb-builder/releases)。

版本号按语义化版本：

| 位 | 什么时候变 | 对使用者的影响 |
| --- | --- | --- |
| 主版本 | 镜像里的大功能、或者改了默认行为（分区布局、登录方式等） | 旧 U 盘建议重新写盘 |
| 次版本 | 新增功能 | 老 U 盘不受影响 |
| 修订号 | 只修 bug | 老 U 盘不受影响 |

---

## v1.3.0 (2026-10-28)

- **新增功能: 局域网急救包(`net` 命令)—— 把 U 盘变成"网络维修工具"**
- **新增功能: opencode + 5 个网络排障技能 —— AI 带着技能一起查网络**
- **修复: `music play` 没声音(ALSA 默认输出绕过 dmix 插件链)**

### 🌐 局域网急救包: `net` 命令

之前这套系统只能"下载 + 听歌"。现在它还能**现场修网络** —— 假设问题出在局域网
内部设定上(网段变了、网关换了、IP 冲突、DNS 被劫持、无线掉线、交换机不转发),
插上 U 盘就能扫拓扑、跑检测、执行修复。

| 命令 | 干什么 |
| --- | --- |
| `net topo` | 扫描局域网, 打印拓扑图(ASCII 树) |
| `net probe` | 深度检测: 丢包/抖动、MTU、IP 冲突、路由环路、DNS 劫持、无线信号、IPv6、代理干扰 |
| `net doctor` | 本机网络栈自检(等价老的 `net-doctor`) |
| `net fix` | 安全修复: `--renew` / `--flush-arp` / `--dns` / `--restart-nm` / `--rebuild-resolv` |
| `net ai` | 用 opencode + 网络排障技能问 AI |
| `net report` | 看历史报告(`~/net-reports/`) |

实现放在 `overlay/usr/local/lib/netkit/`(纯 Python3, 不引第三方库), 关键设计:

- **多源设备发现**: 内核邻居表 → ARP 二层扫描(arp-scan/arping) → ICMP 扫描 →
  mDNS(avahi) → LLDP(交换机通告), 每个设备都记录"是从哪儿发现的"。
  设备类型由三条线索推断: mDNS 服务 → 开放端口(打印机 9100、NAS 445/32400、
  摄像头 554、iPhone 62078) → 主机名关键字, 并把判定依据打印出来。
- **代理 ARP 必须处理**: 有些路由器会替整个网段应答 ARP, ping 扫描会把整个 /24
  报成"在线"(实测报出 70+ 台假设备)。`net topo` 会识别并过滤, 只保留真设备,
  并明确提示"路由器开启了 Proxy ARP"。
- **网段变更可追溯**: 每次扫描把网段/网关/DNS/IP 存进
  `~/.local/state/netkit/history.json`, 下次自动对比并报出"网段变了: A -> B"。
  这直接对应用户提的"局域网网段变动"场景。
- **每条结论带修复命令**: `net probe` 的输出不是"建议检查一下", 而是
  `修复: sudo net fix --renew` 这种可以直接粘的。

新装的轻量依赖(都是几 MB): `arp-scan` `iputils-arping` `ethtool`
`avahi-utils` `lldpd`。

### 🤖 opencode + 网络排障技能

镜像里预装了 opencode v1.19.4(官方预编译二进制, 约 205MB, 离线可用,
构建期下载并**钉了 sha256 校验和**; 官方 release 不发 checksums, 所以校验值
写在 `scripts/build-image.sh` 里当锁文件用)。

预置 `~/.config/opencode/opencode.json` + `AGENTS.md` + 5 个技能:

| 技能 | 管什么 |
| --- | --- |
| `lan-topology` | 扫拓扑并解读(网段/网关/设备类型/代理 ARP 陷阱) |
| `lan-triage` | 分层定位: 物理 → 链路 → 网络 → DNS → 应用 |
| `lan-repair` | 执行安全修复(改完必须复检) |
| `lan-capture` | 抓包定位(DHCP/ARP/DNS/握手) |
| `wifi-triage` | 无线专项(固件/rfkill/信号/频段/漫游) |

用法:

```bash
opencode auth login              # 第一次要先配模型凭据(镜像不预置任何 API key)
net ai                            # 交互模式
net ai "家里网突然变慢了, 帮我查"   # 直接问
```

#### ⚠️ 顺手修掉: `unsupported proxy protocol`

用户实测报 `unsupported proxy protocol`(UnsupportedProxyProtocol)。**是代理引起的**:
opencode 是 Bun 写的, 它的 HTTP 客户端**只认 http/https 代理**, 而这套系统的
`proxy` 命令默认导出的是 `socks5://` —— Bun 碰上 socks5 就直接抛
`UnsupportedProxyProtocol`(不是 opencode 坏了, 也不是 key 或模型的问题)。

现在 `/usr/local/bin/opencode` 是一个包装脚本(真身在
`/usr/local/lib/opencode/opencode`), 启动前先把代理处理掉:

1. 代理是 http/https → 原样用;
2. 代理是 socks5 → 先测直连能不能到模型 API:
   - 直连能 → **去掉代理变量直接连**(最常见, 实测直连可达);
   - 直连不能 → 找同一台机器上的 HTTP 代理端口(8080/7890/3128/8118/10809/20171),
     有就改用它;
   - 都没有 → 打印一句人话告诉用户怎么办, 而不是甩一个天书般的协议报错。

体检命令: `opencode --net-check`

> ⚠️ 按需求把 opencode 的 `bash`/`edit`/`read` 等权限**全部放开**, 且这台机器
> `sudo` 免密 —— AI 能以管理员身份执行命令。日常主力机上建议把权限改回 `ask`。

### 🔊 修复: `music play` 没有声音

**症状**: 播放器 TUI 正常显示"正在播放 0:05 / 4:25", 进度条一直在走, 但一点声音都没有。

**根因**(2026-10-27 真机定位): Debian 的 ALSA `default` 走 **dmix 插件链**,
dmix 的 slave 是 MMAP 模式, 应用侧的 `avail`/`avail_min` 语义跟 cpal(rodio 底层)
的写入循环对不上 —— cpal 以为自己还有空间, 实际一个样本都写不进去。
客观证据: `/proc/asound/card0/pcm0p/sub0/status` 里 **`appl_ptr` 恒为 0**
(而 `hw_ptr` 正常推进), 说明 DMA 在空转放静音。
TUI 的进度是 rodio 的 `controls.position` 时钟, 不代表声卡真收到了样本。

**修法**: 让默认输出**直通声卡硬件**, 绕开 dmix。新增 `audio-setup`:
开机由 `audio-direct.service` 自动跑一次, 生成 `/etc/asound.conf`
(`pcm.!default { type hw; card N; device M }`); `music play` 之前也会检查一次,
所以不重启也能生效。

**实测**: 直通后 `access` 从 `MMAP_INTERLEAVED` 变成 `RW_INTERLEAVED`,
`appl_ptr` 从 0 变成持续推进(397312 → 532480), 声音恢复。

代价: 直通后没有软件混音(一次只能一个程序发声)。想恢复:
`sudo audio-setup --restore`。

### 📦 其他

- 新增 `scripts/test-net-kit.sh`: 守住 netkit 模块、子命令接线、opencode 校验和、
  配置 JSON 合法性、5 个 skill 的 frontmatter、代理 ARP 过滤、音频直通接线。
- `scripts/verify-image.sh` 增加断言: net 命令、netkit 模块、opencode 二进制、
  opencode.json、5 个 skills、audio-setup、audio-direct.service 必须在镜像里。
- CI 流水线增加"局域网诊断 netkit 回归测试"步骤。

---

## v1.2.0 (2026-10-27)

- **新增功能: `music play` —— 终端播放器, 下载完直接听**

### 🎵 播放器进镜像: music-shell (预编译产物)

用户要把 music-shell 的播放功能放进镜像。选型实测(2026-10-27 真机):

| 方案 | 结论 |
| --- | --- |
| 镜像里装 rust 现场编 | ✗ Debian 12 的 rustc 是 1.63, 编不动 `edition = "2024"`(要 ≥1.85) |
| 用上游 release 预编译产物 | ✅ v0.5.0 最高只要 **GLIBC_2.34**, Debian 12 (glibc 2.36) 上直接能跑 |

真机冒烟(PTY 跑 TUI): `音频已连接` → `▶ 正在播放 0:00 → 0:29 / 3:54`, 无报错;
声卡 HDA Intel PCH 存在, `user` 已在 `audio` 组。

改动:

- **构建期下载安装**: `scripts/build-image.sh` 从
  `github.com/yao1987825/music-shell/releases` 拉 `v0.5.0` 的
  `music-shell-x86_64-unknown-linux-gnu.tar.gz` + `checksums.txt`,
  **sha256 校验不过就拒装**; 本机构建时还会当场跑一次 `--version` 暴露 glibc 不兼容。
  版本可用 `MUSIC_SHELL_VERSION` 环境变量覆盖。
- **apt 清单补 `libasound2`**(rodio/ALSA 运行库, 上游 README 明确要求, 少了播放器起不来)
  + `alsa-utils`(`aplay`/`amixer`, 排查声卡用)。
- **乐库配置**: 预置 `~/.config/music-shell/config.json`, `library_path` 固定指向
  `/mnt/songdisk`(歌曲分区), 于是「`music single` 下载 → `music play` 立刻能听」是连着的。
- **`music play` 子命令**: `cmd_play()` 先 `songdisk_check`(分区没挂就别开, 否则
  是空库还会在根分区建出空目录), 再 `exec music-shell` 移交控制权(TUI 占终端)。
- **`music health` 第 7 节**: 查播放器版本、乐库挂载与曲目数、`audio` 组、声卡存在性。
- **构建/产物双重断言**: `build-image.sh` 断言二进制 + libasound2 + 配置 +
  `cmd_play` 接线; `verify-image.sh` 用 debugfs 对分区里的产物再断言一遍。
- **回归测试** `scripts/test-music-play.sh`(9 组: 语法/接线/构建期安装/JSON 模板/
  verify 断言/缺播放器时的报错), 已接入 CI。

已知边界: `music-shell update`(自更新)与下载工具不同, 它需要访问 GitHub,
在便携 U 盘上如果 shell 设了代理会走代理 —— 正常; 没设代理时国内直连 GitHub
的 release 域名通常也不通, 需要时先 `music proxy on <地址>`。

---

## v1.1.2 (2026-10-27)

- 2026-10-27 真机反馈: **`music search` 搜不到, 但浏览器能打开站点**

### 🎵 修 `music search` 搜到 0 条: 下载工具绕开环境代理

用户原话:"很奇怪。如果说访问不了的话, 为什么我在我浏览器能够访问到里面的内容"
—— 猜得对, 不是站点挂了, 是**走的路不同**。同一时刻实测:

| 目标 | 直连 | 走 LAN 代理 (socks5://192.168.6.1:1070) |
| --- | --- | --- |
| `www.gequhai.com` 搜索页 | **200**, 能解析出 15 条 | **403** 反爬挑战页(164 字节) → 0 条 |
| `pan.quark.cn` (夸克转存) | **200** | SSL 失败 |
| `img2.kuwo.cn` (封面) | **200** | SSL 失败 |

根因链: 终端登录时 `/etc/profile.d/99-proxy.sh` 探到代理端口就自动 export
`http_proxy` → `requests` 即使拿到空代理配置也会去读环境变量 → 请求从代理出口
出去 → 站点对这个出口回 403 → 页面里没有歌名 → 解析出 0 条 → 报"没有搜到"。
浏览器不读 `http_proxy`, 走的本来就是直连, 所以浏览器那边一切正常。

修法:

- `music` 跑下载工具 (`single` / `gui` / `playlist`) 前用 `env -u http_proxy ...`
  摘掉环境代理; `git` / `pip` 这类真需要代理的命令不受影响
- `single.py` 启动时也摘一遍 (绕过 `music` 直接 `python3 single.py` 一样直连);
  `config.json` 里显式配的 `proxy` 仍然有效
- `music-health` 第 5 节加"音乐站点直连可达"检查 —— 搜不到时先跑 `music health`
  就能看到是哪一层
- 新增回归测试 `scripts/test-music-proxy.sh` (假项目 + 必死的代理, 带对照组) 并接进 CI

真机复验 (终端里带 `http_proxy` 的环境, 正是出问题的环境):

- `music search "爱在西元前"` → **15 条候选** (周杰伦 / Cover / Live / DJ 版都在)
- `music single "爱在西元前" --index 1` → 夸克高品质下载完成,
  音频 / 歌词 / 封面落到 `/mnt/songdisk/周杰伦/`
- `music health` → `✅ 音乐站点直连可达(200) —— music search 能用`

## v1.1.1 (2026-10-27)

- 2026-10-27 真机反馈: **有线网络没问题, wifi 无法使用**

### 📶 修无线网: 装好固件、解锁、授权、给个能用的入口

用户反馈"有线网络没问题, wifi 无法使用"。真机逐层查下来不是一个原因, 是四个叠在一起:

1. **镜像里一个网卡固件都没装**。换台 Intel/Realtek/USB 网卡的机器, 无线接口
   根本不出现(ath9k 这种固件内置的除外)。现在预装
   `firmware-iwlwifi` / `firmware-realtek` / `firmware-brcm80211` / `firmware-atheros`。
2. **无线电被 rfkill 软锁**。这套系统没有托盘图标也没人手动解锁, 结果就是
   "有线能上、无线上不去"。新增 `wifi-unblock.service`, 开机自动
   `rfkill unblock wifi` + `nmcli radio wifi on`。
3. **NetworkManager 的 polkit 策略要管理员认证**。普通用户敲 nmcli 直接吃到
   `Not authorized to control networking` —— 而这套无头系统里没有 polkit
   认证代理。新增 `/etc/polkit-1/rules.d/50-netdev-network-control.rules`,
   给 netdev 组放行网络控制权。
   *注意扩展名必须是 `.rules`*: polkit 122 只加载 `.rules` 的 JS 规则,
   `.pkla` 是旧 XML 格式, 会被**静默忽略** —— 规则文件明明在, polkit 日志也说
   "编译了 N 条规则", 但我那条根本没被算进去(真机踩过)。
4. **没有连 WiFi 的入口**。没有面板也没有托盘, 小白根本不知道敲什么。
   新增 `wifi` 命令(也可用 `music wifi`):

   ```bash
   wifi                    # 列出周围的无线网
   wifi scan               # 重新扫描
   wifi connect "名字"      # 连接(问密码, 不回显)
   wifi status             # 网卡/开关/连上了哪个
   wifi disconnect         # 断开
   wifi forget "名字"      # 忘掉保存的连接(密码换了用这个)
   wifi on | off | unblock
   ```

   命令内部走 sudo(这套系统 sudo 免密), 所以不受第 3 条的授权问题影响;
   顺带在 `net-doctor` 里加了"2b. 无线网卡"一节, 连不上时直接告诉你卡在哪一层。

真机复验: 普通用户 `nmcli` 的 network-control 权限从"验证"变成"是",
`nmcli dev wifi connect` 不再报 Not authorized(而是正常走到认证阶段),
`wifi list` / `wifi status` 输出正常。

## v1.1.0 (2026-10-25)

- 2026-10-25 真机反馈: **开机后第一个终端输入法没激活, 只有开新标签页才能打中文**
  / **按 Print 弹"无法打开…"警告框**
- 2026-10-24 真机反馈: 标签页切换快捷键不明 / 关光后黑屏 / Ctrl+Alt+T 盖住整个屏幕
  / Shift 切换偶尔失灵 / 基础命令行工具不够
- 本版改动都已在真机重启后复验(开机第一个窗口直接打中文、Print 无警告弹窗、
  Super 方向键窗口操作正常、屏幕只有一个终端窗口)

### 🐛 修开机输入法: 第一个终端也能直接打中文

真机现象: 开机后第一个终端窗口里打字直接进 shell, `Ctrl+Space` 没反应,
**开一个新标签页输入法才活**。定位到三个环环相扣的原因:

1. **切 rime 的时机太早, 而且没人重试**。老写法是"等 fcitx5 有应答 →
   `sleep 1` → `-s rime`", 而 fcitx5-remote 能应答时 rime 引擎往往还没注册完
   —— 此刻发切换会**静默失败**, 开机就永远停在 keyboard-us 直写态。
   现在自启项在后台**反复重试**(最多 120 次, 每次最多等 10 秒), 直到
   `fcitx5-remote -n` 真的报 `rime` 才算完, 并往 `~/.config/fcitx5-boot.log`
   写一行开机结果(以后再出问题一眼能看出卡在哪)。
2. **开机终端开得太早**。它只等"名字上 dbus 总线"就开窗, 那一刻 fcitx5 的
   **输入法模块还没应答**, GTK 端的 im-fcitx5 握手失败后不会恢复 —— 这个窗口
   就终身绕不过输入法。现在改成等 `fcitx5-remote -n` 能返回输入法名
   (模块活了) 才开第一个窗口(有上限, 超时照样开, 不把桌面卡死)。
   **注意不是等"引擎已经切成 rime"**: 真机实测 profile 的 `DefaultIM` 会在运行中
   被 fcitx5 改写(用户上次停在英文态, 下次开机 `DefaultIM` 就变回 keyboard-us),
   而**新建 IM 上下文时会按 `DefaultIM` 重置整组** —— 等引擎再开窗反而会被重置回
   英文。反过来: 先开窗, 引擎随后切到 rime, **已建立的上下文会跟着切**
   (真机实测: 同一个窗口手动 `-s rime` 后立刻就出候选)。
3. **第二个 fcitx5 实例**。老的 `fcitx5-default.desktop` 用 `fcitx5-remote` 轮询
   探测"fcitx5 起没起", 而这个探测本身会触发 dbus 按 `.service` **再拉起一个实例**,
   两个实例抢同一个 IM context。现在: 自启项合并成一个, 构建期把
   `/usr/share/dbus-1/services/org.fcitx.Fcitx5.service` 改名禁用。

配套: 终端守护的开机宽限期 10s → 45s(别跟"等输入法模块应答的终端"抢出两个窗口)。

真机复验(重启后全程不碰键盘): fcitx5 单实例、`im=rime`、**开机第一个窗口
直接打出中文候选**、Shift 中英切换正常、屏幕只有一个终端窗口。

顺带把 Rime 的 CapsLock 从 `switch_key/Caps_Lock: inline_ascii` 改成
`good_old_caps_lock: true` —— 前者在 librime 1.8.5 上会把 CapsLock 降级成
"临时西文"(要按两次才回来), 比默认还难用。

### ⌨️ 修快捷键警告框: 按 Print 不再弹"无法打开…"

真机反馈: "无法打开 print 快捷键这样的警告提示"。真因是这个镜像故意极简
(不要面板/桌面图标/文件管理器/浏览器), 但 **XFCE 默认快捷键还绑着一堆没装的程序**:

| 按键 | 原绑定 | 状态 |
| --- | --- | --- |
| Print / Shift+Print / Alt+Print | `xfce4-screenshooter` | 没装 |
| Super+e / Ctrl+Alt+F | `thunar` | 没装 |
| Super+r / Alt+F2 / Alt+F3 | `xfce4-appfinder` | 没装 |
| Alt+F1 | `xfce4-popup-applicationsmenu` | 没装 |
| Ctrl+Shift+Esc | `xfce4-taskmanager` | 没装 |
| Ctrl+Esc | `xfdesktop --menu` | 没装 |
| Alt+Super+s | `orca` | 没装 |
| XF86WWW / HomePage / XF86Mail | `exo-open --launch WebBrowser/MailReader` | 没浏览器/邮件客户端 |

按下去 XFCE 就去执行一个不存在的命令, 随即弹"无法打开…"的警告框。

- 失效绑定**直接废掉**(改绑 `/bin/true`: 按了没反应, 但不再弹警告);
- 截图键例外: 镜像里已有 `scrot`(依赖极小), 套一层 `/usr/local/bin/screenshot` ——
  **Print=全屏 / Shift+Print=框选 / Alt+Print=当前窗口**, 存到 `~/Pictures`;
- 新增 `/usr/local/bin/keyboard-fix`: 登录时自动跑一遍, 把通道里**所有**
  指向缺失程序的绑定统统废掉(XFCE 插件自带的默认表不只在文件里, 登录时会
  同步进通道, 只改文件压不住), 顺带把截图键和窗口快捷键写上;
- 顺手把用户要的窗口操作写进用户级快捷键: **Super+←/→ 左右平铺, Super+↑ 最大化,
  Super+↓ 还原**, 开机终端也改成**直接最大化**。

### 🔧 修构建: v1.0.5 的镜像其实一次都没构建成功过

v1.0.5 的构建挂在**自家断言**上:

```
[fatal] Rime 的 ascii_composer 写成了字符串而不是 键->动作 映射, Shift 永远不会生效
```

但 Rime 配置明明是对的。真因是**断言的正则写错了**:

```bash
# 断言(错): 冒号前面少算了一个引号
grep -qE 'ascii_composer/switch_key/(Shift_L|Shift_R): inline_ascii' "$RIME_CFG"

# 文件里的实际内容: key 是带引号的, 冒号前面还有一个引号
"ascii_composer/switch_key/Shift_L": inline_ascii
```

正则永远匹配不上 → 掉进 `elif` 分支 → 直接 die。
而报出来的错("写成了字符串")和真因(正则少了个引号)完全对不上,
于是日志把人引向错误的方向。

修法: 正则里补上可选引号 `"?`, 三处一起改
(`build-image.sh` / `verify-image.sh` / `music-health`)。
**同样的错在 `music-health` 里更阴** —— 它会把配置正确的镜像
误报成"Shift 永远不会生效", 让用户去反复折腾一个没坏的输入法。

### 终端体系: 一个窗口 + 标签页 + 永不消失

针对三条终端反馈:

- **关掉所有标签页就黑屏**。这个桌面没有面板也没有桌面图标(用户明确不要),
  所以终端窗口全没了就是真的什么都不剩。新增 `terminal-keepalive`:
  每 3 秒查一次还有没有终端窗口, 没有就拉起一个。
  开机有 10 秒宽限期, 免得和开机终端抢跑开两个窗口。
  `music terminal on/off/status` 控制。
- **标签页切换快捷键不明**。`~/.config/xfce4/terminal/terminalrc` 里
  **显式写死** NewTab / NextTab / PrevTab / CloseTab, 不依赖默认值;
  再加上 `~/.bashrc` 里让**标签页标题跟随当前目录**
  (标签上显示 `user@deb: Downloads`, 一眼看出是哪个标签)。
- **Ctrl+Alt+T 盖住整个屏幕**。新增 `terminal-new`(`xfce4-terminal --tab`:
  已有窗口就加标签页, 没窗口才开新窗口)和 `terminal-setup`:
  开机时用 `xfconf-query` 把 XFCE 里所有指向终端的快捷键改成 `terminal-new`,
  **改完复查一遍**; 兜底再改桌面项的 `Exec` ——
  只用 sed 换 `Exec=` 那一行, Name/Icon/Categories 原样保留
  (`exo-open --launch TerminalEmulator` 是按 Name 匹配的, 改名字就找不到了)。
  两个桌面项都处理: `xfce4-terminal-emulator.desktop`(`xfce4-settings` 装的,
  XFCE 快捷项走这个)和 `xfce4-terminal.desktop`。
- **开机就是终端**。接在上游已有的 `xfce-terminal.desktop` 自启项上
  (它负责等 fcitx5 就绪), 用 `-e /usr/local/bin/terminal-welcome` 先打一张
  键位速查表再进 shell。**不另开自启项**, 免得开机弹出两个终端窗口。
- 预置 `~/.tmux.conf`(进阶用, 默认不启用 —— 多个终端 attach 同一 tmux 会话
  反而看到同一个画面, 只会更乱)。

### 中英文切换: 加一条不看状态的开关

真机反馈"偶尔按 Shift 切不动"。真因是**状态**, 不是配置:

fcitx5 处于 `Inactive`(英文态)时按键根本不经过输入法, Rime 收不到 Shift;
中文态下一切正常 —— 合起来看就成了"偶尔失灵"。
(另外 Rime 的 `ascii_composer` 只在**没有预编辑**时才处理 Shift。)

- 新增 `music im-toggle`: 先读 `fcitx5-remote` 状态再决定发 `-c` 还是 `-C`,
  **不看当前状态**都能切
- Rime 另配 `Caps_Lock` 切换键(比 Shift 少一类误判)
- `music health` 直接报出当前是中文态还是英文态, 并说明此时按 Shift 无效
- README 写清 `Ctrl+Space` / `music im-toggle` / `Shift` / `CapsLock` 的可靠性排序

### 基础命令行工具

新增 ripgrep fd-find bat fzf ncdu jq tree less nano bash-completion
p7zip-full zstd unzip zip lsof procps psmisc diffutils patch net-tools
traceroute mtr-tiny whois tcpdump pciutils usbutils lm-sensors smartmontools
hdparm btop shellcheck plocate bsdextrautils tmux screen wmctrl xdotool

- Debian 把 `fd` / `bat` 装成 `fdfind` / `batcat`, 镜像里补了软链,
  直接敲 `fd` / `bat` 就行
- **没有装 man**: 第 8 步瘦身会把 `/usr/share/man` 整个删掉,
  装一个查不到东西的 `man` 命令比不装更误导, 统一用 `--help`

### 校验

- 构建期断言: 终端脚本齐全 / terminalrc 写了标签页快捷键 / 自启项在 /
  开机终端接上了速查表 / `.tmux.conf` 在 / Rime 有 CapsLock
- 结构校验同样断言, 外加 10 个命令行工具 + `fd`/`bat` 软链
- 回归测试新增: `music keys` / `music terminal on|off|status|new` /
  未知子命令返回 2 / `im-toggle` 三种状态

---

## v1.0.5

- 2026-10-24 真机反馈: "开机自启的终端里按 Shift 切不了中英文, 打出来还是繁体字"
- 用户要求: 只保留一个输入法、Shift 切中英、输出简体

### 输入法重构: 只留 Rime(简体) + Shift 切中英

三个连环坑，逐个挖出来的：

1. **Rime 的配置从没被读过**。fcitx5-rime 的"用户目录"是
   `~/.local/share/fcitx5/rime/`，而我们把 `default.custom.yaml` 放在了
   `~/.config/fcitx5/rime/` —— Rime 根本不看那个目录。真机表现是"Shift
   按了没反应"，而构建期断言查的也是这个错路径，一直绿灯自欺。
   现已移到正确目录，并在 build-image.sh / verify-image.sh 里断言真实路径。
2. **右 Shift 不切换**。Rime 共享 default.yaml 里 `Shift_R: commit_text`
   （只提交不切换），习惯按右 Shift 的人会觉得"切换不了"。左右统一改成
   `inline_ascii`：预编辑为空时按一下进 ASCII 直写，再按一下回中文。
   注意 Rime 的 ascii_composer 只在"没有预编辑"时处理 Shift —— 正在打拼音
   想临时切英文，先按 Esc 清掉预编辑再按 Shift。
3. **开机默认是键盘直写态**。fcitx5 起来后当前输入法落在 `keyboard-us`
   （rime 是 on-demand addon，DefaultIM 不生效），此时按 Shift 根本没人
   接管按键 —— 这才是"Shift 完全没反应"的直接原因。现在：
   - profile 里只留 `rime` + `keyboard-us` 两项，rime 排第一；
   - 新增自启项 `fcitx5-default.desktop`，等 fcitx5 就绪后
     `fcitx5-remote -s rime`，开机即中文态。

### 繁体字问题

原来 profile 里的 fcitx5 内置拼音(pinyin 引擎)首候选是繁体("國家")，
而且它不吃单键 Shift。按用户要求"删掉其它输入法，只留一个"：
镜像与真机都已卸载 `fcitx5-chinese-addons`(-bin/-data)，只保留 Rime，
并用 `luna_pinyin_simp` 方案锁死简体输出(首候选"国家")。

### 关于搜狗

Debian 12 仓库里没有搜狗包(`sogoupinyin`/`fcitx-sogoupinyin` 候选为空)，
搜狗 Linux 版基于已淘汰的 fcitx4，与 fcitx5 混装必炸。等价替代是 Rime
(可定制、纯简体、Shift 可切)。

### 附带

- `~/.config/autostart` 目录原本是 root:root，用户连自启项都加不了 → 构建期
  改为归用户。
- `music-health` 修 Rime 路径误报，并新增"当前输入法是不是 rime"检查
  (不是 rime 就提示 Shift 不会有反应)。

## v1.0.4

- 2026-10-23 真机（v1.0.3 + 64G U 盘）实测发现两个"扩了但文件系统永远不补"的连环 bug
- 2026-10-24 同台真机复现"开机自启的终端永远打不出中文"，根因是 autostart 竞态
- 2026-10-24 真机通缉另外两坑：MUSIC 挂载点属主不可写；夸克下载恒 412
- 2026-10-24 新功能：单曲下载自动按歌手归类；`music reorg` 兼容历史平铺文件

### MUSIC 挂载点属主：user 不可写("错误: 歌曲分区不可写")

mkfs 出来的 ext4 根目录属主是 root:root，迁移数据时 rsync 只搬子目录内容，
盘根 inode 永远是 root —— user 下载/搜索直接报"歌曲分区不可写"。usb-grow
在 mount /mnt/songdisk 之后显式把挂载点 chown 给 uid=1000(幂等无害)。

### 夸克下载恒 412：cookie 缺 __puus(上游补丁)

夸克 CDN 直链必须带新鲜 `__puus` cookie(约 3 小时有效)，但扫码登录拿到的
11 个字段里根本没有它；取直链的 /file/download API 响应的 Set-Cookie 会
首次下发。上游 Yannick-Mo/gequhai-downloader 不处理 → 取链成功但下载恒
412(Tengine)。新增 scripts/patch-quark-puus.py：抓 API 响应 Set-Cookie 的
__puus 合回 cookie 再交给 download_file；构建期在 clone 之后打补丁，补丁
没打上会 die。真机验证：'突然好想你-五月天.mp3'(10.6MB)成功落 /mnt/songdisk。

### 单曲下载自动按歌手归类

`music single` 的产物不再平铺在歌盘根目录，而是落
`<歌盘>/<歌手>/<歌名-歌手>.mp3(.lrc/.jpg)` 三件套同目录。已有文件用
`music reorg` 一次性归档（按文件名最后一个 - 切出歌手）；`music ls`
会同时列出根目录与歌手子目录里的文件。真机验证：下载"光良 童话"
自动创建 `光良/` 子目录，三件套齐全。

### autostart 竞态：开机首个终端窗口终身无法输入中文xfce4-session 并行拉起所有 autostart 项，实测开机首窗 terminal(666) 抢在
fcitx5(675) 之前启动。GTK 端 im-fcitx5 模块这时连 fcitx5 的 dbus 握手失败
后**不会恢复**，这个窗口从此按键直通 shell（预编辑/候选窗/ctrl+space 全部
无反应），但手动新开的任何终端窗口都完全正常 —— 因为此时 fcitx5 早已就绪。

- 症状与 2026-10-23 的"env/配置都对了还是切不动"完全是另一回事：输入法
  引擎、配置、dbus 总线全部健康，坏的只是"第一个窗口的时间窗"。
- 修复：terminal 的 autostart 改为等待 `org.fcitx.Fcitx5` 出现在 session
  bus 上再启动（最长约 15 秒，超时兜底照常开终端，不会卡死桌面）。
- 构建期加断言：autostart 里必须含 `NameHasOwner` 等待，否则 die。
- 真机验证：镜像内同款修复部署后重启，开机自动打开的首个终端窗口中
  xdotool 打 `nihao` 能提交出"你好"（截图确认候选流程恢复）。

### 问题链（第一次开机表现正确，之后全卡住）

第一次开机把 MUSIC 数据搬好、分区表写完（用户中途手动 `sudo reboot` 抢在
sgdisk 之前完成是运气好）；之后每次开机本该走"补文件系统"的路，却有两处
死结拦住，盘永远停在 root 6G / MUSIC 1.5G 的半扩状态：

1. **空闲判定按物理末尾算**。GPT 备份头占磁盘最后 34 个扇区，MUSIC 已经
   长到 last usable 时，`TOTAL - MUSIC_LAST - 1` 还能算出 33 个扇区的
   "伪空闲" → 不走"已用满"分支，继续重规划 → 对齐后的边界落进老 MUSIC
   触发"贴尾巴"分支 → MUSIC 新家只剩 33 扇区 → 被几何守卫拦下报
   "新位置放不下老数据"。改为按 `TOTAL - 34`（GPT 可用上限）算空闲，且
   剩余不足一个对齐单位（2MiB）就直接进补账分支，绝不再重规划。
2. **dumpe2fs 解析永远失败**。`fs_size_sectors` 用 `awk -F': '` 取 `$2`，
   但真实输出是 `Block count:` 后跟一列空格再跟数字，`$2` 把前导空格
   一起带回，`^[0-9]+$` 永远匹配不上 → 返回空 → `is_lagging` 恒为
   "没欠账" → 连"补账"分支都进不去。改为取行尾字段 `$NF`，并把解析逻辑
   拆成 `parse_fs_sectors` 纯函数、用真机实际输出格式进自测回归。

### 验证

- 真机当场验证：修复版脚本推上去后 `--auto` 一次跑完，root 6G→21G
  （在线 resize2fs）、MUSIC 1.5G→37G（e2fsck + resize2fs）全部到位

---

## v1.0.3

- 2026-10-23

真机（v1.0.2 + 64G U 盘）测出来的四个问题，加上"以后都不用手动操作"的要求。

### 修复

#### `usb-grow.sh`：文件系统补不齐就再也补不齐了

**现象**：分区表改成功、root 扩到 21G，但 MUSIC 的 `resize2fs` 报
`Please run 'e2fsck -f /dev/sdb4 first` 失败；此后**重跑多少次都没用** ——
磁盘已经没有空闲扇区，脚本开头一句"磁盘已用满, 什么都不做"就退出了。

**原因**：脚本把"磁盘没有空闲扇区"当成了"没事可做"。但此时分区表已经改完，
MUSIC 分区变大了、文件系统还是老大小 —— 这是"欠账"，需要的是 `resize2fs`
而不是重新划空间。

**改法**：

- 用 `dumpe2fs -h` 读出文件系统真实大小，和分区大小比对，欠账就走补齐流程
  （这个判断是纯算术函数 `is_lagging`，带 1MiB 容差，已进自测）
- MUSIC 补扩展前先 `e2fsck -f -p`，否则 `resize2fs` 只会甩那句 e2fsck 提示然后失败
- 不再相信 `partx -u` 的退出码（它会返回 0 却什么都没做），改为拿
  `/sys/class/block/<分区>/size` 里内核认的扇区数与分区表比对，不一致就
  `partprobe` → `blockdev --rereadpt` 再试一遍，然后明确告诉用户
  "剩下的收尾会在下次开机自动完成"

#### 分辨率：1440x900 的屏一直被设成固定的大分辨率

**现象**：换好几块屏试，每次都被设成同一个分辨率（驱动给的模式表里最大那个）。

**原因**：两处叠加。① 只扫 EDID 基础块的时序描述符，非 16:9 面板（1440x900 /
1280x1024）常把原生模式写在 CTA-861 扩展块里，于是解析不到；② 解析不到就掉进
"取面积最大"的兜底，于是每块屏都被拉到同一个大分辨率。

**改法**：

- EDID 基础块 + CTA-861 扩展块一起扫（`--list` 会显示"EDID 原生 xxx"）
- 驱动没给原生模式时，取**离原生最近**的那个（面积接近度 + 宽高比接近度），
  而不是面积最大；没有 EDID 时才用老兜底
- 自测新增 6 项（1440x900 回归、扩展块原生、4:3 不跳 16:9 等），共 41 项

#### 输入法：切不动（配置属主是 root）

**现象**：v1.0.2 里 Ctrl+Space 切不动，v1.0.1 正常。

**原因**：`~/.config/fcitx5/profile` 和 `config` 是在构建脚本 `chown -R` **之后**
才写出来的，属主落成 `root:root 0644` —— 普通用户读得到、写不进去。fcitx5 切换
输入法时要往这两个文件写状态，写不进去就没反应（而且时好时坏，很难查）。

**改法**：

- 写完显式 `chown` 回用户；构建期和 `verify-image.sh` 都**断言属主**，
  属主不对直接让构建失败，不给这种坑再流到用户手上
- `fcitx5-frontend-gtk3` / `fcitx5-frontend-qt5` 从"可选包"提到**必装**
  （前端缺失时终端里 Ctrl+Space 完全没反应，而用户只会觉得输入法坏了）
- `music health` 新增这两项检查，`music im-fix` 新增自动改属主

#### `music-health`：`/run/udev/data` 路径少了 `b` 前缀

和 `usb-grow.sh` 同一个根因（udev 块设备条目叫 `b8:3` 不是 `8:3`），
导致分区名一栏经常显示"无分区名"。两种文件名都试。

### 新增

- **开机自动扩容**：`usb-grow.service`（oneshot，登录前跑，`--auto` 模式）。
  写完镜像插上就能用，用户不需要手动跑任何脚本；出错不会卡住开机，
  下次开机自动重试。`music health` 会报告它的状态
- `openssh-client` 进必装清单（`verify-image.sh` 断言 `/usr/bin/ssh` 存在）
- 预装 `ssh` 后可用 `scp`/`ssh` 直连这台机器

### 精简

- 桌面只留终端优先的最小集合：`xfce4-session + xfwm4 + xfce4-settings +
  xfce4-terminal`，换掉 `xfce4` 元包 —— 后者会连带装进 `xfce4-panel`（面板）和
  `xfdesktop4`（桌面图标 dock），用户明确说不需要。顺带省下 appfinder /
  notifyd / screensaver 一堆用不上的东西
- 可选包里的 `thunar` / `mousepad` 也去掉（`nano` 保留）；构建期断言
  面板和桌面图标没被顺带装回来

### 构建流程

- 本次 v1.0.3 第一次构建因 `build-image.sh` 把注释插进了 apt 包清单的
  反斜杠续行中间而失败（`xorg: command not found`，浪费一次 20 分钟构建）。
  `lint-helpers.sh` 新增“检查三”：注释插在续行中间直接报错，挂在
  CI 的语法检查步骤，几秒内失败而不是 20 分钟后
- 夹具与回归用例入 `scripts/tests/` + `test-lint-helpers.sh`（9 项全过）

---

## v1.0.2 - 2026-10-23

真机（v1.0.1 镜像 + 64G U 盘）测试发现。

#### `usb-grow.sh`：GPT 备份表还压在 8GiB 镜像的老位置，`--new` 一律被拒

**现象**：MUSIC 数据 dd 搬家成功后，重写分区表报
`Could not create partition 3/4 ...`，sgdisk 明明收到了
`--new=4:45467648:+0`，报错里 `+0` 却展开成了 `16777182`。

**原因**：镜像是**定长**做的（默认 8GiB），写进 58.59GiB 的 U 盘后，
GPT 的备份表还压在镜像做盘时的末尾（8GiB 处），sgdisk 认定
`last usable sector = 16777182` —— 一切超出这一线的分区创建都被拒。
v1.0.0 时代"看起来能写表"，只是 `--delete` 恰好整张重写才顺手把表
搬对了地方；v1.0.1 换成显式的"删 + 建"路径后就不灵了。

**改法**：改任何分区表之前先 `sgdisk -e`，把备份表头/备份表挪到真正的
磁盘末尾（表已在末尾时它就是个 no-op）；`--check` 时也会把
"GPT 只认到镜像大小"这件事提示出来。

---

## v1.0.1 - 2026-10-23（待打 tag）

真机（64G U 盘，跑 v1.0.0 的 `usb-grow.sh`）测试发现的四个问题。

#### `usb-grow.sh`：扩容到一半必失败，而且把磁盘改成了半新半旧

**现象**：`sgdisk --delete=4` 成功后，重建 root 报
`Could not create partition 3 from 1052672 to 45466428`（退出码 4）；
此时旧 MUSIC 条目已被删掉、root 条目没动，盘处于半改状态。

**原因**（两层）：

- 删旧/建新分成三条 sgdisk 调用：重建 p3 时盘上的旧 p3 条目还在，sgdisk
  拒绝创建与既有分区重叠的表项。
- 更根本的是布局几何：root 在前、MUSIC 在后、空闲空间在最后 —— root 想
  变长就必须吃掉 MUSIC 的老位置，**MUSIC 的数据不搬家就无法扩 root**。
  原方案即使"成功"，重建出的 MUSIC 起点也落在完全没数据的扇区上。

**改法**：

- 计算 1MiB 对齐的新分界线；若会与老 MUSIC 区域重叠则退化为"贴着老尾巴放"
- **先 `dd` 把 MUSIC 数据按字节拷到磁盘尾部新家**（fsync 后才动表；
  拷贝失败则盘和跑之前一模一样，重跑无损）
- **同一条 sgdisk 命令里原子完成**删旧 + 建 root + 建 MUSIC
  （只对盘上真实存在的条目发 `--delete`，兼容上次中断过的盘），
  失败时提示用 `sgdisk --loadbackup=<备份>` 恢复

#### `usb-grow.sh`：`/run/udev/data` 永远查不到，非 root 诊断全是 `-`

**现象**：普通用户跑 `--check`，名称/起始扇区/结束扇区一列全是 `-`，
"按名字没认出 MUSIC 分区"。

**原因**：udev 块设备条目文件名带 `b` 前缀（`/run/udev/data/b8:3`），
脚本拼的是 `<主>:<次>`，永远匹配不到文件。

**改法**：两种文件名都试；另外用 udev 缓存的 `ID_PART_ENTRY_START/SIZE`
兜底读扇区范围 —— 这同时让"上次运行中断过的盘"（磁盘 GPT 里条目已删、
内核还认着旧表）**直接自愈**，不需要手动恢复分区表。

---

## v1.0.0 - 2026-10-23

首个正式发布（Debian 12 bookworm / 内核 6.1）。包含 `main` 分支到此刻的全部改动。

### 修复

这三个问题都是在真机（8GiB 镜像写进 64G U 盘、Debian 12 + Xfce）上实测发现的，
现象分别是"扩容脚本跑到一半自己没了"、"分辨率一块屏都设不成"、"终端没有 http_proxy"。

#### `usb-grow.sh`：认分区不再依赖 `lsblk`

**现象**：跑 `usb-grow.sh` 先刷一屏 `/var/log/usb-grow.log: 权限不够`，
然后在"环境诊断"阶段直接失败退出，退出信息报的是"第 156 行失败 / 失败的命令: awk"。

**原因**：认分区用的是 `lsblk -o PARTN,PARTLABEL,FSTYPE`，这台机器上的 `lsblk`
不认这批列名，打一行 `unknown column: ...` 并返回非零；脚本开了 `set -e` + `pipefail`，
非零退出码顺着命令替换把整个脚本带走，报出来的"失败命令"还是管道里的 `awk`，极具误导性。

**改法**：

- 分区号 / 设备节点 → `/sys/block/<盘>/*/partition`（内核给的，最可靠）
- 扇区范围 / GPT 分区名 → `sgdisk -p`（我们自己写进去的分区表）
- 文件系统标签 / 类型 → `/run/udev/data/<主>:<次>`（udev 已识别好，普通用户也读得到）
- 所有探测统一走 `try()`：认不出就返回空串，换下一条线索，**不再有任何一个探测能让脚本退出**
- 识别顺序：GPT 分区名 / 文件系统标签 → 挂载点（`/` 与 `/mnt/songdisk`）→ 文件系统类型 → 磁盘最后一个分区

#### `usb-grow.sh`：日志权限报错刷屏

**现象**：普通用户每跑一次，屏幕上就是十几行 `行 57: /var/log/usb-grow.log: 权限不够`。

**原因**：`printf ... >> "$LOG_FILE" 2>/dev/null` 里重定向按书写顺序生效，
`>>file` 先做，打开失败那句报错是在 stderr 还没接到 `/dev/null` 时打出来的。

**改法**：启动时挑一个真能写的日志路径（`/var/log/usb-grow.log` → `~/.local/state/usb-grow.log`
→ `/tmp`），写日志时把 `2>/dev/null` 放到前面，并在输出里说明日志写到哪儿了；
日志超过 512KB 自动重新开始（U 盘根分区就 6GiB，日志不能无限长）。

#### `screen-fit`：一块屏都设不成

**现象**：`xrandr: cannot find mode 640x480       73.00*`，分辨率纹丝不动。

**原因**：`--mode` 被塞了 `xrandr --query` 打印的**整行**（含 `73.00*` 这种给人看的标记），
xrandr 找不到叫这个名字的模式。

**改法**：

- `--mode` 只传第一个空白前的**模式名**（`640x480`），刷新率走单独的 `--rate`；
  带 `--rate` 失败时自动退回只设模式名（有些驱动不吃显式 `--rate`）
- "当前模式"改认 xrandr 打在模式后面的 `*` 标记，而不是输出头部那行
  （`640x480+0+0` 带不出刷新率；同一分辨率挂着好几个刷新率时，
  用头部判断会把"已经是了"误判成"需要设置"，对着当前模式白设一次）
- "已经是目标分辨率"改成按 `(宽, 高, 刷新率)` 三元组比对，不再比整行字符串
- 有一块屏没设成功时返回**非零**退出码（开机自启的 `--restore` 和 `music-health` 靠这个判断）

#### `proxy`：桌面终端里拿不到 `http_proxy`

**现象**：明明在图形桌面里，`proxy status` 一直显示 `终端环境变量: 未设置`。

**原因**：`/etc/profile.d/99-proxy.sh` 只有**登录 shell** 会读，
而 `xfce4-terminal` 开出来的是非登录交互 shell（只读 `~/.bashrc`）。

**改法**：构建时在 `user` 与 `root` 的 `~/.bashrc` 里也 source 同一份脚本，两条路都通。
代理没开时实测不影响终端启动速度（连接被拒是毫秒级）。

#### `music-health`：分区信息可能整段静默丢失

同一类问题：分区清单和分区名都走 `lsblk` 的列名，`lsblk` 一旦不认就整块跳过，
体检报告显示"分区""剩余空间"都是空的。改成和 `usb-grow.sh` 同一套来源（sysfs + udev 数据库），
读不到时明说"需要 root 才能读整盘"，而不是假装没有剩余空间。

#### `music`：哪里都打不出中文 —— Rime 拼音词库没被装上

**现象**：fcitx5 图标亮着、`Ctrl+Space` 也有反应，但在任何程序里打拼音都出不了中文，
终端里尤其明显。

**原因**：Debian 的 `fcitx5-rime` 只硬依赖一个几 KB 的 `librime-data` 元包，
真正的拼音词库 `rime-data-luna-pinyin` 只是 Recommends；镜像装包用了
`--no-install-recommends`，词库就没了。Rime 部署时找不到 `luna_pinyin_simp`
方案，整个引擎空转 —— 这是"装了输入法却打不了字"的最常见原因，壁纸
证书和旧镜像的都是同一根因。

**改法**：

- 必需包清单显式加上 `rime-data-luna-pinyin` 与 `fcitx5-chinese-addons`
  （后者为 profile 里引用的 pinyin 引擎兜底）
- 构建期验证这两个文件真实存在（词库方案 yaml / pinyin 引擎 addon），
  缺任何一个直接让构建失败 —— 这类错误在真机上只能靠手指头试出来
- `music im-fix` / `music-health` 增加词库检测与修复（补装 + 清掉部署失败
  的旧产物 + 通知 fcitx5 重新部署）
- `[Hotkey]` 全局快捷键从 `fcitx5/profile` 挪到 `fcitx5/config`（profile
  只认 Groups 信息，写在里面的 Hotkey 一直被忽略）

#### CI：第一次发 Release 失败（artifact 下载重试 5 次全挂）

**现象**：打 v1.0.0 tag 后构建、压缩、上传产物全部成功，
最后一步 `download-artifact` 从 Azure blob 拉回 946MB 的产物时重试 5 次全失败，Release 没发出去。

**原因**：那一步本来就是多余的 —— `out/` 目录还在同一个 job 的 workspace 里，
不需要"上传后再下载回来"。

**改法**：删掉 `download-artifact` 中转，Release 步骤直接用 workspace 里的产物，
少搬 946MB，这类瞬时失败也不复存在了。

### 新增

- `usb-grow.sh --self-test`：认分区逻辑自测（喂一份真机抓下来的 `sgdisk -p` 输出做夹具，17 项），
  构建期自动跑，失败直接让构建失败 —— 这类错误在真机上的代价是"认错分区把分区表改了"，不可逆
- `fit.py --self-test` 从 21 项扩到 33 项，覆盖上面 `screen-fit` 的三条坑
- 镜像里的 `BUILD-INFO.txt` 增加 `构建器版本` 一行（git describe 的结果），
  出问题时能一眼看出这份镜像是哪版脚本做的
- 构建时预建 `root:user 0664` 的 `/var/log/usb-grow.log`，避免第一次跑被 root 建出 0644 导致日志散成两处
- 推 `v*` tag 时，GitHub Actions 构建完成后自动把镜像 + 校验和 + `BUILD-INFO.txt`
  发到 Releases，说明里带镜像信息、校验值、写盘命令和本次改动
- **母盘瘦身**：打包前删掉包文档（每包留 copyright）/ 手册页 / 非中文 locale
  翻译 / apt 索引与缓存，约省 200~400MB；只删静态文件，不动 `/var/lib/dpkg`，
  运行时再装包先 `apt-get update` 即可

### 已知问题

- `screen-fit` 在完全读不到 EDID 的屏上（无 EDID 的老投影仪）只会退到启发式：
  取刷新率 ≥60 的最大分辨率，输出里会标明"没读到 EDID，用的推测值"
- 写盘后如果分区表没被内核接受（`partx`/`partprobe` 失败），需要重启一次再跑一次 `usb-grow.sh`；
  脚本会自己校验 `/mnt/songdisk` 的实际大小并明确提示，不会假装成功