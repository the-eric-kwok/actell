import Foundation
import SwiftAgentKit

/// Derives the MCP tools/list payload from the existing DeviceTool definitions,
/// keeping one source of truth with the built-in agent. `finish` is excluded:
/// external clients end their own turns.
enum MCPToolCatalog {
    static let names = ["screenshot", "tap", "drag", "home", "list_apps", "launch_app", "type_text", "wait"]
    static let inputNames: Set<String> = ["tap", "drag", "home", "launch_app", "type_text"]

    static func listPayload() -> [[String: Any]] {
        // description/parameters never touch the coordinator; an inert one is safe.
        let inert = ActionCoordinator(bridge: UnavailableBridge(), limits: AgentLimits(),
                                      approve: { _ in false }, onImage: { _, _ in }, onReceipt: { _ in })
        return names.map { name in
            let tool = DeviceTool(name: name, coordinator: inert)
            return ["name": name, "description": tool.description, "inputSchema": schema(tool.parameters)]
        }
    }

    private static func schema(_ parameters: ToolParameters) -> [String: Any] {
        var properties: [String: Any] = [:]
        for (key, property) in parameters.properties {
            var value: [String: Any] = ["type": property.type, "description": property.description]
            if let items = property.itemsType { value["items"] = ["type": items] }
            properties[key] = value
        }
        var result: [String: Any] = ["type": "object", "properties": properties]
        if !parameters.required.isEmpty { result["required"] = parameters.required.sorted() }
        return result
    }
}
