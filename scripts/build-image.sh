#!/usr/bin/env bash
#
# build-image.sh —— 构建「Debian 12 + Xfce + Fcitx5/Rime」可写 U 盘系统镜像
#
# 产物:  out/debian-usb-<suite>.img  (整盘镜像, 可用 Rufus / balenaEtcher / dd 写入 U 盘)
#
# 分区表 (GPT):
#   p1  BIOS-BOOT   1MiB    ef02  仅传统 BIOS 需要, UEFI 模式留空即可
#   p2  EFI         512MiB  ef00  UEFI 启动 (shim + grubx64 + grub.cfg 链)
#   p3  DEBIAN_ROOT ext4           系统根分区 /
#   p4  MUSIC       ext4           歌曲盘, 挂载到 /mnt/songdisk
#
# 关键实现说明:
#   * 用 mke2fs -d 把 rootfs 目录直接"灌"进 ext4 镜像文件, 全程不需要 loop 设备 / 挂载,
#     因此在 GitHub Actions 上以普通 user+sudo 即可稳定构建。
#   * EFI 分区用 mkfs.vfat + mtools(mcopy) 写入, 同样不需要挂载。
#   * fstab / GRUB 配置里的 UUID 在建文件系统之前就先生成好, 因此不需要事后回填。
#   * 不调用 efibootmgr, 不会往主板 NVRAM 写任何启动项; 不会碰宿主机内置硬盘。
#
# 依赖: debootstrap e2fsprogs(>=1.43) dosfstools mtools gdisk xz-utils  需要 root
#
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

############################### 可调参数 #################################
SUITE="${SUITE:-bookworm}"                       # bookworm=Debian12, trixie=Debian13
MIRROR="${MIRROR:-http://deb.debian.org/debian}"
SECURITY_MIRROR="${SECURITY_MIRROR:-http://security.debian.org/debian-security}"

# ---- 镜像里预置的第三方源 ----
# 传 off / none 表示"不要换源"。这里用 :- 而不是 -:
# workflow 的 job 级 env 一定会把变量定义出来(可能是空串),
# 用 - 会把"未指定"和"显式清空"混成一回事。
APT_MIRROR="${APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
case "$APT_MIRROR"     in off|none|"") APT_MIRROR="" ;; esac
case "$PIP_INDEX_URL"  in off|none|"") PIP_INDEX_URL="" ;; esac

# ---- 预置代理(只是写好配置, 不会强制打开) ----
# /etc/profile.d/99-proxy.sh 会先探测端口通不通, 通了才 export http_proxy;
# 代理没跑的时候什么都不设, 免得表现成"所有下载全部失败"。
PROXY_URL_DEFAULT="${PROXY_URL_DEFAULT:-socks5://192.168.6.1:1070}"

IMG_SIZE_MB="${IMG_SIZE_MB:-8192}"               # 镜像总大小 (MiB)
ESP_SIZE_MB="${ESP_SIZE_MB:-512}"                # EFI 分区
ROOT_SIZE_MB="${ROOT_SIZE_MB:-6144}"             # 根分区
BIOS_SIZE_MB="${BIOS_SIZE_MB:-1}"                # BIOS boot 分区
# 歌曲分区不预设大小: 它吃掉"整盘减去其它分区和 GPT 备份区"剩下的全部空间,
# 实际字节数在分区表建好后从 sgdisk 反查(见第 7 步), 避免手算出错压掉备份 GPT 头。

HOSTNAME_DEB="${HOSTNAME_DEB:-debian-usb}"
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-user}"
LOCALE_NAME="${LOCALE_NAME:-zh_CN.UTF-8}"
TIMEZONE_NAME="${TIMEZONE_NAME:-Asia/Shanghai}"

# 构建器版本: 打进镜像的 BUILD-INFO.txt, 出问题时能一眼看出这份镜像是哪版脚本做的。
# 优先用 git 描述(tag 优先), 在导出的源码包/无 git 目录下退到 commit 或 unknown。
BUILDER_VERSION="${BUILDER_VERSION:-$(git -C "${REPO_DIR}" describe --tags --always --dirty 2>/dev/null || echo unknown)}"

WITH_BIOS_GRUB="${WITH_BIOS_GRUB:-0}"            # 1=额外安装传统 BIOS 的 GRUB(实验性, 需 loop 设备)
WITH_PROJECTS="${WITH_PROJECTS:-1}"              # 1=把两个下载器项目预装进镜像

# 镜像档位:
#   full = 图形下载器(PyQt6) + Playwright Chromium + Noto CJK 字体  (~4.2GB 内容)
#   slim = 纯命令行: 不装 PyQt6 / Chromium / Noto CJK              (~2.9GB 内容, 省约 1.3GB)
# 注意: 命令行单曲下载(music single)只依赖 requests, slim 档完全可用。
PROFILE="${PROFILE:-full}"
WITH_PYQT=1
WITH_PLAYWRIGHT_BROWSER=1
WITH_NOTO_CJK=1
case "$PROFILE" in
  full) ;;
  slim)
    WITH_PYQT=0
    WITH_PLAYWRIGHT_BROWSER=0
    WITH_NOTO_CJK=0
    ;;
  *) die "未知 PROFILE: ${PROFILE} (可选 full|slim)" ;;
esac
SERIAL_CONSOLE="${SERIAL_CONSOLE:-1}"            # 1=GRUB 内核加串口控制台(便于 QEMU 冒烟测试)

REPO_GEQUHAI="${REPO_GEQUHAI:-https://github.com/Yannick-Mo/gequhai-downloader.git}"
REPO_PLAYLIST="${REPO_PLAYLIST:-https://github.com/hoogrey/gequhai-playlist-downloader.git}"

BUILD_DIR="${BUILD_DIR:-${REPO_DIR}/build}"
OUT_DIR="${OUT_DIR:-${REPO_DIR}/out}"
COMPRESS="${COMPRESS:-xz}"                       # xz | gzip | none

ROOTFS="${BUILD_DIR}/rootfs"
ROOT_IMG="${BUILD_DIR}/root.ext4"
ESP_IMG="${BUILD_DIR}/esp.img"
MUSIC_IMG="${BUILD_DIR}/music.ext4"
OUT_IMG="${OUT_DIR}/debian-usb-${SUITE}.img"

############################### 工具函数 ###################################
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# 数自测"真正通过了几项"。
#
# 注意: 直接 `grep -c '✅'` 会把末尾的 "✅ 25/25 项通过" 汇总行也数进去,
# 于是日志里写"26 项"而实际只有 25 项, 看着像多了项。这里把汇总行剔掉。
#
# 必须定义在**第一次被调用之前** —— bash 是先定义后使用, 定义晚了会
# "selftest_count: command not found"。这函数放在这儿的另一个原因:
# 放在文件靠后位置很容易踩到这个坑(和之前 ok() 没定义是同一类错误)。
selftest_count() {
  local f="$1" n
  [[ -f "$f" ]] || { echo 0; return 0; }
  n="$(grep '✅' "$f" 2>/dev/null | grep -cv '项通过' || true)"
  echo "${n:-0}"
}

MOUNTS=()
cleanup() {
  local rc=$?
  set +e
  # 逆序卸载 chroot 里挂进去的 /run /sys /proc /dev
  for m in /run /sys /proc /dev/pts /dev; do
    if mountpoint -q "${ROOTFS}${m}" 2>/dev/null; then umount -lf "${ROOTFS}${m}" 2>/dev/null; fi
  done
  if [[ -n "${LOOP_DEV:-}" ]]; then losetup -d "$LOOP_DEV" 2>/dev/null; fi
  return $rc
}
trap cleanup EXIT

require_root() { [[ "$(id -u)" == "0" ]] || die "请用 root 运行: sudo bash scripts/build-image.sh"; }

require_cmd() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] || die "缺少命令: ${missing[*]}  (apt install debootstrap e2fsprogs dosfstools mtools gdisk xz-utils)"
}

check_mke2fs_d() {
  local ver
  ver="$(mke2fs -V 2>&1 | head -1 | sed -n 's/.*mke2fs \([0-9.]*\).*/\1/p')"
  if [[ -z "$ver" ]]; then die "无法检测 mke2fs 版本"; fi
  if [[ "$(printf '%s\n1.43\n' "$ver" | sort -V | head -1)" != "1.43" ]]; then
    die "mke2fs $ver 不支持 -d 参数, 需要 >= 1.43"
  fi
  log "mke2fs $ver (支持 -d)"
}

################################ 主流程 ####################################
require_root
require_cmd debootstrap mke2fs mkfs.vfat mcopy mmd sgdisk dd tar xz git
check_mke2fs_d

(( ESP_SIZE_MB + ROOT_SIZE_MB + BIOS_SIZE_MB + 64 < IMG_SIZE_MB )) \
  || die "分区总大小 ${ESP_SIZE_MB}+${ROOT_SIZE_MB}+${BIOS_SIZE_MB} 超过镜像 ${IMG_SIZE_MB}MB"

mkdir -p "$BUILD_DIR" "$OUT_DIR"
# 本脚本以 root 运行, 而 workflow 的后续步骤以普通用户运行。
# out/ 目录若属主是 root 且权限 755, 普通用户连新建文件都会被拒(Permission denied),
# 所以这里把产物目录放开写权限。
chmod 0777 "$OUT_DIR" 2>/dev/null || true
# 上一次构建如果中断了, 可能还挂着 mount, 先卸干净
for m in /run /sys /proc /dev/pts /dev; do
  if mountpoint -q "${ROOTFS}${m}" 2>/dev/null; then umount -lf "${ROOTFS}${m}" 2>/dev/null || true; fi
