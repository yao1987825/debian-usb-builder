---
name: lan-repair
description: 执行局域网/上网的安全修复 —— DHCP 续租、清 ARP 缓存、重启 NetworkManager、切 DNS、重建 resolv.conf。Use when the user says 修复网络/重置网络/重新获取IP/换个DNS/清缓存/网络修复, or asks to fix, reset, renew, or repair the network configuration.
---

# 网络修复(安全可逆)

这台机器上 **sudo 对 user 免密**, 所以修复动作可以直接执行 —— 但仍然要**先诊断再动手**,
一次只改一处, 改完立刻复检。

## 官方修复入口

```bash
net fix --renew            # 重新申请 DHCP 地址(换网段后最常用)
net fix --flush-arp        # 清 ARP/邻居表(网关换了、老设备"看不见"了)
net fix --dns 223.5.5.5   # 把 DNS 换成指定服务器
net fix --restart-nm      # 重启 NetworkManager
net fix --rebuild-resolv  # 重建 /etc/resolv.conf 软链接
```

可以叠加: `net fix --renew --flush-arp`。

修完**必须复检**:

```bash
net probe
```

## 手工修复(上面覆盖不到时)

```bash
# 1) 路由器把网段改了, 需要手动固定到新网段
sudo nmcli con show
sudo nmcli con mod "Wired connection 1" ipv4.method manual ipv4.addresses 192.168.6.50/24 ipv4.gateway 192.168.6.1
sudo nmcli con up "Wired connection 1"

# 2) DHCP 拿不到地址, 手动指定一个空闲地址(先 ping 确认没人用)
ping -c2 192.168.6.50
sudo ip addr add 192.168.6.50/24 dev <网卡>
sudo ip route add default via 192.168.6.1
sudo ip neigh flush all

# 3) DNS 整个坏了, 直接写死
sudo sh -c 'printf "nameserver 223.5.5.5\nnameserver 119.29.29.29\n" > /etc/resolv.conf'
sudo systemctl restart systemd-resolved

# 4) NetworkManager 卡死
sudo systemctl restart NetworkManager
nmcli general status

# 5) WiFi 掉了
wifi scan && wifi connect "SSID" 密码
```

## 顺序很重要

1. 先 `net probe` 找到是哪一层坏了;
2. 只改那一层(别顺手把 DNS 也换了, 换了分不清是谁修好的);
3. 改完 `net probe` 复检;
4. 修不好就升级手段: 抓包([[lan-capture]])或换静态 IP。

## 不要做的事

- 不要 `rm -rf` 用户的下载目录/歌曲分区/配置;
- 不要动 `music-shell` 相关的 `/etc/asound.conf`(那是音频直通配置, 跟网络无关);
- 不要删除 `/etc/NetworkManager/system-connections/` 里的连接, 用户要靠它上无线网;
- 没有用户确认前, 不要重启机器或改无线网密码。
