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
#   usb-grow.sh --self-test    # 分区识别逻辑自测(不需要 root)
#
# 说明: 非 root 直接跑会自动用 sudo 重新执行自己, 不用自己加 sudo。
#
set -Eeuo pipefail
umask 022

ROOT_PERCENT=30
MODE=grow
DRY_RUN=0
# 日志文件在启动时再定(见 init_log): 非 root 时 /var/log 写不进去,
# 直接往那儿 append 会让 bash 每打印一行就报一次"权限不够", 刷屏。
LOG_FILE=""
# 原样保存参数, 自动提权时要原样传给 sudo 重新执行的自己
ORIG_ARGS=("$@")

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; BLU=$'\033[1;34m'; RST=$'\033[0m'

usage() {
  cat <<'EOF'
用法: usb-grow.sh [选项]

  (无参数)              把剩余空间分给 root(30%) 和 MUSIC(70%)
  --root-percent N      root 拿 N%, MUSIC 拿剩下的(默认 30)
  --check               只做诊断, 打印当前情况, 不做任何修改(不需要 root)
  --dry-run             打印将执行的改动, 但不真正修改
  --self-test           分区识别逻辑自测(不需要 root, 不碰任何磁盘)
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
    --self-test)    MODE=selftest; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$ROOT_PERCENT" =~ ^[0-9]+$ ]] || { echo "错误: --root-percent 必须是 0~100 的整数" >&2; exit 2; }

# ---------------- 输出 ----------------
# 同时写终端和日志文件, 避免"终端里什么都看不到"的情况
#
# 探测命令一律走 try(): 拿不到值就返回空, 绝不让非零退出码顺着 set -e /
# pipefail 爬到命令替换里把整个脚本干掉。真正的判断留给调用方。
try() { "$@" 2>/dev/null || true; }

# udev 已经把识别好的分区信息写在 /run/udev/data/<主>:<次> 里了, 而且是全局可读的。
# 分区名/标签/文件系统类型从这里拿, 普通用户也能拿到 —— 不依赖任何外部命令。
udev_prop() {   # udev_prop <主:次> <ID_FS_LABEL 之类的键>
  local f="/run/udev/data/${1}" k="E: ${2}="
  [[ -r "$f" ]] || return 0
  awk -v k="$k" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$f" 2>/dev/null || true
}

# 解析 `sgdisk -p` 的输出(从 stdin 读), 归一化成一行一个:
#     分区号 起始扇区 结束扇区 分区名
# sgdisk -p 的分区行长这样, 第一列是纯数字的才是分区行(表头、磁盘信息、
# 可用扇区那几行第一列都是英文, 天然被排除); 没有分区名的写个 - 占位。
#    Number  Start (sector)    End (sector)  Size       Code  Name
#         1            2048            4095   1024.0 KiB  EF02  BIOS-BOOT
#         3         1052672        13635583   6.0 GiB     8300  DEBIAN_ROOT
sgdisk_rows() {
  awk 'NF>=6 && $1 ~ /^[0-9]+$/ {print $1, $2, $3, (NF>=7 ? $7 : "-")}'
}

to_gib() { awk -v s="${1:-0}" 'BEGIN{printf "%.2f", s*512/1073741824}'; }

# ---------------- 在 PART_TABLE 上做查询 ----------------
# PART_TABLE 每行: 分区号 主:次 设备节点 GPT名字 FS标签 文件系统类型 起始扇区 结束扇区
# 这几个函数一律"认不出就返回空字符串", 绝不返回非零 —— 命令替换在
# set -e + pipefail 下被非零退出码带走, 是这个脚本以前最大的坑。
part_num_by_label() {   # GPT 分区名 或 文件系统标签 -> 分区号
  awk -v l="$1" '$4==l || $5==l {print $1}' <<<"$PART_TABLE"
}
part_num_by_fstype() {  # 文件系统类型(ext4/vfat/...) -> 分区号
  awk -v l="$1" '$6==l {print $1}' <<<"$PART_TABLE"
}
part_num_by_mount() {   # 挂载点 -> 分区号
  local src
  src="$(try findmnt -no SOURCE "$1")"; src="${src%%$'\n'*}"
  [[ -n "$src" ]] || return 0
  src="$(try readlink -f "$src")"
  [[ -n "$src" ]] || return 0
  awk -v d="$src" '$3==d {print $1}' <<<"$PART_TABLE"
}
part_field() {          # 分区号 -> 那一列(3=设备 7=起始扇区 8=结束扇区)
  awk -v n="$1" -v i="$2" '$1==n {print $i}' <<<"$PART_TABLE"
}
part_last_num() {       # 最后一个分区号(兜底用)
  awk 'NF {a=$1} END {print a}' <<<"$PART_TABLE"
}

