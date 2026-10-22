#!/usr/bin/env bash
#
# usb-grow.sh —— 把 U 盘上没被分区的剩余空间分给 root / MUSIC 两个分区
#
# 背景: CI 产出的镜像固定大小(默认 8GiB)。写进 64G/128G 的 U 盘后,
#       磁盘剩余空间处于"未分区"状态, 这个脚本负责重新划分并在线扩容文件系统。
#
# 用法:
#   sudo usb-grow.sh                 # root 分 30%, MUSIC 分 70%
#   sudo usb-grow.sh --root-percent 50
#   sudo usb-grow.sh --dry-run       # 只打印将要执行的改动
#
set -Eeuo pipefail

ROOT_PERCENT=30
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-percent) ROOT_PERCENT="${2:?--root-percent 需要一个数字}"; shift 2 ;;
    --dry-run)      DRY_RUN=1; shift ;;
    -h|--help)      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[grow]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请用 root 运行: sudo usb-grow.sh"
command -v sgdisk >/dev/null 2>&1 || die "缺少 sgdisk (apt install gdisk)"
command -v resize2fs >/dev/null 2>&1 || die "缺少 resize2fs (apt install e2fsprogs)"

# ---- 找到承载 root 的物理磁盘 ----
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SRC" ]] || die "找不到根分区挂载点"
DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
[[ -n "$DISK_NAME" ]] || die "无法确定根分区所在物理磁盘 ($ROOT_SRC)"
DISK="/dev/${DISK_NAME}"

part_path() { lsblk -ln -o PATH,PARTN "$DISK" 2>/dev/null | awk -v n="$1" '$2==n {print $1; exit}'; }
part_num_by_label() {
  lsblk -ln -o PARTN,PARTLABEL "$DISK" 2>/dev/null | awk -v l="$1" '$2==l {print $1; exit}'
}

ROOT_PART="${ROOT_PART:-$(part_num_by_label DEBIAN_ROOT)}"
MUSIC_PART="$(part_num_by_label MUSIC)"
[[ -n "$ROOT_PART" ]] || ROOT_PART=3
[[ -n "$MUSIC_PART" ]] || die "找不到 MUSIC 分区(标签 MUSIC), 本脚本只支持本镜像的分区布局"
[[ "$ROOT_PART" != "$MUSIC_PART" ]] || die "分区编号异常"

ROOT_DEV="$(part_path "$ROOT_PART")"
MUSIC_DEV="$(part_path "$MUSIC_PART")"
[[ -n "$ROOT_DEV" && -n "$MUSIC_DEV" ]] || die "找不到分区设备节点"

TOTAL_SECTORS="$(cat "/sys/block/${DISK_NAME}/size")"
# sgdisk -i 输出形如: "First sector: 2048 (at 1024.0 KiB)" / "Last sector: 1234"
info_field() {
  sgdisk -i "$1" "$DISK" | awk -v k="$2" 'index($0,k){for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}'
}

ROOT_START="$(info_field "$ROOT_PART" 'First sector')"
ROOT_LAST="$(info_field "$ROOT_PART" 'Last sector')"
MUSIC_START="$(info_field "$MUSIC_PART" 'First sector')"
MUSIC_LAST="$(info_field "$MUSIC_PART" 'Last sector')"
[[ -n "$ROOT_START" && -n "$ROOT_LAST" && -n "$MUSIC_START" && -n "$MUSIC_LAST" ]] \
  || die "读取分区表失败"

FREE_SECTORS=$(( TOTAL_SECTORS - MUSIC_LAST - 1 ))
if (( FREE_SECTORS <= 0 )); then
  log "磁盘已用满, 没有可扩容的空间"
  exit 0
fi

ROOT_EXTRA=$(( FREE_SECTORS * ROOT_PERCENT / 100 ))
(( ROOT_EXTRA > 0 )) || ROOT_EXTRA=0
MUSIC_EXTRA=$(( FREE_SECTORS - ROOT_EXTRA ))

NEW_ROOT_LAST=$(( ROOT_LAST + ROOT_EXTRA ))
NEW_MUSIC_START=$(( NEW_ROOT_LAST + 1 ))

to_gib() { awk -v s="$1" 'BEGIN{printf "%.2f", s*512/1073741824}'; }

log "磁盘      : ${DISK} ($(to_gib "$TOTAL_SECTORS") GiB)"
log "当前      : p${ROOT_PART}=root($(to_gib $((ROOT_LAST-ROOT_START+1))) GiB)  p${MUSIC_PART}=MUSIC($(to_gib $((MUSIC_LAST-MUSIC_START+1))) GiB)"
log "未分配    : $(to_gib "$FREE_SECTORS") GiB"
log "扩容后    : p${ROOT_PART}=root($(to_gib $((NEW_ROOT_LAST-ROOT_START+1))) GiB)  p${MUSIC_PART}=MUSIC($(to_gib $((TOTAL_SECTORS-NEW_MUSIC_START)) ) GiB)"

if (( DRY_RUN )); then
  log "--dry-run: 不做任何修改"
  exit 0
fi

# MUSIC 必须先卸载, 否则内核不允许改分区表
if mountpoint -q /mnt/songdisk; then
  log "卸载 /mnt/songdisk"
  umount /mnt/songdisk
fi

log "重写分区表 ..."
sgdisk -d "$MUSIC_PART" "$DISK" >/dev/null
sgdisk -n "${ROOT_PART}:${ROOT_START}:${NEW_ROOT_LAST}" -t "${ROOT_PART}:8300" -c "${ROOT_PART}:DEBIAN_ROOT" "$DISK" >/dev/null
sgdisk -n "${MUSIC_PART}:${NEW_MUSIC_START}:+0"              -t "${MUSIC_PART}:8300" -c "${MUSIC_PART}:MUSIC"       "$DISK" >/dev/null

partx -u "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null || warn "partprobe 失败, 可能需要重启后再执行一次"

log "扩展文件系统 ..."
resize2fs "$ROOT_DEV"  || die "root 文件系统扩容失败(如果提示 busy, 请重启后再跑一次本脚本)"
resize2fs "$MUSIC_DEV" || warn "MUSIC 文件系统扩容失败"

mount /mnt/songdisk 2>/dev/null || true
log "完成 ✅  当前歌曲盘:"
df -h /mnt/songdisk 2>/dev/null | sed 's/^/[grow] /' || true
df -h /            2>/dev/null | sed 's/^/[grow] /' || true
