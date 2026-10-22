#!/usr/bin/env bash
#
# build-n1-image.sh —— 为 Phicomm N1 (Amlogic S905D) 构建定制 Armbian 镜像
#
# 流程:
#   1. 克隆 ophub/amlogic-s9xxx-armbian, 校验板型在官方板型库里
#   2. 从 ophub release 取一个通用 trunk 镜像作为基线
#   3. 调用 ophub 的 rebuild 脚本, 重打包成 N1 板型 (u-boot + dtb + BOOT/ROOTFS)
#   4. 后处理: 追加 MUSIC 分区, 挂载 rootfs 装软件栈, 写 fstab
#   5. 输出 .img.gz
#
# 必须跑在 ARM64 机器上(github 的 ubuntu-24.04-arm runner), 这样 chroot 进
# ARM rootfs 是原生的, 不用 qemu 模拟。
#
# 分区布局 (msdos/MBR, 与 ophub 的 Amlogic 保持一致):
#   p1  BOOT    fat32   内核 + dtb + u-boot overload
#   p2  ROOTFS  ext4    系统根分区 /        (标签 ROOTFS)
#   p3  MUSIC   ext4    歌曲分区            (标签 MUSIC, 挂 /mnt/songdisk)
#
set -Eeuo pipefail
umask 022

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

############################### 可调参数 #################################
# BOARD 是 ophub 板型库里第 14 列(BOARD / SOC 族)的取值, 不是第 2 列的型号名。
#   Phicomm-N1              -> s905d
#   Phicomm-N1(DMA-thresh)  -> s905d-n1-thresh
# 直接写板型库里的 BOARD 值也可以。
BOARD="${BOARD:-s905d}"
ARM_REPO="${ARM_REPO:-ophub/amlogic-s9xxx-armbian}"
ARM_REF="${ARM_REF:-main}"
DISTRO="${DISTRO:-trixie}"                      # 基线镜像的发行版 (trixie/bookworm/noble/resolute)
KERNEL_TAG="${KERNEL_TAG:-}"                    # 留空 = 用基线镜像里的精确内核版本
PROFILE="${PROFILE:-desktop}"                   # desktop | cli
BOOTFS_SIZE_MB="${BOOTFS_SIZE_MB:-512}"         # BOOT 分区大小
ROOTFS_SIZE_MB="${ROOTFS_SIZE_MB:-4096}"        # ROOTFS 分区大小
MUSIC_SIZE_MB="${MUSIC_SIZE_MB:-2048}"          # MUSIC(歌曲)分区大小
USER_NAME="${USER_NAME:-user}"
USER_PASS="${USER_PASS:-user}"
LOCALE_NAME="${LOCALE_NAME:-zh_CN.UTF-8}"
TIMEZONE_NAME="${TIMEZONE_NAME:-Asia/Shanghai}"
WITH_PYQT="${WITH_PYQT:-0}"                     # 1 = 预装 PyQt6 图形版
WITH_PLAYWRIGHT="${WITH_PLAYWRIGHT:-0}"         # 1 = 预装 Playwright Chromium

BUILD_DIR="${BUILD_DIR:-${REPO_DIR}/build-n1}"
ARM_DIR="${ARM_DIR:-${BUILD_DIR}/amlogic-s9xxx-armbian}"
OUT_DIR="${OUT_DIR:-${REPO_DIR}/out}"

