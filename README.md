# Debian 12 U 盘系统镜像构建器

用 **GitHub Actions** 在云端构建一个可以直接写进 U 盘的 Debian 12 系统镜像：
`Xfce 轻量桌面 + Fcitx5/Rime 中文输入 + 独立歌曲分区 + 预装两个 Python 下载器`。
**本地零占用**，构建全程发生在 GitHub 的 runner 上，你只需要下载产物、写入 U 盘。

> 本仓库同时支持两条产线：
> - **x86_64 通用镜像**（第一～七章）：自建 debootstrap 根文件系统，GPT + GRUB/EFI，写 U 盘。
> - **Phicomm N1 电视盒子镜像**（第八章）：Amlogic S905D / ARM64，基于 ophub 的
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

### 1. 把 U 盘剩余空间用起来

镜像默认只有 8GiB。插到 64G / 128G 的 U 盘上后，剩余空间是"未分区"状态，在终端里执行：

```bash
sudo usb-grow.sh              # root 拿 30%, MUSIC 拿 70%
sudo usb-grow.sh --root-percent 50
sudo usb-grow.sh --dry-run    # 先看计划再执行
```

扩容后 `df -h` 就能看到 `/mnt/songdisk` 变成几十 G，**不需要重装**。

### 2. 中文输入法

- 默认已配置好 Fcitx5 + Rime 简体拼音，`Ctrl+Space` 切换输入法，`Shift+左Shift` 切中英文。
- 镜像里已经预置了 70 多条歌手/歌名词库（`周杰伦`、`五月天`、`夜曲`…），
  打 `zhoujielun` 就能出「周杰伦」。
- 想加自己的词：编辑 `~/.config/fcitx5/rime/user.dict.yaml`，格式是
  `词语<TAB>拼音编码`（编码用空格分音节）：

  ```yaml
  entries:
    - 我的歌单	m wo ge dan
  ```

  保存后 Fcitx5 的 Rime 插件会自动重新部署（一般 1 秒内生效）；
  想手动触发可以执行 `rime_deployer --build`。
- 改了输入法配置完全没反应时：`im-config -n fcitx5` 然后注销重登。

### 3. 下载歌曲

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

# 图形界面: 搜索并下载单曲(夸克网盘转存, 需 PyQt6)
music gui

# 看歌曲目录 / 已下载列表 / 环境自检
music out
music ls
music doctor
```

所有下载默认写到歌曲分区 `/mnt/songdisk`。下载前会自动检查该分区是否已挂载、是否可写，
没挂载会尝试自动挂载并给出明确提示，而不是直接报错。

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

**Q：QEMU 冒烟测试报"没捕获到 GRUB 输出"**
这只是警告，不是失败。OVMF 可能没走 UEFI 可移动介质路径，或串口输出没打开；结构校验通过就说明镜像结构没问题。

**Q：`music single` 报"项目源码的接口和本脚本对不上"**
`gequhai-downloader` 上游改了接口（比如 `search_songs` 改名、删了 `safe_filename`）。
本脚本在调用前会做 `hasattr` 预检，缺哪个接口会直接列出来，而不是甩一屏 traceback。
处理办法：`cd ~/projects/gequhai-downloader && git pull` 看是不是上游变了；
如果确实变了，同步改 `single.py` 里的 `REQUIRED_API`，或者先用 `music gui` 走图形界面。

---

## 七之二、命令行回归测试

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
│   └── test-music-cli.sh                     # music 命令行回归测试(见下)
├── overlay/                                  # x86 与 N1 共用, 直接覆盖到镜像 rootfs 里
│   ├── usr/local/bin/
│   │   ├── usb-grow.sh                       # x86: 一键扩展分区到整盘(GPT)
│   │   └── music                             # 下载器快捷入口(single/playlist/gui/doctor)
│   ├── usr/local/lib/musictools/
│   │   └── single.py                         # 命令行单曲搜索下载(纯 requests, 不用 PyQt6)
│   └── home/user/.config/fcitx5/rime/        # Rime 简体拼音方案 + 73 条歌名词库
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

## 八、Phicomm N1（Amlogic S905D）电视盒子镜像

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
