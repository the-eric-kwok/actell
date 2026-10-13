import SwiftUI
import UIKit
import UserNotifications

struct MCPSettingsView: View {
    @ObservedObject var mcp: MCPServerModel
    @AppStorage(MCPServerModel.portDefaultsKey) private var port = Int(MCPServerModel.defaultPort)
    @AppStorage(MCPServerModel.loopbackOnlyDefaultsKey) private var loopbackOnly = false
    @State private var revealPassword = false
    @State private var password = ""
    @State private var storedPassword = ""
    @State private var feedback = ""
    @State private var confirmRotate = false
    @State private var confirmClearDevices = false
    private var passwordEdited: Bool { password != storedPassword }
    var body: some View {
        Form {
            Section {
                Toggle("启用 MCP 服务", isOn: Binding(get: { mcp.running }, set: { enabled in
                    if enabled {
                        // Device prompts while backgrounded need notification permission.
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        mcp.start()
                    } else { mcp.disable() }
                    loadPassword()
                })).accessibilityIdentifier("mcpServerEnabled")
                Text(mcp.statusText).font(.caption).foregroundStyle(.secondary)
            } footer: {
                Text("通过明文 HTTP 在局域网提供 screenshot/tap 等设备工具，持密码者即拥有完整控制权。服务经 Bonjour（_mcp._tcp）向整个局域网广播。仅在可信局域网使用；App 退后台后依赖后台保活，系统挂起或锁屏会中断服务。")
            }
            Section {
                HStack {
                    Text("端口")
                    TextField("27300", value: $port, format: .number.grouping(.never))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .onChange(of: port) { _, value in
                            guard (1024...65535).contains(value) else { return }
                            if mcp.running { mcp.stop(reason: "端口已修改"); mcp.start() }
                        }
                }
                Toggle("仅本机回环（不广播）", isOn: $loopbackOnly)
                    .onChange(of: loopbackOnly) { _, _ in
                        if mcp.running { mcp.stop(reason: "监听范围已修改"); mcp.start() }
                    }
            } header: {
                Text("监听")
            } footer: {
                Text("默认监听局域网接口（蜂窝一律拒绝）。开启仅本机回环后，只有本机 127.0.0.1 可连接，适合 VPN 回环等本机客户端场景。")
            }
            Section("访问密码") {
                HStack {
                    Group {
                        if revealPassword {
                            TextField("访问密码（≥16 字符）", text: $password)
                                .font(.system(.footnote, design: .monospaced))
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                        } else {
                            SecureField("访问密码（≥16 字符）", text: $password)
                        }
                    }
                    .onSubmit(savePassword)
                    .accessibilityIdentifier("mcpPasswordField")
                    Button { revealPassword.toggle() } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }.buttonStyle(.borderless).accessibilityLabel(revealPassword ? "隐藏密码" : "显示密码")
                }
                if passwordEdited {
                    Button("保存修改后的密码", action: savePassword)
                        .accessibilityIdentifier("mcpSavePassword")
                }
                Button("复制到剪贴板") {
                    UIPasteboard.general.string = password
                    feedback = "已复制访问密码；请尽快粘贴到客户端配置"
                }.accessibilityIdentifier("mcpCopyPassword")
                Button("重新生成密码", role: .destructive) { confirmRotate = true }
                    .accessibilityIdentifier("mcpRotatePassword")
                if !feedback.isEmpty { Text(feedback).font(.caption).foregroundStyle(.secondary) }
            }
            Section {
                if mcp.trustedDevices.isEmpty {
                    Text("暂无已授权设备").foregroundStyle(.secondary)
                }
                ForEach(mcp.trustedDevices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.identity).font(.system(.footnote, design: .monospaced))
                            Text("最后连接：\(device.lastConnected.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mcp.activeIdentities.contains(device.identity) {
                            Image(systemName: "link").foregroundStyle(.green)
                                .accessibilityLabel("当前在线")
                        }
                    }
                    .swipeActions { Button("移除", role: .destructive) { mcp.removeDevice(device.identity) } }
                }
                Button("清空已授权设备", role: .destructive) { confirmClearDevices = true }
                    .disabled(mcp.trustedDevices.isEmpty)
                    .accessibilityIdentifier("mcpClearTrustedDevices")
            } header: {
                Text("已授权设备")
            } footer: {
                Text("在线设备显示连接图标。左滑移除即撤销授权，该设备现有会话立即终止，下次连接需重新确认。7 天未连接的设备自动移除；重新生成或修改密码会清空列表。")
            }
        }
        .navigationTitle("MCP 服务")
        .onAppear { loadPassword() }
        .confirmationDialog("重新生成访问密码？所有客户端的旧密码立即失效，在途动作将终止。", isPresented: $confirmRotate, titleVisibility: .visible) {
            Button("重新生成", role: .destructive) {
                do { _ = try mcp.rotatePassword(); loadPassword(); feedback = "密码已重新生成" }
                catch { feedback = error.localizedDescription }
            }
        }
        .confirmationDialog("清空全部已授权设备？它们的会话将立即终止，下次连接需重新确认。", isPresented: $confirmClearDevices, titleVisibility: .visible) {
            Button("清空", role: .destructive) { mcp.clearTrustedDevices() }
        }
    }
    private func loadPassword() {
        storedPassword = (try? MCPAccessCredential.load()).flatMap { $0 } ?? ""
        password = storedPassword
    }
    private func savePassword() {
        guard passwordEdited else { return }
        do {
            try mcp.setCustomPassword(password)
            loadPassword()
            feedback = "密码已更新；旧凭据全部失效"
        } catch {
            feedback = error.localizedDescription
        }
    }
}

/// Global presenter so device-trust prompts surface wherever the user is.
struct MCPApprovalPresenter: ViewModifier {
    @ObservedObject var mcp: MCPServerModel
    func body(content: Content) -> some View {
        content.alert("新设备请求连接 MCP", isPresented: Binding(
            get: { mcp.deviceRequest != nil },
            set: { shown in if !shown, let id = mcp.deviceRequest?.identity { mcp.resolveDevice(id, approved: false) } })) {
            Button("拒绝", role: .cancel) { if let id = mcp.deviceRequest?.identity { mcp.resolveDevice(id, approved: false) } }
            Button("允许") { if let id = mcp.deviceRequest?.identity { mcp.resolveDevice(id, approved: true) } }
        } message: {
            Text("\(mcp.deviceRequest?.identity ?? "")\(mcp.deviceRequest?.clientVersion.map { "\n客户端版本 \($0)" } ?? "")\n允许后该设备可凭访问密码控制本机。60 秒内未处理视为拒绝。")
        }
    }
}