log()  { printf '\033[1;34m[n1]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

disk_usage() { df -h "${BUILD_DIR}" 2>/dev/null | tail -1 | sed 's/^/    [disk] /'; }

[[ "$(uname -m)" == "aarch64" || "$(uname -m)" == "arm64" ]] \
  || die "必须在 ARM64 机器上运行(github runner: ubuntu-24.04-arm), 当前: $(uname -m)"
[[ "$(id -u)" == "0" ]] || die "请用 root 运行"

for c in losetup parted sfdisk mkfs.ext4 mkfs.vfat partprobe curl gunzip gzip python3 git; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令: $c"
done

mkdir -p "$BUILD_DIR" "$OUT_DIR" "$ARM_DIR"
chmod 0777 "$OUT_DIR" 2>/dev/null || true

############################### 第 1 步: 取 ophub 源码 ###################
step "1/6 准备 ${ARM_REPO} 源码"
if [[ ! -d "${ARM_DIR}/.git" ]]; then
  git clone --depth 1 "https://github.com/${ARM_REPO}.git" "$ARM_DIR"
else
  git -C "$ARM_DIR" fetch --depth 1 origin "$ARM_REF" && git -C "$ARM_DIR" reset --hard "origin/${ARM_REF}"
fi
log "ophub 源码: $(git -C "$ARM_DIR" rev-parse --short HEAD)"

MODEL_DB="${ARM_DIR}/build-armbian/armbian-files/common-files/etc/model_database.conf"
[[ -f "$MODEL_DB" ]] || die "找不到板型库: ${MODEL_DB}"

# 友好的型号名 -> ophub 板型库第 14 列(BOARD)的取值
case "$BOARD" in
  "Phicomm-N1")             REBUILD_BOARD="s905d" ;;
  "Phicomm-N1(DMA-thresh)") REBUILD_BOARD="s905d-n1-thresh" ;;
  *)                        REBUILD_BOARD="$BOARD" ;;
esac

# ophub 匹配板型的方式: 去掉 NA/NULL/空格后, 找结尾是 ":<BOARD>:(yes|no)" 的行
clean_model_conf() {
  sed -e 's/NA//g' -e 's/NULL//g' -e 's/[ ][ ]*//g' "$MODEL_DB" | grep -E '^[^#].+'
}
match_line="$(clean_model_conf | grep -E "^.*:${REBUILD_BOARD}:(yes|no)$" | head -n 1 || true)"
if [[ -z "$match_line" ]]; then
  die "板型 [${BOARD} -> ${REBUILD_BOARD}] 不在 ophub 板型库中。Phicomm N1 常用的是:
     Phicomm-N1              (S905D, 普通版)        -> BOARD=s905d
     Phicomm-N1(DMA-thresh)  (S905D, 以太网流控关闭) -> BOARD=s905d-n1-thresh"
fi
log "板型条目:"
echo "  ${match_line}" | sed 's/^/  /'
log "rebuild -b ${REBUILD_BOARD}"

############################### 第 2 步: 下载基线镜像 ###################
step "2/6 下载基线 Armbian 镜像 (trunk/${DISTRO}/arm64)"
IMAGES_DIR="${ARM_DIR}/build/output/images"
mkdir -p "$IMAGES_DIR"

# ophub 是"每个发行版一个 release"的, releases/latest 未必是我们要的发行版,
# 所以要跨多个 release 去找(和 ophub 官方工作流的做法一致)。
base_asset="$(curl -fsSL "https://api.github.com/repos/${ARM_REPO}/releases?per_page=30" \
  | python3 -c '
import json,re,sys
d=sys.argv[1]
rel=json.load(sys.stdin)
pat=re.compile(r"trunk_"+re.escape(d)+r"_arm64_[0-9].*\.img\.gz$")
best=None
for r in rel:
    for a in r.get("assets",[]):
        if pat.search(a.get("name","")):
            if best is None or a.get("updated_at","") > best.get("updated_at",""):
                best=a
print(best["browser_download_url"] if best else "")
' "$DISTRO")"
[[ -n "$base_asset" ]] || die "没找到匹配 ${DISTRO} 的基线镜像资产"
base_file="${base_asset##*/}"
log "基线镜像: ${base_file}"

gz_path="${IMAGES_DIR}/${base_file}"
if [[ ! -f "$gz_path" ]]; then
  log "下载中(约 800MB)..."
  curl -fL --retry 3 --retry-delay 5 -o "$gz_path" "$base_asset"
