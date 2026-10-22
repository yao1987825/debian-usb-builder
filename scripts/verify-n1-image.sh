#!/usr/bin/env bash
#
# verify-n1-image.sh —— 校验 N1 镜像的结构是否正确
#
#   bash scripts/verify-n1-image.sh out/Armbian_Phicomm-N1_*.img.gz
#
# 检查项:
#   1. MBR 分区表: p1 BOOT(fat32) / p2 ROOTFS(ext4) / p3 MUSIC(ext4)
#   2. MBR 引导码(前 446 字节)存在 —— 这是 Amlogic u-boot 的启动入口
#   3. BOOT 分区里有内核、dtb、u-boot overload
#   4. ROOTFS 里有 fcitx5/rime 配置、music 脚本、两个下载器项目、fstab 的 MUSIC 行
#   5. MUSIC 分区标签正确
#
set -Eeuo pipefail

IMG="${1:?用法: verify-n1-image.sh <镜像路径>}"
[[ -f "$IMG" ]] || { echo "文件不存在: ${IMG}" >&2; exit 1; }
[[ "$(id -u)" == "0" ]] || { echo "请用 root 运行: sudo bash scripts/verify-n1-image.sh ${IMG}" >&2; exit 1; }

WORK="$(mktemp -d)"
LOOP=""
cleanup() {
  set +e
  [[ -n "$MOUNT_ROOT" ]] && mountpoint -q "$MOUNT_ROOT" && umount -lf "$MOUNT_ROOT"
  [[ -n "$MOUNT_BOOT" ]] && mountpoint -q "$MOUNT_BOOT" && umount -lf "$MOUNT_BOOT"
  [[ -n "$MOUNT_MUSIC" ]] && mountpoint -q "$MOUNT_MUSIC" && umount -lf "$MOUNT_MUSIC"
  [[ -n "$LOOP" ]] && losetup -d "$LOOP"
  rm -rf "$WORK"
}
MOUNT_ROOT=""; MOUNT_BOOT=""; MOUNT_MUSIC=""
trap cleanup EXIT

FAIL=0
ok()   { printf '  \033[1;32m✅\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m❌\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
info() { printf '  \033[1;34mℹ️ \033[0m %s\n' "$*"; }

case "$IMG" in
  *.gz|*.xz) gzip -dc "$IMG" 2>/dev/null > "${WORK}/img" || xz -dc "$IMG" > "${WORK}/img" ;;
  *) cp -f "$IMG" "${WORK}/img" ;;
esac
RAW="${WORK}/img"
echo "== 镜像: ${IMG}"
echo "== 大小: $(( $(stat -c%s "$RAW") / 1048576 ))MB"

####################### 1. MBR 分区表 #######################
echo
echo "== 1. MBR 分区表"
python3 - "$RAW" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
if mbr[510:512] != b'\x55\xaa':
    print("  ❌ MBR 签名不正确")
    sys.exit(1)
print("  ℹ️  MBR 签名正确")
for i in range(4):
    off = 446 + 16 * i
    if mbr[off+4] == 0:
        continue
    lba, cnt = struct.unpack_from('<II', mbr, off + 8)
    print("  ℹ️  p%d  type=0x%02x  lba=%d  sectors=%d  (%.1f MiB)"
          % (i+1, mbr[off+4], lba, cnt, cnt*512/1048576))
PY

####################### 2. MBR 引导码 #######################
echo
echo "== 2. MBR 引导码(Amlogic u-boot)"
python3 - "$RAW" <<'PY'
import sys
with open(sys.argv[1], 'rb') as f:
    boot = f.read(446)
if boot[:64] == b'\x00' * 64:
    print("  ❌ 前 64 字节全为 0, u-boot 引导码丢失")
    sys.exit(1)
print("  ✅ 前 446 字节存在 u-boot 引导码 (前 4 字节: %s)"
      % ' '.join('%02x' % b for b in boot[:4]))
PY

####################### 3~5. 挂载检查 #######################
# 注意: 必须带 -f, 否则 losetup 只会查询已有关联, 不会新建 loop 设备
LOOP="$(losetup -P -f --show "$RAW")"
[[ -n "$LOOP" ]] || { echo "losetup 失败" >&2; exit 1; }
for _ in $(seq 1 30); do
  [[ -b "${LOOP}p3" ]] && break
  partprobe "$LOOP" 2>/dev/null || true
  udevadm settle 2>/dev/null || true
  sleep 1
done

MOUNT_BOOT="${WORK}/boot"; MOUNT_ROOT="${WORK}/root"; MOUNT_MUSIC="${WORK}/music"
mkdir -p "$MOUNT_BOOT" "$MOUNT_ROOT" "$MOUNT_MUSIC"

