#!/usr/bin/env bash
#
# n1-customize-rootfs.sh —— 在已挂载的 Phicomm N1 rootfs 内完成系统定制
#
# 与 x86 版 (build-image.sh) 的关键差异:
#   * 不装内核 —— 内核由 ophub rebuild 放在 BOOT 分区里, rootfs 里只有模块
#   * 不改 root 的 fstab 那一行 —— Armbian 已按 UUID 写好, 动了反而起不来
#   * 默认不装 PyQt6 / Playwright Chromium —— N1 只有 2GB 内存
#
# 输入(环境变量):
#   ROOTFS_MOUNT   已挂载的 rootfs 目录 (必填)
#   PROFILE        desktop | cli          (默认 desktop)
#   USER_NAME/USER_PASS/LOCALE_NAME/TIMEZONE_NAME
#   WITH_PYQT      1 = 预装 PyQt6 图形版   (默认 0)
#   WITH_PLAYWRIGHT 1 = 预装 Playwright Chromium (默认 0)
#   REPO_DIR       构建器仓库根目录
#
set -Eeuo pipefail
umask 022

: "${ROOTFS_MOUNT:?必须设置 ROOTFS_MOUNT (已挂载的 rootfs 目录)}"
[[ -d "${ROOTFS_MOUNT}/etc" ]] || { echo "ROOTFS_MOUNT 不是有效的 rootfs: ${ROOTFS_MOUNT}" >&2; exit 1; }

PROFILE="${PROFILE:-desktop}"
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-user}"
LOCALE_NAME="${LOCALE_NAME:-zh_CN.UTF-8}"
TIMEZONE_NAME="${TIMEZONE_NAME:-Asia/Shanghai}"
WITH_PYQT="${WITH_PYQT:-0}"
WITH_PLAYWRIGHT="${WITH_PLAYWRIGHT:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${REPO_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
REPO_GEQUHAI="${REPO_GEQUHAI:-https://github.com/Yannick-Mo/gequhai-downloader.git}"
REPO_PLAYLIST="${REPO_PLAYLIST:-https://github.com/hoogrey/gequhai-playlist-downloader.git}"

log()  { printf '\033[1;34m[n1-rootfs]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn ]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

MOUNTS=()
cleanup() {
  local rc=$?
  set +e
  for m in /run /sys /proc /dev/pts /dev; do
    if mountpoint -q "${ROOTFS_MOUNT}${m}" 2>/dev/null; then umount -lf "${ROOTFS_MOUNT}${m}" 2>/dev/null; fi
  done
  return $rc
}
trap cleanup EXIT

case "$PROFILE" in
  desktop|cli) ;;
  *) die "未知 PROFILE: ${PROFILE} (可选 desktop|cli)" ;;
esac

############################### 第 0 步: 识别发行版 #######################
step "0/8 识别发行版"
OS_ID="$(sed -n 's/^ID=//p' "${ROOTFS_MOUNT}/etc/os-release" | tr -d '"' | head -1)"
OS_CODENAME="$(sed -n 's/^VERSION_CODENAME=//p' "${ROOTFS_MOUNT}/etc/os-release" | tr -d '"' | head -1)"
[[ -n "$OS_CODENAME" ]] || OS_CODENAME="$(ls "${ROOTFS_MOUNT}/usr/share/debian_base" 2>/dev/null | head -1)"
[[ -n "$OS_CODENAME" ]] || OS_CODENAME="trixie"

if [[ "$OS_ID" == "ubuntu" || "$OS_CODENAME" == "resolute" || "$OS_CODENAME" == "noble" ]]; then
  APT_MIRROR="http://archive.ubuntu.com/ubuntu"
  APT_SECURITY="http://security.ubuntu.com/ubuntu"
  APT_UPDATES="http://archive.ubuntu.com/ubuntu"
else
  APT_MIRROR="http://deb.debian.org/debian"
  APT_SECURITY="http://security.debian.org/debian-security"
  APT_UPDATES="http://deb.debian.org/debian"
fi
log "发行版: ${OS_ID:-unknown} ${OS_CODENAME}  镜像源: ${APT_MIRROR}"

############################### 第 1 步: 网络与 apt 源 ###################
step "1/8 配置 DNS 与 apt 源"