done
rm -rf "$ROOTFS" "$ROOT_IMG" "$ESP_IMG" "$MUSIC_IMG"

# ---------- 生成 UUID (先于文件系统创建, 便于直接写进 fstab / grub.cfg) ----------
# 注意: 必须保留标准带横线格式, mke2fs -U 只认这种写法
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
ROOT_UUID="$(gen_uuid)"
MUSIC_UUID="$(gen_uuid)"
log "root UUID=${ROOT_UUID}"
log "music UUID=${MUSIC_UUID}"

####################### 第 1 步: debootstrap 生成 rootfs ###################
step "1/9 debootstrap ${SUITE} → rootfs 目录"
debootstrap --arch=amd64 --variant=minbase \
  --include=systemd-sysv,apt-utils,ca-certificates,gnupg,locales,tzdata \
  "$SUITE" "$ROOTFS" "$MIRROR"

####################### 第 2 步: 进入 chroot 配置系统 #######################
step "2/9 chroot 内配置: 源/语言/时区/软件"

# 让 chroot 能联网(构建期用宿主机 DNS)。
# 注意: 宿主机常是 systemd-resolved 的 127.0.0.53, 在 chroot 里不可达, 必须过滤掉。
: > "${ROOTFS}/etc/resolv.conf"
if [[ -f /etc/resolv.conf ]]; then
  grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' \
    | grep -vE '^(127\.|::1|0\.0\.0\.0)' >> "${ROOTFS}/etc/resolv.conf" || true
fi
if ! grep -q '^nameserver' "${ROOTFS}/etc/resolv.conf"; then
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' >> "${ROOTFS}/etc/resolv.conf"
  log "未取到宿主机可用 DNS, 回退到 223.5.5.5 / 119.29.29.29"
fi

cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${SECURITY_MIRROR} ${SUITE}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF

mkdir -p "${ROOTFS}/dev/pts" "${ROOTFS}/proc" "${ROOTFS}/sys" "${ROOTFS}/run"
mount --bind /dev  "${ROOTFS}/dev";  MOUNTS+=("${ROOTFS}/dev")
mount --bind /dev/pts "${ROOTFS}/dev/pts"; MOUNTS+=("${ROOTFS}/dev/pts")
mount --bind /proc "${ROOTFS}/proc"; MOUNTS+=("${ROOTFS}/proc")
mount --bind /sys  "${ROOTFS}/sys";  MOUNTS+=("${ROOTFS}/sys")
mount --bind /run  "${ROOTFS}/run";  MOUNTS+=("${ROOTFS}/run")

# 构建期间不要在 chroot 里真的启动守护进程(invoke-rc.d 会被 policy-rc.d 拦掉)
cat > "${ROOTFS}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "${ROOTFS}/usr/sbin/policy-rc.d"

