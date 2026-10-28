---
name: wifi-triage
description: 无线网络专项排查 —— 连不上 WiFi、信号弱、频繁掉线、连上但没网、5G/2.4G 频段选择、驱动与 rfkill 锁。Use when the user mentions WiFi/无线/无线网卡/连不上热点/信号弱/掉线/频段, or asks about wireless adapter, driver, rfkill, or signal quality problems.
---

# 无线网络专项

这台 U 盘系统对无线网卡做了加固(固件齐备 + 开机自动解锁 rfkill + polkit 放行),
但信号/频段/漫游这类问题仍需现场处理。

## 先看基本状态

```bash
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status   # 网卡认出来了吗
nmcli radio wifi                                     # 无线电开关
rfkill list                                          # 有没有被锁
iw dev                                               # 接口列表
iw dev <接口> link                                   # SSID/信号/频段/信道/速率
```

## 常见故障与对策

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `nmcli` 说 No Wi-Fi device | 缺固件/驱动 | 装 `firmware-iwlwifi`(Intel)/`firmware-realtek`/`firmware-brcm80211`; 看 `dmesg \| grep -i firmware` |
| 网卡在但连不上 | rfkill 软锁 | `sudo rfkill unblock wifi`; 开机自动解锁由 `wifi-unblock.service` 负责 |
| 扫描不到热点 | 5G-only 路由 + 网卡只支持 2.4G | 换 2.4G 热点或换 5G 网卡 |
| 频繁掉线 | 信号弱/省电/信道拥挤 | `sudo iw dev <接口> set power_save off`; 换信道; 靠近路由器 |
| 连上但没网 | 拿到 IP 但没网段/网关 | 看 `net probe` 的网关与网段段 |
| 之前连的热点不见了 | 配置文件丢了 | `wifi scan` 重新扫并连接 |

## 操作命令(用系统的 `wifi` 封装)

```bash
wifi scan                        # 扫描附近热点(带信号强度)
wifi connect "SSID" 密码          # 连接
wifi status                      # 当前连接状态
wifi on / wifi off               # 无线电开关
```

## 信号强度参考(dBm)

- `> -50` → 很好
- `-50 ~ -60` → 正常
- `-60 ~ -70` → 偏弱, 大文件会卡
- `< -70` → 很差, 基本不可用

## 频段

- 2.4GHz: 穿墙好、干扰大、带宽低(适合大户型/老设备)
- 5GHz: 速度快、穿墙差(适合近距离/同房间)

```bash
iw dev <接口> scan | grep -E "SSID|freq"
```

## 与其它技能配合

掉线/慢这类问题常常要连着看整体: 先 `net probe`(无线段会给出信号与频段),
再 `net topo` 看网关和设备, 最后 [[lan-capture]] 抓 DHCP 报文确认地址分配。