# ---------------- 分区识别自测 ----------------
# 为什么专门写这个: "认分区"这一段全是 awk 字符串处理, 错了在真机上的表现
# 要么是扩容脚本自己没了, 要么是认错分区把分区表改了 —— 后者不可逆。
# 好在这一段不需要碰磁盘, 拿一份真实的 sgdisk -p 输出就能在构建期验完。
SELFTEST_FAILED=0
st_case() {   # st_case <说明> <期望> <实际>
  if [[ "$2" == "$3" ]]; then
    printf '  ✅ %s\n' "$1"
  else
    printf '  ❌ %s\n       期望: [%s]\n       实际: [%s]\n' "$1" "$2" "$3"
    SELFTEST_FAILED=$((SELFTEST_FAILED + 1))
  fi
  return 0
}
st_rows() { printf '%s\n' "$1" | sgdisk_rows | wc -l | tr -d '[:space:]'; }

self_test() {
  local sg free

  # 这段是从真机上原样抄下来的 sgdisk -p 输出: 8GiB 镜像写进 64G U 盘时的样子
  sg='Disk /dev/sdb: 122880000 sectors, 58.6 GiB
Model: HighSpeed USB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 3C966FB7-CDAE-4B3E-BD54-6FE5CB3C3DFA
Partition table holds up to 128 entries
Main partition table begins at sector 2 and ends at sector 33
First usable sector is 34, last usable sector is 16777182
Partitions will be aligned on 2048-sector boundaries
Total free space is 2014 sectors (1007.0 KiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048            4095   1024.0 KiB  EF02  BIOS-BOOT
   2            4096         1052671   512.0 MiB  EF00  EFI
   3         1052672        13635583   6.0 GiB     8300  DEBIAN_ROOT
   4        13635584        16777182   1.5 GiB     8300  MUSIC'

  st_case "只挑出 4 个分区行(表头/磁盘信息那几行不能被当成分区)" "4" "$(st_rows "$sg")"
  st_case "root 分区行解析正确" "3 1052672 13635583 DEBIAN_ROOT" \
          "$(printf '%s\n' "$sg" | sgdisk_rows | awk '$1==3')"
  st_case "EFI 分区行解析正确" "2 4096 1052671 EFI" \
          "$(printf '%s\n' "$sg" | sgdisk_rows | awk '$1==2')"
  st_case "空输入不产生任何分区行" "0" "$(st_rows '')"
  st_case "sgdisk 自己的报错信息不会被当成分区" "0" "$(st_rows 'sgdisk: bad header')"
  st_case "没有分区名的行也能解析(名字位置写 -)" "-" \
          "$(printf '   9         34          2047   1007.0 KiB  8300\n' | sgdisk_rows | awk '$1==9{print $4}')"

  # 用同一份数据拼一张 PART_TABLE(分区号 主:次 设备 名字 标签 类型 起始 结束),
  # 文件系统类型照实际情况填: BIOS-BOOT 是 FAT16, EFI 是 vfat, 后两个才是 ext4
  PART_TABLE="$(printf '%s\n' "$sg" | sgdisk_rows |
    awk '{t = ($1==2 ? "vfat" : ($1==1 ? "fat16" : "ext4"));
          printf "%s 8:%d /dev/sdb%s %s - %s %s %s\n", $1, $1, $1, $4, t, $2, $3}')"

  st_case "按 GPT 分区名认出 root"       "3"       "$(part_num_by_label DEBIAN_ROOT)"
  st_case "按 GPT 分区名认出 MUSIC"      "4"       "$(part_num_by_label MUSIC)"
  st_case "认出 root 的设备节点"        "/dev/sdb3" "$(part_field 3 3)"
  st_case "认出 MUSIC 的设备节点"       "/dev/sdb4" "$(part_field 4 3)"
  st_case "认出 root 的起始扇区"         "1052672"  "$(part_field 3 7)"
  st_case "认出 MUSIC 的结束扇区"        "16777182" "$(part_field 4 8)"
  st_case "按文件系统类型认出 ext4 分区"  "3 4"     "$(part_num_by_fstype ext4 | tr '\n' ' ' | sed 's/ $//')"
  st_case "认不出的名字返回空(而不是非零退出码)" "" "$(part_num_by_label NOSUCHPART)"
  st_case "兜底取最后一个分区"           "4"       "$(part_last_num)"
  st_case "空分区表时兜底也返回空"        ""        "$(PART_TABLE=; part_last_num)"

  # 未分配空间 = 总扇区 - 最后一个分区的结束扇区 - 1
  free=$(( 122880000 - 16777182 - 1 ))
  st_case "未分配空间算得对(122880000 - 16777182 - 1 扇区 ≈ 50.59 GiB)" "50.59" "$(to_gib "$free")"

  echo
  if (( SELFTEST_FAILED == 0 )); then
    echo "✅ 分区识别自测全部通过"
    return 0
  fi
  echo "❌ 分区识别自测失败 ${SELFTEST_FAILED} 项 —— usb-grow.sh 在真机上会认错分区"
  return 1
}

