---
name: lan-capture
description: 用 tcpdump/tshark 抓包定位局域网问题 —— 抓包看谁在发包、DNS 查询异常、DHCP 交互、ARP 冲突、连接超时。Use when the user asks 抓包/抓一下包/看看数据/packet capture/tshark/tcpdump/谁在发包, or when ping works but an app protocol fails and you need to see the actual packets.
---

# 抓包定位

前面几层都正常(网关通、IP 通、DNS 通), 但某个服务还是用不了 —— 这时候要**看真实报文**。

## 抓之前先想清楚要看什么

| 现象 | 该抓什么 |
| --- | --- |
| 网页打开慢/打不开 | DNS 查询 + TCP 三次握手: `port 53 or port 80 or port 443` |
| 某个设备连不上 | 该设备 IP 的 ARP + 目标端口 |
| 拿不到 IP | DHCP: `udp port 67 or 68` |
| IP 冲突 | ARP 请求/应答: `arp` |
| 时通时断 | 丢包定位: `icmp and host <网关>` |

## 基本操作

```bash
# 抓某个网卡的包(先看网卡名: ip -br link)
sudo tcpdump -i <网卡> -nn -c 100 -w /tmp/net.pcap

# 实时看(带解读)
sudo tcpdump -i <网卡> -nn 'arp or icmp'

# DNS 查询
sudo tcpdump -i <网卡> -nn 'port 53'

# 某个主机
sudo tcpdump -i <网卡> -nn host 192.168.6.182

# 抓完看统计(镜像里有 tcpdump, tshark 可能没装)
sudo tcpdump -r /tmp/net.pcap -nn | head -50
```

## 读包要点

- **ARP 里有同一 IP 的不同 MAC** → IP 冲突, 去 `net probe` 看冲突段。
- **DHCP Discover 发出去但没有 Offer** → DHCP 服务没响应(路由器 DHCP 挂了/地址池耗尽/VLAN 隔离)。
- **DNS 应答的 IP 很怪**(比如全是同一个广告 IP) → DNS 被劫持, 换 DNS。
- **TCP 三次握手停在 SYN 没有 SYN-ACK** → 对方没监听或被防火墙拦了。
- **有 FIN/RST 但对端没收到** → 中间设备(交换机/防火墙)在丢包。

## 注意

- 抓包会短暂占住网卡并产生真实流量, 抓完记得 `Ctrl+C` 停止;
- 抓的是别人的局域网流量, 只用于**故障诊断**, 不要留存或外传;
- 报告里只写结论和必要的报文摘要, 不要整包贴给用户。
