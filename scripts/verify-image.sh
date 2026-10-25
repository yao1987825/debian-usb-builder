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

# 数自测"真正通过了几项"。
# 注意: 直接 `grep -c '✅'` 会把末尾的 "✅ 25/25 项通过" 汇总行也算进去,
# 于是日志里写"26 项"而实际只有 25 项。这里把汇总行剔掉。
selftest_count() {
  local f="$1" n
  [[ -f "$f" ]] || { echo 0; return 0; }
  n="$(grep '✅' "$f" 2>/dev/null | grep -cv '项通过' || true)"
  echo "${n:-0}"
}

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
    # 注意: debugfs 以 root 身份执行, dump 出来的文件属主是 root,
    #       普通用户改不了它的权限 —— 测试脚本本来就用 `bash <file>` 调用,
    #       不需要执行位, 所以这里不要 chmod。
    local tmp_music; tmp_music="$(mktemp -d)/music"
    if $SUDO debugfs -R "dump /usr/local/bin/music ${tmp_music}" "$p3" 2>/dev/null && [[ -s "$tmp_music" ]]; then
      if MUSIC_BIN="$tmp_music" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-music-cli.sh" >/dev/null 2>&1; then
        ok "镜像里的 music 命令行回归测试通过(参数没有丢失)"
      else
        die "镜像里的 music 命令行回归测试失败"
      fi
    else
      warn "没能从根分区取出 /usr/local/bin/music, 跳过回归测试"
    fi

    # 输入法: Rime 的 Shift 切换曾经写成字符串而不是映射, 真机只表现为
    # "按 Shift 没反应", 极难定位 —— 所以直接查文件内容。
    # 路径必须是 Rime 用户目录 ~/.local/share/fcitx5/rime/(真机 v1.0.4 的坑:
    # 配置放在 ~/.config/fcitx5/rime/ 下 Rime 根本不看)。
    local _rime
    _rime="$($SUDO debugfs -R "cat /home/user/.local/share/fcitx5/rime/default.custom.yaml" "$p3" 2>/dev/null || true)"
    if [[ -z "$_rime" ]]; then
      die "Rime 用户目录里没有 default.custom.yaml(必须在 /home/user/.local/share/fcitx5/rime/), Rime 配置根本没被读到"
    fi
    # 正则里的 "?" 不能省: YAML 的 key 带引号, 冒号前面还有一个引号
    if grep -qE 'ascii_composer/switch_key/(Shift_L|Shift_R)"?: inline_ascii' <<<"$_rime"; then
      ok "Rime 的 Shift 切中英文已用扁平键配置(inline_ascii)"
    elif grep -q 'ascii_composer/switch_key' <<<"$_rime"; then
      die "Rime 的 ascii_composer 写成了字符串而不是 键->动作 映射, Shift 永远不会生效"
    else
      die "Rime 没配 Shift 切中英文(按 Shift 不会有反应)"
    fi
    if grep -q "schema: luna_pinyin_simp" <<<"$_rime"; then
      ok "Rime 已锁定简体方案 luna_pinyin_simp"
    else
      die "Rime 没指定简体方案 luna_pinyin_simp —— 打出来会是繁体字"
    fi
    if $SUDO debugfs -R "cat /home/user/.xprofile" "$p3" 2>/dev/null | grep -q "GTK_IM_MODULE=fcitx"; then
      ok "已写入 ~/.xprofile 的 IM 环境变量(不依赖 im-config 钩子)"
    else
      die "缺少 ~/.xprofile 的 IM 环境变量, lightdm 自动登录时输入法起不来"
    fi
    if $SUDO debugfs -R "cat /home/user/.config/autostart/fcitx5.desktop" "$p3" 2>/dev/null | grep -q "fcitx5 -d"; then
      ok "已写入 fcitx5 自启项"
    else
      die "缺少 fcitx5 自启项, 输入法开机不会自动启动"
    fi
    # 真机 v1.0.5 的坑: 只启动不校验, 引擎切不过去就永远停在 keyboard-us,
    # 表现为"开机第一个终端打不出中文, 开新标签页才行"。
    local _fc
    _fc="$($SUDO debugfs -R "cat /home/user/.config/autostart/fcitx5.desktop" "$p3" 2>/dev/null || true)"
    if grep -q "fcitx5-remote -n" <<<"$_fc" && grep -q "fcitx5-remote -s rime" <<<"$_fc"; then
      ok "fcitx5 自启项会校验并重试切到 rime(引擎没注册完也不会卡在直写态)"
    else
      die "fcitx5 自启项没有'重试切 rime 直到 -n 报 rime'的逻辑 —— 开机输入法会停在英文直写态"
    fi
    if $SUDO debugfs -R "stat /home/user/.config/autostart/fcitx5-default.desktop" "$p3" 2>/dev/null | grep -q "Inode:"; then
      die "还留着 fcitx5-default.desktop —— 它会拉起第二个 fcitx5 实例抢 IM context"
    else
      ok "没有多余的 fcitx5-default.desktop(不会出现第二个 fcitx5 实例)"
    fi
    if $SUDO debugfs -R "stat /usr/share/dbus-1/services/org.fcitx.Fcitx5.service" "$p3" 2>/dev/null | grep -q "Inode:"; then
      die "fcitx5 的 dbus 自动激活没禁用 —— 探测名字时会被拉起第二个实例"
    else
      ok "fcitx5 的 dbus 自动激活已禁用"
    fi

    # ---- 终端体系(用户实测反馈: 标签页快捷键不明 / 关光后黑屏 / Ctrl+Alt+T 盖屏) ----
    # 注意: 路径必须是 Rime 用户目录 ~/.local/share/fcitx5/rime/
    # (放在 ~/.config/fcitx5/rime/ 下 Rime 根本不看, 真机 v1.0.4 的坑)
    local _r
    _r="$($SUDO debugfs -R "cat /home/user/.local/share/fcitx5/rime/default.custom.yaml" "$p3" 2>/dev/null || true)"
    if grep -q 'ascii_composer/good_old_caps_lock' <<<"$_r"; then
      ok "Rime 另配了 CapsLock 切换键(Shift 失灵时的第二条路)"
    else
      warn "Rime 没配 CapsLock 切换键(Shift 失灵时只能靠 Ctrl+Space / music im-toggle)"
    fi
    local _trc
    _trc="$($SUDO debugfs -R "cat /home/user/.config/xfce4/terminal/terminalrc" "$p3" 2>/dev/null || true)"
    if grep -q 'Shortcuts=NewTab' <<<"$_trc" \
       && grep -q 'Shortcuts=NextTab' <<<"$_trc" \
       && grep -q 'Shortcuts=PrevTab' <<<"$_trc"; then
      ok "终端配置里显式写了标签页的 建/切/关 快捷键"
    else
      die "终端配置里没有显式写标签页快捷键, 用户猜不到怎么切标签页"
    fi
    local _a
    for _a in terminal-keepalive terminal-setup; do
      if $SUDO debugfs -R "cat /home/user/.config/autostart/${_a}.desktop" "$p3" 2>/dev/null | grep -q "Exec="; then
        ok "自启项存在: ${_a}.desktop"
      else
        die "缺少自启项 ${_a}.desktop —— 终端守护/键位设置都不会生效"
      fi
    done
    # 开机那个终端必须接上键位速查表(小白面对空终端不知道能干什么)
    local _xt
    _xt="$($SUDO debugfs -R "cat /home/user/.config/autostart/xfce-terminal.desktop" "$p3" 2>/dev/null || true)"
    if grep -q "terminal-welcome" <<<"$_xt"; then
      ok "开机终端已接上键位速查表"
    else
      die "开机终端没接 terminal-welcome —— 登录后是个空终端, 用户不知道能干什么"
    fi
    if grep -q "fcitx5-remote -n" <<<"$_xt"; then
      ok "开机终端会等 rime 引擎就绪再开(首个窗口就能打中文)"
    else
      die "开机终端没等 rime 引擎 —— 第一个窗口会是英文直写态, 只有开新标签页才能打中文"
    fi
    if grep -q -- "--maximize" <<<"$_xt"; then
      ok "开机终端直接最大化"
    else
      die "开机终端没有最大化 —— 用户开机第一眼看到的是小窗口"
    fi

    # ---- 快捷键: 指向缺失程序的绑定会弹"无法打开…"警告(真机 2026-10-25 反馈) ----
    local _ksd _ksu
    _ksd="$($SUDO debugfs -R "cat /etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml" "$p3" 2>/dev/null || true)"
    if [[ -n "$_ksd" ]]; then
      local _bad _hit=""
      for _bad in xfce4-screenshooter thunar xfce4-appfinder orca xfce4-taskmanager xfdesktop xfce4-popup-applicationsmenu; do
        if grep -q "$_bad" <<<"$_ksd"; then _hit="$_bad"; break; fi
      done
      if [[ -n "$_hit" ]]; then
        die "默认快捷键里还绑着 ${_hit} —— 镜像里没装这个程序, 按了会弹'无法打开'警告"
      else
        ok "默认快捷键里没有指向缺失程序的绑定(按这些键不再弹警告)"
      fi
    else
      warn "没读到系统默认快捷键文件, 跳过失效绑定检查"
    fi
    _ksu="$($SUDO debugfs -R "cat /home/user/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml" "$p3" 2>/dev/null || true)"
    if grep -q "/usr/local/bin/screenshot" <<<"$_ksu"; then
      ok "Print 截图键已改绑到 scrot 封装(按了真能截图, 不再报错)"
    else
      die "用户级快捷键里没有截图键绑定 —— Print 会变成失效绑定"
    fi
    if grep -q "tile_left_key" <<<"$_ksu"; then
      ok "窗口快捷键(Super+←/→/↑/↓)已写进用户级快捷键"
    else
      die "用户级快捷键里没有窗口平铺快捷键"
    fi
    if $SUDO debugfs -R "stat /usr/local/bin/screenshot" "$p3" 2>/dev/null | grep -q "Inode:"; then
      ok "截图脚本已就位: /usr/local/bin/screenshot"
    else
      die "缺少 /usr/local/bin/screenshot —— Print 截图键没有后端"
    fi
    if $SUDO debugfs -R "stat /usr/bin/scrot" "$p3" 2>/dev/null | grep -q "Inode:"; then
      ok "截图后端已装: /usr/bin/scrot"
    else
      die "缺少 /usr/bin/scrot —— 截图键没有后端"
    fi
    if $SUDO debugfs -R "cat /home/user/.bashrc" "$p3" 2>/dev/null | grep -q "_music_set_title"; then
      ok "终端标签页标题跟随当前目录"
    else
      warn "没写标签页标题(标签页上只有编号, 不好分辨)"
    fi
    # 基础命令行工具(用户要求"未来加新功能, 基础命令行工具要具备")
    local _tool
    for _tool in /usr/bin/rg /usr/bin/fdfind /usr/bin/batcat /usr/bin/fzf /usr/bin/jq \
                 /usr/bin/tree /usr/bin/tmux /usr/bin/screen /usr/bin/wmctrl /usr/bin/xdotool; do
      if $SUDO debugfs -R "stat ${_tool}" "$p3" 2>/dev/null | grep -q "Inode:"; then
        ok "命令行工具已装: ${_tool}"
      else
        die "缺少命令行工具 ${_tool}"
      fi
    done
    for _tool in /usr/local/bin/fd /usr/local/bin/bat; do
      if $SUDO debugfs -R "stat ${_tool}" "$p3" 2>/dev/null | grep -q "Inode:"; then
        ok "命令名软链已补: ${_tool}"
      else
        die "缺少 ${_tool} 软链(用户敲 fd/bat 会找不到命令)"
      fi
    done

    # 网络: 没有 NetworkManager 就是一台没有网络的机器, 必须卡住
    local _f
    for _f in /usr/local/bin/net-doctor /usr/local/bin/net-rescue /usr/local/bin/usb-grow.sh \
              /usr/local/bin/screen-fit /usr/local/bin/proxy \
              /usr/local/bin/music-health /usr/local/bin/music-im-fix /usr/bin/nmcli \
              /usr/local/bin/terminal-keepalive /usr/local/bin/terminal-new \
              /usr/local/bin/terminal-keys /usr/local/bin/terminal-setup \
              /usr/local/bin/terminal-welcome; do
      if $SUDO debugfs -R "stat ${_f}" "$p3" 2>/dev/null | grep -q "Inode:"; then
        ok "根分区存在 ${_f}"
      else
        die "根分区缺少 ${_f} —— 没有它开机就没有网络 / 无法扩容"
      fi
    done
    # 光"文件在"不够, 还得能被 bash 解析 —— 语法错/函数定义顺序错这种问题
    # 在真机上表现为"命令跑起来毫无反应", 必须在构建期就卡住。
    local _s _d
    for _s in /usr/local/bin/music /usr/local/bin/net-doctor /usr/local/bin/net-rescue /usr/local/bin/usb-grow.sh \
               /usr/local/bin/screen-fit /usr/local/bin/proxy \
               /usr/local/bin/music-health /usr/local/bin/music-im-fix \
               /usr/local/bin/terminal-keepalive /usr/local/bin/terminal-new \
               /usr/local/bin/terminal-keys /usr/local/bin/terminal-setup \
               /usr/local/bin/terminal-welcome; do
      _d="$(mktemp -d)"
      if $SUDO debugfs -R "dump ${_s} ${_d}/probe" "$p3" 2>/dev/null && [[ -s "${_d}/probe" ]]; then
        if bash -n "${_d}/probe" 2>/dev/null; then
          ok "${_s} 语法检查通过"
        else
          die "${_s} 语法错误, bash -n 解析不过"
        fi
      else
        die "没能从根分区取出 ${_s}, 无法做语法检查"
      fi
    done

    # 显示分辨率: 解析逻辑错了在真机上只是"分辨率没变", 很难看出是脚本的锅,
    # 所以把 --self-test 的结果也带出来看一眼。
    _d="$(mktemp -d)"
    if $SUDO debugfs -R "dump /usr/local/lib/screentools/fit.py ${_d}/fit.py" "$p3" 2>/dev/null \
       && [[ -s "${_d}/fit.py" ]]; then
      ok "根分区存在 /usr/local/lib/screentools/fit.py"
      if python3 "${_d}/fit.py" --self-test >"${_d}/self.log" 2>&1; then
        ok "EDID/xrandr 解析自测通过($(selftest_count "${_d}/self.log") 项)"
      else
        sed 's/^/[screen-fit] /' "${_d}/self.log" >&2 || true
        die "EDID/xrandr 解析自测失败, screen-fit 会匹配错分辨率"
      fi
    else
      die "根分区缺少 /usr/local/lib/screentools/fit.py"
    fi
    if $SUDO debugfs -R "stat /usr/bin/xrandr" "$p3" 2>/dev/null | grep -q "Inode:"; then
      ok "根分区存在 /usr/bin/xrandr(screen-fit 依赖它)"
    else
      die "根分区缺少 /usr/bin/xrandr, screen-fit 无法工作"
    fi
    if $SUDO debugfs -R "cat /etc/xdg/autostart/screen-fit.desktop" "$p3" 2>/dev/null | grep -q "screen-fit --restore"; then
      ok "已配置开机自动匹配显示器分辨率"
    else
      die "没有 screen-fit 自启动项, 开机分辨率不会自动匹配"
    fi

    # 软件源: 用户明确要求换清华源, 换不成就等于没做
    local _sl
    local _want="${APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}"
    case "$_want" in off|none|"") _want="" ;; esac
    _sl="$($SUDO debugfs -R "cat /etc/apt/sources.list" "$p3" 2>/dev/null || true)"
    if [[ -n "$_want" ]]; then
      local _host="${_want#*://}"; _host="${_host%%/*}"
      if grep -q "$_host" <<<"$_sl"; then
        ok "apt 源已换成 ${_host}"
      else
        warn "apt 源不是 ${_host}(构建时镜像站拉不动会自动回退官方源), 当前内容:"
        sed 's/^/         /' <<<"$_sl"
      fi
    else
      ok "apt 源保持官方源(未指定 APT_MIRROR)"
    fi
    if [[ -n "${PIP_INDEX_URL:-}" ]]; then
      local _phost="${PIP_INDEX_URL}"
      case "$_phost" in off|none|"") _phost="" ;; esac
      if [[ -n "$_phost" ]]; then
        _phost="${_phost#*://}"; _phost="${_phost%%/*}"
        if $SUDO debugfs -R "cat /etc/pip.conf" "$p3" 2>/dev/null | grep -q "$_phost"; then
          ok "pip 源已换成 ${_phost}"
        else
          warn "pip 源不是 ${_phost}"
        fi
      fi
    fi

    # 代理: 预置配置必须存在, 且生成出来的 shell 必须合法
    _d="$(mktemp -d)"
    if $SUDO debugfs -R "dump /etc/profile.d/99-proxy.sh ${_d}/99-proxy.sh" "$p3" 2>/dev/null \
       && [[ -s "${_d}/99-proxy.sh" ]]; then
      if bash -n "${_d}/99-proxy.sh" 2>/dev/null; then
        ok "/etc/profile.d/99-proxy.sh 存在且语法正确"
      else
        die "/etc/profile.d/99-proxy.sh 语法错误, source 它会让登录失败"
      fi
      if grep -q 'PROXY_URL=' "${_d}/99-proxy.sh"; then
        ok "预置代理: $(grep -oP 'PROXY_URL="\K[^"]+' "${_d}/99-proxy.sh" | head -1)"
      else
        warn "99-proxy.sh 里没找到 PROXY_URL"
      fi
    else
      die "根分区缺少 /etc/profile.d/99-proxy.sh"
    fi

    _d="$(mktemp -d)"
    if $SUDO debugfs -R "dump /usr/local/lib/musictools/quark_login.py ${_d}/quark_login.py" "$p3" 2>/dev/null \
       && [[ -s "${_d}/quark_login.py" ]]; then
      ok "根分区存在 /usr/local/lib/musictools/quark_login.py"
      if python3 "${_d}/quark_login.py" --self-test >"${_d}/q.log" 2>&1; then
        ok "夸克登录逻辑自测通过($(selftest_count "${_d}/q.log") 项)"
      else
        sed 's/^/[quark] /' "${_d}/q.log" >&2 || true
        die "夸克登录逻辑自测失败, music quark-login 不能用"
      fi
    else
      die "根分区缺少 quark_login.py, 无法扫码登录夸克"
    fi

    # music 虚拟环境里的包: music single 的可用性全靠 requests。
    # 注意只能读 site-packages 目录列表, 不能直接跑镜像里的 python ——
    # venv 的 bin/python 是指向 /usr/bin/python3 的绝对路径软链, 在宿主机上
    # 执行会解析到宿主的解释器, 什么包都测不出来。
    local _pyv _sp _pkg
    _pyv="$($SUDO debugfs -R "ls /home/user/.venvs/music/lib" "$p3" 2>/dev/null | tr -s ' ' '\n' | grep -E '^python3\.[0-9]+$' | head -1 || true)"
    if [[ -n "$_pyv" ]]; then
      _sp="$($SUDO debugfs -R "ls /home/user/.venvs/music/lib/${_pyv}/site-packages" "$p3" 2>/dev/null || true)"
      for _pkg in requests socks qrcode; do
        if grep -qE "(^| )${_pkg}([.-]|$)" <<<"$_sp"; then
          ok "music 虚拟环境里有 ${_pkg}"
        elif [[ "$_pkg" == "qrcode" ]]; then
          warn "music 虚拟环境里没有 qrcode —— 扫码登录会退化成只打印链接(仍可用)"
        else
          die "music 虚拟环境里没有 ${_pkg} —— music single / 代理会直接不可用"
        fi
      done
    else
      die "根分区里找不到 music 虚拟环境(/home/user/.venvs/music), music single 不可用"
    fi

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

    # 开机自动扩容: 用户的要求是"写盘即用, 不用手动跑脚本"。
    # 这个单元没启用 = 用户第一次开机就发现根分区还是 6G。
    if $SUDO debugfs -R "ls /etc/systemd/system/multi-user.target.wants" "$p3" 2>/dev/null | grep -q "usb-grow.service"; then
      ok "usb-grow.service 已设为开机自启(开机自动扩容)"
    else
      die "usb-grow.service 没开机自启 —— 写完镜像还得手动跑 usb-grow.sh, 等于没做自动"
    fi
    if $SUDO debugfs -R "stat /usr/local/bin/usb-grow.sh" "$p3" 2>/dev/null | grep -q "0755"; then
      ok "usb-grow.sh 可执行"
    else
      die "usb-grow.sh 不是 0755, systemd 起不来它"
    fi

    # 输入法配置属主: 真机 v1.0.2 就是死在这(root 属主 -> 切换时写不进去)
    if $SUDO debugfs -R "stat /home/user/.config/fcitx5/profile" "$p3" 2>/dev/null | grep -qE "User:\s+1000|uid:\s+1000"; then
      ok "fcitx5/profile 属主是普通用户"
    else
      die "fcitx5/profile 属主不是普通用户, 输入法切换会失灵(真机 v1.0.2 的坑)"
    fi

    # 桌面精简: 面板/桌面图标一旦回来, 开机就会冒出用户不要的 dock
    for _p in xfce4-panel xfdesktop4; do
      if $SUDO debugfs -R "cat /var/lib/dpkg/status" "$p3" 2>/dev/null | grep -q "^Package: ${_p}$"; then
        die "镜像里装了 ${_p}, 开机会有面板/桌面图标"
      fi
    done
    ok "镜像里没有面板/桌面图标包"

    # openssh-client 是这轮明确要求预装的
    if $SUDO debugfs -R "stat /usr/bin/ssh" "$p3" 2>/dev/null | grep -q "Inode:"; then
      ok "openssh-client 已预装(/usr/bin/ssh)"
    else
      die "openssh-client 没装进镜像"
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