# 踩过的坑: 原来是 `printf ... >> "$LOG_FILE" 2>/dev/null || true`。
# bash 的重定向是按书写顺序生效的, `>>file` 先做 —— 打开失败时那句
# "权限不够" 是在 stderr 还指着终端的时候打出来的, 2>/dev/null 根本来不及兜底。
# 于是普通用户跑一次 usb-grow.sh, 屏幕上就是十几行 /var/log/usb-grow.log: 权限不够。
# 现在先 init_log 挑一个真能写的路径, 写日志时也把 2>/dev/null 放到前面。
init_log() {
  local f d sz
  for f in /var/log/usb-grow.log "${HOME:-/root}/.local/state/usb-grow.log" "/tmp/usb-grow.$(id -u).log"; do
    d="$(dirname "$f")"
    { mkdir -p "$d"; } 2>/dev/null || continue
    { : ; } 2>/dev/null >>"$f" || continue
    # U 盘上日志无上限地长会慢慢吃掉根分区, 超过 512KB 就重新开始
    sz="$(try wc -c <"$f")"; sz="${sz:-0}"
    if [[ "$sz" =~ ^[0-9]+$ ]] && (( sz > 524288 )); then
      { : >"$f"; } 2>/dev/null || true
    fi
    LOG_FILE="$f"
    return 0
  done
  LOG_FILE=""
  return 0
}
init_log

log_line() {
  [[ -n "$LOG_FILE" ]] || return 0
  { printf '%s\n' "[grow] $*"; } 2>/dev/null >>"$LOG_FILE" || true
  return 0
}

say()  { printf '%s[grow]%s %s\n' "$BLU" "$RST" "$*"; log_line "$*"; }
step(){ printf '\n%s==> %s%s\n' "$BLU" "$*" "$RST"; log_line ""; log_line "==> $*"; }
ok()  { printf '  %s✅%s %s\n' "$GRN" "$RST" "$*"; log_line "  ✅ $*"; }
warn(){ printf '  %s⚠️ %s%s\n' "$YEL" "$*" "$RST"; log_line "  ⚠️  $*"; }
die() { printf '\n%s❌ 失败: %s%s\n' "$RED" "$*" "$RST" >&2; log_line "❌ 失败: $*"; exit 1; }

# 日志路径可能是空的(哪都写不了), 这时候就别再提"完整日志在哪儿"
log_hint() { [[ -n "$LOG_FILE" ]] && say "完整日志: $LOG_FILE"; return 0; }

