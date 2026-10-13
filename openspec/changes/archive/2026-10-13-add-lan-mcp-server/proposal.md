# 新增通用局域网 MCP 服务模式

## Why

Actell 已具备完整的设备控制工具层（screenshot/tap/drag/home/launch_app/type_text/wait 等）与授权、排队、不重放语义，但只有 App 内置模型 agent 能调用。README 中「向其他 agent 暴露标准 MCP 接口」的目标一直处于规划未实现状态。实现通用局域网 MCP 服务后，Mac/PC 上的任意 MCP 客户端（Claude Code、其他 agent 框架）都能把这台 iPhone 当作受控设备使用，不依赖 App 内置的模型供应商配置。

## What Changes

- 新增「MCP 服务模式」：App 内通过 Network framework 启动一个 Streamable HTTP 的 MCP server（JSON-RPC 2.0：`initialize`、`tools/list`、`tools/call`），把现有 `DeviceTool` 工具集暴露给局域网客户端，并以 Bonjour 广播供自动发现。
- 新增访问密码鉴权：App 生成（或用户自定义）一个共享访问密码，持有密码的客户端可无限制、不限时随时连接；每请求携带 Bearer 凭据，错误一律 401。
- MCP 工具调用复用现有 `ActionCoordinator` 的输入互斥、不重放不确定结果和停止释放语义；默认密码即授权，不提供逐次确认模式。
- 设置页新增 MCP 模式开关与状态展示（监听地址/端口、访问密码管理、当前会话）；MCP 会话与本机 agent 任务按整回合互斥。
- 截图结果以 MCP image content（base64 JPEG）返回，附 image_id 与像素尺寸元数据。
- 中英 README 与相关文档同步更新，移除「MCP 未实现」表述。

## Capabilities

### New Capabilities

- `mcp-server`: 局域网 MCP 服务的传输、协议握手、工具列表与调用分发、错误映射。
- `mcp-pairing-auth`: 访问密码的生成/修改/重置、每请求鉴权与监听范围约束。
- `mcp-device-trust`: 密码门禁之上的逐设备信任：首次连接本机确认、平铺信任表（标识＋最后连接时间）持久化、7 天未连接自动删除、改密码清空。
- `mcp-session-arbitration`: MCP 调用与本机 agent 任务之间的互斥排队、授权衔接、停止与释放、后台存活行为。

### Modified Capabilities

（无——现有能力尚无 openspec 规格文件；设备工具层的行为不变，仅新增调用方。）

## Impact

- 新增源码目录（预计 `ios-app/PhoneAgent/MCP/`）：HTTP 监听、Bonjour 注册、JSON-RPC 编解码、会话管理、访问密码存储（Keychain）。
- 复用并小幅扩展：`Agent/DeviceTools.swift`（ActionCoordinator 作为 MCP 工具执行后端）、`SessionCommands/`（排队与互斥）、设置 UI、后台保活路径（音频/PiP）。
- 依赖决策：手写精简 MCP 协议层或引入 `modelcontextprotocol/swift-sdk`（内嵌 SwiftAgentKit 快照已删除上游 MCP 模块，不可直接复用）。
- 测试：新增回环网络协议测试与鉴权/互斥/停止释放覆盖，纳入默认 target；按项目规则不得删减现有核心覆盖。
- 工程文件：新增源码后需重新生成 Xcode 工程（`generate_xcode_project.py`）。