echo
echo "== 3. BOOT 分区(p1)"
if mount "${LOOP}p1" "$MOUNT_BOOT" 2>/dev/null; then
  if ls "${MOUNT_BOOT}"/uEnv.txt "${MOUNT_BOOT}"/armbianEnv.txt >/dev/null 2>&1; then
    ok "存在 uEnv.txt / armbianEnv.txt 启动配置"
  else
    bad "找不到 uEnv.txt / armbianEnv.txt"
  fi
  if ls "${MOUNT_BOOT}"/u-boot*.bin >/dev/null 2>&1; then
    ok "存在 u-boot overload: $(ls "${MOUNT_BOOT}"/u-boot*.bin | head -3 | xargs -n1 basename | tr '\n' ' ')"
  else
    bad "找不到 u-boot overload 文件"
  fi
  if ls "${MOUNT_BOOT}"/u-boot-*.dtb >/dev/null 2>&1; then
    ok "存在 dtb 文件 ($(ls "${MOUNT_BOOT}"/u-boot-*.dtb | wc -l) 个)"
  else
    bad "找不到 dtb 文件"
  fi
  if ls "${MOUNT_BOOT}"/Image* "${MOUNT_BOOT}"/initrd* >/dev/null 2>&1; then
    ok "存在内核镜像: $(ls "${MOUNT_BOOT}"/Image* "${MOUNT_BOOT}"/initrd* 2>/dev/null | head -2 | xargs -n1 basename | tr '\n' ' ')"
  else
    bad "找不到内核镜像"
  fi
  if grep -qs 'phicomm-n1' "${MOUNT_BOOT}/uEnv.txt" "${MOUNT_BOOT}/armbianEnv.txt" 2>/dev/null \
     || ls "${MOUNT_BOOT}"/*phicomm-n1* >/dev/null 2>&1; then
    ok "启动配置里指向 Phicomm N1"
  else
    info "未在启动配置里直接看到 phicomm-n1 字样(dtb 可能由 u-boot 按板型自动加载)"
  fi
  umount "$MOUNT_BOOT"; MOUNT_BOOT=""
else
  bad "挂载 p1 失败"
fi

echo
echo "== 4. ROOTFS 分区(p2)"
if mount "${LOOP}p2" "$MOUNT_ROOT" 2>/dev/null; then
  for f in /usr/local/bin/music /usr/local/lib/musictools/single.py \
           /home/user/projects/gequhai-downloader/gequhai.py \
           /home/user/projects/gequhai-playlist-downloader/gequhai_downloader.py; do
    if [[ -e "${MOUNT_ROOT}${f}" ]]; then ok "存在 ${f}"; else bad "缺少 ${f}"; fi
  done
  if [[ -x "${MOUNT_ROOT}/home/user/.venvs/music/bin/python" ]]; then
    ok "单曲下载 venv 可用"
  else
    bad "单曲下载 venv 缺失"
  fi
  if [[ -f "${MOUNT_ROOT}/home/user/.config/fcitx5/profile" ]]; then
    ok "fcitx5 配置存在"
  else
    bad "fcitx5 配置缺失"
  fi
  if [[ -f "${MOUNT_ROOT}/home/user/.config/fcitx5/rime/user.dict.yaml" ]]; then
    ok "Rime 自定义词库存在 ($(grep -cE '^[[:space:]]*-' "${MOUNT_ROOT}/home/user/.config/fcitx5/rime/user.dict.yaml" 2>/dev/null || echo '?') 条)"
  else
    bad "Rime 自定义词库缺失"
  fi
  if grep -q 'GTK_IM_MODULE=fcitx' "${MOUNT_ROOT}/etc/environment" 2>/dev/null; then
    ok "环境变量已配置中文输入法"
  else
    bad "环境变量里没有 fcitx 配置"
  fi
  if grep -q '/mnt/songdisk' "${MOUNT_ROOT}/etc/fstab"; then
    ok "fstab 里有歌曲分区挂载项"
    grep '/mnt/songdisk' "${MOUNT_ROOT}/etc/fstab" | sed 's/^/       /'
  else
    bad "fstab 里没有 /mnt/songdisk"
  fi
  if grep -qE '^UUID=\S+ +/ +ext4' "${MOUNT_ROOT}/etc/fstab"; then
    ok "根分区仍按 UUID 挂载(Armbian 原样保留)"
  else
    bad "根分区的 fstab 行被改动了"
  fi
  if [[ -x "${MOUNT_ROOT}/usr/local/bin/n1-grow.sh" ]]; then
    ok "n1-grow.sh 扩容脚本存在"
  else
    bad "n1-grow.sh 缺失"
  fi
  umount "$MOUNT_ROOT"; MOUNT_ROOT=""
else
  bad "挂载 p2 失败"
fi

echo
echo "== 5. MUSIC 分区(p3)"
MUSIC_LABEL="$(blkid -s LABEL -o value "${LOOP}p3" 2>/dev/null || true)"
MUSIC_UUID="$(blkid -s UUID -o value "${LOOP}p3" 2>/dev/null || true)"
if [[ "$MUSIC_LABEL" == "MUSIC" ]]; then
  ok "分区标签 MUSIC (UUID=${MUSIC_UUID})"
else
  bad "分区标签不是 MUSIC (实际: ${MUSIC_LABEL:-空})"
fi
if mount "${LOOP}p3" "$MOUNT_MUSIC" 2>/dev/null; then
  ok "可以挂载"
  umount "$MOUNT_MUSIC"; MOUNT_MUSIC=""
else
  bad "挂载 p3 失败"
fi

echo
if (( FAIL == 0 )); then
  echo "✅ 结构校验全部通过"
  exit 0
else
  echo "❌ 有 ${FAIL} 项校验失败"
  exit 1
fi
