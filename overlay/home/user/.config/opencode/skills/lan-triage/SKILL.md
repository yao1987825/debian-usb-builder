---
name: lan-triage
description: 分层定位局域网/上网故障 —— 断网、上不了网、网速慢、频繁掉线、某些网站打不开、打印机连不上。Use when the user reports 网络故障/断网/上不了网/网速很慢/掉线/局域网不通/网页打不开, or asks why the network is down, slow, or flaky.
---

# 网络故障分层定位

**核心纪律: 不要跳步, 不要凭经验下结论。** 按物理层 → 链路层 → 网络层 → DNS → 应用层
的顺序逐层排除, 每层都要有实测证据。用户说"断网"时, 九成问题在前两层就能定位。

## 第 0 步: 跑一次全量体检

```bash
net probe                # 局域网深度检测(丢包/MTU/IP冲突/环路/DNS/无线/代理)
net doctor               # 本机网络栈自检(NM/IP/路由/DNS/代理)
```

`net probe` 的输出**每一条结论后面都跟着修复命令**, 从上往下看, 第一个红色/黄色项
通常就是根因。不要跳过它自己重新猜。

## 第 1 步: 物理层 —— 网线/网卡/WiFi 信号

```bash
ip -br link                 # 网卡是不是 UP
ethtool <网卡> | grep -E "Link detected|Speed"   # 有没有物理链路
iw dev <无线网卡> link       # WiFi 信号/频段/速率
```

- `Link detected: no` → 网线/水晶头/交换机端口问题, 软件层怎么改都没用。
- WiFi 信号 < -70dBm → 靠近路由器或改连 5G。

## 第 2 步: 链路层 —— 网段对不对、ARP 通不通

```bash
ip -4 addr show <网卡>       # 有没有拿到地址
ip route show                # 有没有默认路由, 网关是谁
ip neigh show                # 邻居表里能看到谁
ping -c3 <网关>              # 网关通不通
```

**网段不一致是最常见的"局域网内部设定问题"**: 路由器把 192.168.1.0/24 改成了
192.168.6.0/24, 而某台设备还停在旧网段, 于是"能连路由器但连不上别的设备"。
用 `net topo` 看当前网段, 再和用户预期/历史记录对照。

## 第 3 步: 网络层 —— 通到外网了吗

```bash
traceroute -n 1.1.1.1        # 断在哪一跳
mtr -n -c 10 223.5.5.5       # 逐跳丢包
ping -c20 <网关>             # 丢包率与抖动
```

- 网关通、外面不通 → 路由器/运营商/上游问题, 不是本机设置。
- 某跳开始 100% 丢包 → 问题在那一跳设备。

## 第 4 步: MTU(隐性杀手)

```bash
ping -M do -s 1472 223.5.5.5   # 大包发不出去 = MTU 被卡
```

VPN/PPPoE 隧道会把 MTU 卡在 1400 左右, 表现是"网页能开但下载卡死"。

## 第 5 步: DNS

```bash
resolvectl status
getent hosts www.baidu.com
dig @223.5.5.5 www.baidu.com
```

- 名字解析不了但 IP 能 ping 通 → 纯 DNS 问题, `net fix --dns 223.5.5.5`。
- 不同 DNS 返回不同 IP → 分流或劫持。

## 第 6 步: 应用层

```bash
curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' https://www.baidu.com
```

## 汇报格式

```
结论: <哪一层、什么问题>
证据: <跑过的命令 + 关键输出>
处理: <可直接粘贴执行的命令, 按顺序>
```
一次只给**一个**根因和一条路, 别把八条建议一次性甩给用户。

相关技能: [[lan-repair]] 执行修复, [[lan-topology]] 看拓扑, [[wifi-triage]] 无线专项,
[[lan-capture]] 抓包。
