#!/usr/bin/env bash
# 静态检查: shell 脚本里的两类低级错误, 在构建开始前就抓出来。
#
#   检查一: 调用了**没有定义**的函数/命令
#           之前 build-image.sh 里写了 `ok "..."`, 但只定义了 log/warn/die/step,
#           bash -n 检查不出来(语法合法), 一直跑到第 4/9 步才
#           "ok: command not found"(exit 127), 白白浪费一整次 20 分钟的构建。
#
#   检查二: 函数**定义晚于**第一次调用
#           bash 是先定义后使用, 定义写在调用后面照样是 "xxx: command not found"。
#           这个坑很隐蔽: 语法合法、shellcheck 也不报, 运行时才炸。
#           selftest_count 就踩过一次(定义在第 495 行, 第 460 行就在用它)。
#
# 判定"命令位置"的规则(避免把中文提示语里的英文单词误判成命令):
#   - 行首(可带缩进)
#   - 紧跟在 && || ; | ( { ! 之后(中间只允许空白)
# 另外跳过整行注释和 heredoc 正文, 免得把里面的英文单词当成命令。
#
# 用法: bash scripts/lint-helpers.sh [文件...]
# 退出码: 0 = 干净; 1 = 有问题

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT" || exit 1

# 常见外部命令白名单(这些会以引号字符串作为首参)
COMMON_CMDS='echo printf read test true false source exit return local export declare eval exec sleep mkdir rmdir rm cp mv ln cat sed awk grep egrep fgrep cut tr sort uniq head tail wc find xargs ls df du stat date touch chmod chown mkfs mke2fs mkdosfs dd sgdisk parted partprobe losetup mount umount chroot apt apt-get dpkg dpkg-query dpkg-deb dpkg-reconfigure update-alternatives useradd usermod groupadd passwd systemctl service curl wget git python python3 pip pip3 node npm tar unzip zip gpg openssl xrandr fc-list fc-cache locale localectl timedatectl blkid lsblk findmnt lscpu lspci lsusb udevadm sysctl modinfo depmod ldconfig insmod rmmod shutdown reboot poweroff halt ip ifconfig ping dig nslookup host getent journalctl dmesg loginctl sudo su id whoami getcap setcap chattr tune2fs e2fsck resize2fs dumpe2fs debugfs bmaptool unsquashfs mksquashfs rsync bc dc nproc setsid nohup flock mktemp realpath basename dirname readlink cmp diff patch sha256sum md5sum zstd xz bzip2 gzip xxd bash sh dash env cd partx blockdev sfdisk fdisk cfdisk wipefs mdadm lvm pvcreate vgcreate lvcreate'

is_common() {
  local name="$1" c
  for c in $COMMON_CMDS; do
    [[ "$c" == "$name" ]] && return 0
  done
  return 1
}

is_keyword() {
  case "$1" in
    if|then|else|elif|fi|for|while|until|do|done|case|esac|in|function|select|time|\
    return|break|continue|local|declare|typeset|export|readonly|shift|set|unset|trap|\
    eval|exec|command|builtin|source) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# 用 awk 一次性扫完一个文件。
#
# 不用 bash 逐行循环: 那个写法每个行都要 fork 两三个 grep, 扫完整个仓库要好几分钟,
# 放在 CI 里没法接受。awk 单进程扫完只要一秒。
#
# 输出格式:
#   UNDEF <行号> <名字>          调用了没定义的命令/函数
#   ORDER <调用行> <名字> <定义行> 定义晚于调用
# ---------------------------------------------------------------------------
read -r -d '' AWK_SRC <<'AWKEOF'
BEGIN { in_here = "" }

function is_cmdpos(line, start,   i, c) {
  if (start <= 1) return 1
  i = start - 1
  while (i >= 1) {
    c = substr(line, i, 1)
    if (c == " " || c == "\t") { i--; continue }
    break
  }
  if (i < 1) return 1
  c = substr(line, i, 1)
  return (c == "&" || c == "|" || c == ";" || c == "(" || c == "{" || c == "!")
}

function scan_calls(line, ln,   rest, piece, nm, pos, off) {
  off = 0
  rest = line
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*[ \t]+"/)) {
    piece = substr(rest, RSTART, RLENGTH)
    nm = piece
    sub(/[ \t]+"$/, "", nm)
    pos = off + RSTART
    if (is_cmdpos(line, pos)) {
      if (!(nm in firstuse)) firstuse[nm] = ln
    }
    off += RLENGTH
    rest = substr(rest, RLENGTH + 1)
  }
}

