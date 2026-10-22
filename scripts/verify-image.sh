#!/usr/bin/env bash
#
# verify-image.sh —— 校验构建出来的 U 盘镜像
#
#   verify-image.sh --struct <img>   结构校验(分区表 / EFI 文件 / 内核 / fstab)  必须通过
#   verify-image.sh --boot   <img>   QEMU UEFI 启动冒烟测试(尽力而为, 不通过也不算失败)
#
set -Eeuo pipefail

MODE="${1:-}"
IMG="${2:-}"
[[ -n "$MODE" && -n "$IMG" ]] || { echo "用法: $0 --struct|--boot <image>" >&2; exit 2; }
[[ -f "$IMG" ]] || { echo "找不到镜像文件: $IMG" >&2; exit 2; }

log()  { printf '\033[1;34m[verify]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fatal]\033[0m %s\n' "$*" >&2; exit 1; }

SUDO=""
[[ "$(id -u)" == "0" ]] || SUDO="sudo"

############################### 结构校验 ###################################
struct_check() {
  log "=== 结构校验: $IMG ==="

  # 1) 分区表
  sgdisk -v "$IMG" > /tmp/sgdisk-verify.txt 2>&1 || true
  if grep -qi "no problems found" /tmp/sgdisk-verify.txt; then
    ok "GPT 分区表无损坏"
  else
    cat /tmp/sgdisk-verify.txt
    die "GPT 分区表校验失败"
  fi

  local n_parts
  # 注意: sgdisk -p 作用于"文件"时, Device 列显示的是文件名而不是空格开头,
  # 所以不能靠行首空格数分区, 要靠"4 个数字 + 容量单位"这个特征。
  n_parts="$(sgdisk -p "$IMG" | grep -cE '[0-9]+ +[0-9]+ +[0-9]+ +[0-9.]+ [KMG]iB' || true)"
  if [[ "$n_parts" -eq 4 ]]; then
    ok "分区数量 = 4 (BIOS-BOOT / EFI / root / MUSIC)"
  else
    sgdisk -p "$IMG" | sed 's/^/[verify]   /'
    die "分区数量异常: ${n_parts} (期望 4)"
  fi

  sgdisk -p "$IMG" | sed 's/^/[verify]   /'

  # 2) 挂载检查(需要 loop 设备)
  if ! command -v losetup >/dev/null 2>&1; then
    warn "缺少 losetup, 跳过内容校验"
    return 0
  fi

  local loop=""
  # 必须带 -f: 不带 -f 时 losetup 只会"查询"文件已有的关联设备, 不会新建,
  # 结果永远是 "failed to use device: No such device", 内容校验会被静默跳过。
  loop="$($SUDO losetup -P -f --show "$IMG" 2>/dev/null || true)"
  if [[ -z "$loop" ]]; then
    warn "无法创建 loop 设备(容器里可能没权限), 跳过内容校验"
    return 0
  fi
  # shellcheck disable=SC2064
  trap "$SUDO losetup -d '$loop' 2>/dev/null || true" RETURN
  # 等内核把分区节点建出来
  local _i
  for _i in $(seq 1 20); do
    [[ -b "${loop}p4" ]] && break
    $SUDO partprobe "$loop" 2>/dev/null || true
    sleep 1
  done

  local p2="${loop}p2" p3="${loop}p3" p4="${loop}p4"
  [[ -b "$p2" ]] || die "EFI 分区设备不存在: $p2"

  # 3) EFI 分区内容
  local esp_mount; esp_mount="$(mktemp -d)"
  if $SUDO mount -o ro "$p2" "$esp_mount" 2>/dev/null; then
    local f
    for f in EFI/BOOT/BOOTX64.EFI EFI/BOOT/grubx64.efi EFI/BOOT/grub.cfg; do
      if [[ -f "${esp_mount}/${f}" ]]; then ok "EFI: ${f}"; else die "EFI 缺少 ${f}"; fi
    done
    if grep -q "configfile" "${esp_mount}/EFI/BOOT/grub.cfg" 2>/dev/null; then
      ok "EFI 引导链配置正确"
    else
      die "EFI/BOOT/grub.cfg 内容异常"
    fi
    $SUDO umount "$esp_mount" 2>/dev/null || true
  else
    warn "无法挂载 EFI 分区, 跳过 EFI 内容校验"
  fi
  rmdir "$esp_mount" 2>/dev/null || true

  # 4) 根分区内容(只读, 用 debugfs 不用挂载)
  #    debugfs / dumpe2fs 要读块设备, 权限是 root 专属, 所以必须走 $SUDO
  if command -v debugfs >/dev/null 2>&1; then
    local boot_list kver
    boot_list="$($SUDO debugfs -R "ls /boot" "$p3" 2>/dev/null | tr -s ' ' '\n' | grep -E '^vmlinuz-' | head -1 || true)"
    if [[ -n "$boot_list" ]]; then
      kver="${boot_list#vmlinuz-}"
      ok "根分区内核: ${kver}"
    else
      die "根分区 /boot 下没有找到内核"
    fi
    if $SUDO debugfs -R "ls /boot" "$p3" 2>/dev/null | grep -q "initrd.img-${kver}"; then
      ok "根分区 initrd 存在"
    else
      die "根分区缺少 initrd.img-${kver}"
    fi
    local fstab; fstab="$($SUDO debugfs -R "cat /etc/fstab" "$p3" 2>/dev/null || true)"
    if grep -q "songdisk" <<<"$fstab"; then
      ok "/etc/fstab 已挂载歌曲分区"
    else
      die "/etc/fstab 缺少 /mnt/songdisk"
    fi
    if grep -q "/boot/efi" <<<"$fstab"; then
      ok "/etc/fstab 已挂载 EFI 分区"
    else
      die "/etc/fstab 缺少 /boot/efi"
    fi

    # 把镜像里安装的那份 music 抠出来, 跑一遍命令行回归测试
    # (防止 "关键词被 shift 吃掉" 这类静默 bug 混进产物)
    local tmp_music; tmp_music="$(mktemp -d)/music"
    if $SUDO debugfs -R "dump /usr/local/bin/music ${tmp_music}" "$p3" 2>/dev/null && [[ -s "$tmp_music" ]]; then
      chmod +x "$tmp_music"
      if MUSIC_BIN="$tmp_music" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-music-cli.sh" >/dev/null 2>&1; then
        ok "镜像里的 music 命令行回归测试通过(参数没有丢失)"
      else
        die "镜像里的 music 命令行回归测试失败"
      fi
    else
      warn "没能从根分区取出 /usr/local/bin/music, 跳过回归测试"
    fi

    # 网络: 没有 NetworkManager 就是一台没有网络的机器, 必须卡住
    local _f
    for _f in /usr/local/bin/net-doctor /usr/local/bin/usb-grow.sh /usr/bin/nmcli; do
      if $SUDO debugfs -R "stat ${_f}" "$p3" 2>/dev/null | grep -q "Inode:"; then
        ok "根分区存在 ${_f}"
      else
        die "根分区缺少 ${_f} —— 没有它开机就没有网络 / 无法扩容"
      fi
    done
    if $SUDO debugfs -R "ls /etc/systemd/system/multi-user.target.wants" "$p3" 2>/dev/null | grep -q "NetworkManager.service"; then
      ok "NetworkManager 已设为开机自启"
    else
      die "NetworkManager 没有开机自启 —— 开机后没人给网卡分配 IP, 必然连不上网"
    fi
    if $SUDO debugfs -R "ls /etc/systemd/system/sysinit.target.wants" "$p3" 2>/dev/null | grep -q "systemd-resolved.service"; then
      ok "systemd-resolved 已设为开机自启(DNS 解析)"
    else
      warn "systemd-resolved 没开机自启, DNS 可能解析不了"
    fi
  else
    warn "缺少 debugfs, 跳过根分区内容校验"
  fi

  # 5) 歌曲分区
  if [[ -b "$p4" ]]; then
    if $SUDO dumpe2fs -h "$p4" 2>/dev/null | grep -q "Filesystem volume name:.*MUSIC"; then
      ok "歌曲分区标签 MUSIC 正确"
    else
      warn "歌曲分区标签不是 MUSIC"
    fi
  fi

  ok "结构校验全部通过"
}