# ---------------- 绝不静默退出 ----------------
# 之前这个脚本最大的毛病: set -e + pipefail 下, 任何一个外部命令(lsblk/sgdisk/
# partprobe)返回非零, 脚本就直接消失, 屏幕上什么都看不到, 看起来就是"跑起来
# 没有任何反馈"。现在任何一步失败都会明确报出「哪一行、哪条命令、退出码」。
on_err() {
  local rc="$1" line="$2" cmd="$3"
  trap - ERR
  printf '\n%s❌ 第 %s 行失败(退出码 %s)%s\n' "$RED" "$line" "$rc" "$RST" >&2
  printf '   失败的命令: %s\n' "$cmd" >&2
  if [[ -n "$LOG_FILE" && -s "$LOG_FILE" ]]; then
    printf '\n下面是最后 15 行日志(完整日志在 %s):\n' "$LOG_FILE" >&2
    tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/   | /' >&2
  fi
  printf '\n排查建议:\n' >&2
  printf '   1) 报错涉及 sgdisk/partprobe: 分区表可能正在被占用, 插到别的电脑重启一次再跑\n' >&2
  printf '   2) 报错涉及 umount: 关掉正在访问 /mnt/songdisk 的程序(播放器/文件管理器)再重试\n' >&2
  printf '   3) 先跑 %s --check 看完整诊断(不需要 root)\n' "$(basename "$0")" >&2
  printf '   4) 上一条命令的真实输出: sudo %s --check 2>&1 | tee /tmp/grow.txt\n' "$(basename "$0")" >&2
  exit "$rc"
}
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# 自测不需要 root, 也不碰磁盘, 所以放在自动提权之前。
# 用 if 而不是 `self_test; exit $?`: set -e 会在 self_test 返回非零时
# 先触发 ERR 陷阱, 把一段自测失败变成一场"脚本崩了"的假象。
if [[ "$MODE" == "selftest" ]]; then
  if self_test; then exit 0; else exit 1; fi
fi

# ---------------- 自动提权 ----------------
# 说清楚"为什么"要 root: 改分区表要往整块磁盘的 GPT 里写, 内核只允许 root 做。
# 这是 Linux 的硬限制, 没有任何脚本能绕开。
if [[ "$(id -u)" != "0" ]]; then
  if [[ "$MODE" == "check" ]]; then
    warn "当前不是 root, 诊断结果可能不完整(部分挂载点/标签需要权限才能读)"
  elif command -v sudo >/dev/null 2>&1; then
    say "扩容要重写磁盘的分区表(GPT), 只有 root 有权限 —— 这不是脚本的规矩, 是内核的"
    say "正在通过 sudo 重新执行(本机的 sudo 免密, 不会问你密码)..."
    # 原样把参数传过去。注意不能写成 ${DRY_RUN:+...} —— DRY_RUN="0" 也是非空,
    # 那样会导致不加 sudo 直接跑也变成 dry-run。
    exec sudo -E bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}
  else
    die "需要 root 权限, 但系统里没有 sudo。请用 root 用户执行: usb-grow.sh"
  fi
fi

# ---------------- 环境诊断 ----------------
step "环境诊断"
say "脚本        : $(readlink -f "$0")"
say "执行用户    : $(id -un) (uid=$(id -u))"
say "内核/架构   : $(uname -sr) / $(uname -m)"

for c in sgdisk findmnt resize2fs partprobe partx awk; do
  command -v "$c" >/dev/null 2>&1 || die "缺少命令 [$c]。安装: sudo apt-get install -y gdisk e2fsprogs util-linux"
done
ok "依赖命令齐全 (sgdisk / resize2fs / partprobe / partx)"

ROOT_SRC="$(try findmnt -no SOURCE /)"
[[ -n "$ROOT_SRC" ]] || die "找不到根分区的挂载来源(findmnt -no SOURCE / 返回空)"
ROOT_SRC="$(try readlink -f "$ROOT_SRC")"

