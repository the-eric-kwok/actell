## Context

Actell 当前只有 App 内置模型 agent 能调用设备控制工具。工具执行后端收敛在 `ios-app/PhoneAgent/Agent/DeviceTools.swift` 的 `ActionCoordinator`（校验、授权、互斥、不重放、停止释放均已实现并有测试覆盖）。内嵌 SwiftAgentKit 快照刻意删除了上游 MCP 模块。设备控制链路（VPN 回环 / ESP32 NCM + CoreDevice）与本设计正交：MCP 只是新增一个调用方。

约束：
- iOS App 环境，没有 stdio 场景，MCP 只能走网络传输。
- 项目规则：核心协议、单次授权、会话隔离、不重放、停止释放的测试覆盖必须保留并对新路径补齐。
- App 可能被系统挂起；后台保活依赖现有音频/PiP 路径。

## Goals / Non-Goals

**Goals:**
- 局域网内任意标准 MCP 客户端可发现工具并驱动这台 iPhone（截图 + 输入）。
- 外部调用与本机 agent 共享同一执行后端与安全语义，不出现第二套授权/校验逻辑。
- 共享访问密码鉴权，默认不信任局域网内任何不持密码的主机。

**Non-Goals:**
- 不做 TLS/HTTPS（第一版明文 HTTP + 访问密码；见风险节）。
- 不做 MCP resources/prompts/sampling，只实现 tools。
- 不做公网/蜂窝可达、多设备中继（Bonjour 仅限本局域网发现）。
- 不改变设备控制链路本身（RemotePairing 身份、CoreDevice 后端不动）。

## Decisions

### D1 协议实现：手写精简 MCP 层，不引入 swift-sdk
只需 `initialize`/`tools/list`/`tools/call`/`ping` 四个方法加 Streamable HTTP POST 语义，协议面约数百行。官方 `modelcontextprotocol/swift-sdk` 功能全但带来版本跟踪与平台最低版本耦合；SwiftAgentKit 上游 MCP 模块偏客户端侧。手写可完全掌控错误映射与安全策略，测试也在本仓库内闭环。
替代方案：引入 swift-sdk（被否：依赖面大于收益）；捡回 SwiftAgentKit 上游 MCP 模块（被否：主要是 client 实现）。

### D2 传输：Network framework 的 NWListener + 最小 HTTP/1.1 处理
Streamable HTTP 的最小子集：客户端 POST JSON-RPC 到单一端点，响应为 `application/json`（不实现 SSE 流式响应与 GET 通道，第一版无服务端推送需求）。不引入第三方 HTTP 服务器库。
替代方案：SSE 旧传输（已被规范弃用）；WebSocket（非标准 MCP 传输）。

### D3 工具定义单一来源
`tools/list` 的 schema 由现有 `DeviceTool.parameters`/`description` 序列化生成（ToolParameters → JSON Schema 转换函数），保证与内置 agent 永远一致。`finish` 不暴露。

### D4 执行后端：每个 MCP 会话一个 ActionCoordinator
MCP 会话（持密码客户端经 initialize 建立的一段活动期）创建自己的 `ActionCoordinator` 实例，approve 回调接到现有授权 UI，lifecycle 接到现有 RunLifecycleCoordinator 排队机制——「一个 MCP 会话」等价于「一个 agent 回合主体」参与互斥。截图帧缓存天然做到会话内 image_id 关联。

### D5 鉴权：共享访问密码
无配对流程、无逐客户端 token。App 首次开启 MCP 模式时自动生成 18 字符随机访问密码（字母+数字+符号混合、拒绝采样去取模偏差，约 112 位熵），设置页可查看（默认遮蔽）、复制到剪贴板、重新生成或改为自定义密码（≥16 字符）。客户端每请求以 `Authorization: Bearer <密码>` 携带，常数时间比较，错误返回 401；同源连续失败 10 次后延迟响应以减缓在线猜测。密码存 Keychain（ThisDeviceOnly）。重新生成/修改即吊销全部旧凭据，在途动作按停止语义终止。不做 TLS 的前提下监听范围约束（拒绝蜂窝接口）降低暴露面。
替代方案：配对码换逐客户端 token（被否：多一轮配对交互，单用户场景收益小）；自签证书 TLS + 指纹校验（推迟：客户端配置成本高，列入后续迭代）。