# 宿主机常是 systemd-resolved 的 127.0.0.53, 在 chroot 里不可达, 必须过滤掉
# 注意: Armbian 镜像里的 /etc/resolv.conf 可能是指向 /run/systemd/resolve/... 的软链接,
# 而 /run 是从宿主机 bind mount 进来的 —— 直接写会把宿主机的 DNS 配置改掉。
# 所以先删掉软链接, 再写普通文件。
if [[ -L "${ROOTFS_MOUNT}/etc/resolv.conf" ]]; then
  log "移除 rootfs 里指向 /run 的 resolv.conf 软链接(避免改到宿主机 DNS)"
  rm -f "${ROOTFS_MOUNT}/etc/resolv.conf"
fi
: > "${ROOTFS_MOUNT}/etc/resolv.conf"
if [[ -f /etc/resolv.conf ]]; then
  grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' \
    | grep -vE '^(127\.|::1|0\.0\.0\.0)' >> "${ROOTFS_MOUNT}/etc/resolv.conf" || true
fi
if ! grep -q '^nameserver' "${ROOTFS_MOUNT}/etc/resolv.conf"; then
  printf 'nameserver 223.5.5.5\nnameserver 119.29.29.29\n' >> "${ROOTFS_MOUNT}/etc/resolv.conf"
  log "未取到宿主机可用 DNS, 回退到 223.5.5.5 / 119.29.29.29"
fi

