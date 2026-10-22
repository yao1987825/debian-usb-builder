# Debian 12 U 盘系统镜像构建器

用 **GitHub Actions** 在云端构建一个可以直接写进 U 盘的 Debian 12 系统镜像：
`Xfce 轻量桌面 + Fcitx5/Rime 中文输入 + 独立歌曲分区 + 预装两个 Python 下载器`。
**本地零占用**，构建全程发生在 GitHub 的 runner 上，你只需要下载产物、写入 U 盘。

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

> 建议把仓库设为 **Public**：公开仓库的 GitHub Actions 免费额度无限；
> 私有仓库免费额度是每月 2000 分钟，也够用，但要注意额度。

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
# 歌单批量下载(CSV 放 ~/projects/gequhai-playlist-downloader/playlist.csv)
music playlist playlist.csv

# 图形界面: 搜索并下载单曲(夸克网盘转存)
music gui

# 看歌曲目录 / 已下载列表
music out
music ls
```

也可以直接用原生命令：

```bash
cd ~/projects/gequhai-playlist-downloader
~/.venvs/playlist/bin/python gequhai_downloader.py --csv playlist.csv --out /mnt/songdisk
~/.venvs/playlist/bin/python convert_aac_to_mp3.py --dir /mnt/songdisk
```

### 4. 两个下载器的分工（注意差别）

| | `gequhai-downloader` | `gequhai-playlist-downloader` |
| --- | --- | --- |
| 形态 | PyQt6 **图形界面**（`music gui`） | **纯命令行**（`music playlist`） |
| 输入 | 搜索框里打字（可用中文） | 歌单 CSV（歌名+歌手） |
| 输出 | 直接下音频 + 歌词 + 封面 | 音频；**夸克网盘链接只存成 `.link.txt`，不会自动下载** |
| 额外依赖 | 夸克 Cookie、默认走 Clash 代理 `127.0.0.1:7897` | Playwright Chromium（已离线装好） |

图形版默认代理指向 Clash，但 U 盘机器上通常没跑 Clash → 直接在图形界面里把代理清空即可
（配置文件 `~/projects/gequhai-downloader/config.json`，镜像预置的是空代理版本）。

---

## 四、想改构建参数

在 Actions 页面点 **Run workflow** 就能改：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `suite` | `bookworm` | `bookworm`=Debian12，`trixie`=Debian13 |
| `img_size_mb` | `8192` | 镜像总大小。**填大只是让压缩包变大**，真正的大小写盘后用 `usb-grow.sh` 扩 |
| `root_size_mb` | `6144` | 根分区大小，装大量 Python 包时可以调大 |
| `with_bios_grub` | `0` | 传统 BIOS 的 GRUB（现代 UEFI 机器不需要） |
| `with_projects` | `1` | 是否预装两个下载器 + Playwright Chromium |

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

**Q：QEMU 冒烟测试报"没捕获到 GRUB 输出"**
这只是警告，不是失败。OVMF 可能没走 UEFI 可移动介质路径，或串口输出没打开；结构校验通过就说明镜像结构没问题。

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
├── .github/workflows/build-usb-image.yml   # CI 流水线
├── scripts/
│   ├── build-image.sh                      # 核心: debootstrap → 分区 → GRUB → 预装
│   └── verify-image.sh                     # 结构校验 + QEMU 启动冒烟测试
├── overlay/                                # 直接覆盖到镜像 rootfs 里的文件
│   └── usr/local/bin/
│       ├── usb-grow.sh                     # 一键扩展分区到整盘
│       └── music                           # 下载器快捷入口
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

## 免责声明

镜像里预置的下载器仅供个人学习与技术实验使用。请自行确认你拥有相关内容的合法下载、
保存与格式转换权限，遵守著作权人的授权条件与目标站点的服务条款。
