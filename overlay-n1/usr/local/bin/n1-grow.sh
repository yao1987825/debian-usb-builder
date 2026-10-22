#!/usr/bin/env bash
#
# n1-grow.sh —— 把 SD 卡 / U 盘上剩余的未分配空间全部给歌曲分区(MUSIC)
#
# 背景:
#   CI 产出的 N1 镜像大小是固定的(默认 BOOT 512M + ROOTFS 4096M + MUSIC 2048M)。
#   写进 16G / 32G 的卡以后, 卡的尾部是一大段"未分配"空间, 这个脚本把这段空间
#   直接补给最后一个分区(MUSIC), 并在线扩容它的 ext4 文件系统。
#
# 为什么不用 sgdisk / parted 改分区表:
#   N1 是 Amlogic 设备, 磁盘分区表是 MBR(msdos), 而 MBR 的头 446 字节是 Amlogic
#   u-boot 的引导码 —— 用 sgdisk/parted/sfdisk 改表会把引导码冲掉, 盒子就再也
#   起不来。这里只改 MBR 里"分区 3 扇区数"那 4 个字节(偏移 490), 其余字节一个
#   字节都不碰, 引导码原封不动。
#
# 用法:
#   sudo n1-grow.sh            # 把剩余空间全给 MUSIC
#   sudo n1-grow.sh --dry-run  # 只打印将要执行的改动
#
set -Eeuo pipefail

DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m[grow]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "请用 root 运行: sudo n1-grow.sh"
command -v resize2fs >/dev/null 2>&1 || die "缺少 resize2fs (apt install e2fsprogs)"
command -v python3  >/dev/null 2>&1 || die "缺少 python3"

# ---- 找到承载 root 的物理磁盘 ----
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
[[ -n "$ROOT_SRC" ]] || die "找不到根分区挂载点"
DISK_NAME="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1)"
[[ -n "$DISK_NAME" ]] || die "无法确定根分区所在物理磁盘 ($ROOT_SRC)"
DISK="/dev/${DISK_NAME}"

part_num_by_label() {
  lsblk -ln -o PARTN,PARTLABEL "$DISK" 2>/dev/null | awk -v l="$1" '$2==l {print $1; exit}'
}
part_path() {
  lsblk -ln -o PATH,PARTN "$DISK" 2>/dev/null | awk -v n="$1" '$2==n {print $1; exit}'
}

MUSIC_PART="$(part_num_by_label MUSIC)"
[[ -n "$MUSIC_PART" ]] || die "找不到 MUSIC 分区(标签 MUSIC), 本脚本只支持本镜像的分区布局"
MUSIC_DEV="$(part_path "$MUSIC_PART")"
[[ -n "$MUSIC_DEV" ]] || die "找不到 MUSIC 分区设备节点"

TOTAL_SECTORS="$(cat "/sys/block/${DISK_NAME}/size")"
MUSIC_START="$(cat "/sys/block/${DISK_NAME}/${DISK_NAME}${MUSIC_PART}/start")"
MUSIC_COUNT="$(cat "/sys/block/${DISK_NAME}/${DISK_NAME}${MUSIC_PART}/size")"
[[ -n "$TOTAL_SECTORS" && -n "$MUSIC_START" && -n "$MUSIC_COUNT" ]] || die "读取分区信息失败"

# MUSIC 必须是最后一个分区, 否则后面还有数据, 不能直接吃掉尾部空间
NEXT_START="$(cat "/sys/block/${DISK_NAME}/${DISK_NAME}$((MUSIC_PART+1))/start" 2>/dev/null || true)"
if [[ -n "$NEXT_START" ]]; then
  die "分区 ${MUSIC_PART} 后面还有分区 (起始扇区 ${NEXT_START}), 不能直接扩容尾部"
fi

NEW_COUNT=$(( TOTAL_SECTORS - MUSIC_START ))
to_gib() { awk -v s="$1" 'BEGIN{printf "%.2f", s*512/1073741824}'; }

log "磁盘      : ${DISK} ($(to_gib "$TOTAL_SECTORS") GiB)"
log "MUSIC     : p${MUSIC_PART} ${MUSIC_DEV}  当前 $(to_gib "$MUSIC_COUNT") GiB"
log "未分配    : $(to_gib $(( TOTAL_SECTORS - MUSIC_START - MUSIC_COUNT ))) GiB"
log "扩容后    : $(to_gib "$NEW_COUNT") GiB"

if (( NEW_COUNT <= MUSIC_COUNT )); then
  log "磁盘已用满, 没有可扩容的空间"
  exit 0
fi

if (( DRY_RUN )); then
  log "--dry-run: 不做任何修改"
  exit 0
fi

# MUSIC 必须先卸载, 否则内核不允许改分区表
if mountpoint -q /mnt/songdisk; then
  log "卸载 /mnt/songdisk"
  umount /mnt/songdisk
fi

log "改写 MBR 里的分区扇区数(只动 4 个字节, u-boot 引导码不受影响)..."
python3 - "$DISK" "$MUSIC_PART" "$NEW_COUNT" <<'PY'
import struct, sys
dev, partnum, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(dev, 'r+b') as f:
    mbr = f.read(512)
    if mbr[510:512] != b'\x55\xaa':
        sys.exit("MBR 签名不正确, 不是有效的分区表")
    off = 446 + 16 * (partnum - 1) + 12      # 扇区数字段(小端 4 字节)
    old = struct.unpack_from('<I', mbr, off)[0]
    struct.pack_into('<I', mbr, off, count)
    f.seek(off)
    f.write(mbr[off:off + 4])
print("分区表扇区数: %d -> %d" % (old, count))
PY

partx -u "$DISK" 2>/dev/null || partprobe "$DISK" 2>/dev/null \
  || warn "partprobe 失败, 可能需要重启后再执行一次本脚本"

log "扩展文件系统 ..."
resize2fs "$MUSIC_DEV" || die "MUSIC 文件系统扩容失败(如果提示 busy, 请重启后再跑一次本脚本)"

mount /mnt/songdisk 2>/dev/null || true
log "完成 ✅"
df -h /mnt/songdisk 2>/dev/null | sed 's/^/[grow] /' || true
df -h /            2>/dev/null | sed 's/^/[grow] /' || true