fi
base_img="${IMAGES_DIR}/${base_file%.gz}"
if [[ ! -f "$base_img" ]]; then
  log "解压基线镜像 ..."
  gunzip -f "$gz_path"
fi
# 解压后立刻删掉压缩包, ARM runner 磁盘很紧张
rm -f "$gz_path"
log "基线 .img: $(du -h "$base_img" | cut -f1)"
disk_usage

# 内核版本: 优先用基线镜像文件名里的精确版本(如 6.18.56),
# 保证 rebuild 去下载的内核一定存在; 也可以用 KERNEL_TAG 指定 "6.18.y" 让它自动取最新。
KERNEL_VER=""
if [[ -n "$KERNEL_TAG" ]]; then
  KERNEL_VER="$KERNEL_TAG"
  KERNEL_AUTO="true"
  log "内核: 自动匹配最新 ${KERNEL_TAG}"
else
  KERNEL_VER="$(echo "$base_file" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | tail -1)"
  KERNEL_AUTO="false"
  log "内核: 固定 ${KERNEL_VER} (与基线镜像一致)"
fi
[[ -n "$KERNEL_VER" ]] || die "无法确定内核版本"

############################### 第 3 步: 用 ophub rebuild 重打包 ###################
step "3/6 ophub rebuild -b ${REBUILD_BOARD}"
cd "$ARM_DIR"
# -s 语法: BOOTFS/ROOTFS  (MiB);  -t ext4;  -k 内核;  -a 是否自动取最新内核
./rebuild -b "$REBUILD_BOARD" -k "$KERNEL_VER" -a "$KERNEL_AUTO" -t ext4 \
  -s "${BOOTFS_SIZE_MB}/${ROOTFS_SIZE_MB}" || die "rebuild 失败"
cd "${REPO_DIR}"

built_gz="$(ls -t "${IMAGES_DIR}"/*.img.gz 2>/dev/null | head -1)"
[[ -n "$built_gz" ]] || die "rebuild 没有产出 .img.gz"
log "rebuild 产出: $(basename "$built_gz") ($(du -h "$built_gz" | cut -f1))"

