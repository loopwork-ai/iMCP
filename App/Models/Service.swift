import MCP

public typealias ResourceContent = MCP.Resource.Content

@preconcurrency
protocol Service {
    var isActivated: Bool { get async }
    func activate() async throws

    @ResourceTemplateBuilder var resourceTemplates: [ResourceTemplate] { get }
    @ToolBuilder var tools: [Tool] { get }
}

// MARK: - Default Implementation

extension Service {
    // MARK: - Activation

    var isActivated: Bool {
        get async {
            return true
        }
    }

    func activate() async throws {}

    // MARK: - Resources

    var resourceTemplates: [ResourceTemplate] { [] }

    func read(resource uri: String) async throws -> ResourceContent? {
        for template in resourceTemplates {
            if let content = try await template.read(uri: uri) {
                return content
            }
        }
        return nil
    }

    // MARK: - Tools

    var tools: [Tool] { [] }

    func call(tool name: String, with arguments: [String: Value]) async throws -> Value? {
        for tool in tools where tool.name == name {
            return try await tool.callAsFunction(arguments)
        }

        return nil
    }
}

// MARK: - Builders

@resultBuilder
struct ToolBuilder {
    static func buildBlock(_ tools: Tool...) -> [Tool] {
        tools
    }
}

@resultBuilder
struct ResourceTemplateBuilder {
    static func buildBlock(_ templates: ResourceTemplate...) -> [ResourceTemplate] {
        templates
    }
}
