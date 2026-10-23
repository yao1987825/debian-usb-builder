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