### D8 授权模型：密码即授权
持有当前访问密码的客户端可随时连接并执行输入动作，无会话接受弹窗、无时效限制。设置密码/抄写密码到客户端的那一刻是唯一的人工授权决策点；撤销手段为重新生成密码、停止当前会话或关闭 MCP 模式。`Mcp-Session-Id` 会话仅承担协议记账与截图 image_id 归属边界，不承载授权语义；空闲超时仅用于资源回收。不提供逐动作确认模式；默认即密码全授权。桥接层的 task-scoped 授权原语（authorizeTaskInput 等）复用为密码模式的底层实现。

### D6 忙碌策略：输入类立即报忙，不排队
外部客户端有自己的重试/规划循环，排队会造成「动作在用户不知情的未来时刻突然执行」。所以输入类调用遇互斥直接返回 isError 工具结果；截图在空隙允许。

### D7 端口：默认 27300，可在设置中修改
默认值避开常见服务端口，无 IANA 冲突即可；修改后重启监听生效，设置页始终展示当前实际监听地址与端口。

### D9 实现 Bonjour 广播
开启 MCP 模式时通过 NWListener 注册 Bonjour 服务（`_mcp._tcp`，实例名含设备名），客户端可自动发现地址与端口；关闭模式即注销。Info.plist 声明 NSBonjourServices 与本地网络用途描述。代价是向全网段宣告服务存在，由访问密码鉴权兜底；设置页保留手动地址展示作为发现失败时的后备。

### D10 设备信任与使用说明
密码是基础门禁，其上叠加逐设备信任表：标识为「`.local` 主机名-客户端名」或「IP-客户端名」，首次 `initialize` 挂起并本机弹窗（60 秒超时按拒绝、拒绝不记住、同标识合并、后台发本地通知）。信任表只存标识与最后连接时间，排除备份的 JSON 文件，7 天未连接自动删除，改密码清空。标识可伪造，仅作防误连与管理。`instructions` 由 `ios-operation` 技能改写为不超过 2000 字符的 MCP 版，因 Claude Code 静默截断超过 2048 字符的说明；两份文本互相注明位置以便同步。

## Risks / Trade-offs

- [明文 HTTP 下访问密码可被同网段嗅探，而密码即完整控制权] → 默认仅局域网/VPN 回环监听、UI 明示风险、一键重新生成密码与一键停止；TLS 列为后续迭代。
- [Bonjour 广播向全网段宣告服务存在，扩大被探测面] → 鉴权在前（无/错凭据一律 401）、同源连续失败限速。
- [密码无时效、无逐次确认，泄露后可长期静默控制设备] → 设置页常驻当前会话状态展示、重新生成密码即时生效并终止在途动作；文档明确建议只在可信局域网使用。
- [App 被系统挂起导致服务静默失联] → 复用音频/PiP 保活；设置页明示局限；挂起期间在途动作按「结果未知、不重发」处理。
- [手写 HTTP 解析的健壮性] → 限制请求体 1 MiB、并发 4、仅接受 POST+JSON，异常输入直接断连；回环模糊输入测试纳入默认 target。
- [工程文件再生成遗漏新目录] → 任务清单中明确 `generate_xcode_project.py` 步骤。

## Migration Plan

纯新增功能，默认关闭，无数据迁移。回滚 = 关闭开关或移除 MCP 目录后重新生成工程。README 中「MCP 未实现」表述在验收通过后更新。

## Open Questions

（无——端口、task-scoped 授权形态、mDNS 三项已在 D7–D9 决定。）