cat > "${ROOTFS_MOUNT}/etc/apt/sources.list" <<EOF
deb ${APT_MIRROR} ${OS_CODENAME} main contrib non-free non-free-firmware
deb ${APT_UPDATES} ${OS_CODENAME}-updates main contrib non-free non-free-firmware
deb ${APT_SECURITY} ${OS_CODENAME}-security main contrib non-free non-free-firmware
EOF
# Armbian 自带的 apt 源指向 armbian 镜像站 / 其它发行版, 构建期经常超时甚至 404,
# 全部停用, 只留上面这份官方源(否则 apt-get update 失败会导致后面装不上包)。
for f in "${ROOTFS_MOUNT}"/etc/apt/sources.list.d/*.list "${ROOTFS_MOUNT}"/etc/apt/sources.list.d/*.sources; do
  [[ -e "$f" ]] || continue
  mv -f "$f" "${f}.disabled" 2>/dev/null || rm -f "$f" 2>/dev/null || true
done

mkdir -p "${ROOTFS_MOUNT}/dev/pts" "${ROOTFS_MOUNT}/proc" "${ROOTFS_MOUNT}/sys" "${ROOTFS_MOUNT}/run"
mount --bind /dev  "${ROOTFS_MOUNT}/dev";  MOUNTS+=("${ROOTFS_MOUNT}/dev")
mount --bind /dev/pts "${ROOTFS_MOUNT}/dev/pts"; MOUNTS+=("${ROOTFS_MOUNT}/dev/pts")
mount --bind /proc "${ROOTFS_MOUNT}/proc"; MOUNTS+=("${ROOTFS_MOUNT}/proc")
mount --bind /sys  "${ROOTFS_MOUNT}/sys";  MOUNTS+=("${ROOTFS_MOUNT}/sys")
mount --bind /run  "${ROOTFS_MOUNT}/run";  MOUNTS+=("${ROOTFS_MOUNT}/run")

# 构建期间不要在 chroot 里真的启动守护进程
cat > "${ROOTFS_MOUNT}/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "${ROOTFS_MOUNT}/usr/sbin/policy-rc.d"

chroot_run() { chroot "$ROOTFS_MOUNT" /usr/bin/env DEBIAN_FRONTEND=noninteractive LC_ALL=C "$@"; }

chroot_run apt-get update -qq || warn "apt-get update 有告警, 继续"
# 确认主仓库索引真的拿到了, 否则后面的 install 会莫名其妙地"找不到包"
if ! chroot_run apt-get install -y --no-install-recommends --print-uris locales >/dev/null 2>&1; then
  die "apt 源不可用, 无法安装软件包(检查 ${OS_CODENAME} 的软件源)"
fi

############################### 第 2 步: 装软件栈 #######################
step "2/8 安装软件栈 (PROFILE=${PROFILE})"

BASE_PKGS=(
  locales tzdata sudo ca-certificates curl wget git rsync
  python3 python3-venv python3-pip ffmpeg aria2 vim tmux htop pciutils usbutils
  fcitx5 fcitx5-rime fcitx5-config-qt im-config fonts-wqy-zenhei
  xinit x11-xserver-utils dbus-x11
  polkitd policykit-1
)

if [[ "$PROFILE" == "desktop" ]]; then
  DESKTOP_PKGS=(xorg xdg-utils xfce4 xfce4-terminal lightdm lightdm-gtk-greeter fonts-noto-cjk x11-apps)
else
  DESKTOP_PKGS=(xterm)
fi

ALL_PKGS=("${BASE_PKGS[@]}" "${DESKTOP_PKGS[@]}")

# 过滤掉本发行版里不存在的包。
# 不同 Debian 版本的包名会变, 例如 trixie 把 policykit-1 拆成了 polkitd + pkexec,
# 直接整批 install 会因为一个包找不到而全部失败。
avail_pkgs() {
  local policy="" line="" cur="" cand=""
  local -a out=()
  policy="$(chroot_run apt-cache policy "$@" 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^([A-Za-z0-9][A-Za-z0-9+._-]*):$ ]]; then
      if [[ -n "$cur" && -n "$cand" && "$cand" != "(none)" ]]; then out+=("$cur"); fi
      cur="${BASH_REMATCH[1]}"; cand=""
    elif [[ "$line" =~ ^[[:space:]]+Candidate:[[:space:]]*(.+)$ ]]; then
      cand="${BASH_REMATCH[1]}"
    fi
  done <<< "$policy"
  if [[ -n "$cur" && -n "$cand" && "$cand" != "(none)" ]]; then out+=("$cur"); fi
  [[ "${#out[@]}" -eq 0 ]] && return 0
  printf '%s\n' "${out[@]}"
}

mapfile -t PKGS < <(avail_pkgs "${ALL_PKGS[@]}")
[[ "${#PKGS[@]}" -gt 0 ]] || die "没有任何可安装的软件包, apt 源可能不可用"
log "可安装的核心包 (${#PKGS[@]}/${#ALL_PKGS[@]}): ${PKGS[*]}"

chroot_run apt-get install -y --no-install-recommends "${PKGS[@]}" \
  || die "基础软件包安装失败"

# 关键组件必须真的装上了, 否则镜像是个空壳
for p in python3 python3-venv fcitx5 xinit; do
  chroot_run dpkg -s "$p" >/dev/null 2>&1 || die "关键包 ${p} 没有装上"
done
if [[ "$PROFILE" == "desktop" ]]; then
  chroot_run dpkg -s xfce4 >/dev/null 2>&1 || die "关键包 xfce4 没有装上"
  chroot_run dpkg -s lightdm >/dev/null 2>&1 || die "关键包 lightdm 没有装上"
fi

# 可选组件: 装不上不影响系统, 但少了会影响输入法在 GTK/Qt 程序里的表现
apt_optional() {
  local -a pkgs=()
  mapfile -t pkgs < <(avail_pkgs "$@")
  if [[ "${#pkgs[@]}" -eq 0 ]]; then
    warn "可选包在本发行版里都不存在, 跳过: $*"
    return 0
  fi
  if chroot_run apt-get install -y --no-install-recommends "${pkgs[@]}"; then
    log "可选包已安装: ${pkgs[*]}"
  else
    warn "可选包安装失败(忽略): ${pkgs[*]}"
  fi
}
apt_optional \
  fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 \
  fcitx5-frontend-qt5 fcitx5-frontend-qt6 \
  fonts-wqy-microhei fonts-noto-color-emoji \
  thunar mousepad nano tree file unzip zip

chroot_run dpkg --configure -a || warn "dpkg --configure -a 有残留"

############################### 第 3 步: 语言 / 时区 / 账户 ###################
step "3/8 语言 / 时区 / 主机名 / 账户"

sed -i "s/^# *${LOCALE_NAME} UTF-8/${LOCALE_NAME} UTF-8/" "${ROOTFS_MOUNT}/etc/locale.gen" 2>/dev/null || true
grep -q "^${LOCALE_NAME} UTF-8" "${ROOTFS_MOUNT}/etc/locale.gen" 2>/dev/null \
  || echo "${LOCALE_NAME} UTF-8" >> "${ROOTFS_MOUNT}/etc/locale.gen"
chroot_run locale-gen || warn "locale-gen 失败"

cat > "${ROOTFS_MOUNT}/etc/default/locale" <<EOF
LANG=${LOCALE_NAME}
LC_ALL=${LOCALE_NAME}
LANGUAGE=zh_CN:zh
EOF

ln -snf "/usr/share/zoneinfo/${TIMEZONE_NAME}" "${ROOTFS_MOUNT}/etc/localtime"
echo "${TIMEZONE_NAME}" > "${ROOTFS_MOUNT}/etc/timezone"
echo "n1-music" > "${ROOTFS_MOUNT}/etc/hostname"
cat > "${ROOTFS_MOUNT}/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	n1-music
::1		localhost ip6-localhost ip6-loopback
EOF

if ! chroot_run id -u "$USER_NAME" >/dev/null 2>&1; then
  chroot_run useradd --create-home --shell /bin/bash --comment "N1 Music User" "$USER_NAME"
  echo "${USER_NAME}:${USER_PASS}" | chroot_run chpasswd
  # 只添加系统里真实存在的组(不同 Debian 版本提供的组不一样)
  existing_groups="$(chroot_run getent group | cut -d: -f1)"
  for g in sudo audio video plugdev netdev cdrom render; do
    if grep -qx "$g" <<<"$existing_groups"; then
      chroot_run usermod -aG "$g" "$USER_NAME"
    else
      warn "组 ${g} 在本系统不存在, 跳过"
    fi
  done
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$USER_NAME" > "${ROOTFS_MOUNT}/etc/sudoers.d/90-${USER_NAME}"
  chmod 0440 "${ROOTFS_MOUNT}/etc/sudoers.d/90-${USER_NAME}"
else
  log "用户 ${USER_NAME} 已存在, 跳过创建"
fi

# 该账号只存在于 chroot 里, 宿主机没有同名用户, 所以必须用数字 UID/GID 做 chown
USER_UID="$(chroot_run id -u "$USER_NAME")"
USER_GID="$(chroot_run id -g "$USER_NAME")"
log "用户 ${USER_NAME} uid=${USER_UID} gid=${USER_GID}"

############################### 第 4 步: 预装两个下载器项目 ###################
step "4/8 预装下载器项目 + Python 虚拟环境"

mkdir -p "${ROOTFS_MOUNT}/home/${USER_NAME}/projects"
if [[ ! -d "${ROOTFS_MOUNT}/home/${USER_NAME}/projects/gequhai-downloader/.git" ]]; then
  chroot_run git clone --depth 1 "$REPO_GEQUHAI" \
    "/home/${USER_NAME}/projects/gequhai-downloader" || warn "clone ${REPO_GEQUHAI} 失败"
else
  log "gequhai-downloader 已存在, 跳过 clone"
fi
if [[ ! -d "${ROOTFS_MOUNT}/home/${USER_NAME}/projects/gequhai-playlist-downloader/.git" ]]; then
  chroot_run git clone --depth 1 "$REPO_PLAYLIST" \
    "/home/${USER_NAME}/projects/gequhai-playlist-downloader" || warn "clone ${REPO_PLAYLIST} 失败"
else
  log "gequhai-playlist-downloader 已存在, 跳过 clone"
fi

# ① 单曲下载 venv: 只依赖 requests。
#    命令行单曲下载(music single)复用 gequhai-downloader 里的 gequhai/quark/utils,
#    这三个模块只依赖 requests, 不需要 PyQt6, 在 2GB 内存的 N1 上也完全跑得动。
if [[ ! -x "${ROOTFS_MOUNT}/home/${USER_NAME}/.venvs/music/bin/python" ]]; then
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/music"
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/music/bin/pip install --disable-pip-version-check --no-cache-dir -q requests" \
    || warn "requests 安装失败(single 命令不可用)"
else
  log "单曲下载 venv 已存在, 跳过"
fi

# ② 图形版(PyQt6): 有 aarch64 wheel, 但 N1 的 Mali-450 没有 3D 加速, Qt 会走软件渲染,
#    帧率很低, 所以默认不装, 需要时在设备上跑 music setup-gui 补装。
if [[ "$WITH_PYQT" == "1" ]]; then
  if [[ ! -x "${ROOTFS_MOUNT}/home/${USER_NAME}/.venvs/gequhai-gui/bin/python" ]]; then
    chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/gequhai-gui"
    chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/gequhai-gui/bin/pip install --disable-pip-version-check --no-cache-dir -q PyQt6 requests" \
      || warn "PyQt6 安装失败(镜像里 glibc 过旧时会出现这种情况)"
  else
    log "图形版 venv 已存在, 跳过"
  fi
else
  log "默认不装 PyQt6 图形界面 (启动后可用 music setup-gui 补装)"
fi

# ③ 歌单批量版(playwright + imageio-ffmpeg)
#    playwright 1.54.0 与 imageio-ffmpeg 0.6.0 都有 aarch64 wheel, 可以正常安装;
#    但 Playwright 的 Chromium 浏览器内核没有官方 arm64 发行版, 需要时再补装。
if [[ ! -x "${ROOTFS_MOUNT}/home/${USER_NAME}/.venvs/playlist/bin/python" ]]; then
  chroot_run su - "$USER_NAME" -c "python3 -m venv /home/${USER_NAME}/.venvs/playlist"
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/playlist/bin/pip install --disable-pip-version-check --no-cache-dir -q -r /home/${USER_NAME}/projects/gequhai-playlist-downloader/requirements.txt" \
    || warn "playlist 依赖安装失败"
else
  log "歌单 venv 已存在, 跳过"
fi
if [[ "$WITH_PLAYWRIGHT" == "1" ]]; then
  chroot_run su - "$USER_NAME" -c "/home/${USER_NAME}/.venvs/playlist/bin/python -m playwright install --with-deps chromium" \
    || warn "Playwright Chromium 安装失败(官方没有 arm64 内核时必然失败, 可忽略)"
else
  log "默认不装 Playwright Chromium (启动后可用 music setup-playwright 补装)"
fi

############################### 第 5 步: overlay 与输入法 ###################
step "5/8 写入 overlay(快捷脚本 / Rime 词库)"

if [[ -d "${REPO_DIR}/overlay" ]]; then
  cp -a "${REPO_DIR}/overlay/." "${ROOTFS_MOUNT}/"
fi
# x86 的 usb-grow.sh 是 GPT/sgdisk 布局专用的, N1 用的是 MBR, 用 n1-grow.sh 代替
rm -f "${ROOTFS_MOUNT}/usr/local/bin/usb-grow.sh"
if [[ -d "${REPO_DIR}/overlay-n1" ]]; then
  cp -a "${REPO_DIR}/overlay-n1/." "${ROOTFS_MOUNT}/"
fi
find "${ROOTFS_MOUNT}/usr/local/bin" -type f -exec chmod 0755 {} + 2>/dev/null || true
chmod 0755 "${ROOTFS_MOUNT}/usr/local/lib/musictools/single.py" 2>/dev/null || true

# 对着"即将装进镜像的那份" music 跑一遍命令行回归测试
if [[ -f "${ROOTFS_MOUNT}/usr/local/bin/music" ]]; then
  if MUSIC_BIN="${ROOTFS_MOUNT}/usr/local/bin/music" bash "${SCRIPT_DIR}/test-music-cli.sh" >/dev/null 2>&1; then
    log "music 命令行回归测试通过(参数没有丢失)"
  else
    die "music 命令行回归测试失败, 镜像里的 music 脚本有问题"
  fi
fi

# fcitx5 默认使用 rime
mkdir -p "${ROOTFS_MOUNT}/home/${USER_NAME}/.config/fcitx5/rime"
cat > "${ROOTFS_MOUNT}/home/${USER_NAME}/.config/fcitx5/profile" <<'EOF'
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

# im-config: 让 X 会话按 fcitx5 启动输入法
chroot_run su - "$USER_NAME" -c "im-config -n fcitx5" || warn "im-config 配置失败"

############################### 第 6 步: 桌面 / 纯命令行 ###################
step "6/8 配置启动形态 (${PROFILE})"

if [[ "$PROFILE" == "desktop" ]]; then
  mkdir -p "${ROOTFS_MOUNT}/etc/lightdm"
  cat > "${ROOTFS_MOUNT}/etc/lightdm/lightdm.conf" <<EOF
[Seat:*]
user-session=xfce
greeter-session=lightdm-gtk-greeter
autologin-user=${USER_NAME}
autologin-user-timeout=0
autologin-session=xfce
EOF
  chroot_run systemctl enable lightdm || warn "lightdm 启用失败"
  # 登录后自动开一个终端(命令行优先)
  mkdir -p "${ROOTFS_MOUNT}/home/${USER_NAME}/.config/autostart"
  cat > "${ROOTFS_MOUNT}/home/${USER_NAME}/.config/autostart/xfce-terminal.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Terminal
Comment=启动终端
Exec=xfce4-terminal --title="n1-music" --geometry=120x32
Icon=utilities-terminal
Terminal=false
X-GNOME-Autostart-enabled=true
EOF
else
  # 纯命令行: 不装显示管理器, 在 tty 里用 startx 进 X + xterm
  cat > "${ROOTFS_MOUNT}/home/${USER_NAME}/.xinitrc" <<'EOF'
#!/bin/sh
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS=@im=fcitx
if [ -x /usr/bin/fcitx5 ]; then
  fcitx5 -d --replace >/dev/null 2>&1
fi
exec /usr/bin/xterm -geometry 120x32 -title "n1-music"
EOF
  chmod 0755 "${ROOTFS_MOUNT}/home/${USER_NAME}/.xinitrc"
  # 让 root 也能直接 startx
  cp -a "${ROOTFS_MOUNT}/home/${USER_NAME}/.xinitrc" "${ROOTFS_MOUNT}/root/.xinitrc" 2>/dev/null || true
  log "纯命令行模式: 在终端里执行 startx 进入图形终端 (可用中文输入法)"
fi

############################### 第 7 步: 环境变量与歌曲目录 ###################
step "7/8 环境变量 / 歌曲目录 / 属主"

mkdir -p "${ROOTFS_MOUNT}/mnt/songdisk"
chown "${USER_UID}:${USER_GID}" "${ROOTFS_MOUNT}/mnt/songdisk"

cat > "${ROOTFS_MOUNT}/etc/environment" <<EOF
LANG=${LOCALE_NAME}
LC_ALL=${LOCALE_NAME}
LANGUAGE=zh_CN:zh
GTK_IM_MODULE=fcitx
QT_IM_MODULE=fcitx
XMODIFIERS=@im=fcitx
PLAYWRIGHT_BROWSERS_PATH=/home/${USER_NAME}/.cache/ms-playwright
IMAGEIO_FFMPEG_EXE=/usr/bin/ffmpeg
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

# 图形版下载器默认走 Clash(127.0.0.1:7897), 这里给一份清空代理的初始配置
if [[ -f "${ROOTFS_MOUNT}/home/${USER_NAME}/projects/gequhai-downloader/utils.py" ]]; then
  cat > "${ROOTFS_MOUNT}/home/${USER_NAME}/projects/gequhai-downloader/config.json" <<'EOF'
{
  "proxy": "",
  "quark_cookie": ""
}
EOF
fi

chown -R "${USER_UID}:${USER_GID}" "${ROOTFS_MOUNT}/home/${USER_NAME}"

############################### 第 8 步: 清理 ###################
step "8/8 清理 apt 缓存"
chroot_run apt-get clean || true
rm -rf "${ROOTFS_MOUNT}"/var/lib/apt/lists/* 2>/dev/null || true
rm -f  "${ROOTFS_MOUNT}"/var/cache/apt/archives/*.deb 2>/dev/null || true
rm -rf "${ROOTFS_MOUNT}"/var/log/journal/* 2>/dev/null || true
rm -f  "${ROOTFS_MOUNT}"/var/log/*.log 2>/dev/null || true

log "定制完成 ✅  (PROFILE=${PROFILE}, 用户=${USER_NAME})"