chroot_run() { chroot "$ROOTFS" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"; }

chroot_run apt-get update -qq

# 字体: slim 档只留文泉驿(15MB), full 档额外装 Noto CJK(约 200MB)
FONT_PKGS="fonts-wqy-zenhei"
[[ "$WITH_NOTO_CJK" == "1" ]] && FONT_PKGS="${FONT_PKGS} fonts-noto-cjk"

# ---- 必需组件 ----
# 网络: 必须装 NetworkManager。Debian 12 + Xfce 默认不带任何网卡配置服务,
# 没有它开机就没人给网卡分配 IP(DHCP), 表现为"完全连不上网"。
# 输入法: rime-data-luna-pinyin 必须显式列出 --
# 这里的 --no-install-recommends 会跳过它。fcitx5-rime 只硬 Depends 一个
# 几 KB 的 librime-data 元包, 真正的拼音词库 rime-data-luna-pinyin 只是
# Recommends; 不装它 Rime 部署不出拼音方案, 表现是"装了输入法但哪里都
# 打不出中文"。
# 只保留 Rime 一个中文输入法: 用户明确要求"删掉其它输入法, 只留一个,
# Shift 切中英文"。fcitx5-chinese-addons(内置拼音)已从镜像里去掉 ——
# 它默认输出繁体(首候选"國家"), 而且实测不吃单键 Shift; Rime 用
# luna_pinyin_simp 方案是纯简体, Shift 在空预编辑时可切中英。
# 桌面只保留"终端优先"的最小集合。
# 之前装的是 xfce4 元包, 它会连带装进 xfce4-panel(顶部/底部面板)和
# xfdesktop4(桌面图标 dock)—— 用户明确说"不需要 dock 栏, 只要终端",
# 所以这里换成显式的最小集合: 会话管理 + 窗口管理器 + 设置 + 终端。
# 少掉的还有 xfce4-appfinder / notifyd / screensaver 等一堆用不上的东西。
# 注意: 注释不能插在反斜杠续行的中间, 否则会把包名单独拆成一条命令。
chroot_run apt-get install -y --no-install-recommends \
  linux-image-amd64 \
  dbus-x11 policykit-1 sudo locales tzdata \
  xorg xinit xdg-utils \
  xfce4-session xfwm4 xfce4-settings xfce4-terminal \
  lightdm \
  fcitx5 fcitx5-rime fcitx5-config-qt im-config \
  rime-data-luna-pinyin \
  fcitx5-frontend-gtk3 fcitx5-frontend-qt5 \
  openssh-client \
  ${FONT_PKGS} \
  python3 python3-venv python3-pip \
  git curl wget ca-certificates openssh-client \
  ffmpeg aria2 vim tmux screen htop \
  cloud-guest-utils gdisk parted dosfstools e2fsprogs rsync \
  grub-efi-amd64-bin grub-efi-amd64-signed shim-signed \
  systemd-resolved \
  network-manager wpasupplicant iproute2 iputils-ping dnsutils \
  x11-xserver-utils \
  bash-completion less nano tree file jq \
  ripgrep fd-find bat fzf ncdu unzip zip p7zip-full zstd xz-utils bzip2 \
  lsof procps psmisc diffutils patch \
  net-tools traceroute mtr-tiny whois tcpdump \
  pciutils usbutils lm-sensors smartmontools hdparm \
  btop shellcheck plocate bsdextrautils \
  wmctrl xdotool

# ---- 可选组件: 装不上不影响系统, 但少了会影响输入法/桌面体验 ----
apt_optional() {
  local p
  for p in "$@"; do
    if chroot_run apt-get install -y --no-install-recommends "$p"; then
      log "可选包已安装: ${p}"
    else
      warn "可选包安装失败(忽略): ${p}"
    fi
  done
}
apt_optional \
  fcitx5-frontend-gtk4 \
  fcitx5-frontend-qt6 \
  nano tree file unzip zip \
  python3-dev build-essential pkg-config \
  fonts-wqy-microhei fonts-noto-color-emoji \
  lightdm-gtk-greeter

chroot_run dpkg --configure -a

# Debian 把 fd / bat 装成 fdfind / batcat(避免和别的包撞名)。
# 用户敲 "fd" / "bat" 是肌肉记忆, 这里补上软链, 不然还得记 Debian 的怪名字。
ln -sf /usr/bin/fdfind "${ROOTFS}/usr/local/bin/fd"
ln -sf /usr/bin/batcat "${ROOTFS}/usr/local/bin/bat"

# ---- 换软件源 ----
# 放在"重活都干完之后"再换: 构建机在 GitHub 的美国节点, 走 deb.debian.org 反而快;
# 而成品拿到国内用, 清华源才是刚需。换早了只会让 CI 变慢还更容易超时。
apply_mirror() {
  if [[ -z "$APT_MIRROR" ]]; then
    log "APT_MIRROR 为空, 保持官方源"
    return 0
  fi
  local host="${APT_MIRROR#*://}"
  host="${host%%/*}"

  log "切换 apt 源到 ${APT_MIRROR}"
  cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
# 由 build-image.sh 生成(${SUITE})
deb ${APT_MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${APT_MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
deb ${APT_MIRROR}-security ${SUITE}-security main contrib non-free non-free-firmware
EOF

  if chroot_run apt-get -o Acquire::Retries=3 -o Acquire::https::Timeout=30 update -qq; then
    APT_MIRROR_OK=1
    log "清华源可用 ✅ (${host})"
  else
    warn "${host} 在构建机上拉不动, 回退官方源(成品会走官方源, 不是预期行为)"
    APT_MIRROR_OK=0
    cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${SUITE} main contrib non-free non-free-firmware
deb ${SECURITY_MIRROR} ${SUITE}-security main contrib non-free non-free-firmware
deb ${MIRROR} ${SUITE}-updates main contrib non-free non-free-firmware
EOF
    chroot_run apt-get update -qq || die "官方源也 update 失败"
  fi
}
APT_MIRROR_OK=0
apply_mirror

# 语言 / 时区 / 主机名
sed -i "s/^# *${LOCALE_NAME} UTF-8/${LOCALE_NAME} UTF-8/" "${ROOTFS}/etc/locale.gen"
grep -q "^${LOCALE_NAME} UTF-8" "${ROOTFS}/etc/locale.gen" || echo "${LOCALE_NAME} UTF-8" >> "${ROOTFS}/etc/locale.gen"
chroot_run locale-gen
cat > "${ROOTFS}/etc/default/locale" <<EOF
LANG=${LOCALE_NAME}
LC_ALL=${LOCALE_NAME}
LANGUAGE=zh_CN:zh
EOF

ln -snf "/usr/share/zoneinfo/${TIMEZONE_NAME}" "${ROOTFS}/etc/localtime"
echo "${TIMEZONE_NAME}" > "${ROOTFS}/etc/timezone"
echo "${HOSTNAME_DEB}" > "${ROOTFS}/etc/hostname"
cat > "${ROOTFS}/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	${HOSTNAME_DEB}
::1		localhost ip6-localhost ip6-loopback
EOF

# DNS: 构建期间保持用宿主机 resolv.conf(第 3 步的 clone/pip/playwright 都要联网),
# 等所有联网步骤结束、切换到 systemd-resolved, 这样换台机器启动也能自动拿 DNS。
chroot_run systemctl enable systemd-resolved
# 网卡配置: NetworkManager 负责 DHCP / 路由 / WiFi。没有它就是一台没有网络的机器。
chroot_run systemctl enable NetworkManager || die "NetworkManager 启用失败"
# 开机自扩容实机验证在 overlay 复制完之后(第 434 行之后); 这里不能提前断言,
# 因为 overlay 文件此刻还没写进 ROOTFS —— 之前就因为放这里, 构建在
# 第 346 行白炸一次("文件没进镜像", 其实根本还没拷)。
# 让 NetworkManager 用 systemd-resolved 提供的 DNS(和 Debian 官方桌面一致)
mkdir -p "${ROOTFS}/etc/NetworkManager/conf.d"
cat > "${ROOTFS}/etc/NetworkManager/conf.d/10-dns.conf" <<'EOF'
[main]
dns=systemd-resolved
systemd-resolved=true
EOF
[[ -x "${ROOTFS}/usr/bin/nmcli" ]] || die "nmcli 没装上, NetworkManager 安装异常"

# 账户
chroot_run useradd --create-home --shell /bin/bash --comment "USB User" "$USER_NAME"
echo "${USER_NAME}:${USER_PASS}" | chroot_run chpasswd
# 只添加系统里真实存在的组(不同 Debian 版本提供的组不一样, 如 netdev 可能不存在)
existing_groups="$(chroot_run getent group | cut -d: -f1)"
for g in sudo audio video plugdev netdev cdrom; do
  if grep -qx "$g" <<<"$existing_groups"; then
    chroot_run usermod -aG "$g" "$USER_NAME"
  else
    warn "组 ${g} 在本系统不存在, 跳过"
  fi
done
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "${ROOTFS}/etc/sudoers.d/90-${USER_NAME}"
chmod 0440 "${ROOTFS}/etc/sudoers.d/90-${USER_NAME}"

# 该账号只存在于 chroot 里, 宿主机没有同名用户, 所以必须用数字 UID/GID 做 chown
USER_UID="$(chroot_run id -u "$USER_NAME")"
USER_GID="$(chroot_run id -g "$USER_NAME")"
log "用户 ${USER_NAME} uid=${USER_UID} gid=${USER_GID}"

# lightdm 自动登录
mkdir -p "${ROOTFS}/etc/lightdm"
cat > "${ROOTFS}/etc/lightdm/lightdm.conf" <<EOF
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
autologin-user=${USER_NAME}
autologin-user-timeout=0
autologin-session=xfce
EOF
chroot_run systemctl enable lightdm

####################### 第 3 步: 预装两个下载器项目 #######################
if [[ "${WITH_PROJECTS}" == "1" ]]; then
  step "3/9 预装下载器项目 + Python 虚拟环境 + Playwright Chromium"
  mkdir -p "${ROOTFS}/home/${USER_NAME}/projects"
  git clone --depth 1 "$REPO_GEQUHAI"  "${ROOTFS}/home/${USER_NAME}/projects/gequhai-downloader"  || warn "clone ${REPO_GEQUHAI} 失败"
  git clone --depth 1 "$REPO_PLAYLIST" "${ROOTFS}/home/${USER_NAME}/projects/gequhai-playlist-downloader" || warn "clone ${REPO_PLAYLIST} 失败"

  # 踩过的坑(真机 v1.0.4): 夸克 CDN 直链必须带新鲜 __puus cookie(约 3 小时有效),
  # 扫码登录拿到的 11 个字段里根本没有它; /file/download API 响应的 Set-Cookie
  # 会首次下发。上游 Yannick-Mo/gequhai-downloader 不处理, 结果取链成功但下载
  # 恒 412 Precondition Failed(Tengine)。这里构建期给 quark.py 打补丁: 抓响应
  # Set-Cookie 里的 __puus 合回 cookie, 再交给 download_file。
  QUARK_SRC="${ROOTFS}/home/${USER_NAME}/projects/gequhai-downloader/quark.py"
  if [[ -f "$QUARK_SRC" ]]; then
    python3 "${SCRIPT_DIR}/patch-quark-puus.py" "$QUARK_SRC" \
      || warn "quark.py __puus 补丁执行失败(下载会 412)"
    grep -q "_refresh_puus" "$QUARK_SRC" \
      || die "quark.py __puus 补丁没打上 —— 夸克下载会恒 412(真机 v1.0.4 的坑)"
    log "gequhai-downloader quark.py 已打 __puus 补丁"
  fi

  # ① 单曲下载 venv: 只依赖 requests。
  #    命令行单曲下载(music single)复用 gequhai-downloader 里的 gequhai/quark/utils,
  #    这三个模块只依赖 requests, 所以轻量档也能用, 不需要 PyQt6。
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/music"
  # pysocks 必装: requests 默认不支持 socks5:// 代理, 不装的话设了代理反而直接报错
  # qrcode 是可选增强: 装了才能把夸克登录二维码画在终端里, 没装会退化成打印 URL
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/music/bin/pip install --disable-pip-version-check --no-cache-dir -q requests pysocks qrcode" \
    || warn "requests/pysocks/qrcode 安装失败(single 命令或扫码二维码不可用)"

  # ② 图形版(PyQt6): slim 档跳过, 需要时用 music setup-gui 补装
  if [[ "$WITH_PYQT" == "1" ]]; then
    chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/gequhai-gui"
    chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/gequhai-gui/bin/pip install --disable-pip-version-check --no-cache-dir -q PyQt6 requests pysocks" \
      || warn "PyQt6 安装失败"
  else
    log "slim 档: 跳过 PyQt6 图形界面 (启动后可用 music setup-gui 补装)"
  fi

  # 歌单批量版(playwright + Chromium)
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/playlist"
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/playlist/bin/pip install --disable-pip-version-check --no-cache-dir -q -r /home/${USER_NAME}/projects/gequhai-playlist-downloader/requirements.txt" \
    || warn "playlist 依赖安装失败"
  # Playwright Chromium: 以 root 跑, 这样 --with-deps 的 apt 依赖能装上;
  # 浏览器文件落到用户目录下, 之后统一 chown 回普通用户。
  if [[ "$WITH_PLAYWRIGHT_BROWSER" == "1" ]]; then
    chroot_run env "PLAYWRIGHT_BROWSERS_PATH=/home/${USER_NAME}/.cache/ms-playwright" \
      "/home/${USER_NAME}/.venvs/playlist/bin/python" -m playwright install --with-deps chromium \
      || warn "Playwright Chromium 安装失败"
  else
    log "slim 档: 跳过 Playwright Chromium (歌单走静态搜索; 启动后可用 music setup-playwright 补装)"
  fi
else
  step "3/9 跳过项目预装 (WITH_PROJECTS=0)"
fi

####################### 第 4 步: overlay 文件与用户配置 #######################
step "4/9 写入 overlay(输入法/快捷脚本/桌面配置)"
if [[ -d "${REPO_DIR}/overlay" ]]; then
  cp -a "${REPO_DIR}/overlay/." "${ROOTFS}/"
fi
# Windows 上 git 可能没记录执行位, 这里统一补上
find "${ROOTFS}/usr/local/bin" -type f -exec chmod 0755 {} + 2>/dev/null || true
chmod 0755 "${ROOTFS}/usr/local/lib/musictools/single.py" 2>/dev/null || true
chmod 0755 "${ROOTFS}/usr/local/lib/musictools/quark_login.py" 2>/dev/null || true
chmod 0755 "${ROOTFS}/usr/local/lib/screentools/fit.py" 2>/dev/null || true
chown -R "${USER_UID}:${USER_GID}" "${ROOTFS}/home/${USER_NAME}"

# 开机自扩容: 定长镜像写进大 U 盘后, 剩下的空间在开机时自动分给 root/MUSIC。
# 写完镜像插上就能用, 用户不需要手动跑任何脚本(真机翻了三轮才把这条路走通)。
# 这里**必须在补执行位的 chmod 之后**: git 在 Windows 下会把 bin 档的执行位
# 记成 0644, cp -a 原样拷出来, 断言放 chmod 前就会白炸一次(真机踩过)。
[[ -f "${ROOTFS}/etc/systemd/system/usb-grow.service" ]] \
  || die "usb-grow.service 没进镜像, 开机不会自动扩容"
[[ -x "${ROOTFS}/usr/local/bin/usb-grow.sh" ]] \
  || die "usb-grow.sh 没进镜像或没有执行位, systemd 只会拉起一个空壳"
chroot_run systemctl enable usb-grow.service || die "usb-grow.service 启用失败"

# ---- pip 换清华源(放在这里而不是第 2 步: 第 3 步的 pip 装包走官方 PyPI 更快) ----
if [[ -n "$PIP_INDEX_URL" ]]; then
  cat > "${ROOTFS}/etc/pip.conf" <<EOF
# 由 build-image.sh 生成
[global]
index-url = ${PIP_INDEX_URL}
timeout = 120
retries = 5
EOF
  mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/pip"
  cp "${ROOTFS}/etc/pip.conf" "${ROOTFS}/home/${USER_NAME}/.config/pip/pip.conf"
  log "pip 源: ${PIP_INDEX_URL}"
else
  log "PIP_INDEX_URL 为空, pip 保持默认源"
fi

# ---- 预置代理配置(不强制打开) ----
# /etc/profile.d/99-proxy.sh 里是"先探测端口通了才 export", 所以代理没跑的时候
# 终端不会带 http_proxy, 不会把"没开代理"变成"所有下载都失败"。
printf 'PROXY_URL="%s"\n' "${PROXY_URL_DEFAULT}" > "${ROOTFS}/etc/proxy.conf"
chmod 0644 "${ROOTFS}/etc/proxy.conf"
# 模板只从 proxy 脚本本身取(proxy --print-profile-d), 两边各写一份迟早会写岔
"${ROOTFS}/usr/local/bin/proxy" --print-profile-d "${PROXY_URL_DEFAULT}" \
  > "${ROOTFS}/etc/profile.d/99-proxy.sh" \
  || die "proxy --print-profile-d 生成失败"
chmod 0644 "${ROOTFS}/etc/profile.d/99-proxy.sh"
# 生成出来的东西必须还是合法 shell, 否则 /etc/profile.d 一被 source 就整个登录失败
bash -n "${ROOTFS}/etc/profile.d/99-proxy.sh" || die "/etc/profile.d/99-proxy.sh 语法错误"

# 光有 /etc/profile.d 是不够的 —— 那是**登录 shell** 才读的。xfce4-terminal
# 开出来的是非登录交互 shell, 只读 ~/.bashrc, 于是 proxy status 里永远显示
# "终端环境变量: 未设置", 而用户明明在图形桌面里。这里给两个账号的 ~/.bashrc
# 各加一行 source, 两条路都通。
for _bashrc in "${ROOTFS}/home/${USER_NAME}/.bashrc" "${ROOTFS}/root/.bashrc"; do
  [[ -f "$_bashrc" ]] || { : >>"$_bashrc"; chmod 0644 "$_bashrc"; }
  grep -q '99-proxy.sh' "$_bashrc" || cat >>"$_bashrc" <<'EOF'

# --- 代理(由 debian-usb-builder 预置) ---
# xfce4-terminal 这类终端是非登录 shell, 读不到 /etc/profile.d, 这里补一刀。
if [ -r /etc/profile.d/99-proxy.sh ]; then
  . /etc/profile.d/99-proxy.sh
fi
EOF
done
log "预置代理: ${PROXY_URL_DEFAULT}(proxy status / proxy on / proxy off)"

# ---- 终端标签页标题 = 当前目录 ----
# 真机反馈"终端的标签切换快捷键不明" —— 光给快捷键还不够,
# 标签页上得**写清楚现在在哪个目录**, 否则切过去也不知道切到哪了。
# 做法是在每个提示符前发一个 OSC 0 序列改窗口标题(xfce4-terminal 靠它显示标签名)。
#
# 注意: 必须**追加**到 .bashrc, 不能整个覆盖 —— Debian 的 .bashrc 里有
# 交互式判断、PATH 设置、历史记录配置等, 覆盖了就全没了。
if [[ -n "${USER_NAME}" ]]; then
  _user_bashrc="${ROOTFS}/home/${USER_NAME}/.bashrc"
  if [[ -f "$_user_bashrc" ]] && ! grep -q '_music_set_title' "$_user_bashrc"; then
    cat >> "$_user_bashrc" <<'EOF'

# --- debian-usb-builder: 终端标签页标题显示当前目录 ---
# 效果: 标签页上显示 "user@deb: Downloads", 一眼看出这个标签在干什么
_music_set_title() {
  printf '\033]0;%s@%s: %s\007' "${USER:-user}" "${HOSTNAME%%.*}" "${PWD##*/}"
}
case "${TERM}" in
  xterm*|rxvt*|screen*|tmux*)
    PROMPT_COMMAND="_music_set_title${PROMPT_COMMAND:+;${PROMPT_COMMAND}}"
    ;;
esac
EOF
    log "已写入终端标签页标题(跟随当前目录)"
  fi
fi

# ---- 显示分辨率: 每次图形登录自动匹配每块屏的原生分辨率 ----
[[ -x "${ROOTFS}/usr/bin/xrandr" ]] || die "xrandr 没装上, screen-fit 无法工作(x11-xserver-utils)"
[[ -f "${ROOTFS}/usr/local/bin/screen-fit" ]] || die "overlay 里缺 screen-fit"
[[ -f "${ROOTFS}/usr/local/lib/screentools/fit.py" ]] || die "overlay 里缺 fit.py"
# debootstrap 的 minbase 不保证有 /etc/xdg/autostart, 直接 cat 会 "No such file or directory"
mkdir -p "${ROOTFS}/etc/xdg/autostart"
cat > "${ROOTFS}/etc/xdg/autostart/screen-fit.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Screen Fit (自动匹配显示器原生分辨率)
Comment=按 EDID 把每块屏设成它自己的原生分辨率
Exec=/usr/local/bin/screen-fit --restore
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
# 默认就是开的 —— 用户明确要求"开机自动匹配实体屏幕分辨率"。
# 不想要的话: screen-fit --disable
mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/screen-fit"
printf '1\n' > "${ROOTFS}/home/${USER_NAME}/.config/screen-fit/enabled"
log "已配置开机自动匹配显示器原生分辨率(screen-fit --disable 可关)"

# EDID/xrandr 解析逻辑自测: 这一段纯字符串处理, 不需要 X, 构建期就能验。
# 解析错了在真机上的表现是"分辨率没变或者整屏拉伸", 很难一眼看出是脚本的锅。
if python3 "${ROOTFS}/usr/local/lib/screentools/fit.py" --self-test >"${BUILD_DIR}/fit-selftest.log" 2>&1; then
  log "EDID/xrandr 解析自测通过($(selftest_count "${BUILD_DIR}/fit-selftest.log") 项)"
else
  sed 's/^/[screen-fit] /' "${BUILD_DIR}/fit-selftest.log" >&2 || true
  die "EDID/xrandr 解析自测失败, screen-fit 会匹配错分辨率"
fi

# 认分区那一段同样是纯字符串处理(喂一份真的 sgdisk -p 输出), 不碰磁盘,
# 所以能在构建期验。这段以前错在"认分区依赖 lsblk 的列名 + set -e/pipefail",
# 真机上的表现是 usb-grow.sh 跑到一半自己没了, 所以必须在这里卡一道。
if bash "${ROOTFS}/usr/local/bin/usb-grow.sh" --self-test >"${BUILD_DIR}/grow-selftest.log" 2>&1; then
  log "分区识别自测通过($(selftest_count "${BUILD_DIR}/grow-selftest.log") 项)"
else
  sed 's/^/[usb-grow] /' "${BUILD_DIR}/grow-selftest.log" >&2 || true
  die "分区识别自测失败, usb-grow.sh 在真机上会认错分区"
fi

# 日志文件先建好并给普通用户写权限: 否则第一次跑永远是 root 建出来的 0644,
# 普通用户再跑就只能退到 ~/.local/state, 日志散在两个地方。
: >"${ROOTFS}/var/log/usb-grow.log"
chmod 0664 "${ROOTFS}/var/log/usb-grow.log"
chown root:"${USER_NAME}" "${ROOTFS}/var/log/usb-grow.log" 2>/dev/null || true

# 桌面精简的构建期断言: 面板/桌面图标一旦被某个包顺带装回来, 开机就会冒出
# 用户明确不要的 dock 和面板。这里直接检查 autostart 里没有它们。
for _panel in xfce4-panel xfdesktop4; do
  if [[ -e "${ROOTFS}/etc/xdg/autostart/${_panel}.desktop" ]] \
     || grep -q "^Package: ${_panel}\$" "${ROOTFS}/var/lib/dpkg/status" 2>/dev/null; then
    die "${_panel} 又被装进镜像了, 开机会有面板/桌面图标(用户要求只留终端)"
  fi
done
ok "桌面已精简: 无面板、无桌面图标, 登录后直接进终端"

# 夸克扫码登录: URL 拼接 / 状态码解析 / cookie 提取与打码 / 配置写回
# 全部是纯逻辑, 不联网就能测。真实接口在开发期人工实测过(拿到真 token、
# 轮询返回 50004001、假 ticket 被服务端以 AUTH_ERROR:50051 拒绝)。
QL="${ROOTFS}/usr/local/lib/musictools/quark_login.py"
[[ -f "$QL" ]] || die "overlay 里缺 quark_login.py"
if python3 -m py_compile "$QL"; then
  ok_q="语法检查通过"
else
  die "quark_login.py 语法错误"
fi
if python3 "$QL" --self-test >"${BUILD_DIR}/quark-selftest.log" 2>&1; then
  log "夸克登录逻辑自测通过($(selftest_count "${BUILD_DIR}/quark-selftest.log") 项)"
else
  sed 's/^/[quark] /' "${BUILD_DIR}/quark-selftest.log" >&2 || true
  die "夸克登录逻辑自测失败, music quark-login 不能用"
fi
# venv 里的包检查。
#
# 关键: 必须在 chroot 里面跑, 不能用 "${ROOTFS}/home/.../bin/python" 直接执行。
# 因为 venv 的 bin/python 是指向 /usr/bin/python3 的**绝对路径**软链, 在宿主机上
# 执行会解析到**宿主机**的 python3 —— 既不是 venv, 也没有 venv 的 site-packages,
# 于是 import 什么都失败。之前就因为这个误报了"没装 qrcode"。
# 正确做法: chroot_run + su, 让解释器在 chroot 里按 venv 的路径解析。
venv_has() {
  local mod="$1"
  chroot_run su - "$USER_NAME" -c \
    "/home/${USER_NAME}/.venvs/music/bin/python -c 'import ${mod}'" >/dev/null 2>&1
}

# requests 是 music single 的命根子, 缺了整条命令行下载链路直接废掉
if venv_has requests; then
  ok "music 虚拟环境: requests 可用(music single 能用)"
else
  die "music 虚拟环境里没有 requests —— music single / music quark-login 全都不可用"
fi
# pysocks: requests 走 socks5 代理必需, 没有它设了代理反而直接报错
if venv_has socks; then
  ok "music 虚拟环境: PySocks 可用(能走 socks5 代理)"
else
  warn "music 虚拟环境里没有 PySocks —— 走 socks5 代理会报 ProxySchemeUnknown"
fi
# qrcode 是可选的: 没装只会退化成"打印链接", 不该因此卡构建
if venv_has qrcode; then
  log "qrcode 已装, 夸克登录二维码可以直接画在终端里"
else
  warn "venv 里没有 qrcode, 扫码登录会退化成只打印链接(仍可用)"
fi

# shell 语法: 镜像里的这几个脚本是用户的救命工具, 语法错 = 跑起来毫无反应
for _sc in music net-doctor net-rescue usb-grow.sh screen-fit proxy music-health music-im-fix; do
  bash -n "${ROOTFS}/usr/local/bin/${_sc}" || die "镜像里的 ${_sc} 语法错误"
done
log "镜像内脚本语法检查通过"

# 输入法: 光"文件在"不够, Rime 的 Shift 配置写错过一次(把映射写成了字符串),
# 真机表现是"按 Shift 没反应", 根本看不出是配置问题。所以直接检查内容。
# 路径必须是 Rime 的"用户目录" ~/.local/share/fcitx5/rime/ —— 放在
# ~/.config/fcitx5/rime/ 下 Rime 根本不看(真机 v1.0.4 的坑: 配置从没生效)。
RIME_CFG="${ROOTFS}/home/${USER_NAME}/.local/share/fcitx5/rime/default.custom.yaml"
[[ -f "$RIME_CFG" ]] || die "Rime 配置缺失: ${RIME_CFG}(必须在 Rime 用户目录里)"
# 拼音词库必须真实存在: default.custom.yaml 要求 luna_pinyin_simp 方案,
# 但 --no-install-recommends 不会带 rime-data-luna-pinyin(见上面装包注释),
# 词库缺失时 Rime 部署失败, 整个镜像一个中文字都打不出来 —— 构建期就拦下。
[[ -f "${ROOTFS}/usr/share/rime-data/luna_pinyin_simp.schema.yaml" ]] \
  || die "拼音词库缺失: ${ROOTFS}/usr/share/rime-data/luna_pinyin_simp.schema.yaml 未找到(rime-data-luna-pinyin 没装进去), Rime 将无法部署拼音方案"
ok "rime-data-luna-pinyin: luna_pinyin_simp 方案已就位"
# 简体方案必须选中, 否则默认是繁体 luna_pinyin(真机 v1.0.4: 用户打出繁体字)
grep -q "schema: luna_pinyin_simp" "$RIME_CFG" \
  || die "Rime 没指定简体方案 luna_pinyin_simp —— 打出来会是繁体字"
ok "Rime 方案已锁定为简体 luna_pinyin_simp"
if grep -qE 'ascii_composer/switch_key/(Shift_L|Shift_R): inline_ascii' "$RIME_CFG"; then
  ok "Rime Shift 切换中英文已用扁平键配置(inline_ascii)"
elif grep -q 'ascii_composer/switch_key' "$RIME_CFG"; then
  die "Rime 的 ascii_composer 写成了字符串而不是 键->动作 映射, Shift 永远不会生效"
else
  die "Rime 没配 Shift 切中英文(按 Shift 不会有反应)"
fi
# CapsLock 作为第二条切换路(Shift 失灵时的备份)
if grep -q 'ascii_composer/switch_key/Caps_Lock' "$RIME_CFG"; then
  ok "Rime 另配了 CapsLock 切换键"
else
  warn "Rime 没配 CapsLock 切换键(Shift 失灵时只能靠 Ctrl+Space / music im-toggle)"
fi

# ---- 终端体系(真机反馈: 标签页快捷键不明 / 关光后黑屏 / Ctrl+Alt+T 盖屏) ----
# 这几项直接决定"小白能不能用", 缺了就卡构建, 别等刷完盘才发现。
# 注意: 上游把 xfce4 面板和桌面图标都去掉了(用户明确不要), 所以桌面上
# 没有任何可点的入口 —— 终端窗口全没了就真的是一片黑, 守护进程是唯一的兜底。
for _t in terminal-keepalive terminal-new terminal-keys terminal-setup terminal-welcome; do
  [[ -x "${ROOTFS}/usr/local/bin/${_t}" ]] || die "overlay 里缺 /usr/local/bin/${_t}"
done
ok "终端脚本齐全(keepalive/new/keys/setup/welcome)"
TRC="${ROOTFS}/home/${USER_NAME}/.config/xfce4/terminal/terminalrc"
[[ -f "$TRC" ]] || die "缺终端配置: ${TRC}"
if grep -q 'Shortcuts=NewTab' "$TRC" && grep -q 'Shortcuts=NextTab' "$TRC" && grep -q 'Shortcuts=PrevTab' "$TRC"; then
  ok "终端配置里显式写了标签页的 建/切/关 快捷键"
else
  die "终端配置里没写标签页快捷键, 用户猜不到怎么切标签页"
fi
for _a in terminal-keepalive terminal-setup; do
  _ad="${ROOTFS}/home/${USER_NAME}/.config/autostart/${_a}.desktop"
  [[ -f "$_ad" ]] || die "缺自启项: ${_ad}"
  grep -q "Exec=" "$_ad" || die "自启项没有 Exec: ${_ad}"
done
ok "终端自启项齐全(守护/键位设置)"
# 开机那个终端必须先打键位速查表 —— 用户说"像黑客一样在终端下操作",
# 而小白面对一个空终端根本不知道能干什么。
grep -q "terminal-welcome" "${ROOTFS}/home/${USER_NAME}/.config/autostart/xfce-terminal.desktop" 2>/dev/null \
  || die "开机终端没有接 terminal-welcome(键位速查表不会出现)"
ok "开机终端已接上键位速查表"
[[ -f "${ROOTFS}/home/${USER_NAME}/.tmux.conf" ]] || die "缺 ~/.tmux.conf"
ok "tmux 配置已预置(进阶用, 默认不开)"
# 真机 v1.0.2 "输入法切不动"的根因: profile/config 属主是 root, 用户写不进去,
# fcitx5 切换时要写状态, 写不进去就没反应。构建期直接断言属主, 不给这种坑
# 再流到用户手上的机会。
# 注意: 断言必须放在下方真正生成 profile/config 并 chown 之后 —— 这两个文件
# 不在 overlay 里, 是构建脚本 cat 出来的, 提前断言只会白炸一次构建。
FCITX_DIR="${ROOTFS}/home/${USER_NAME}/.config/fcitx5"
# 前端包是"必装", 但再确认一次真的进了 dpkg 状态库 —— 前端缺失时终端里
# Ctrl+Space 完全没反应, 而用户只会觉得"输入法坏了"。
for _pkg in fcitx5-frontend-gtk3 fcitx5-frontend-qt5 fcitx5-config-qt openssh-client; do
  grep -q "^Package: ${_pkg}$" "${ROOTFS}/var/lib/dpkg/status" \
    || die "包 ${_pkg} 没装进镜像(输入法前端/SSH 客户端都会缺)"
done
ok "输入法前端与 openssh-client 已在必装清单里"
# 输入法的两条"保险"也直接写好, 不依赖 im-config 的钩子链条
if [[ -n "${USER_NAME}" ]]; then
  mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/autostart"
  cat > "${ROOTFS}/home/${USER_NAME}/.config/autostart/fcitx5.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5
Comment=启动 fcitx5 输入法
Exec=fcitx5 -d --replace
Icon=fcitx
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  # 开机把输入法切到 rime(中文态)。真机 v1.0.4 的坑: fcitx5 起来后当前输入法
  # 是 keyboard-us(直写), 此时按 Shift 没有任何反应, 用户只会觉得"输入法坏了"。
  # 这里等 fcitx5 就绪后主动切一次, 开机就能直接打中文、按 Shift 切英文。
  cat > "${ROOTFS}/home/${USER_NAME}/.config/autostart/fcitx5-default.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Fcitx 5 Default Input Method
Comment=开机把输入法切到 rime(中文态), 否则 Shift 切换没反应
Exec=sh -c 'for i in $(seq 1 60); do fcitx5-remote >/dev/null 2>&1 && break; sleep 0.2; done; sleep 1; fcitx5-remote -s rime'
Terminal=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
  cat > "${ROOTFS}/home/${USER_NAME}/.xprofile" <<'EOF'
# --- fcitx5 ---
# im-config 靠 Xsession.d 钩子, lightdm 自动登录时经常断链;
# 直接在 .xprofile 里导出, 两条路都通输入法就一定能起来。
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
EOF
  chown "${USER_UID}:${USER_GID}" \
        "${ROOTFS}/home/${USER_NAME}/.config/autostart/fcitx5.desktop" \
        "${ROOTFS}/home/${USER_NAME}/.config/autostart/fcitx5-default.desktop" \
        "${ROOTFS}/home/${USER_NAME}/.xprofile" 2>/dev/null || true
  # autostart 目录本身也要归用户 —— 真机上它曾是 root:root, 普通用户想自己加
  # 个自启项都写不进去("权限不够")。
  chown "${USER_UID}:${USER_GID}" "${ROOTFS}/home/${USER_NAME}/.config/autostart" 2>/dev/null || true
  grep -q "fcitx5-remote -s rime" "${ROOTFS}/home/${USER_NAME}/.config/autostart/fcitx5-default.desktop" \
    || die "缺少开机切 rime 的自启项 —— 开机默认是键盘直写态, 按 Shift 不会有任何反应"
  log "已写入 fcitx5 自启项、开机切 rime 自启项与 ~/.xprofile 环境变量"
fi

# 对着"即将装进镜像的那份" music 跑一遍命令行回归测试。
# 这一步放在这里是因为 x86 的 CI runner 没有 loop 设备, 事后没法再从镜像里
# 把文件抠出来跑; 构建期 rootfs 就是一个目录, 直接测最省事也最可靠。
if [[ -f "${ROOTFS}/usr/local/bin/music" ]]; then
  if MUSIC_BIN="${ROOTFS}/usr/local/bin/music" bash "${SCRIPT_DIR}/test-music-cli.sh" >/dev/null 2>&1; then
    log "music 命令行回归测试通过(参数没有丢失)"
  else
    die "music 命令行回归测试失败, 镜像里的 music 脚本有问题"
  fi
fi

# 所有联网步骤已结束, 现在把 DNS 交给 systemd-resolved
rm -f "${ROOTFS}/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "${ROOTFS}/etc/resolv.conf"

# fcitx5 只保留一个中文输入法: Rime(简体)。用户明确要求"删掉其它输入法,
# 只留一个, Shift 切中英文"。
# 真机 v1.0.4 的坑: fcitx5 启动时当前输入法落在 keyboard-us(直写态),
# 此时按 Shift 根本没人接管 —— 表现为"按 Shift 没反应"。profile 里把
# rime 放第一位, 再配合下面的自启项开机主动切到 rime。
mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/fcitx5/rime"
cat > "${ROOTFS}/home/${USER_NAME}/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime
Icon=/usr/share/icons/hicolor/scalable/apps/fcitx5.svg
Enable On Keyboard Layout=0

[Groups/0/Items/0]
Name=rime
Layout=

[Groups/0/Items/1]
Name=keyboard-us
Layout=

[GroupOrder]
0=Default
EOF

# 全局快捷键必须放在 config(全局配置)里, 不能放进 profile —— profile 只认
# Groups/GroupOrder, 之前把 [Hotkey] 写在 profile 里, fcitx5 不认这段, 白写。
cat > "${ROOTFS}/home/${USER_NAME}/.config/fcitx5/config" <<'EOF'
[Hotkey]
TriggerKeys=Control+space
AltTriggerKeys=Shift+space
EnumerateForwardKeys=Control+Tab
EnumerateBackwardKeys=Shift+Tab
EnumerateWithTriggerKeys=True
EOF

# 踩过的坑(真机 v1.0.2 输入法切不动): 这两个文件是在上面 chown -R 之后才 cat 出来的,
# 于是属主落在 root:root 0644 —— 普通用户读得到、写不进去。fcitx5 切输入法时要
# 往这些文件里写状态, 写不进去时切换就没反应, 而且是"有时能切有时不能",
# 很难查。这里显式把整个 fcitx5 配置目录交还给用户。
chown -R "${USER_UID}:${USER_GID}" "${ROOTFS}/home/${USER_NAME}/.config/fcitx5"

# 属主与存在性断言(profile/config 上面刚生成)
# 注意: 必须比**数字 uid** 而不是 stat -c %U —— %U 按构建宿主机的 /etc/passwd
# 解析, GitHub runner 上 UID 1000 恰好登记叫 "packer", 而镜像里的 1000 是 user;
# 同一个数字在宿主机和镜像里名字不同, 按名字比对必然白炸一次构建。
for _f in "${FCITX_DIR}/profile" "${FCITX_DIR}/config"; do
  [[ -f "$_f" ]] || die "fcitx5 配置缺失: $_f"
  _uid="$(stat -c '%u' "$_f")"
  [[ "$_uid" == "$USER_UID" ]] \
    || die "fcitx5 配置属主 uid 是 ${_uid} 而不是 ${USER_UID}: $_f —— 普通用户写不进去, 输入法切换会失灵"
done
ok "fcitx5 profile/config 属主正确(uid=${USER_UID} ${USER_NAME}), 用户可写"
# Rime 用户目录同样要归用户: Rime 要在里面写 build/ 缓存和 user.yaml,
# 属主不对就部署不出方案(表现是"输入法起来了但打不出中文")。
RIME_DIR="${ROOTFS}/home/${USER_NAME}/.local/share/fcitx5/rime"
[[ -d "$RIME_DIR" ]] || die "Rime 用户目录缺失: ${RIME_DIR}"
chown -R "${USER_UID}:${USER_GID}" "$RIME_DIR"
_rime_uid="$(stat -c '%u' "${RIME_DIR}/default.custom.yaml")"
[[ "$_rime_uid" == "$USER_UID" ]] \
  || die "Rime 配置属主 uid 是 ${_rime_uid} 而不是 ${USER_UID} —— Rime 读不到/写不进用户目录"
ok "Rime 用户目录与配置属主正确(uid=${USER_UID} ${USER_NAME})"

# Rime 的简体拼音方案与自定义词库放在 overlay/home/user/.local/share/fcitx5/rime/ 下
# (Rime 的用户目录就是这里, 放错位置 Rime 根本不看 —— 真机 v1.0.4 的坑)

# 登录后自动开一个终端(命令行优先)
mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/autostart"
# 踩过的坑(真机 v1.0.3 输入法在终端打不出中文): xfce4-session 并行拉起所有
# autostart 项, terminal(666) 抢在 fcitx5(675) 之前启动 —— GTK 端 im-fcitx5
# 连接 fcitx5 的 dbus 握手失败后不会再恢复, 这个窗口就终身绕不过输入法,
# 表现为"打字直接进 shell、ctrl+space 没反应", 但凡手动新开的终端窗口都正常,
# 极难定位。这里让 terminal 等 org.fcitx.Fcitx5 出现在 session bus 上再启动,
# 最长约 15 秒, 超时也照样开终端, 不会把桌面卡死。
cat > "${ROOTFS}/home/${USER_NAME}/.config/autostart/xfce-terminal.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=启动终端
Exec=sh -c 'for i in $(seq 1 75); do dbus-send --session --dest=org.freedesktop.DBus --type=method_call --print-reply / org.freedesktop.DBus.NameHasOwner string:org.fcitx.Fcitx5 >/dev/null 2>&1 && break; sleep 0.2; done; exec xfce4-terminal --title=debian-usb --geometry=120x32 -e /usr/local/bin/terminal-welcome'
Icon=utilities-terminal
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
grep -q "NameHasOwner string:org.fcitx.Fcitx5" \
  "${ROOTFS}/home/${USER_NAME}/.config/autostart/xfce-terminal.desktop" \
  || die "terminal 自启项没有等待 fcitx5 就绪 —— 开机首个窗口会因 IM 握手竞态永远打不出中文(真机 v1.0.3 的坑)"

# 图形版下载器默认走 Clash(127.0.0.1:7897), 这里给一份清空代理的初始配置
if [[ -f "${ROOTFS}/home/${USER_NAME}/projects/gequhai-downloader/utils.py" ]]; then
  cat > "${ROOTFS}/home/${USER_NAME}/projects/gequhai-downloader/config.json" <<'EOF'
{
  "proxy": "",
  "quark_cookie": ""
}
EOF
fi

# 环境变量
cat > "${ROOTFS}/etc/environment" <<EOF
LANG=${LOCALE_NAME}
LC_ALL=${LOCALE_NAME}
LANGUAGE=zh_CN:zh
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
PLAYWRIGHT_BROWSERS_PATH=/home/${USER_NAME}/.cache/ms-playwright
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

# im-config: 让 X 会话按 fcitx5 启动输入法
chroot_run su - "$USER_NAME" -c "im-config -n fcitx5" || warn "im-config 配置失败"

####################### 第 5 步: fstab 与 GRUB 配置 #######################
step "5/9 写入 fstab / GRUB 配置"

cat > "${ROOTFS}/etc/fstab" <<EOF
# <file system>                <mount point>  <type>  <options>                                   <dump>  <pass>
UUID=${ROOT_UUID}  /              ext4   defaults,noatime,errors=remount-ro        0       1
LABEL=EFI                       /boot/efi     vfat   umask=0077,utf8=1                          0       1
UUID=${MUSIC_UUID} /mnt/songdisk ext4 defaults,noatime,nofail,x-systemd.device-timeout=15  0       2
tmpfs                           /tmp           tmpfs  defaults,nosuid,nodev,size=1G              0       0
EOF

mkdir -p "${ROOTFS}/mnt/songdisk"
chown "${USER_UID}:${USER_GID}" "${ROOTFS}/mnt/songdisk"

KVER="$(ls "${ROOTFS}/lib/modules" 2>/dev/null | sort -V | tail -1)"
[[ -n "$KVER" ]] || die "内核没有安装成功, 找不到 /lib/modules/*"
log "内核版本: ${KVER}"

mkdir -p "${ROOTFS}/boot/grub"
{
  echo "# 由 build-image.sh 自动生成"
  echo "set default=0"
  echo "set timeout=6"
  echo ""
  echo "insmod part_gpt"
  echo "insmod part_msdos"
  echo "insmod ext2"
  echo "insmod fat"
  if [[ "${SERIAL_CONSOLE}" == "1" ]]; then
    echo "serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"
    echo "terminal_output console serial"
  fi
  echo ""
  echo "menuentry 'Debian GNU/Linux 12 (USB · Xfce + Fcitx5/Rime) —— 图形/中文输入' {"
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}"
  if [[ "${SERIAL_CONSOLE}" == "1" ]]; then
    echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro quiet splash loglevel=3 console=ttyS0,115200n8"
  else
    echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro quiet splash loglevel=3"
  fi
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
  echo ""
  echo "menuentry 'Debian GNU/Linux 12 (USB · 详细启动日志, 无图形 splash)' {"
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}"
  echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro console=tty1 loglevel=7"
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
  echo ""
  echo "menuentry 'Debian GNU/Linux 12 (USB · 恢复模式 / 单用户)' {"
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID}"
  echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID} ro single"
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
} > "${ROOTFS}/boot/grub/grub.cfg"

