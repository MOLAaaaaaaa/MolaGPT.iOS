# MolaGPT iOS

<p align="left">
  <a href="https://chatgpt.wljay.cn/v2">MolaGPT Web</a>
  ·
  <a href="https://linux.do/">LINUX DO 论坛</a>
  ·
  <a href="https://github.com/MOLAaaaaaaa/MolaGPT.iOS/releases">下载</a>
  ·
  <a href="https://github.com/MOLAaaaaaaa/MolaGPT.Mobile">MolaGPT Android</a>
  ·
  <a href="https://github.com/MOLAaaaaaaa/MolaGPT.Desktop">MolaGPT Desktop</a>
</p>

MolaGPT iOS 是 [MolaGPT](https://chatgpt.wljay.cn/v2) 的原生 iOS 客户端，用 Swift 6 和 SwiftUI 编写，功能与 [Android 版](https://github.com/MOLAaaaaaaa/MolaGPT.Mobile)对齐，界面按 Apple 人机界面指南（HIG）重新设计，没有照搬 Material。除了连接 MolaGPT 账户，也可以接入 OpenAI 兼容、OpenAI Responses、Anthropic 和 Gemini 等自定义模型服务，在手机上管理对话、工具、记忆、角色、世界书和图像工作台，还能远程继续桌面端对话、控制 Agent 会话。

> [!WARNING]
> 项目处于早期阶段（0.1.0），遇到问题欢迎提 Issue。

## 安装

从 [Releases](https://github.com/MOLAaaaaaaa/MolaGPT.iOS/releases) 下载 IPA，用 AltStore、SideStore、TrollStore 等工具自签安装。需要 iOS 17 及以上。

## 功能特性

### 对话体验

- 原生 SwiftUI 界面，支持浅色、深色和跟随系统。
- 流式 Markdown 渲染，支持代码高亮、表格、LaTeX 公式（基于 SwiftMath 原生绘制）、Mermaid、图片、思考过程和工具调用状态。
- 可视化回答（自定义模型）：函数图像、图表、可排序表格、指标卡原生绘制；整页网页以卡片显示，在隔离沙盒中运行。
- 联网搜索过程合并展示，回答里用来源角标标注引用。
- 可按对话调节推理强度，自动识别各服务商的推理参数。
- 编辑已发送消息并在分支间切换；重新生成保留历史版本。
- 每条回答显示 Token 用量、首字延迟、生成速度和花费。
- 上下文用量指示，超出窗口时自动压缩历史。
- 附件支持拍照、相册和文件。
- 后台流式任务与完成通知；生成进度显示在**实时活动 / 灵动岛**上。
- **分享扩展**：从其他 App 把文字、链接、图片和文件分享给 MolaGPT。

### 模型与工具

- MolaGPT 账号登录、模型发现、额度展示和云端会话增量同步。
- BYOK 自定义模型服务，兼容 OpenAI 兼容接口、OpenAI Responses、Anthropic 和 Gemini 原生格式，密钥存于系统钥匙串。
- 自动获取模型列表，为模型标注推理、工具和视觉能力；可一键获取模型价格（models.dev），也可自定义。
- 支持 DuckDuckGo、Tavily、Exa 联网搜索和远程 MCP 服务器，可按工具启用或停用。
- 图像生成工具，以及 Agent Skills 导入与按需读取。

### 记忆与回答处理

- 本地记忆：模型可在对话中保存或遗忘信息，并在新对话中使用。
- 回忆对话：需要时检索本地历史对话作为参考。
- 回答后处理：生成结束后按正则规则替换内容，代码和公式保持原样。
- MolaGPT 账户支持个性化记忆、用户画像和回答风格管理。

### 角色扮演

- 内置通用、写作、代码、翻译和学术角色，可新建、复制和编辑；系统提示词支持变量。
- 导入 SillyTavern 角色卡（PNG、JSON、charX，V1 至 V3 规范），保留人设、场景、开场白和对话示例。
- 世界书按关键词触发设定片段，支持常驻条目、正则关键词、扫描深度、Token 预算和递归扫描。

### 画图工作台

- 原生图像生成与编辑，兼容 OpenAI Images、Chat Completions 图像回退和 Gemini 图像响应。
- 支持参考图、多轮修改、批量生成和画图历史。

### 远程控制

- 在手机上继续桌面端 MolaGPT 对话，查看历史与实时回答、发送消息或停止回答。
- 同一账号直接配对电脑，或使用桌面端配对码配对。
- 开启桌面端 Agent 桥接后，可以查看和控制 Claude Code 与 Codex 会话，处理工具审批。

## 项目结构

```text
.
├── Package.swift          SwiftPM 清单（模块分层见下）
├── xtool.yml              xtool 打包配置：主 App + 两个扩展
├── Xcode/project.yml      XcodeGen 工程定义
├── Sources/
│   ├── MolaCore/          纯 Foundation：领域模型、各服务商协议、SSE、工具循环、Markdown、角色卡与世界书（可在 Linux 上编译和测试）
│   ├── MolaStorage/       SQLite3 与钥匙串持久化
│   ├── MolaGPT/           SwiftUI App：对话、会话、设置、账户、记忆、角色、技能、画图、远程控制
│   ├── MolaActivity/      实时活动共享数据结构
│   ├── MolaWidgets/       实时活动 / 灵动岛扩展
│   └── MolaShare/         分享扩展
├── Tests/MolaCoreTests/   MolaCore 单元测试
├── Resources/             Info.plist、entitlements 与图标
└── scripts/               构建、测试与打包脚本
```

模块依赖单向：`MolaCore` ← `MolaStorage` ← `MolaGPT`。

## 构建

需要 iOS 17 SDK 和 Swift 6 工具链。可以用 Xcode 构建，也可以用 [xtool](https://github.com/xtool-org/xtool) 在 Linux 或 macOS 上交叉编译。

### Xcode

直接打开仓库附带的工程：

```bash
open Xcode/MolaGPT.xcodeproj
```

工程由 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 根据 `Xcode/project.yml` 生成。增删文件或修改配置后请编辑 `project.yml` 并重新生成，不要直接改工程文件：

```bash
cd Xcode && xcodegen generate
```

打开后为 `MolaGPTApp`、`MolaShareExtension`、`MolaWidgetsExtension` 三个 target 选择自己的签名 Team，再运行 `MolaGPT` scheme。如果更换了 Bundle ID 前缀，App Group（`Resources/*.entitlements`）也要同步修改。

### xtool

需要 [swiftly](https://github.com/swiftlang/swiftly) 安装的 Swift 工具链、xtool，以及按 xtool 文档准备好的 iOS SDK。

Debug 构建：

```bash
./scripts/build.sh
```

打包自签用 IPA（输出到 `dist/`）：

```bash
./scripts/package-ipa.sh
```

### 单元测试

`MolaCore` 是纯 Foundation 模块，可以在 Linux 上直接测试：

```bash
./scripts/test-core.sh
```

在 Xcode 中也可以对 `MolaGPT` scheme 运行测试（⌘U）。

## 致谢

- 画图工作台源自 [DisaWdcba](https://github.com/DisaWdcba) 为 Android 版贡献的原生抹茶画图工作台，并参考了 [SimpleAIPainting](https://github.com/DisaWdcba/SimpleAIPainting)。
- Agent 控制的桥接与中继架构参考了 [Remodex](https://github.com/Emanuele-web04/remodex) 的设计。
- 数学公式渲染使用 [SwiftMath](https://github.com/mgriebling/SwiftMath)。

欢迎通过 Issue 或 Pull Request 反馈问题和参与改进。
