#!/usr/bin/env bash
#
# usb-grow.sh —— 把 U 盘上没被分区的剩余空间分给 root / MUSIC 两个分区
#
# 背景: CI 产出的镜像固定大小(默认 8GiB)。写进 64G/128G 的 U 盘后,
#       磁盘剩余空间处于"未分区"状态, 这个脚本负责重新划分并在线扩容文件系统。
#
# 用法:
#   usb-grow.sh                 # 默认 root 分 30%, MUSIC 分 70%
#   usb-grow.sh --root-percent 50
#   usb-grow.sh --check        # 只诊断, 不改任何东西(不需要 root)
#   usb-grow.sh --dry-run      # 打印将执行的改动, 但不动分区表
#
# 说明: 非 root 直接跑会自动用 sudo 重新执行自己, 不用自己加 sudo。
#
set -Eeuo pipefail
umask 022

ROOT_PERCENT=30
MODE=grow
DRY_RUN=0
LOG_FILE=/var/log/usb-grow.log

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'

usage() {
  cat <<'EOF'
用法: usb-grow.sh [选项]

  (无参数)              把剩余空间分给 root(30%) 和 MUSIC(70%)
  --root-percent N      root 拿 N%, MUSIC 拿剩下的(默认 30)
  --check               只做诊断, 打印当前情况, 不做任何修改(不需要 root)
  --dry-run             打印将执行的改动, 但不真正修改
  -h, --help            显示本帮助

不带 sudo 也能直接跑, 脚本会自己提权。
EOF
}

# ---------------- 参数解析 ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-percent) ROOT_PERCENT="${2:?--root-percent 需要一个数字}"; shift 2 ;;
    --check)        MODE=check; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$ROOT_PERCENT" =~ ^[0-9]+$ ]] || { echo "错误: --root-percent 必须是 0~100 的整数" >&2; exit 2; }