############################### QEMU 冒烟测试 ###############################
boot_check() {
  log "=== QEMU UEFI 启动冒烟测试 ==="
  if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
    warn "没有 qemu-system-x86_64, 跳过"
    return 0
  fi
  local code vars
  code="$(ls /usr/share/OVMF/OVMF_CODE*.fd 2>/dev/null | head -1 || true)"
  vars="$(ls /usr/share/OVMF/OVMF_VARS*.fd 2>/dev/null | head -1 || true)"
  if [[ -z "$code" ]]; then
    warn "没找到 OVMF 固件, 跳过"
    return 0
  fi

  local workdir; workdir="$(mktemp -d)"
  cp "$vars" "${workdir}/OVMF_VARS.fd" 2>/dev/null || : > "${workdir}/OVMF_VARS.fd"
  local serial="${workdir}/serial.log"
  : > "$serial"

  log "启动虚拟机(最多 240 秒, 没有 KVM 会比较慢) ..."
  timeout 240 qemu-system-x86_64 \
    -machine q35 -m 2048 -smp 2 -nographic \
    -drive if=pflash,format=raw,readonly=on,file="$code" \
    -drive if=pflash,format=raw,file="${workdir}/OVMF_VARS.fd" \
    -drive file="$IMG",format=raw,if=virtio \
    -serial file:"$serial" \
    -display none -no-reboot >/dev/null 2>&1 || true

  if grep -q "GNU GRUB" "$serial" 2>/dev/null; then
    ok "GRUB 菜单已通过串口输出 —— 镜像可被 UEFI 引导"
    if grep -q "Debian GNU/Linux" "$serial" 2>/dev/null; then
      ok "GRUB 菜单包含 Debian 启动项"
    fi
    log "串口日志片段:"
    head -30 "$serial" | sed 's/^/[verify]   /'
  else
    warn "串口没有捕获到 GRUB 输出(不代表镜像不可引导: OVMF 可能未走可移动介质路径, 或未使用串口输出)"
    log "串口日志片段:"
    head -20 "$serial" | sed 's/^/[verify]   /'
  fi
  rm -rf "$workdir"
  return 0
}

case "$MODE" in
  --struct) struct_check ;;
  --boot)   boot_check ;;
  *) echo "未知模式: $MODE" >&2; exit 2 ;;
esac