# EFI 分区里的引导链配置: 找到根分区 -> 读真正的 grub.cfg
cat > "${BUILD_DIR}/esp-grub.cfg" <<EOF
search.fs_uuid ${ROOT_UUID} root
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF

####################### 第 6 步: 生成三个分区镜像 #######################
step "6/9 生成 ext4 / vfat 分区镜像"

# 清理 apt 缓存与包索引(能省 250MB 左右, 也让镜像干净些)
chroot_run apt-get clean || true
rm -rf "${ROOTFS}"/var/lib/apt/lists/* 2>/dev/null || true
rm -f  "${ROOTFS}"/var/cache/apt/archives/*.deb 2>/dev/null || true
rm -rf "${ROOTFS}"/var/log/journal/* 2>/dev/null || true
rm -f  "${ROOTFS}"/var/log/*.log 2>/dev/null || true

# 关键: 必须先卸载 chroot 的 bind mount。
# 否则 mke2fs -d 会把 /proc、/sys、/dev 的运行时内容一起灌进 ext4 镜像里。
for m in /run /sys /proc /dev/pts /dev; do
  if mountpoint -q "${ROOTFS}${m}" 2>/dev/null; then
    umount -lf "${ROOTFS}${m}" 2>/dev/null || true
  fi
done
MOUNTS=()
log "已卸载 chroot bind mount, 开始写入 ext4"

# 构建期的 policy-rc.d 不能进最终镜像(否则目标机上装包时服务起不来)
rm -f "${ROOTFS}/usr/sbin/policy-rc.d"

# --- 先把 EFI 引导文件从 rootfs 里取出来(必须在删除 rootfs 之前!) ---
EFI_FILES="${BUILD_DIR}/efi-files"
mkdir -p "$EFI_FILES"
shim_bin=""; grub_signed=""; grub_plain=""; mok_bin=""
if [[ -d "${ROOTFS}/usr/lib/shim" ]]; then
  f="$(find "${ROOTFS}/usr/lib/shim" -name 'shimx64.efi*' 2>/dev/null | head -1 || true)"
  [[ -n "$f" ]] && { cp -a "$f" "${EFI_FILES}/BOOTX64.EFI"; shim_bin="${EFI_FILES}/BOOTX64.EFI"; }
  f="$(find "${ROOTFS}/usr/lib/shim" -name 'MokManager.efi' 2>/dev/null | head -1 || true)"
  [[ -n "$f" ]] && { cp -a "$f" "${EFI_FILES}/MokManager.efi"; mok_bin="${EFI_FILES}/MokManager.efi"; }
fi
if [[ -d "${ROOTFS}/usr/lib/grub" ]]; then
  f="$(find "${ROOTFS}/usr/lib/grub" -name 'grubx64.efi.signed' 2>/dev/null | head -1 || true)"
  if [[ -n "$f" ]]; then
    cp -a "$f" "${EFI_FILES}/grubx64.efi"; grub_signed="${EFI_FILES}/grubx64.efi"
  else
    f="$(find "${ROOTFS}/usr/lib/grub" -name 'grubx64.efi' -not -name '*.signed' 2>/dev/null | head -1 || true)"
    if [[ -n "$f" ]]; then
      cp -a "$f" "${EFI_FILES}/grubx64.efi"; grub_plain="${EFI_FILES}/grubx64.efi"
    fi
  fi
fi
[[ -n "$shim_bin" ]] && log "找到 shim: $(basename "$shim_bin")"
[[ -n "$grub_signed" ]] && log "找到签名 grubx64.efi"
[[ -n "$grub_plain" ]] && log "找到未签名 grubx64.efi"

####################### 第 7 步: 分区表 + 分区镜像 + 拼盘 #######################
step "7/9 创建整盘镜像与 GPT 分区表"

# 关键顺序: 先建分区表, 再按分区表里各分区的"真实大小"生成分区镜像。
# 反过来做(先按整数 MiB 做镜像)必然出事: GPT 末尾要给备份分区表 + 备份头留 34 个扇区,
# 最后一个分区一旦顶到磁盘末尾, dd 就会覆盖掉备份 GPT 头, 分区表直接作废
# (sgdisk 报 "Backup header: ERROR", 固件也认不出分区表)。
rm -f "$OUT_IMG"
truncate -s "${IMG_SIZE_MB}M" "$OUT_IMG"
sgdisk --clear "$OUT_IMG" >/dev/null
sgdisk -n "1:0:+${BIOS_SIZE_MB}M" -t 1:ef02 -c 1:"BIOS-BOOT"   "$OUT_IMG" >/dev/null
sgdisk -n "2:0:+${ESP_SIZE_MB}M"  -t 2:ef00 -c 2:"EFI"         "$OUT_IMG" >/dev/null
sgdisk -n "3:0:+${ROOT_SIZE_MB}M" -t 3:8300 -c 3:"DEBIAN_ROOT" "$OUT_IMG" >/dev/null
sgdisk -n "4:0:+0"                -t 4:8300 -c 4:"MUSIC"       "$OUT_IMG" >/dev/null
sgdisk -A 2:set:2 "$OUT_IMG" >/dev/null   # p2 打上 legacy boot 属性

first_sector() { sgdisk -i "$1" "$OUT_IMG" | awk '/First sector:/ {print $3}'; }
last_sector()  { sgdisk -i "$1" "$OUT_IMG" | awk '/Last sector:/ {print $3}'; }
part_bytes()   { echo $(( ( $(last_sector "$1") - $(first_sector "$1") + 1 ) * 512 )); }

ESP_BYTES="$(part_bytes 2)"
ROOT_BYTES="$(part_bytes 3)"
MUSIC_BYTES="$(part_bytes 4)"
log "分区精确大小(字节): ESP=${ESP_BYTES} ROOT=${ROOT_BYTES} MUSIC=${MUSIC_BYTES}"

# 分区起点必须 1MiB 对齐, dd 才能用 bs=1M 精确定位
for n in 2 3 4; do
  (( $(first_sector "$n") % 2048 == 0 )) || die "分区 ${n} 起点未按 1MiB 对齐"
done

# --- 根分区镜像(内容来自 rootfs 目录) ---
truncate -s "$ROOT_BYTES" "$ROOT_IMG"
mke2fs -q -t ext4 -L DEBIAN_ROOT -U "$ROOT_UUID" -d "$ROOTFS" "$ROOT_IMG"
log "根分区镜像: $(du -sm "$ROOT_IMG" | cut -f1)MB"

# --- 歌曲分区镜像 ---
mkdir -p "${BUILD_DIR}/empty"
truncate -s "$MUSIC_BYTES" "$MUSIC_IMG"
mke2fs -q -t ext4 -L MUSIC -U "$MUSIC_UUID" -d "${BUILD_DIR}/empty" "$MUSIC_IMG"

# --- EFI 分区镜像 ---
truncate -s "$ESP_BYTES" "$ESP_IMG"
mkfs.vfat -F 32 -n EFI "$ESP_IMG"

mmd -i "$ESP_IMG" ::EFI ::EFI/BOOT ::EFI/debian || true
if [[ -n "$shim_bin" ]]; then
  mcopy -i "$ESP_IMG" "$shim_bin" ::EFI/BOOT/BOOTX64.EFI
  log "已写入 shim: $(basename "$shim_bin")"
else
  warn "没找到 shimx64.efi, 传统 UEFI 固件可能拒绝启动(可关闭 Secure Boot)"
fi
if [[ -n "$grub_signed" ]]; then
  mcopy -i "$ESP_IMG" "$grub_signed" ::EFI/BOOT/grubx64.efi
  mcopy -i "$ESP_IMG" "$grub_signed" ::EFI/debian/grubx64.efi
  log "已写入签名 grubx64.efi"
elif [[ -n "$grub_plain" ]]; then
  mcopy -i "$ESP_IMG" "$grub_plain" ::EFI/BOOT/grubx64.efi
  mcopy -i "$ESP_IMG" "$grub_plain" ::EFI/debian/grubx64.efi
  warn "使用未签名 grubx64.efi (Secure Boot 开启时无法启动)"
else
  die "找不到 grubx64.efi, 无法制作可启动镜像"
fi
[[ -n "$mok_bin" ]] && mcopy -i "$ESP_IMG" "$mok_bin" ::EFI/BOOT/MokManager.efi
mcopy -i "$ESP_IMG" "${BUILD_DIR}/esp-grub.cfg" ::EFI/BOOT/grub.cfg
mcopy -i "$ESP_IMG" "${BUILD_DIR}/esp-grub.cfg" ::EFI/debian/grub.cfg

####################### 第 7 步: 把分区写进整盘镜像 #######################
# rootfs 已经用完, 立刻释放磁盘空间(BIOS GRUB 模式还要用 /boot, 稍后再删)
if [[ "${WITH_BIOS_GRUB}" != "1" ]]; then
  rm -rf "$ROOTFS"
  log "已删除 rootfs 目录, 释放磁盘空间"
fi

p2_start="$(first_sector 2)"; p3_start="$(first_sector 3)"; p4_start="$(first_sector 4)"
dd if="$ESP_IMG"   of="$OUT_IMG" bs=1M seek=$(( p2_start * 512 / 1048576 )) conv=notrunc status=none
dd if="$ROOT_IMG"  of="$OUT_IMG" bs=1M seek=$(( p3_start * 512 / 1048576 )) conv=notrunc status=none
rm -f "$ROOT_IMG"      # 已并入整盘镜像, 立刻释放 3~6GB
dd if="$MUSIC_IMG" of="$OUT_IMG" bs=1M seek=$(( p4_start * 512 / 1048576 )) conv=notrunc status=none
rm -f "$MUSIC_IMG" "$ESP_IMG"
log "分区起始扇区: EFI@p2=${p2_start} root@p3=${p3_start} music@p4=${p4_start}"

# 自检: GPT(含备份头)必须完好, 否则这张 U 盘插上去也没法引导
if ! sgdisk -v "$OUT_IMG" 2>&1 | grep -qi "no problems found"; then
  sgdisk -v "$OUT_IMG" 2>&1 | sed 's/^/[sgdisk] /' || true
  die "GPT 分区表校验未通过"
fi
log "GPT 校验通过 ✅"

# 传统 BIOS 的 GRUB (可选, 实验性): 需要 loop 设备
if [[ "${WITH_BIOS_GRUB}" == "1" ]]; then
  step "7b/9 安装传统 BIOS GRUB (i386-pc)"
  if command -v losetup >/dev/null 2>&1 && LOOP_DEV="$(losetup --show -P "$OUT_IMG" 2>/dev/null)"; then
    if command -v grub-install >/dev/null 2>&1; then
      grub-install --target=i386-pc --boot-directory="${ROOTFS}/boot" "$LOOP_DEV" \
        && log "BIOS GRUB 安装完成" || warn "grub-install 失败, 仅 UEFI 可用"
    else
      warn "宿主机缺少 grub-install(apt install grub-pc-bin), 跳过 BIOS GRUB"
    fi
  else
    warn "无法使用 loop 设备, 跳过 BIOS GRUB (UEFI 不受影响)"
  fi
fi

####################### 第 8 步: 清理与自检 #######################
step "8/9 清理并瘦身母盘"

# ---- 瘦身: 删掉母盘里"装了但用不上"的内容 ----
# 只删可再生成的静态内容, 包数据库(/var/lib/dpkg)一律不动, apt/dpkg 状态不会坏:
#   1) /usr/share/doc    包装的 README/changelog(每包只留 copyright), 官网都有
#   2) /usr/share/man /info /groff   手册页, 镜像里没有 man 工作流, 一页也用不到
#   3) /usr/share/locale 除 zh_CN / en_US / C* 之外的翻译(.mo), 镜像是给中文用户的
#   4) apt 索引与下载缓存(debootstrap 及后续装包攒下的, 几十 MB 起步)
# 运行时再装包先 apt-get update 即可(music-im-fix 里已经是这个顺序)
if [[ -d "$ROOTFS" ]]; then
  _used() { du -sb \
    "$ROOTFS/usr/share/doc" "$ROOTFS/usr/share/man" "$ROOTFS/usr/share/info" \
    "$ROOTFS/usr/share/groff" "$ROOTFS/usr/share/locale" \
    "$ROOTFS/var/lib/apt/lists" "$ROOTFS/var/cache/apt" \
    2>/dev/null | awk '{s+=$1} END {print s+0}'; }
  _before="$(_used)"
  find "$ROOTFS/usr/share/doc" -mindepth 1 -type f ! -name copyright -delete 2>/dev/null || true
  find "$ROOTFS/usr/share/doc" -mindepth 1 -type d -empty -delete 2>/dev/null || true
  find "$ROOTFS/usr/share/man"  -mindepth 1 -delete 2>/dev/null || true
  find "$ROOTFS/usr/share/info" -mindepth 1 -delete 2>/dev/null || true
  find "$ROOTFS/usr/share/groff" -mindepth 1 -delete 2>/dev/null || true
  find "$ROOTFS/usr/share/locale" -mindepth 1 -maxdepth 1 \
    ! -name "zh_CN*" ! -name "en_US*" ! -name "C*" \
    -exec rm -rf {} + 2>/dev/null || true
  rm -rf "$ROOTFS"/var/lib/apt/lists/* "$ROOTFS"/var/lib/apt/lists/partial 2>/dev/null || true
  rm -rf "$ROOTFS"/var/cache/apt/archives/*.deb "$ROOTFS"/var/cache/apt/archives/partial 2>/dev/null || true
  _after="$(_used)"
  log "瘦身: 释放 $(( (_before - _after) / 1024 / 1024 )) MB 的文档/手册/翻译/apt 残留"
fi

[[ -d "$ROOTFS" ]] && rm -rf "$ROOTFS"
rm -rf "${BUILD_DIR}/empty" "${BUILD_DIR}/efi-files"
rm -f "$ROOT_IMG" "$MUSIC_IMG" "$ESP_IMG"

sgdisk -v "$OUT_IMG" | sed 's/^/[sgdisk] /'
log "镜像大小: $(du -h "$OUT_IMG" | cut -f1) (实际占用), $(stat -c%s "$OUT_IMG") 字节"
log "分区表:"
sgdisk -p "$OUT_IMG" | sed 's/^/[sgdisk] /'

####################### 第 9 步: 压缩 + 校验和 #######################
step "9/9 压缩与校验和"

avail_mb="$(df -m --output=avail "$OUT_DIR" 2>/dev/null | tail -1 | tr -d ' ')"
if [[ "$avail_mb" =~ ^[0-9]+$ ]] && (( avail_mb < 4096 )); then
  warn "剩余磁盘仅 ${avail_mb}MB, 压缩可能失败(可把 img_size_mb 调小后重试)"
fi

case "$COMPRESS" in
  xz)    xz -T0 -6 -k -f "$OUT_IMG" ;;
  gzip)  gzip -6 -k -f "$OUT_IMG" ;;
  none)  ;;
  *) die "未知压缩方式: $COMPRESS" ;;
esac

cat > "${OUT_DIR}/BUILD-INFO.txt" <<EOF
构建时间   : $(date -Is)
构建器版本 : ${BUILDER_VERSION}   (github.com/yao1987825/debian-usb-builder)
Debian     : ${SUITE}
内核       : ${KVER}
镜像       : $(basename "$OUT_IMG")
镜像大小   : ${IMG_SIZE_MB} MiB (压缩前)
分区       :
$(sgdisk -p "$OUT_IMG" | grep -E '[0-9]+ +[0-9]+ +[0-9]+ +[0-9.]+ [KMG]iB' | sed 's/^/  /')
root UUID  : ${ROOT_UUID}
歌曲挂载点 : /mnt/songdisk
登录用户   : ${USER_NAME} / 密码 ${USER_PASS}
预装项目   : $( [[ "${WITH_PROJECTS}" == "1" ]] && echo "是" || echo "否" )
镜像档位   : ${PROFILE}
  PyQt6 图形界面   : $( [[ "${WITH_PYQT}" == "1" ]] && echo "已安装" || echo "未安装(用 music setup-gui 补装)" )
  Playwright Chromium: $( [[ "${WITH_PLAYWRIGHT_BROWSER}" == "1" ]] && echo "已安装" || echo "未安装(用 music setup-playwright 补装)" )
  Noto CJK 字体    : $( [[ "${WITH_NOTO_CJK}" == "1" ]] && echo "已安装" || echo "未安装" )
单曲下载    : music single "<歌名>"   (只依赖 requests, 任何档位都可用)
apt 源      : ${APT_MIRROR:-官方源}   $( [[ "$APT_MIRROR_OK" == "1" ]] && echo "(已生效)" || echo "(构建时拉不动, 已回退官方源)" )
pip 源      : ${PIP_INDEX_URL:-默认 PyPI}
预置代理    : ${PROXY_URL_DEFAULT}   (proxy status / proxy on / proxy off)
显示分辨率  : 开机自动按 EDID 匹配每块屏的原生分辨率 (screen-fit --disable 可关)
Secure Boot: 需要 shim 签名(已随镜像写入); 若无法启动请在固件里关闭 Secure Boot
EOF
cat "${OUT_DIR}/BUILD-INFO.txt"

# 注意: 本脚本以 root 运行, 而 workflow 的后续步骤以普通用户运行,
# 所以这里生成的校验和文件必须放开权限, 否则后面覆盖会 Permission denied。
( cd "$OUT_DIR" && sha256sum ./*.img.xz > SHA256SUMS.txt 2>/dev/null || true; chmod 0666 SHA256SUMS.txt 2>/dev/null || true )
log "产物:"
ls -lh "$OUT_DIR" | sed 's/^/[out]   /'
log "完成 ✅"
