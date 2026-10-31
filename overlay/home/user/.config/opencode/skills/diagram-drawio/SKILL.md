---
name: diagram-drawio
description: 用 draw.io(drawio)MCP 画架构图/流程图/时序图, 并读取或修改已有的 .drawio 文件。Use when the user asks 画图/架构图/流程图/时序图/拓扑图/示意图/draw.io/mxGraph/把这段代码画成图, or asks to draw a diagram, produce an architecture/flowchart/sequence diagram, or edit an existing .drawio file.
---

# draw.io 画图(MCP)

这台机器上装了 **draw.io MCP 服务**(`next-ai-drawio-mcp`), opencode 已连上,
工具在 `mcp__drawio__*` 下。

## 一条铁律

**不要自己手写 mxCell XML。** 这个 MCP 的价值就在于它知道图形库的名字
(AWS/Azure/GCP/K8s/Cisco 的真实图标名)、连接线规则、层级布局。
自己拼 XML 出来的图, 样式基本都不对。

正确流程:

```
start_session  →  拿到绘制指南(drawing guide) + 预览页 URL
   ↓
create_new_diagram / edit_diagram   ← 用指南里的规则画
   ↓
export_diagram                      ← 存成 .drawio / .png / .svg
```

## 常用工具

| 工具 | 用途 |
| --- | --- |
| `start_session` | **第一步**。开预览页, 返回绘制指南; 带 `session_id` 可以接着上次的图 |
| `create_new_diagram` | 从 mxCell XML 画一张新图 |
| `edit_diagram` | 按 id 增/改/删单元格(要么全成功要么全不改) |
| `get_diagram` | 拿当前图里的 XML(用户在浏览器里的手改也能读回来) |
| `get_selection` | 用户在预览里选中的图形 |
| `screenshot_diagram` | 页面截图, 让 AI 自己检查有没有重叠 |
| `load_diagram` / `export_diagram` | 打开 `.drawio`/`.drawio.svg`; 存成 `.drawio`/`.png`/`.svg` |
| `restore_version` | 回到之前的版本(最近 20 个版本都留着) |
| `list_saved_diagrams` | 以前保存过的图 |
| `get_drawing_guide` / `get_shape_library` | 绘制规则; 某个图形库的图标样式(如 `aws4`) |
| `list_pages` / `add_page` / `rename_page` / `delete_page` | 多页图 |

## 改已有文件时

```
load_diagram(路径)  →  edit_diagram(...)  →  export_diagram(同一个路径)
```

**先 load 再改、最后导回同一个路径**, 别直接覆盖源文件。

## 图存在哪

- `~/.next-ai-drawio/<session-id>.drawio`(带最近 20 个版本, 最新的 50 张图保留);
- 自己写的规则放 `~/.next-ai-drawio/instructions.md`(比如"一律用极简风格"),
  每次调用都会带上, 不用重启。

## 这台机器上的两个限制(要知道, 别硬试)

1. **没有图形界面浏览器**: 镜像里没装浏览器, 所以
   - 预览页打不开 → `get_selection` / `screenshot_diagram` 用不了;
   - **PNG/SVG 导出走不通**(导出靠预览页渲染), 但 **`.drawio` 文件完全正常** ✓
   - 想看图/要 PNG: `sudo apt-get install -y chromium`(装完重启 opencode 才有预览),
     或者把生成的 `.drawio` 文件拿到有 draw.io 的机器上打开。
2. **中文界面**: 预览/编辑器语言已固定为中文(`DRAWIO_LANG=zh`)。

## 汇报给用户时

- 说清楚图存到了哪个文件(给绝对路径);
- 有预览页的话把 URL 给用户, 让他自己在浏览器里看/手改;
- 提醒"余票/价格这类实时数据"不在图的职责范围内(那是 train/travel 的活)。
