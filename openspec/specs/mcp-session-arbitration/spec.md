# mcp-session-arbitration Specification

## Purpose
TBD - created by archiving change add-lan-mcp-server. Update Purpose after archive.
## Requirements
### Requirement: 与本机 agent 任务互斥
同一时刻 SHALL 只有一个控制主体（本机 agent 回合或一个 MCP 客户端会话）可以执行设备输入动作。MCP 工具调用 MUST 复用现有按整回合排队的机制：本机 agent 任务运行期间，MCP 的输入类调用排队或返回「设备忙」错误（含当前状态说明）；反之亦然。`screenshot` 与 `wait` 等观察类调用的互斥策略 SHALL 与输入类分开定义：截图在他方执行间隙允许，输入一律互斥。

#### Scenario: 本机任务运行中 MCP 请求 tap
- **WHEN** 本机 agent 回合正在执行时 MCP 客户端调用 tap
- **THEN** 该调用返回「设备忙」工具错误（isError: true），不排队执行输入

#### Scenario: 多个 MCP 客户端争用
- **WHEN** 客户端 A 有在途输入动作时客户端 B 调用输入工具
- **THEN** B 收到「设备忙」错误；A 的动作不受影响

### Requirement: 授权与不重放语义保持
持有效访问密码且设备在信任表中即视为已授权：MCP 输入动作无需逐次本机确认，底层复用桥接层的 task-scoped 授权原语。MCP 不提供逐动作确认模式。坐标动作 MUST 绑定最近一次由同客户端会话获取的截图（image_id 关联），截图失效或设备会话变化时动作拒绝执行。结果不确定的动作 MUST NOT 自动重发，错误消息须明确说明「结果未知；未自动重发」。

#### Scenario: 默认模式下的 MCP tap
- **WHEN** 持有效密码的客户端在默认授权模式下调用 tap
- **THEN** 动作不弹本机确认直接进入执行，仍受截图参照绑定与互斥约束

#### Scenario: 无截图参照的坐标动作
- **WHEN** MCP 客户端未先调用 screenshot 就调用 tap
- **THEN** 动作被拒绝，提示需要先获取坐标参照画面

### Requirement: 停止与释放
用户 SHALL 能从 App 一键停止当前 MCP 会话：终止在途动作、释放设备桥接资源（与现有停止释放语义一致）、使该会话后续输入调用失败直至客户端重新开始。客户端断开连接 SHALL 等价于会话停止。

#### Scenario: 用户手动停止
- **WHEN** 用户点击停止当前 MCP 会话
- **THEN** 在途动作终止且不重发，媒体/桥接资源释放，客户端收到错误

### Requirement: 后台存活行为明示
MCP 服务在 App 退后台时 SHALL 复用现有后台保活路径（音频/PiP）并在设置中明示其局限：系统挂起、终止或锁屏可能中断服务。服务被系统挂起后恢复时 MUST NOT 自动重放挂起期间未完成的输入动作。

#### Scenario: 后台挂起后恢复
- **WHEN** App 在 MCP 动作在途时被系统挂起随后恢复
- **THEN** 该动作按结果未知处理，不自动重发；客户端收到明确错误