# 源镜像已经用完, 删掉腾空间
rm -f "${IMAGES_DIR}"/*-trunk_*.img
# 内核包解压后也不再需要
rm -rf "${ARM_DIR}/build-armbian/kernel"
disk_usage

OUT_IMG="${BUILD_DIR}/n1-${REBUILD_BOARD}.img"
rm -f "$OUT_IMG"
log "解压 rebuild 产物 ..."
gunzip -c "$built_gz" > "$OUT_IMG"
rm -f "$built_gz"
log "工作镜像: $(du -h "$OUT_IMG" | cut -f1)"
disk_usage

############################### 第 4 步: 追加 MUSIC 分区 ###################
step "4/6 追加 MUSIC 分区 (${MUSIC_SIZE_MB}MB)"

# 关键点: Amlogic 的 u-boot 引导码写在 MBR 的头 446 字节里,
# 用 parted/sfdisk 改分区表会把引导码冲掉, 盒子就再也起不来。
# 所以这里只手工往 MBR 里写 p3 的 16 字节分区条目, 其余字节一个都不碰。
p2_info="$(python3 - "$OUT_IMG" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
if mbr[510:512] != b'\x55\xaa':
    sys.exit("MBR 签名不正确, 不是有效的分区表")
off = 446 + 16 * 1          # p2
lba, cnt = struct.unpack_from('<II', mbr, off + 8)
ptype = mbr[off + 4]
if ptype != 0x83:
    sys.exit("p2 的类型不是 0x83(Linux), 实际是 0x%02x" % ptype)
# p3 必须是空的
off3 = 446 + 16 * 2
if mbr[off3 + 4] != 0x00:
    sys.exit("p3 已经被占用, 拒绝覆盖")
print(lba, cnt)
PY
)" || die "读取分区表失败"
P2_START="$(echo "$p2_info" | awk '{print $1}')"
P2_COUNT="$(echo "$p2_info" | awk '{print $2}')"
P3_START=$(( P2_START + P2_COUNT ))
P3_SECTORS=$(( MUSIC_SIZE_MB * 2048 ))
log "p2: start=${P2_START} count=${P2_COUNT}   p3: start=${P3_START} count=${P3_SECTORS}"

# 先备份 MBR, 改完再比对引导码有没有被动过
head -c 512 "$OUT_IMG" > "${BUILD_DIR}/mbr.before"

CUR_SECTORS=$(( $(stat -c%s "$OUT_IMG") / 512 ))
NEED_SECTORS=$(( P3_START + P3_SECTORS ))
if (( NEED_SECTORS > CUR_SECTORS )); then
  log "扩展镜像到 $(( NEED_SECTORS * 512 / 1048576 ))MB (为 p3 腾出空间)"
  truncate -s $(( NEED_SECTORS * 512 )) "$OUT_IMG"
fi

python3 - "$OUT_IMG" "$P3_START" "$P3_SECTORS" <<'PY'
import struct, sys
path, lba, count = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(path, 'r+b') as f:
    mbr = bytearray(f.read(512))
    off = 446 + 16 * 2          # p3 条目
    e = bytearray(16)
    e[0] = 0x00                              # 非活动
    e[1:4] = b'\xfe\xff\xff'                 # CHS: 用 LBA 表示
    e[4] = 0x83                              # 类型: Linux
    e[5:8] = b'\xfe\xff\xff'
    struct.pack_into('<I', e, 8, lba)        # 起始扇区
    struct.pack_into('<I', e, 12, count)     # 扇区数
    mbr[off:off + 16] = e
    f.seek(off)
    f.write(bytes(e))
print("已写入 p3 条目: lba=%d count=%d" % (lba, count))
PY

# 校验引导码(前 446 字节)没有被改动
head -c 446 "${BUILD_DIR}/mbr.before" > "${BUILD_DIR}/mbr.before.boot"
head -c 446 "$OUT_IMG"            > "${BUILD_DIR}/mbr.after.boot"
cmp -s "${BUILD_DIR}/mbr.before.boot" "${BUILD_DIR}/mbr.after.boot" \
  || die "MBR 引导码被改动了, 中止"
log "MBR 引导码校验通过(前 446 字节完全一致)"

log "当前分区表:"
sfdisk -d "$OUT_IMG" 2>/dev/null | sed 's/^/  /' || true
disk_usage

############################### 第 5 步: 装软件栈 ###################
step "5/6 挂载 rootfs / MUSIC 并安装软件栈"
LOOP=""
cleanup() {
  set +e
  for m in "${ROOTFS_MOUNT:-}" "${MUSIC_MOUNT:-}"; do
    [[ -n "$m" ]] && mountpoint -q "$m" && umount -lf "$m"
  done
  [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP"
  return 0
}
trap cleanup EXIT

# 注意: 必须带 -f, 否则 losetup 只会"查询"文件已有的关联设备, 不会新建,
# 报 "failed to use device: No such device"。
LOOP="$(losetup -P -f --show "$OUT_IMG")"
[[ -n "$LOOP" ]] || die "losetup 失败"

# 等内核把分区节点建出来(udev 可能慢一拍)
for _ in $(seq 1 30); do
  [[ -b "${LOOP}p3" ]] && break
  partprobe "$LOOP" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1
done
[[ -b "${LOOP}p2" && -b "${LOOP}p3" ]] || die "内核没有识别出 p2/p3 分区"

ROOTFS_MOUNT="${BUILD_DIR}/mnt-root"
MUSIC_MOUNT="${BUILD_DIR}/mnt-music"
mkdir -p "$ROOTFS_MOUNT" "$MUSIC_MOUNT"

# 先格式化再挂载(顺序反了会把文件系统写进挂载点)
mkfs.ext4 -q -F -L MUSIC "${LOOP}p3" || die "格式化 MUSIC 分区失败"
mount "${LOOP}p3" "$MUSIC_MOUNT"
mount "${LOOP}p2" "$ROOTFS_MOUNT"
log "已挂载 rootfs 与 MUSIC 分区"

# 调用定制脚本
PROFILE="$PROFILE" USER_NAME="$USER_NAME" USER_PASS="$USER_PASS" \
LOCALE_NAME="$LOCALE_NAME" TIMEZONE_NAME="$TIMEZONE_NAME" \
WITH_PYQT="$WITH_PYQT" WITH_PLAYWRIGHT="$WITH_PLAYWRIGHT" \
ROOTFS_MOUNT="$ROOTFS_MOUNT" REPO_DIR="$REPO_DIR" \
  bash "${SCRIPT_DIR}/n1-customize-rootfs.sh" || die "rootfs 定制失败"

# fstab: 歌曲分区用 UUID 挂载 (rootfs 那一行是 Armbian 按 UUID 写好的, 不要动)
MUSIC_UUID="$(blkid -s UUID -o value "${LOOP}p3")"
if ! grep -q '/mnt/songdisk' "${ROOTFS_MOUNT}/etc/fstab"; then
  printf 'UUID=%s /mnt/songdisk ext4 defaults,noatime,nofail,x-systemd.device-timeout=15 0 2\n' "$MUSIC_UUID" \
    >> "${ROOTFS_MOUNT}/etc/fstab"
fi
log "fstab 已写入, MUSIC UUID=${MUSIC_UUID}"

sync
umount "$ROOTFS_MOUNT"; umount "$MUSIC_MOUNT"
losetup -d "$LOOP"; LOOP=""
trap - EXIT
disk_usage
############################### 第 6 步: 输出 ###################
step "6/6 压缩输出"
OUT_NAME="Armbian_${REBUILD_BOARD}_${DISTRO}_$(echo "$KERNEL_VER" | tr '.' '_')_n1-music_$(date +%Y%m%d)"
FINAL_IMG="${OUT_DIR}/${OUT_NAME}.img"
cp --sparse=always -f "$OUT_IMG" "$FINAL_IMG"
rm -f "$OUT_IMG"

cd "$OUT_DIR"
log "压缩中(镜像约 $(( $(stat -c%s "$FINAL_IMG") / 1048576 ))MB)..."
if command -v pigz >/dev/null 2>&1; then
  pigz -f -k -p 4 "$FINAL_IMG"
else
  gzip -f -k "$FINAL_IMG"
fi
rm -f "$FINAL_IMG"
sha256sum ./*.img.gz > SHA256SUMS-N1.txt 2>/dev/null || true
chmod 0666 SHA256SUMS-N1.txt 2>/dev/null || true
chmod 0644 ./*.img.gz 2>/dev/null || true
chmod 0777 "$OUT_DIR" 2>/dev/null || true

{
  echo "board        = ${REBUILD_BOARD}  (${BOARD})"
  echo "distro       = ${DISTRO}"
  echo "kernel       = ${KERNEL_VER}"
  echo "profile      = ${PROFILE}"
  echo "bootfs_mb    = ${BOOTFS_SIZE_MB}"
  echo "rootfs_mb    = ${ROOTFS_SIZE_MB}"
  echo "music_mb     = ${MUSIC_SIZE_MB}"
  echo "user         = ${USER_NAME} / ${USER_PASS}"
  echo "built_at     = $(date -Is)"
  echo "source       = ${ARM_REPO}@${ARM_REF} + ophub release 基线镜像"
} > "${OUT_DIR}/BUILD-INFO-N1.txt"
chmod 0666 "${OUT_DIR}/BUILD-INFO-N1.txt" 2>/dev/null || true

ls -lh "$OUT_DIR"
log "完成 ✅"