{
  line = $0

  # heredoc 正文: 整段跳过(里面的英文单词不是命令)
  if (in_here != "") {
    tmp = line
    gsub(/^[ \t]+/, "", tmp)
    gsub(/[ \t]+$/, "", tmp)
    if (tmp == in_here) in_here = ""
    next
  }

  # 整行注释跳过
  if (line ~ /^[ \t]*#/) next

  # 函数定义
  if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{/) {
    nm = line
    sub(/\(.*/, "", nm)
    if (!(nm in defline)) defline[nm] = NR
  }

  scan_calls(line, NR)

  # 新的 heredoc 起始: <<WORD  <<-WORD  <<'WORD'  <<"WORD"
  #
  # 注意三种必须排除的情况, 否则扫描会"卡住"把文件后半段全跳过:
  #   1) <<< 是 herestring, 内容在同一行, 不是块
  #   2) <<-? 前面还有一个 < 时是 <<<
  #   3) 分隔符里带 $ 说明它是变量, 真实结束符是变量值, 猜不到 -> 不跟踪
  if (match(line, /<<-?[ \t]*("[^"]+"|'[^']+'|[A-Za-z_][A-Za-z0-9_]*)/)) {
    pre = substr(line, 1, RSTART - 1)
    before = (RSTART > 1) ? substr(line, RSTART - 1, 1) : ""
    if (before != "<" && pre !~ /'/) {
      d = substr(line, RSTART, RLENGTH)
      sub(/^<<-?[ \t]*/, "", d)
      gsub(/["']/, "", d)
      if (d == "") {
        # 纯 << 后面没跟分隔符, 不跟踪
      } else if (d ~ /\$/) {
        # 分隔符是变量, 猜不到真实结束符, 不跟踪(宁可漏报也不要吞掉半个文件)
      } else {
        in_here = d
        here_line = NR
      }
    }
  }
}

END {
  for (nm in firstuse) {
    if (!(nm in defline)) printf "UNDEF\t%s\t%s\n", firstuse[nm], nm
  }
  for (nm in defline) {
    if ((nm in firstuse) && firstuse[nm] < defline[nm]) {
      printf "ORDER\t%s\t%s\t%s\n", firstuse[nm], nm, defline[nm]
    }
  }
  # heredoc 没闭合: 说明跟踪失败, 后面的行根本没被扫到, 必须报出来
  if (in_here != "") printf "HEREDOC\t%s\t%s\n", here_line, in_here
}
AWKEOF

status=0
files=("$@")
if [[ ${#files[@]} -eq 0 ]]; then
  # scripts/tests 里放的是**故意写错**的测试夹具, 必须排除, 否则它自己就会被报成坏的
  mapfile -t files < <(find scripts overlay overlay-n1 -type f -name '*.sh' \
                         -not -path 'scripts/tests/*' 2>/dev/null | sort)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  printf 'lint-helpers: 没有找到任何待检查的文件(REPO_ROOT=%s)\n' "$REPO_ROOT" >&2
  exit 1
fi

for f in "${files[@]}"; do
  [[ -f "$f" ]] || { printf '  %s: 文件不存在\n' "$f" >&2; status=1; continue; }
  while IFS=$'\t' read -r kind a b c; do
    [[ -n "$kind" ]] || continue
    case "$kind" in
      UNDEF)
        if is_keyword "$b"; then continue; fi
        is_common "$b" && continue
        printf '  %s: 第 %s 行调用了没有定义的命令/函数 -> %s\n' "$f" "$a" "$b"
        status=1
        ;;
      ORDER)
        printf '  %s: 函数 %s 在第 %s 行被调用, 但定义在第 %s 行(bash 要求先定义后使用)\n' \
          "$f" "$b" "$a" "$c"
        status=1
        ;;
      HEREDOC)
        printf '  %s: 第 %s 行开始的 heredoc(结束符 %s)没匹配到结束行, 后面的内容没被扫描\n' \
          "$f" "$a" "$b"
        status=1
        ;;
    esac
  done < <(awk "$AWK_SRC" "$f")
done

if [[ $status -eq 0 ]]; then
  printf 'lint-helpers: 检查了 %d 个 shell 脚本, 未发现未定义的命令/函数或定义顺序问题\n' "${#files[@]}"
fi
exit $status
