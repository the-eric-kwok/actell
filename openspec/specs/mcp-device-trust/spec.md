# mcp-device-trust Specification

## Purpose
TBD - created by archiving change add-lan-mcp-server. Update Purpose after archive.
## Requirements
### Requirement: 设备标识
服务 SHALL 以「主机名-客户端名」标识一台设备：主机名由来源 IP 反查得到且以 `.local` 结尾时使用（统一小写），否则以「IP-客户端名」标识。客户端名取自 `initialize` 请求的 `clientInfo.name`，缺失时记为 `unknown`。标识由对方自报或局域网解析得到，可被持有密码者伪造，仅用于防误连与管理，MUST NOT 替代访问密码门禁。

#### Scenario: 可反查主机名
- **WHEN** 来源 IP 反查得到 `macbook.local`，`clientInfo.name` 为 `claude-code`
- **THEN** 设备标识为 `macbook.local-claude-code`

#### Scenario: 无法反查主机名
- **WHEN** 来源 IP 为 `192.168.1.20` 且反查失败，`clientInfo.name` 为 `claude-code`
- **THEN** 设备标识为 `192.168.1.20-claude-code`

### Requirement: 首次连接本机确认
通过密码鉴权、但设备标识不在信任表中的 `initialize` 请求 MUST 挂起，并在本机弹出授权确认（显示设备标识与客户端版本）。用户同意后写入信任表并返回会话；拒绝或 60 秒内未处理返回 403，且不记住拒绝。同一设备标识等待期间的重复 `initialize` MUST 合并到同一个确认，不重复弹窗。App 不在前台时 SHALL 发送本地通知提示返回确认。

#### Scenario: 同意授权
- **WHEN** 未信任设备发起 `initialize`，用户在弹窗选择允许
- **THEN** 请求返回会话 ID，设备写入信任表

#### Scenario: 拒绝或超时
- **WHEN** 用户拒绝，或 60 秒内未处理
- **THEN** 请求返回 403，信任表不变；该设备下次连接再次弹窗

#### Scenario: 已信任设备
- **WHEN** 信任表中的设备再次发起 `initialize`
- **THEN** 不弹窗直接返回会话，并更新其最后连接时间

### Requirement: 信任表管理与持久化
信任表 SHALL 平铺保存每台设备的标识与最后连接时间，不记录会话明细、调用记录或来源 IP 历史，持久化于排除备份的本地文件。设置页 SHALL 以单个列表展示全部条目（按最后连接时间倒序，在线设备显示连接图标），支持逐条移除与一键清空（清空会终止全部设备会话）；移除即撤销信任，该设备的现有会话立即终止，在途动作按停止语义处理。最后连接时间超过 7 天的条目 MUST 自动删除。重新生成或修改访问密码 MUST 清空信任表并终止全部会话。

#### Scenario: 移除设备
- **WHEN** 用户在设置页移除某设备
- **THEN** 该设备会话立即失效（后续请求 404），下次 `initialize` 重新弹窗

#### Scenario: 7 天未连接
- **WHEN** 某设备最后连接时间距今超过 7 天
- **THEN** 该条目被删除，再次连接需重新确认

#### Scenario: 重新生成密码
- **WHEN** 用户重新生成或修改访问密码
- **THEN** 信任表清空，全部会话终止

