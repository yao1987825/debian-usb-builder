"""netkit —— 局域网诊断工具箱(装在 /usr/local/lib/netkit)。

模块划分:
  util      通用小工具(跑命令/颜色/落盘)
  netinfo   本机网络身份 + 历史快照(网段变化检测)
  devclass  MAC/端口/mDNS 线索 -> 设备类型
  discover  局域网设备发现(ARP/ping/mDNS/LLDP 多源合并)
  topo      拓扑组装 + ASCII 树渲染
  probe     局域网问题深度检测
  cli       子命令分发
"""

__version__ = "1.0.0"
