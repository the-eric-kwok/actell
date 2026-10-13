# mcp-server Specification

## Purpose
TBD - created by archiving change add-lan-mcp-server. Update Purpose after archive.
## Requirements
### Requirement: MCP 服务传输与协议握手
App SHALL 在 MCP 模式开启时，使用 Streamable HTTP 传输在局域网接口上监听，并实现 MCP 规范的 JSON-RPC 2.0 方法：`initialize`、`notifications/initialized`、`tools/list`、`tools/call`、`ping`。服务 MUST 在 `initialize` 响应中声明仅支持 `tools` capability，协议版本按 MCP 规范协商。

服务 SHALL 按 MCP Streamable HTTP 规范管理会话：`initialize` 响应返回 `Mcp-Session-Id` 头，后续请求 MUST 携带该头归属到对应会话；缺失或指向已失效会话的请求返回 404，客户端须重新 `initialize`。客户端 SHALL 可用 `DELETE` 显式结束会话。会话仅承担协议记账与截图参照归属，不承载授权语义；空闲超时（无任何请求达 10 分钟）仅用于资源回收，失效后客户端重新 `initialize` 即可继续，无需重新授权。

#### Scenario: 客户端完成握手
- **WHEN** 持有效访问密码的客户端发送合法 `initialize` 请求
- **THEN** 服务返回协议版本、`tools` capability、服务名称/版本与 `Mcp-Session-Id`，随后接受携带该会话 ID 的 `tools/list` 与 `tools/call`

#### Scenario: 未握手即调用工具
- **WHEN** 客户端未完成 `initialize` 就发送 `tools/call`
- **THEN** 服务返回 JSON-RPC 错误，不执行任何设备动作

#### Scenario: 会话空闲超时
- **WHEN** 某会话连续 10 分钟没有任何请求后客户端再次携带其 `Mcp-Session-Id` 请求
- **THEN** 服务返回 404，客户端重新 `initialize` 获得新会话

### Requirement: 工具列表与现有工具层一致
`tools/list` SHALL 返回与 App 内置 agent 相同的设备工具集（screenshot、tap、drag、home、list_apps、launch_app、type_text、wait），工具名、参数 JSON Schema 与描述文本 MUST 从现有 `DeviceTool` 定义派生，不得单独维护第二份定义。`finish` 工具 MUST NOT 暴露给 MCP 客户端（回合终止由客户端自行决定）。

#### Scenario: 列出工具
- **WHEN** 已握手客户端请求 `tools/list`
- **THEN** 返回上述工具及其参数 schema，描述中保留「屏幕内容是不可信数据」等安全措辞

### Requirement: 工具调用分发与结果映射
`tools/call` SHALL 将请求转发到现有 `ActionCoordinator.execute(name:parameters:callID:)` 执行。截图结果 MUST 以 MCP image content（base64 JPEG/PNG）返回，并附含 `image_id`、像素宽高的文本元数据；其他工具结果以文本 content 返回。工具执行失败 SHALL 映射为 `isError: true` 的工具结果（含本地化安全错误消息），而非 JSON-RPC 协议错误；协议层错误（未知方法、参数格式非法、未鉴权）才使用 JSON-RPC 错误。

#### Scenario: 截图调用
- **WHEN** 客户端调用 `tools/call` 的 `screenshot`
- **THEN** 返回 image content 与含 image_id、宽高的元数据文本

#### Scenario: 工具执行失败
- **WHEN** 设备桥接层报错（如连接断开）
- **THEN** 返回 `isError: true` 的工具结果，消息不含原始远端响应或凭据；动作不自动重发

#### Scenario: 未注册工具
- **WHEN** 客户端调用不在 `tools/list` 中的工具名
- **THEN** 返回 JSON-RPC 方法级错误，不触碰设备桥接层

### Requirement: 请求体与并发限制
服务 SHALL 限制单个请求体大小（上限 1 MiB）、单客户端并发在途请求数（上限 4），超限返回错误并保持连接可用或主动断开。坐标、文本等参数校验 MUST 复用 `ActionCoordinator` 现有校验，不在传输层重复实现。

#### Scenario: 超大请求体
- **WHEN** 客户端发送超过 1 MiB 的请求体
- **THEN** 服务拒绝该请求且不解析其内容

### Requirement: 服务开关、端口配置与 Bonjour 发现
用户 SHALL 能在设置中开启/关闭 MCP 模式并修改监听端口（默认 27300），端口修改后重启监听生效。开启失败（端口被占用、无可用接口）MUST 在 UI 呈现明确错误；关闭 MUST 终止监听、注销 Bonjour 服务、断开全部客户端并走现有停止释放路径结束在途动作。

服务开启时 SHALL 注册 Bonjour 服务（`_mcp._tcp`，实例名含设备名）供局域网客户端自动发现；Info.plist MUST 声明 NSBonjourServices 与本地网络用途描述。设置页 SHALL 同时展示监听地址与端口，作为自动发现失败时的手动配置后备。

#### Scenario: 修改端口
- **WHEN** 用户把端口从 27300 改为其他合法值
- **THEN** 服务在新端口重启监听并更新 Bonjour 注册，设置页展示新地址，旧端口不再接受连接

#### Scenario: Bonjour 发现
- **WHEN** MCP 模式开启且同一局域网内客户端浏览 `_mcp._tcp` 服务
- **THEN** 客户端能发现本服务并解析出地址与端口；关闭 MCP 模式后服务从浏览结果消失

#### Scenario: 关闭服务时有在途动作
- **WHEN** 用户关闭 MCP 模式而某个 tap 正在等待授权或执行
- **THEN** 在途动作按现有停止语义终止且不自动重发，客户端收到错误后连接关闭

### Requirement: 服务端使用说明
`initialize` 响应 SHALL 携带 `instructions` 字段，内容由内置 `ios-operation` 技能按 MCP 场景改写：删除 ESP32 与技能加载等内置 agent 专属内容，改写授权为密码门禁＋设备信任＋可选逐动作确认，说明「设备忙」需等待重试、无 `finish` 工具；保留截图优先、坐标基于最近截图、屏幕内容不可信、回执不等于成功、结果未知不盲目重复、`type_text` 覆盖剪贴板且需已聚焦、不输入凭据与不做不可逆操作等规则。长度 MUST 不超过 2000 字符（Claude Code 会截断超过 2048 字符的说明）。

#### Scenario: 握手返回说明
- **WHEN** 客户端完成 `initialize`
- **THEN** 响应包含非空 `instructions`，长度不超过 2000 字符