# 从 /dev/sdb3 反推物理磁盘 sdb: 顺着 sysfs 的 .../block/sdb/sdb3 往上数一级。
# 刻意不走 lsblk —— 它认分区靠的是 PARTN/PARTLABEL/FSTYPE 这些列名, 版本一老
# 就变成 "lsblk: unknown column: ..." 并返回非零, 整个脚本会被 pipefail 带走。
ROOT_KNAME="$(basename "$ROOT_SRC")"
DISK_NAME="$(try basename "$(try readlink -f "/sys/class/block/${ROOT_KNAME}/..")")"
if [[ -z "$DISK_NAME" || ! -e "/sys/block/${DISK_NAME}" ]]; then
  # 兜底: lsblk 只用单列 PKNAME(没有逗号, 各版本都认)
  DISK_NAME="$(try lsblk -no PKNAME "$ROOT_SRC")"; DISK_NAME="${DISK_NAME%%$'\n'*}"
fi
[[ -n "$DISK_NAME" && -e "/sys/block/${DISK_NAME}" ]] \
  || die "无法从 ${ROOT_SRC} 推断出物理磁盘(/sys 和 lsblk 都没给出结果)"
DISK="/dev/${DISK_NAME}"

TOTAL_SECTORS="$(try cat "/sys/block/${DISK_NAME}/size")"
[[ "$TOTAL_SECTORS" =~ ^[0-9]+$ ]] || die "读不到 ${DISK} 的扇区数(/sys/block/${DISK_NAME}/size)"

PART_TYPE="$(try lsblk -dn -o PTTYPE "$DISK")"; PART_TYPE="${PART_TYPE%%$'\n'*}"
say "根分区      : $ROOT_SRC  (挂载点 /)"
say "物理磁盘    : $DISK"
say "磁盘容量    : $(to_gib "$TOTAL_SECTORS") GiB"
say "分区表      : ${PART_TYPE:-gpt(按 sgdisk 推断)}"
[[ -n "$LOG_FILE" ]] && say "日志        : $LOG_FILE"

say "当前分区表:"
# 这里不再用 lsblk。踩过的坑: lsblk 认分区靠 PARTN/PARTLABEL/FSTYPE 这些列名,
# 一旦这台机器上的 lsblk 不认(版本/发行版差异), 它会打一行
# "unknown column: ..." 并返回非零; 而这个脚本开着 pipefail + set -e,
# 非零退出码会顺着命令替换把整个脚本干掉 —— 真机上表现就是 usb-grow.sh
# 跑到一半自己没了, 报出来的"失败命令"还是管道里的 awk, 极具误导性。
SG_RAW="$(try sgdisk -p "$DISK")"
[[ -n "$SG_RAW" ]] || warn "sgdisk 读不到 ${DISK}(普通用户常没有读整盘权限), 分区名只能靠 udev 数据库"
SG_ROWS="$(sgdisk_rows <<<"$SG_RAW")"

# 归一化成分区表, 每行: 分区号 主:次 设备节点 GPT名字 FS标签 文件系统类型 起始扇区 结束扇区
# 三个来源互补: sysfs 给分区号和设备节点, sgdisk -p 给扇区范围和 GPT 名字,
# /run/udev/data 给标签和文件系统类型(普通用户也读得到, lsblk 认标签靠的就是它)。
PART_TABLE="$(
  for _sys in /sys/block/"${DISK_NAME}"/"${DISK_NAME}"*; do
    [[ -r "${_sys}/partition" ]] || continue
    _p="$(try cat "${_sys}/partition")"
    _mm="$(try cat "${_sys}/dev")"
    [[ -n "$_p" && -n "$_mm" ]] || continue
    _dev="/dev/${_sys##*/}"
    _name="$(awk -v n="$_p" '$1==n{print $4}' <<<"$SG_ROWS")"
    [[ -n "$_name" ]] || _name="$(udev_prop "$_mm" ID_PART_ENTRY_NAME)"
    _lbl="$(udev_prop "$_mm" ID_FS_LABEL)"
    _fst="$(udev_prop "$_mm" ID_FS_TYPE)"
    _st="$(awk -v n="$_p" '$1==n{print $2}' <<<"$SG_ROWS")"
    _en="$(awk -v n="$_p" '$1==n{print $3}' <<<"$SG_ROWS")"
    # 注意: 拿不到的字段一律写 "-" 占位, 不能留空 ——
    # 下面用 `read` 逐行拆表, 默认 IFS 会把连续的空格折叠掉, 一留空整行就错位。
    printf '%s %s %s %s %s %s %s %s\n' "$_p" "$_mm" "$_dev" \
      "${_name:--}" "${_lbl:--}" "${_fst:--}" "${_st:--}" "${_en:--}"
  done
)"

