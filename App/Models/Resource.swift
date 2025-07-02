import Foundation
import MCP
import Ontology

struct ResourceTemplate: Sendable {
    let name: String
    let description: String?
    let uriTemplate: String
    let mimeType: String?
    private let reader: @Sendable (String) async throws -> ResourceContent?

    init(
        name: String,
        description: String? = nil,
        uriTemplate: String,
        mimeType: String? = nil,
        reader: @Sendable @escaping (String) async throws -> ResourceContent?
    ) {
        self.name = name
        self.description = description
        self.uriTemplate = uriTemplate
        self.mimeType = mimeType
        self.reader = reader
    }

    func read(uri: String) async throws -> ResourceContent? {
        try await reader(uri)
    }
}
