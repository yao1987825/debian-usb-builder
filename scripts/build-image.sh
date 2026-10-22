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

IMG_SIZE_MB="${IMG_SIZE_MB:-8192}"               # 镜像总大小 (MiB)
ESP_SIZE_MB="${ESP_SIZE_MB:-512}"                # EFI 分区
ROOT_SIZE_MB="${ROOT_SIZE_MB:-6144}"             # 根分区
BIOS_SIZE_MB="${BIOS_SIZE_MB:-1}"                # BIOS boot 分区
MUSIC_SIZE_MB="${MUSIC_SIZE_MB:-$(( IMG_SIZE_MB - ESP_SIZE_MB - ROOT_SIZE_MB - BIOS_SIZE_MB ))}"

HOSTNAME_DEB="${HOSTNAME_DEB:-debian-usb}"
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-user}"
LOCALE_NAME="${LOCALE_NAME:-zh_CN.UTF-8}"
TIMEZONE_NAME="${TIMEZONE_NAME:-Asia/Shanghai}"

WITH_BIOS_GRUB="${WITH_BIOS_GRUB:-0}"            # 1=额外安装传统 BIOS 的 GRUB(实验性, 需 loop 设备)
WITH_PROJECTS="${WITH_PROJECTS:-1}"              # 1=把两个下载器项目预装进镜像
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
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

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

[[ "${MUSIC_SIZE_MB}" -gt 0 ]] || die "分区大小参数不合理: IMG_SIZE_MB 太小"
(( ESP_SIZE_MB + ROOT_SIZE_MB + MUSIC_SIZE_MB + BIOS_SIZE_MB <= IMG_SIZE_MB )) \
  || die "分区总大小 ${ESP_SIZE_MB}+${ROOT_SIZE_MB}+${MUSIC_SIZE_MB}+${BIOS_SIZE_MB} 超过镜像 ${IMG_SIZE_MB}MB"

mkdir -p "$BUILD_DIR" "$OUT_DIR"
# 上一次构建如果中断了, 可能还挂着 mount, 先卸干净
for m in /run /sys /proc /dev/pts /dev; do
  if mountpoint -q "${ROOTFS}${m}" 2>/dev/null; then umount -lf "${ROOTFS}${m}" 2>/dev/null || true; fi
done
rm -rf "$ROOTFS" "$ROOT_IMG" "$ESP_IMG" "$MUSIC_IMG"

# ---------- 生成 UUID (先于文件系统创建, 便于直接写进 fstab / grub.cfg) ----------
gen_uuid() { cat /proc/sys/kernel/random/uuid; }
ROOT_UUID="$(gen_uuid)"; ROOT_UUID="${ROOT_UUID//-/}"
MUSIC_UUID="$(gen_uuid)"; MUSIC_UUID="${MUSIC_UUID//-/}"
log "root UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}"

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

# ---- 必需组件 ----
chroot_run apt-get install -y --no-install-recommends \
  linux-image-amd64 \
  dbus-x11 policykit-1 sudo locales tzdata \
  xorg xinit xdg-utils \
  xfce4 xfce4-terminal \
  lightdm \
  fcitx5 fcitx5-rime fcitx5-config-qt im-config \
  fonts-wqy-zenhei fonts-noto-cjk \
  python3 python3-venv python3-pip \
  git curl wget ca-certificates \
  ffmpeg aria2 vim tmux htop \
  cloud-guest-utils gdisk parted dosfstools e2fsprogs rsync \
  grub-efi-amd64-bin grub-efi-amd64-signed shim-signed \
  systemd-resolved

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
  fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 \
  fcitx5-frontend-qt5 fcitx5-frontend-qt6 \
  thunar mousepad nano tree file unzip zip \
  python3-dev build-essential pkg-config \
  x11-xserver-utils fonts-wqy-microhei fonts-noto-color-emoji \
  lightdm-gtk-greeter

chroot_run dpkg --configure -a

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

  # 图形版(PyQt6)
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/gequhai-gui"
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/gequhai-gui/bin/pip install --disable-pip-version-check --no-cache-dir -q PyQt6 requests" \
    || warn "PyQt6 安装失败"

  # 歌单批量版(playwright + Chromium)
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/playlist"
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/playlist/bin/pip install --disable-pip-version-check --no-cache-dir -q -r /home/${USER_NAME}/projects/gequhai-playlist-downloader/requirements.txt" \
    || warn "playlist 依赖安装失败"
  # Playwright Chromium: 以 root 跑, 这样 --with-deps 的 apt 依赖能装上;
  # 浏览器文件落到用户目录下, 之后统一 chown 回普通用户。
  chroot_run env "PLAYWRIGHT_BROWSERS_PATH=/home/${USER_NAME}/.cache/ms-playwright" \
    "/home/${USER_NAME}/.venvs/playlist/bin/python" -m playwright install --with-deps chromium \
    || warn "Playwright Chromium 安装失败"
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
chown -R "${USER_NAME}:${USER_NAME}" "${ROOTFS}/home/${USER_NAME}"