if [[ -n "$PART_TABLE" ]]; then
  printf '    %-5s %-11s %-15s %-7s %-12s %s\n' 分区 设备 名称 类型 起始扇区 结束扇区
  while read -r _p _mm _dev _name _lbl _fst _st _en; do
    [[ -n "$_p" ]] || continue
    printf '    p%-4s %-11s %-15s %-7s %-12s %s\n' \
      "$_p" "$_dev" "$_name" "$_fst" "$_st" "$_en"
  done <<<"$PART_TABLE"
else
  warn "在 ${DISK} 上一个分区都没认出来, 后面大概率会失败"
fi
if [[ -n "$LOG_FILE" ]]; then
  { printf '\n==> 当前分区表(sgdisk -p)\n%s\n' "$SG_RAW"; } >>"$LOG_FILE" 2>/dev/null || true
fi

# ---------------- 定位 root / music 分区 ----------------
ROOT_PART="$(part_num_by_label DEBIAN_ROOT)"
[[ -n "$ROOT_PART" ]] || ROOT_PART="$(part_num_by_mount /)"
[[ -n "$ROOT_PART" ]] || ROOT_PART="$(part_num_by_fstype ext4)"

MUSIC_PART="$(part_num_by_label MUSIC)"
[[ -n "$MUSIC_PART" ]] || MUSIC_PART="$(part_num_by_mount /mnt/songdisk)"
if [[ -z "$MUSIC_PART" ]]; then
  # 兜底: 取最后一个分区
  MUSIC_PART="$(part_last_num)"
  [[ -n "$MUSIC_PART" ]] && warn "按名字没认出 MUSIC 分区, 已改用磁盘上的最后一个分区 p${MUSIC_PART}"
fi

[[ -n "$ROOT_PART" ]]  || die "识别不出 root 分区(找过: GPT 名 DEBIAN_ROOT / 挂载点 / / ext4)"
[[ -n "$MUSIC_PART" ]] || die "识别不出 MUSIC 分区(找过: GPT 名 MUSIC / 挂载点 /mnt/songdisk / 最后一个分区)"
[[ "$ROOT_PART" != "$MUSIC_PART" ]] || die "root 与 MUSIC 被识别成了同一个分区(p${ROOT_PART}), 已中止"

ROOT_DEV="$(part_field "$ROOT_PART" 3)"
MUSIC_DEV="$(part_field "$MUSIC_PART" 3)"
[[ -n "$ROOT_DEV" && -n "$MUSIC_DEV" ]] || die "找不到分区设备节点(p${ROOT_PART}=${ROOT_DEV:-空} p${MUSIC_PART}=${MUSIC_DEV:-空})"

ROOT_START="$(part_field "$ROOT_PART" 7)"
ROOT_LAST="$(part_field "$ROOT_PART" 8)"
MUSIC_START="$(part_field "$MUSIC_PART" 7)"
MUSIC_LAST="$(part_field "$MUSIC_PART" 8)"
# 扇区信息只来自 sgdisk -p, 而读整块磁盘要 root 权限 —— 这里把两种失败分开说清楚
# (表里读不到的字段是 "-", 所以空和 "-" 都要当成"没读到")
for _v in "$TOTAL_SECTORS" "$ROOT_START" "$ROOT_LAST" "$MUSIC_START" "$MUSIC_LAST"; do
  if [[ -z "$_v" || "$_v" == "-" ]]; then
    die "读不到 ${DISK} 的分区扇区范围。最常见的原因是权限: 读整块磁盘需要 root, 请跑 sudo usb-grow.sh --check"
  fi
  [[ "$_v" =~ ^[0-9]+$ ]] || die "分区扇区范围里出现非数字($_v), 分区表可能已损坏, 先跑 --check 看完整信息"
