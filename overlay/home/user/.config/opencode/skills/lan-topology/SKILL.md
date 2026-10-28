---
name: lan-topology
description: 扫描并解读局域网的拓扑结构 —— 网段、网关、有哪些设备在线、谁是路由器/打印机/手机、IP 有没有被占。Use when the user asks 局域网拓扑/网络结构/网段是什么/有哪些设备/谁占了 IP/网络图/拓扑图, or asks who is on the LAN, what subnet am I on, or which devices are online.
---

# 局域网拓扑扫描与解读

这台机器是"网络急救包", 首要能力是**一眼看清局域网长什么样**。

## 一条命令搞定

```bash
net topo                 # 扫描 + ASCII 拓扑树(主入口)
net topo --json          # 额外存一份结构化 JSON
net topo --save          # 额外存一份纯文本报告
net topo --quick         # 快速模式: 不做二层扫描/端口探测, 几秒出结果
net topo --cidr 192.168.1.0/24   # 手动指定网段
```

报告落在 `~/net-reports/`(可用 `net report` 看历史)。

## 怎么读这张树

```
├── 🌐 路由器/网关  192.168.6.1      ← 本机默认网关
│       · 厂商 Xiaomi · 主机名 kwrt.lan · 延迟 0.4ms
├── 📱 手机  192.168.6.182            ← 按设备类型归类
│       · MAC 06:e2:7f:49:f9:6f · 主机名 OnePlus-Ace-6T.lan
└── ❓ 未知设备  192.168.6.133
        · MAC 10:bf:48:32:ad:ad · 主机名 debian-usb.lan
```

- **图标/类型**由三条线索推断: mDNS 服务(最准) → 开放端口(打印机 9100、NAS 445/32400、摄像头 554、iPhone 62078) → 主机名关键字。判定依据会写在设备下面一行。
- **延迟**是 ping 的往返时间。几十到几百毫秒的 WiFi 设备通常是省电模式, 不是故障。
- 设备多的时候树只列前 40 台, 完整清单在 `--json` 输出里。

## 关键陷阱: 代理 ARP

如果统计里出现"路由器开启了 Proxy ARP", 说明路由器**替整个网段应答 ARP/ICMP**,
此时 ping 扫描会把整个 /24 都报成"在线"(实测能报出 70+ 台假设备)。
这种网段里**只有带 MAC 的才算真设备**, 别拿"ping 得通"当设备在线的证据。

## 排查网段变动

`net topo` 会把本次的网段/网关/DNS 存进 `~/.local/state/netkit/history.json`。
下一次运行会自动对比, 如果提示"网段变了 / 默认网关变了", 就说明问题出在
路由器改了 DHCP 地址池 —— 同一网段的其它设备也要跟着改。

```bash
cat ~/.local/state/netkit/history.json | tail -30
```

## 汇报给用户时

1. 先说结论: 网段是什么、网关是谁、在线几台、发现了几台打印机/摄像头这类设备。
2. 有异常(假设备多、网关不明、大量同 IP)要单独点名。
3. 不要把每个设备都念一遍, 挑用户会关心的说。
