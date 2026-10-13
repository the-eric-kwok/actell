## 1. 协议与传输基础

- [x] 1.1 新建 `ios-app/PhoneAgent/MCP/` 目录；实现 JSON-RPC 2.0 编解码（请求/响应/错误对象、批处理拒绝、id 匹配）
- [x] 1.2 实现 `ToolParameters` → JSON Schema 转换，从现有 `DeviceTool` 生成 `tools/list` 条目（排除 `finish`）
- [x] 1.3 用 NWListener 实现最小 HTTP/1.1 POST 端点：请求体 1 MiB 上限、仅接受 POST + application/json、异常输入断连
- [x] 1.4 实现 MCP 握手与会话管理：`initialize`/`notifications/initialized`/`ping`、`Mcp-Session-Id` 发放与归属校验、DELETE 结束会话、空闲 10 分钟超时作废（失效会话请求返回 404）；未握手调用工具返回协议错误

## 2. 鉴权与发现

- [x] 2.1 实现访问密码生成与管理：首次开启自动生成（≥128 位熵可抄写形式）、支持重新生成与自定义（≥16 字符）、Keychain（ThisDeviceOnly）存储
- [x] 2.2 实现每请求 Bearer 鉴权中间层：常数时间比较，无/错凭据返回 401 不进入 JSON-RPC 分发；同源连续失败 10 次后延迟响应
- [x] 2.3 实现密码变更的即时失效：旧凭据会话与在途动作按停止语义终止
- [x] 2.4 实现监听范围约束与端口配置：默认局域网接口（拒绝蜂窝），可选仅 VPN 回环地址；端口默认 27300 可改，改后重启监听；设置页展示监听地址与端口
- [x] 2.5 实现 Bonjour 注册/注销（`_mcp._tcp`，实例名含设备名，端口变更同步更新）；Info.plist 声明 NSBonjourServices 与本地网络用途描述

## 3. 会话与执行衔接

- [x] 3.1 实现 MCP 会话对象：每会话一个 `ActionCoordinator`，lifecycle 接 RunLifecycleCoordinator 参与整回合互斥；默认密码即授权（复用桥接层 task-scoped 授权原语），不提供逐动作确认模式
- [x] 3.2 实现 `tools/call` 分发到 `ActionCoordinator.execute`：截图返回 MCP image content + image_id/宽高元数据文本；工具失败映射为 `isError: true` 结果
- [x] 3.3 实现忙碌策略：输入类调用遇本机任务或他客户端在途输入立即返回「设备忙」工具错误；截图在空隙放行
- [x] 3.4 实现会话停止与断连等价处理：终止在途动作不重发、释放桥接资源、后续输入调用失败
- [x] 3.5 接入后台保活路径与挂起恢复语义：挂起期间在途动作按「结果未知、不重发」返回

## 4. 设置 UI

- [x] 4.1 设置页新增 MCP 模式开关、监听状态（地址/端口/错误）、访问密码管理（默认遮蔽、展开查看、重新生成、自定义）
- [x] 4.2 风险提示文案（明文 HTTP、密码即完整控制权、Bonjour 广播、后台局限）
- [x] 4.3 当前 MCP 会话状态展示与一键停止入口

## 5. 测试

- [x] 5.1 协议层回环测试：握手、tools/list 与 DeviceTool 定义一致性、未知方法/非法参数/超大请求体/异常输入
- [x] 5.2 鉴权测试：正确/错误/缺失凭据、401 路径、常数时间比较、失败限速、密码重新生成后旧凭据失效与在途动作停止
- [x] 5.3 会话语义测试：输入互斥报忙、无截图参照拒绝坐标动作、不重放不确定结果、停止释放
- [x] 5.4 全部新测试纳入默认 target；现有核心覆盖未删减。按用户要求改在 iPhone 17 Pro 真机验证：MCPServerTests 13 用例全过；全量 436 例中 6 个附件类失败为真机 /var 符号链接路径校验的既有环境问题，与本改动无关

## 6. 工程与文档

- [x] 6.1 运行 `python3 ios-app/scripts/generate_xcode_project.py` 纳入新源码目录；无签名 iPhoneOS build 通过
- [x] 6.2 更新中英 README：移除「MCP 未实现」表述，补充开启方式、客户端配置示例（Claude Code mcpServers 配置）、安全与后台局限说明
- [x] 6.3 更新 `docs/PROJECT-TODOS.md` 记录验收证据；真机验证一次外部 MCP 客户端完成截图 + 实际 tap

## 7. 设备信任与使用说明

- [x] 7.1 监听层解析来源 IP，异步反查 `.local` 主机名（限时，失败回落 IP）
- [x] 7.2 实现信任表存储：标识＋最后连接时间，排除备份 JSON，7 天自动删除，改密码清空
- [x] 7.3 `initialize` 接入设备确认：未信任挂起弹窗、60 秒超时 403、同标识合并、后台本地通知；移除设备终止其会话
- [x] 7.4 设置页信任设备列表（按最后连接倒序、逐条移除）与全局确认弹窗
- [x] 7.5 改写 `ios-operation` 为 MCP instructions（≤2000 字符）并在 `initialize` 返回
- [x] 7.6 测试：标识规则、同意／拒绝／超时、合并、移除、7 天清理、改密码清空、instructions 长度；真机构建安装

## 8. 迭代修正（真机验收发现）

- [x] 8.1 修复反查超时失效（getnameinfo 不可取消导致 initialize 卡死）与连接槽位耗尽；连接加空闲超时
- [x] 8.2 MCP 服务开关持久化，App 重启后自动恢复
- [x] 8.3 设置页合并为单个「已授权设备」列表（在线设备显示连接图标），移除「授权模式」perAction 选项
