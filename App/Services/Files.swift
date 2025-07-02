import AppKit
import Foundation
import MCP
import OSLog
import Ontology
import UniformTypeIdentifiers

private let log = Logger.service("files")

final class FilesService: Service {
    static let shared = FilesService()

    var isActivated: Bool {
        get async {
            hasFullDiskAccess()
        }
    }

    func activate() async throws {
        log.debug("Activating Files service")
        if !(await isActivated) {
            await promptForFullDiskAccess()
        }
    }

    var resourceTemplates: [ResourceTemplate] {
        ResourceTemplate(
            name: "file",
            description: "Access file contents and metadata",
            uriTemplate: "file://{path}",
            mimeType: "application/json"
        ) { (uri: String) -> Resource.Content? in
            log.debug("Reading file resource template: \(uri)")

            // Parse and validate the file URI
            guard let fileURL = URL(string: uri.removingPercentEncoding ?? uri),
                fileURL.scheme == "file",
                fileURL.isFileURL
            else {
                throw MCPError.invalidRequest("Invalid file URI: \(uri)")
            }

            log.debug("File path: \(fileURL.path)")

            // Check if the file exists
            guard try fileURL.checkResourceIsReachable() else {
                log.error("File does not exist: \(fileURL.path)")
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadNoSuchFileError,
                    userInfo: [NSLocalizedDescriptionKey: "File does not exist"]
                )
            }

            // Get file attributes and resource values in one go
            let resourceValues = try fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])

            // Check if it's a directory
            if resourceValues.isDirectory == true {
                // For directories, create JSON representation with file metadata
                let jsonString = try directoryJSON(for: fileURL)
                return Resource.Content.text(
                    jsonString, uri: uri, mimeType: "inode/directory+json")
            }

            // Check file size (limit to 100MB)
            if let fileSize = resourceValues.fileSize,
                fileSize > 100_000_000
            {
                throw NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileReadTooLargeError,
                    userInfo: [NSLocalizedDescriptionKey: "File too large to read"]
                )
            }

            // For regular files, get MIME type efficiently
            let mimeType = getMimeType(for: fileURL)

            // Try to read as text first
            if mimeType.hasPrefix("text/")
                || mimeType == "application/json"
                || mimeType == "application/xml"
                || mimeType == "application/x-yaml"
                || mimeType == "application/toml"
            {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    return Resource.Content.text(content, uri: uri, mimeType: mimeType)
                }
            }

            // Fallback to reading as binary
            let data = try Data(contentsOf: fileURL)
            return Resource.Content.binary(data, uri: uri, mimeType: mimeType)

        }
    }

    private func hasFullDiskAccess() -> Bool {
        // Try to access a protected directory that requires Full Disk Access
        let protectedPath = "/Library/Application Support/com.apple.TCC/"
        let fileManager = FileManager.default

        return fileManager.isReadableFile(atPath: protectedPath)
    }

    @MainActor
    private func promptForFullDiskAccess() async {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = """
            iMCP needs Full Disk Access to read files throughout your system.

            1. Click 'Open System Preferences' below
            2. Go to  Privacy & Security → Full Disk Access
            3. Drag iMCP from Finder to the Full Disk Access list
            """
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemPreferences()
            revealAppInFinder()
        }
    }

    private func openSystemPreferences() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    private func revealAppInFinder() {
        guard let appPath = Bundle.main.bundleURL.path as String? else {
            log.error("Could not determine app bundle path")
            return
        }

        NSWorkspace.shared.selectFile(appPath, inFileViewerRootedAtPath: "")
    }
}

// MARK: -

private struct FileInfo: Codable {
    enum Kind: String, Codable {
        case file
        case directory
    }

    let name: String
    let kind: Kind
    let size: Int?
    let modified: String?
}

private func directoryJSON(for url: URL) throws -> String {
    let contents = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        ])
    guard !contents.isEmpty else {
        return "[]"
    }

    guard contents.count < 1024 else {
        throw NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileReadTooLargeError,
            userInfo: [NSLocalizedDescriptionKey: "Directory too large to read"]
        )
    }

    let dateFormatter = ISO8601DateFormatter()

    let files = contents.compactMap { fileURL -> FileInfo? in
        guard
            let resourceValues = try? fileURL.resourceValues(forKeys: [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            ])
        else {
            return nil
        }

        let kind: FileInfo.Kind = resourceValues.isDirectory == true ? .directory : .file
        let size = resourceValues.fileSize
        let modified = resourceValues.contentModificationDate.map {
            dateFormatter.string(from: $0)
        }

        return FileInfo(
            name: fileURL.lastPathComponent,
            kind: kind,
            size: size,
            modified: modified
        )
    }.sorted { $0.name < $1.name }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    let jsonData = try encoder.encode(files)
    return String(data: jsonData, encoding: .utf8) ?? "[]"
}

// MARK: -

private func getMimeType(for url: URL) -> String {
    if let utType = UTType(filenameExtension: url.pathExtension),
        let mimeType = utType.preferredMIMEType
    {
        return mimeType
    }

    return "application/octet-stream"
}