# ---------------- 输出 ----------------
# 同时写终端和日志文件, 避免"终端里什么都看不到"的情况
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
say()  { printf '%s[grow]%s %s\n' "$BLU" "$RST" "$*"; printf '%s\n' "[grow] $*" >> "$LOG_FILE" 2>/dev/null || true; }
step(){ printf '\n%s==> %s%s\n' "$BLU" "$*" "$RST"; printf '\n==> %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
ok()  { printf '  %s✅%s %s\n' "$GRN" "$RST" "$*"; printf '  ✅ %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
warn(){ printf '  %s⚠️ %s%s\n' "$YEL" "$*" "$RST"; printf '  ⚠️  %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
die() { printf '\n%s❌ 失败: %s%s\n' "$RED" "$*" "$RST"; printf '\n❌ 失败: %s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; exit 1; }

# ---------------- 自动提权 ----------------
if [[ "$(id -u)" != "0" ]]; then
  if [[ "$MODE" == "check" ]]; then
    warn "当前不是 root, 诊断结果可能不完整(挂载点/标签需要权限)"
  elif command -v sudo >/dev/null 2>&1; then
    say "需要 root 权限, 正在通过 sudo 重新执行..."
    exec sudo -E bash "$0" ${DRY_RUN:+$([ "$DRY_RUN" = 1 ] && echo --dry-run)} --root-percent "$ROOT_PERCENT"
  else
    die "需要 root 权限, 但系统里没有 sudo。请用 root 用户执行: usb-grow.sh"
  fi
fi

# ---------------- 环境诊断 ----------------
step "环境诊断"
say "脚本        : $(readlink -f "$0")"
say "执行用户    : $(id -un) (uid=$(id -u))"
say "内核/架构   : $(uname -sr) / $(uname -m)"

for c in sgdisk lsblk findmnt resize2fs partprobe partx; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 [$c]。安装: sudo apt-get install -y gdisk e2fsprogs util-linux parted"
done
ok "依赖命令齐全 (sgdisk / resize2fs / partprobe / partx)"

ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SRC" ]] || die "找不到根分区的挂载来源(findmnt -no SOURCE / 返回空)"
DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
[[ -n "$DISK_NAME" ]] || die "无法从 $ROOT_SRC 推断出物理磁盘(lsblk -no PKNAME 返回空)"
DISK="/dev/${DISK_NAME}"

TOTAL_SECTORS="$(cat "/sys/block/${DISK_NAME}/size" 2>/dev/null || true)"
[[ -n "$TOTAL_SECTORS" ]] || die "读不到 ${DISK} 的扇区数(/sys/block/${DISK_NAME}/size)"

to_gib() { awk -v s="${1:-0}" 'BEGIN{printf "%.2f", s*512/1073741824}'; }

PART_TYPE="$(lsblk -dn -o PTTYPE "$DISK" 2>/dev/null || true)"
say "根分区      : $ROOT_SRC  (挂载点 /)"
say "物理磁盘    : $DISK"
say "磁盘容量    : $(to_gib "$TOTAL_SECTORS") GiB"
say "分区表      : ${PART_TYPE:-未知}"

say "当前分区表:"
lsblk -no NAME,PARTN,PARTLABEL,FSTYPE,SIZE "$DISK" 2>/dev/null | sed 's/^/    /' | tee -a "$LOG_FILE" >/dev/null 2>&1 || true
lsblk -no NAME,PARTN,PARTLABEL,FSTYPE,SIZE "$DISK" 2>/dev/null | sed 's/^/    /'

# ---------------- 定位 root / music 分区 ----------------
part_num_by_label() {
  lsblk -ln -o PARTN,PARTLABEL "$DISK" 2>/dev/null | awk -v l="$1" '$2==l {print $1; exit}'
}
part_num_by_fstype() {
  lsblk -ln -o PARTN,FSTYPE "$DISK" 2>/dev/null | awk -v l="$1" '$2==l {print $1; exit}'
}
part_path() { lsblk -ln -o PATH,PARTN "$DISK" 2>/dev/null | awk -v n="$1" '$2==n {print $1; exit}'; }
# sgdisk -i 输出形如: "First sector: 2048 (at 1024.0 KiB)" / "Last sector: 1234"
info_field() {
  sgdisk -i "$1" "$DISK" 2>/dev/null | awk -v k="$2" 'index($0,k){for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}'
}

ROOT_PART="$(part_num_by_label DEBIAN_ROOT)"
[[ -n "$ROOT_PART" ]] || ROOT_PART="$(part_num_by_fstype ext4)"
if [[ -z "$ROOT_PART" ]]; then
  # 兜底: 根分区挂载点对应的分区号
  ROOT_PART="$(lsblk -ln -o PARTN,MOUNTPOINT "$DISK" 2>/dev/null | awk '$2=="/" {print $1; exit}')"
fi

MUSIC_PART="$(part_num_by_label MUSIC)"
if [[ -z "$MUSIC_PART" ]]; then
  # 兜底 1: 挂载点
  MUSIC_PART="$(lsblk -ln -o PARTN,MOUNTPOINT "$DISK" 2>/dev/null | awk '$2=="/mnt/songdisk" {print $1; exit}')"
fi
if [[ -z "$MUSIC_PART" ]]; then
  # 兜底 2: 取最后一个分区
  MUSIC_PART="$(lsblk -ln -o PARTN "$DISK" 2>/dev/null | awk 'NF{a=$1} END{print a}')"
  [[ -n "$MUSIC_PART" ]] && warn "按标签没认出 MUSIC 分区, 已改用磁盘上的最后一个分区 p${MUSIC_PART}"
fi

[[ -n "$ROOT_PART" ]]  || die "识别不出 root 分区。请手动指定: ROOT_PART=<编号> usb-grow.sh"
[[ -n "$MUSIC_PART" ]] || die "识别不出 MUSIC 分区。请手动指定: MUSIC_PART=<编号> usb-grow.sh"
[[ "$ROOT_PART" != "$MUSIC_PART" ]] || die "root 与 MUSIC 被识别成了同一个分区(p${ROOT_PART}), 已中止"

ROOT_DEV="$(part_path "$ROOT_PART")"
MUSIC_DEV="$(part_path "$MUSIC_PART")"
[[ -n "$ROOT_DEV" && -n "$MUSIC_DEV" ]] || die "找不到分区设备节点(p${ROOT_PART}=${ROOT_DEV:-空} p${MUSIC_PART}=${MUSIC_DEV:-空})"

ROOT_START="$(info_field "$ROOT_PART" 'First sector')"
ROOT_LAST="$(info_field "$ROOT_PART" 'Last sector')"
MUSIC_START="$(info_field "$MUSIC_PART" 'First sector')"
MUSIC_LAST="$(info_field "$MUSIC_PART" 'Last sector')"
[[ -n "$ROOT_START" && -n "$ROOT_LAST" && -n "$MUSIC_START" && -n "$MUSIC_LAST" ]] \
  || die "用 sgdisk 读取分区扇区范围失败(分区表可能已损坏)。先跑 --check 看完整信息"

ok "root 分区 : p${ROOT_PART} = ${ROOT_DEV}  (扇区 ${ROOT_START}..${ROOT_LAST})"
ok "MUSIC 分区: p${MUSIC_PART} = ${MUSIC_DEV}  (扇区 ${MUSIC_START}..${MUSIC_LAST})"

FREE_SECTORS=$(( TOTAL_SECTORS - MUSIC_LAST - 1 ))
say "未分配空间: $(to_gib "$FREE_SECTORS") GiB"

# ---------------- --check 到此结束 ----------------
if [[ "$MODE" == "check" ]]; then
  echo
  if (( FREE_SECTORS <= 0 )); then
    say "磁盘已用满, 没有可扩容的空间"
  else
    say "有 $(to_gib "$FREE_SECTORS") GiB 未分配。执行 usb-grow.sh 可以把它分给 root / MUSIC"
  fi
  say "完整日志: ${LOG_FILE}"
  exit 0
fi

# ---------------- 计算方案 ----------------
if (( FREE_SECTORS <= 0 )); then
  say "磁盘已用满, 没有可扩容的空间, 什么都不做"
  exit 0
fi

ROOT_EXTRA=$(( FREE_SECTORS * ROOT_PERCENT / 100 ))
(( ROOT_EXTRA > 0 )) || ROOT_EXTRA=0
MUSIC_EXTRA=$(( FREE_SECTORS - ROOT_EXTRA ))

NEW_ROOT_LAST=$(( ROOT_LAST + ROOT_EXTRA ))
NEW_MUSIC_START=$(( NEW_ROOT_LAST + 1 ))

step "扩容方案"
say "新增可分配: $(to_gib "$FREE_SECTORS") GiB  (root ${ROOT_PERCENT}% / MUSIC $((100-ROOT_PERCENT))%)"
say "root   : $(to_gib $((ROOT_LAST-ROOT_START+1))) GiB  ->  $(to_gib $((NEW_ROOT_LAST-ROOT_START+1))) GiB"
say "MUSIC  : $(to_gib $((MUSIC_LAST-MUSIC_START+1))) GiB  ->  $(to_gib $((TOTAL_SECTORS-NEW_MUSIC_START))) GiB"

if (( DRY_RUN )); then
  say "--dry-run: 到此为止, 不做任何修改"
  exit 0
fi

# ---------------- 备份分区表 ----------------
step "备份分区表"
GPT_BACKUP="/root/usb-grow-gpt-backup-$(date +%Y%m%d-%H%M%S).bin"
sgdisk --backup="$GPT_BACKUP" "$DISK" >/dev/null 2>&1 \
  && ok "已备份 GPT 到 ${GPT_BACKUP}" \
  || warn "GPT 备份失败(不影响继续, 但改表出问题就没法回滚了)"

# ---------------- 执行 ----------------
step "执行扩容"
if mountpoint -q /mnt/songdisk; then
  say "卸载 /mnt/songdisk (内核不允许移动已挂载的分区)"
  umount /mnt/songdisk || die "卸载 /mnt/songdisk 失败, 请关掉正在访问歌曲盘的程序后重试"
  ok "已卸载"
fi

say "重写分区表 ..."
sgdisk --delete="$MUSIC_PART" "$DISK" >/dev/null 2>&1 || die "删除旧 MUSIC 分区条目失败"
say "  扩展 root 到扇区 ${NEW_ROOT_LAST}"
sgdisk --new="${ROOT_PART}:${ROOT_START}:${NEW_ROOT_LAST}" \
       --typecode="${ROOT_PART}:8300" --change-name="${ROOT_PART}:DEBIAN_ROOT" \
       "$DISK" >/dev/null 2>&1 || die "重建 root 分区条目失败"
say "  在扇区 ${NEW_MUSIC_START} 重建 MUSIC 到磁盘末尾"
sgdisk --new="${MUSIC_PART}:${NEW_MUSIC_START}:+0" \
       --typecode="${MUSIC_PART}:8300" --change-name="${MUSIC_PART}:MUSIC" \
       "$DISK" >/dev/null 2>&1 || die "重建 MUSIC 分区条目失败"
ok "分区表已更新"

say "通知内核重新读取分区表 ..."
partx -u "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null \
  || warn "partprobe 失败。如果后面报设备不存在, 重启一次再跑本脚本"

step "扩展文件系统"
say "扩展 root (${ROOT_DEV}) ..."
if resize2fs "$ROOT_DEV" 2>&1 | sed 's/^/    /'; then
  ok "root 文件系统已扩展"
else
  die "root 文件系统扩展失败。若提示 busy, 请重启后再跑一次: usb-grow.sh"
fi

say "扩展 MUSIC (${MUSIC_DEV}) ..."
if resize2fs "$MUSIC_DEV" 2>&1 | sed 's/^/    /'; then
  ok "MUSIC 文件系统已扩展"
else
  warn "MUSIC 文件系统扩展失败, 可重启后再跑一次: usb-grow.sh"
fi

mount /mnt/songdisk 2>/dev/null || warn "自动挂载 /mnt/songdisk 失败, 请手动: sudo mount /mnt/songdisk"

step "结果"
ok "扩容完成 🎉"
df -h / /mnt/songdisk 2>/dev/null | sed 's/^/    /'
say "完整日志: ${LOG_FILE}"