# 所有联网步骤已结束, 现在把 DNS 交给 systemd-resolved
rm -f "${ROOTFS}/etc/resolv.conf"
ln -s /run/systemd/resolve/stub-resolv.conf "${ROOTFS}/etc/resolv.conf"

# fcitx5 默认使用 rime
mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/fcitx5/rime"
cat > "${ROOTFS}/home/${USER_NAME}/.config/fcitx5/profile" <<'EOF'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime
Icon=/usr/share/icons/hicolor/scalable/apps/fcitx5.svg
Enable On Keyboard Layout=0

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[Groups/0/Items/2]
Name=pinyin
Layout=

[GroupOrder]
0=Default

[Hotkey]
TriggerKeys=Control+space
EnumerateWithTriggerKeys=True
AltTriggerKeys=Shift+space
EnumerateForwardKeys=Control+Tab
EnumerateBackwardKeys=Shift+Tab
EOF

# Rime 的简体拼音方案与自定义词库放在 overlay/home/user/.config/fcitx5/rime/ 下

# 登录后自动开一个终端(命令行优先)
mkdir -p "${ROOTFS}/home/${USER_NAME}/.config/autostart"
cat > "${ROOTFS}/home/${USER_NAME}/.config/autostart/xfce-terminal.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=启动终端
Exec=xfce4-terminal --title="debian-usb" --geometry=120x32
Icon=utilities-terminal
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

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
UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}  /              ext4   defaults,noatime,errors=remount-ro        0       1
LABEL=EFI                       /boot/efi     vfat   umask=0077,utf8=1                          0       1
UUID=${MUSIC_UUID:0:8}-${MUSIC_UUID:8:4}-${MUSIC_UUID:12:4}-${MUSIC_UUID:16:4}-${MUSIC_UUID:20:12}  /mnt/songdisk ext4 defaults,noatime,nofail,x-systemd.device-timeout=15  0       2
tmpfs                           /tmp           tmpfs  defaults,nosuid,nodev,size=1G              0       0
EOF

mkdir -p "${ROOTFS}/mnt/songdisk"
chown "${USER_NAME}:${USER_NAME}" "${ROOTFS}/mnt/songdisk"

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
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}"
  if [[ "${SERIAL_CONSOLE}" == "1" ]]; then
    echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12} ro quiet splash loglevel=3 console=ttyS0,115200n8"
  else
    echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12} ro quiet splash loglevel=3"
  fi
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
  echo ""
  echo "menuentry 'Debian GNU/Linux 12 (USB · 详细启动日志, 无图形 splash)' {"
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}"
  echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12} ro console=tty1 loglevel=7"
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
  echo ""
  echo "menuentry 'Debian GNU/Linux 12 (USB · 恢复模式 / 单用户)' {"
  echo "    search --no-floppy --fs-uuid --set=root ${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}"
  echo "    linux /boot/vmlinuz-${KVER} root=UUID=${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12} ro single"
  echo "    initrd /boot/initrd.img-${KVER}"
  echo "}"
} > "${ROOTFS}/boot/grub/grub.cfg"

# EFI 分区里的引导链配置: 找到根分区 -> 读真正的 grub.cfg
cat > "${BUILD_DIR}/esp-grub.cfg" <<EOF
search.fs_uuid ${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12} root
set prefix=(\$root)/boot/grub
configfile \$prefix/grub.cfg
EOF

####################### 第 6 步: 生成三个分区镜像 #######################
step "6/9 生成 ext4 / vfat 分区镜像"

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

# --- 根分区 ---
truncate -s "${ROOT_SIZE_MB}M" "$ROOT_IMG"
mke2fs -q -t ext4 -L DEBIAN_ROOT -U "$ROOT_UUID" -d "$ROOTFS" "$ROOT_IMG"
log "根分区镜像: ${ROOT_SIZE_MB}MB (内容 $(du -sm "$ROOTFS" | cut -f1)MB)"

# --- 歌曲分区 ---
mkdir -p "${BUILD_DIR}/empty"
truncate -s "${MUSIC_SIZE_MB}M" "$MUSIC_IMG"
mke2fs -q -t ext4 -L MUSIC -U "$MUSIC_UUID" -d "${BUILD_DIR}/empty" "$MUSIC_IMG"

# --- EFI 分区 ---
truncate -s "${ESP_SIZE_MB}M" "$ESP_IMG"
mkfs.vfat -F 32 -n EFI "$ESP_IMG"

