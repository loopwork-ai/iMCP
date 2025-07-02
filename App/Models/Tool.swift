import Foundation
import JSONSchema
import MCP
import Ontology

public struct Tool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    let annotations: MCP.Tool.Annotations
    private let implementation: @Sendable ([String: Value]) async throws -> Value

    public init<T: Encodable & Sendable>(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCP.Tool.Annotations,
        implementation: @Sendable @escaping ([String: Value]) async throws -> T
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.implementation = { input in
            let result = try await implementation(input)

            let encoder = JSONEncoder()
            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                TimeZone.current
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

            let data = try encoder.encode(result)

            let decoder = JSONDecoder()
            return try decoder.decode(Value.self, from: data)
        }
    }

    public func callAsFunction(_ input: [String: Value]) async throws -> Value {
        try await implementation(input)
    }
}