done

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
  log_hint
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
say "root   : $(to_gib $((ROOT_LAST-ROOT_START+1))) GiB  ->  $(to_gib $((NEW_ROOT_LAST-ROOT_START+1))) GiB  (+$(to_gib "$ROOT_EXTRA") GiB)"
say "MUSIC  : $(to_gib $((MUSIC_LAST-MUSIC_START+1))) GiB  ->  $(to_gib $((TOTAL_SECTORS-NEW_MUSIC_START))) GiB  (+$(to_gib "$MUSIC_EXTRA") GiB)"

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
printf '    $ sgdisk --delete=%s %s\n' "$MUSIC_PART" "$DISK"
sgdisk --delete="$MUSIC_PART" "$DISK" || die "删除旧 MUSIC 分区条目失败(退出码 $?)"

say "  扩展 root 到扇区 ${NEW_ROOT_LAST}"
printf '    $ sgdisk --new=%s:%s:%s ...\n' "$ROOT_PART" "$ROOT_START" "$NEW_ROOT_LAST"
sgdisk --new="${ROOT_PART}:${ROOT_START}:${NEW_ROOT_LAST}" \
       --typecode="${ROOT_PART}:8300" --change-name="${ROOT_PART}:DEBIAN_ROOT" \
       "$DISK" || die "重建 root 分区条目失败(退出码 $?)"

say "  在扇区 ${NEW_MUSIC_START} 重建 MUSIC 到磁盘末尾"
printf '    $ sgdisk --new=%s:%s:+0 ...\n' "$MUSIC_PART" "$NEW_MUSIC_START"
sgdisk --new="${MUSIC_PART}:${NEW_MUSIC_START}:+0" \
       --typecode="${MUSIC_PART}:8300" --change-name="${MUSIC_PART}:MUSIC" \
       "$DISK" || die "重建 MUSIC 分区条目失败(退出码 $?)"
ok "分区表已更新"

# 备份头被压掉是最危险的后果(插到别的机器上整张盘认不出来), 这里必须验
if sgdisk -v "$DISK" 2>&1 | grep -qi "no problems found"; then
  ok "GPT 校验通过 ✅"
else
  warn "GPT 校验发现问题, 下面是细节:"
  sgdisk -v "$DISK" 2>&1 | sed 's/^/         /' || true
  warn "如果备份 GPT 头被压掉了, 务必重启一次并确认能正常启动"
fi

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
df -h / /mnt/songdisk 2>/dev/null | sed 's/^/    /' || true

# ---- 后置校验: 脚本说"成功"不算数, 真的变大了才算 ----
# 不做这一步的话, 分区表改了但内核没接受 / resize2fs 静默失败, 屏幕上照样
# 打印"扩容完成 🎉", 而 /mnt/songdisk 还是老大小 —— 这正是"没作用"的来源。
MUSIC_GB_AFTER="$(df -BG --output=size /mnt/songdisk 2>/dev/null | tail -1 | tr -dc '0-9' || true)"
[[ -n "$MUSIC_GB_AFTER" ]] || MUSIC_GB_AFTER=0
MUSIC_GB_EXPECT="$(to_gib $((TOTAL_SECTORS-NEW_MUSIC_START)) | cut -d. -f1)"

echo
if (( MUSIC_GB_AFTER >= MUSIC_GB_EXPECT - 1 )); then
  ok "扩容完成 🎉 /mnt/songdisk 现在 ${MUSIC_GB_AFTER}G"
else
  warn "文件系统实际只有 ${MUSIC_GB_AFTER}G, 达不到预期的 ${MUSIC_GB_EXPECT}G —— 分区表改了但文件系统没跟上"
  warn "绝大多数情况是内核还没接受新的分区大小。重启一次, 再跑一次 ${0##*/} 即可补齐"
  warn "或者手动执行: sudo partprobe ${DISK} && sudo resize2fs ${MUSIC_DEV}"
fi
ok "root 分区: $(df -h / 2>/dev/null | awk 'NR==2{print $2}' || echo '?')"
log_hint