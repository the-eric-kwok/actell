# mcp-pairing-auth 规格增量

## ADDED Requirements

### Requirement: 访问密码
MCP 服务 SHALL 使用一个共享访问密码作为唯一凭据：App 在首次开启 MCP 模式时自动生成 18 字符随机密码，字符集混合英文字母、数字与符号（仅限 HTTP 头与 JSON 安全的 ASCII 符号），采用拒绝采样避免取模偏差（约 112 位熵），且 MUST 同时包含三类字符。设置页 SHALL 支持查看（默认遮蔽）、复制到剪贴板与重新生成，也允许用户改为自定义密码（最短 16 字符）。持有当前密码的客户端可随时连接并调用工具，不设时效、不设连接次数限制。重新生成或修改密码 MUST 使旧密码立即失效，并按停止语义终止使用旧密码的在途动作与会话。

#### Scenario: 客户端凭密码连接
- **WHEN** 客户端携带当前访问密码发起请求
- **THEN** 请求通过鉴权进入 JSON-RPC 分发，无需任何配对或本机确认步骤

#### Scenario: 重新生成密码
- **WHEN** 用户在设置页重新生成访问密码
- **THEN** 旧密码立即失效，使用旧密码的会话与在途动作按停止语义终止，设置页展示新密码

### Requirement: 每请求鉴权
每个 MCP HTTP 请求 MUST 携带 `Authorization: Bearer <访问密码>`。校验 SHALL 使用常数时间比较。无凭据或凭据错误的请求 MUST 返回 401 且不进入 JSON-RPC 分发。连续鉴权失败 SHALL 触发限速（同一来源地址连续失败 10 次后延迟响应），减缓在线暴力猜测。

#### Scenario: 凭据错误
- **WHEN** 客户端携带错误密码请求
- **THEN** 服务返回 401，不执行任何设备动作

### Requirement: 密码存储
访问密码 SHALL 存储于 Keychain（ThisDeviceOnly，不随备份迁移到其他设备）。设置页查看密码明文 MUST 需要用户主动展开（默认遮蔽）。

#### Scenario: App 重装
- **WHEN** App 被删除重装
- **THEN** 旧密码不再可用，首次开启 MCP 模式时生成新密码

### Requirement: 监听范围约束
服务 SHALL 仅监听用户选定的接口范围：默认局域网（Wi-Fi/USB 共享）接口，可选仅 VPN 回环地址。MUST NOT 监听蜂窝公网接口。监听地址与端口 SHALL 在设置中可见，供客户端配置。

#### Scenario: 默认监听
- **WHEN** 用户开启 MCP 模式且未修改监听范围
- **THEN** 服务仅在局域网接口监听，蜂窝接口上的连接被拒绝