shim_bin="$(find "${ROOTFS}/usr/lib/shim" -name 'shimx64.efi*' 2>/dev/null | head -1 || true)"
grub_signed="$(find "${ROOTFS}/usr/lib/grub" -name 'grubx64.efi.signed' 2>/dev/null | head -1 || true)"
grub_plain="$(find "${ROOTFS}/usr/lib/grub" -name 'grubx64.efi' -not -name '*.signed' 2>/dev/null | head -1 || true)"
mok_bin="$(find "${ROOTFS}/usr/lib/shim" -name 'MokManager.efi' 2>/dev/null | head -1 || true)"

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

####################### 第 7 步: 组装整盘镜像 #######################
step "7/9 组装 GPT 分区表并写入各分区"
rm -f "$OUT_IMG"
truncate -s "${IMG_SIZE_MB}M" "$OUT_IMG"
sgdisk --clear "$OUT_IMG" >/dev/null
sgdisk -n "1:0:+${BIOS_SIZE_MB}M" -t 1:ef02 -c 1:"BIOS-BOOT"   "$OUT_IMG" >/dev/null
sgdisk -n "2:0:+${ESP_SIZE_MB}M"  -t 2:ef00 -c 2:"EFI"         "$OUT_IMG" >/dev/null
sgdisk -n "3:0:+${ROOT_SIZE_MB}M" -t 3:8300 -c 3:"DEBIAN_ROOT" "$OUT_IMG" >/dev/null
sgdisk -n "4:0:+0"                -t 4:8300 -c 4:"MUSIC"       "$OUT_IMG" >/dev/null
sgdisk -A 2:set:2 "$OUT_IMG" >/dev/null   # p2 打上 legacy boot 属性

sector_of() { sgdisk -i "$1" "$OUT_IMG" | awk '/First sector:/ {print $3}'; }

p2_start="$(sector_of 2)"; p3_start="$(sector_of 3)"; p4_start="$(sector_of 4)"
dd if="$ESP_IMG"   of="$OUT_IMG" bs=1M seek=$(( p2_start * 512 / 1048576 )) conv=notrunc status=none
dd if="$ROOT_IMG"  of="$OUT_IMG" bs=1M seek=$(( p3_start * 512 / 1048576 )) conv=notrunc status=none
dd if="$MUSIC_IMG" of="$OUT_IMG" bs=1M seek=$(( p4_start * 512 / 1048576 )) conv=notrunc status=none
log "分区起始: EFI@p2=${p2_start} root@p3=${p3_start} music@p4=${p4_start}"

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
step "8/9 清理中间文件并自检"
rm -rf "$ROOTFS" "${BUILD_DIR}/empty"
rm -f "$ROOT_IMG" "$MUSIC_IMG"

sgdisk -v "$OUT_IMG" | sed 's/^/[sgdisk] /'
log "镜像大小: $(du -h "$OUT_IMG" | cut -f1) (实际占用), $(stat -c%s "$OUT_IMG") 字节"
log "分区表:"
sgdisk -p "$OUT_IMG" | sed 's/^/[sgdisk] /'

####################### 第 9 步: 压缩 + 校验和 #######################
step "9/9 压缩与校验和"
case "$COMPRESS" in
  xz)    xz -T0 -6 -k -f "$OUT_IMG" ;;
  gzip)  gzip -6 -k -f "$OUT_IMG" ;;
  none)  ;;
  *) die "未知压缩方式: $COMPRESS" ;;
esac

cat > "${OUT_DIR}/BUILD-INFO.txt" <<EOF
构建时间   : $(date -Is)
Debian     : ${SUITE}
内核       : ${KVER}
镜像       : $(basename "$OUT_IMG")
镜像大小   : ${IMG_SIZE_MB} MiB (压缩前)
分区       : p1 BIOS-BOOT(${BIOS_SIZE_MB}MiB) / p2 EFI(${ESP_SIZE_MB}MiB) / p3 root(${ROOT_SIZE_MB}MiB ext4) / p4 MUSIC(${MUSIC_SIZE_MB}MiB ext4)
root UUID  : ${ROOT_UUID:0:8}-${ROOT_UUID:8:4}-${ROOT_UUID:12:4}-${ROOT_UUID:16:4}-${ROOT_UUID:20:12}
歌曲挂载点 : /mnt/songdisk
登录用户   : ${USER_NAME} / 密码 ${USER_PASS}
预装项目   : $( [[ "${WITH_PROJECTS}" == "1" ]] && echo "是" || echo "否" )
Secure Boot: 需要 shim 签名(已随镜像写入); 若无法启动请在固件里关闭 Secure Boot
EOF
cat "${OUT_DIR}/BUILD-INFO.txt"

( cd "$OUT_DIR" && sha256sum ./*.img* > SHA256SUMS.txt )
log "产物:"
ls -lh "$OUT_DIR" | sed 's/^/[out]   /'
log "完成 ✅"
