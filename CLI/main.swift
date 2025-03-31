import Logging
import MCP
import Network
import SystemPackage

import struct Foundation.Data
import class Foundation.RunLoop

// Set up signal handling for Ctrl+C
signal(SIGINT) { _ in
    log.critical("Received interrupt signal, shutting down...")
    exit(0)
}

var log = Logger(label: "com.loopwork.iMCP.server") { StreamLogHandler.standardError(label: $0) }
log.logLevel = .debug

// Network setup
let serviceType = "_mcp._tcp"
let parameters = NWParameters.tcp
parameters.acceptLocalOnly = true
parameters.includePeerToPeer = false

if let tcpOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
    tcpOptions.version = .v4
}

// Create browser at top level
let browser = NWBrowser(
    for: .bonjour(type: serviceType, domain: nil),
    using: parameters
)
log.info("Created Bonjour browser for service type: \(serviceType)")

actor ConnectionState {
    private var hasResumed = false

    func checkAndSetResumed() -> Bool {
        if !hasResumed {
            hasResumed = true
            return true
        }
        return false
    }
}

/// An actor that provides a configurable proxy between standard I/O and network connections
actor StdioProxy {
    // Connection configuration
    private let endpoint: NWEndpoint
    private let parameters: NWParameters
    private let stdinBufferSize: Int
    private let networkBufferSize: Int

    // Connection state
    private var connection: NWConnection?
    private var isRunning = false

    /// Creates a new StdioProxy with the specified network configuration
    /// - Parameters:
    ///   - endpoint: The network endpoint to connect to
    ///   - parameters: Network connection parameters
    ///   - stdinBufferSize: Buffer size for reading from stdin (default: 4096)
    ///   - networkBufferSize: Buffer size for reading from network (default: 4096)
    init(
        endpoint: NWEndpoint,
        parameters: NWParameters = .tcp,
        stdinBufferSize: Int = 4096,
        networkBufferSize: Int = 4096
    ) {
        self.endpoint = endpoint
        self.parameters = parameters
        self.stdinBufferSize = stdinBufferSize
        self.networkBufferSize = networkBufferSize
    }

    /// Starts the proxy
    func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Create the connection
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        // Start the connection
        connection.start(queue: .main)

        // Set up state monitoring for the entire lifetime of the connection
        connection.stateUpdateHandler = { state in
            Task { [weak self] in
                await self?.handleConnectionState(state, continuation: nil)
            }
        }

        // Wait for the connection to become ready
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Swift.Error>) in
            connection.stateUpdateHandler = { state in
                Task { [weak self] in
                    await self?.handleConnectionState(state, continuation: continuation)
                }
            }
        }

        // Create a structured concurrency task group for handling I/O
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Add task for handling stdin to network
            group.addTask { [stdinBufferSize] in
                do {
                    try await self.handleStdinToNetwork(bufferSize: stdinBufferSize)
                } catch {
                    log.error("Stdin handler failed: \(error)")
                    throw error
                }
            }

            // Add task for handling network to stdout
            group.addTask { [networkBufferSize] in
                do {
                    try await self.handleNetworkToStdout(bufferSize: networkBufferSize)
                } catch {
                    log.error("Network handler failed: \(error)")
                    throw error
                }
            }

            // Wait for any task to complete (or fail)
            try await group.next()
            log.debug("A task completed, cancelling remaining tasks")

            // If we get here, one of the tasks completed or failed
            // Cancel all remaining tasks
            group.cancelAll()

            // Stop the proxy
            await self.stop()
        }
    }

    /// Stops the proxy and cleans up resources
    func stop() async {
        isRunning = false
        connection?.cancel()
        connection = nil
    }

    /// Handles connection state changes
    private func handleConnectionState(
        _ state: NWConnection.State, continuation: CheckedContinuation<Void, Swift.Error>?
    ) async {
        switch state {
        case .ready:
            log.debug("Connection established to \(endpoint)")
            continuation?.resume()
        case .failed(let error):
            log.debug("Connection failed: \(error)")
            if let continuation = continuation {
                continuation.resume(throwing: error)
            }
            await stop()
        case .cancelled:
            log.debug("Connection cancelled")
            if let continuation = continuation {
                continuation.resume(throwing: CancellationError())
            }
            await stop()
        case .waiting(let error):
            log.debug("Connection waiting: \(error)")
        case .preparing:
            log.debug("Connection preparing...")
        case .setup:
            log.debug("Connection setup...")
        @unknown default:
            log.debug("Unknown connection state")
        }
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw Error.transportError(Errno.badFileDescriptor)
        }
    }

    /// Handles forwarding data from stdin to the network
    private func handleStdinToNetwork(bufferSize: Int) async throws {
        let stdin = FileDescriptor.standardInput
        try setNonBlocking(fileDescriptor: stdin)

        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()
        var consecutiveWouldBlockCount = 0
        let maxConsecutiveWouldBlocks = 1000  // After this many consecutive would-blocks, we'll timeout

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                log.debug("Connection no longer active, stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                log.debug(
                    "Connection state changed to \(connection.state), stopping stdin handler")
                throw StdioProxyError.connectionClosed
            }

            do {
                // Read data from stdin using SystemPackage approach
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try stdin.read(into: UnsafeMutableRawBufferPointer(pointer))
                }

                if bytesRead == 0 {
                    // EOF reached
                    log.debug("EOF reached on stdin, stopping stdin handler")
                    break
                }

                if bytesRead > 0 {
                    // Reset the would-block counter when we successfully read data
                    consecutiveWouldBlockCount = 0

                    // Append the read bytes to pending data
                    pendingData.append(contentsOf: buffer[0..<bytesRead])

                    // Check if the data is only whitespace
                    let isOnlyWhitespace = pendingData.allSatisfy {
                        let char = Character(UnicodeScalar($0))
                        return char.isWhitespace || char.isNewline
                    }

                    // Only send if we have non-whitespace content
                    if !isOnlyWhitespace && !pendingData.isEmpty {
                        // Send data to the network connection
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<Void, Swift.Error>) in
                            connection.send(
                                content: pendingData,
                                completion: .contentProcessed { error in
                                    if let error = error {
                                        continuation.resume(throwing: error)
                                    } else {
                                        continuation.resume()
                                    }
                                })
                        }

                        log.debug("Sent \(pendingData.count) bytes to network")
                    } else if isOnlyWhitespace && !pendingData.isEmpty {
                        log.trace("Skipping send of \(pendingData.count) whitespace-only bytes")
                    }

                    // Clear pending data after processing
                    pendingData.removeAll(keepingCapacity: true)
                }
            } catch {
                if let posixError = error as? Errno, posixError == .wouldBlock {
                    // Would block, yield to other tasks
                    consecutiveWouldBlockCount += 1

                    // Check if we've exceeded the timeout threshold
                    if consecutiveWouldBlockCount > maxConsecutiveWouldBlocks {
                        log.warning(
                            "Stdin read timed out after \(maxConsecutiveWouldBlocks) consecutive would-blocks"
                        )
                        // Instead of breaking, throw a special error that indicates we need to reconnect
                        throw StdioProxyError.stdinTimeout
                    }

                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }

                log.error("Error in stdin handler: \(error)")
                throw error
            }
        }

        log.debug("Stdin handler task completed")
    }

    /// Handles forwarding data from the network to stdout
    private func handleNetworkToStdout(bufferSize: Int) async throws {
        let stdout = FileDescriptor.standardOutput
        var consecutiveEmptyReads = 0
        let maxConsecutiveEmptyReads = 100  // After this many consecutive empty reads, we'll check connection state

        while true {
            // Check connection state at the beginning of each loop iteration
            guard isRunning, let connection = self.connection else {
                log.debug("Connection no longer active, stopping network handler")
                throw StdioProxyError.connectionClosed
            }

            // Also check connection state
            if connection.state != .ready && connection.state != .preparing {
                log.debug(
                    "Connection state changed to \(connection.state), stopping network handler")
                throw StdioProxyError.connectionClosed
            }

            do {
                // Check connection state periodically if we're getting consecutive empty reads
                if consecutiveEmptyReads > 0
                    && consecutiveEmptyReads % maxConsecutiveEmptyReads == 0
                {
                    // If we've had too many empty reads, consider it a timeout
                    if consecutiveEmptyReads > maxConsecutiveEmptyReads * 10 {
                        log.warning(
                            "Network read timed out after \(consecutiveEmptyReads) consecutive empty reads"
                        )
                        throw StdioProxyError.networkTimeout
                    }
                }

                // Receive data from the network connection with timeout
                let receiveTask = Task {
                    try await withCheckedThrowingContinuation {
                        (continuation: CheckedContinuation<Data, Swift.Error>) in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: bufferSize) {
                            data, _, isComplete, error in
                            if let error = error {
                                continuation.resume(throwing: error)
                                return
                            }

                            if let data = data {
                                continuation.resume(returning: data)
                            } else if isComplete {
                                log.debug("Network connection complete")
                                continuation.resume(throwing: StdioProxyError.connectionClosed)
                            } else {
                                continuation.resume(returning: Data())
                            }
                        }
                    }
                }

                // Add a timeout for the receive operation
                let timeoutTask = Task {
                    try await Task.sleep(for: .seconds(5))
                    receiveTask.cancel()
                    return Data()
                }

                // Wait for either the receive task or the timeout
                let data: Data
                do {
                    data = try await receiveTask.value
                    timeoutTask.cancel()
                } catch is CancellationError {
                    // Receive was cancelled by timeout
                    consecutiveEmptyReads += 10  // Accelerate the empty read counter
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                }

                if data.isEmpty {
                    // No data available, yield to other tasks
                    consecutiveEmptyReads += 1
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } else {
                    // Reset counter when we get data
                    consecutiveEmptyReads = 0

                    log.debug("Received \(data.count) bytes from network")
                }

                // Write data to stdout using SystemPackage approach
                // Handle partial writes by writing all data in chunks if necessary
                var remainingData = data
                while !remainingData.isEmpty {
                    try remainingData.withUnsafeBytes { buffer in
                        let bytesWritten = try stdout.write(UnsafeRawBufferPointer(buffer))
                        if bytesWritten < buffer.count {
                            log.debug("Partial write: \(bytesWritten) of \(buffer.count) bytes")
                            // Remove the bytes that were written
                            remainingData = remainingData.dropFirst(bytesWritten)
                        } else {
                            // All bytes were written
                            remainingData.removeAll()
                        }
                    }

                    // If we still have data to write, give a small delay to allow the system to process
                    if !remainingData.isEmpty {
                        try await Task.sleep(for: .milliseconds(1))
                    }
                }
            } catch let error as NWError where error.errorCode == 96 {
                // Handle "No message available on STREAM" error
                log.debug("Network read yielded no data, waiting...")
                consecutiveEmptyReads += 1
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                // Check if the connection was cancelled or closed
                if let nwError = error as? NWError,
                    nwError.errorCode == 57  // Socket is not connected
                        || nwError.errorCode == 54  // Connection reset by peer
                {
                    log.debug("Connection closed by peer: \(error)")
                    throw StdioProxyError.connectionClosed
                }

                if error is StdioProxyError {
                    throw error
                }

                log.error("Error in network handler: \(error)")
                throw error
            }
        }
    }
}

// Define custom errors for the StdioProxy
enum StdioProxyError: Swift.Error {
    case stdinTimeout
    case networkTimeout
    case connectionClosed
}

// Update the main task to handle reconnection
Task {
    do {
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            // Add Bonjour connection task
            taskGroup.addTask {
                while true {
                    do {
                        log.info("Starting Bonjour service discovery...")

                        // Find and connect to iMCP app
                        let endpoint: NWEndpoint = try await withCheckedThrowingContinuation {
                            continuation in
                            let connectionState = ConnectionState()

                            browser.stateUpdateHandler = { state in
                                log.debug("Browser state changed: \(state)")
                                if case .failed(let error) = state {
                                    log.error("Browser failed: \(error)")
                                    Task {
                                        if await connectionState.checkAndSetResumed() {
                                            continuation.resume(throwing: error)
                                        }
                                    }
                                }
                            }

                            browser.browseResultsChangedHandler = { results, changes in
                                log.debug("Found \(results.count) Bonjour services")
                                if let endpoint = results.first?.endpoint {
                                    Task {
                                        if await connectionState.checkAndSetResumed() {
                                            log.info("Selected endpoint: \(endpoint)")
                                            continuation.resume(returning: endpoint)
                                        }
                                    }
                                }
                            }

                            log.debug("Starting Bonjour browser...")
                            browser.start(queue: .main)
                        }

                        log.info("Creating connection to endpoint...")

                        // Create the proxy
                        let proxy = StdioProxy(
                            endpoint: endpoint,
                            parameters: parameters,
                            stdinBufferSize: 8192,
                            networkBufferSize: 8192
                        )

                        do {
                            // Start the proxy
                            try await proxy.start()
                        } catch StdioProxyError.stdinTimeout {
                            log.info("Stdin timed out, will reconnect...")
                            // Short delay before reconnecting
                            try await Task.sleep(for: .seconds(1))
                            continue
                        } catch StdioProxyError.networkTimeout {
                            log.info("Network timed out, will reconnect...")
                            try await Task.sleep(for: .seconds(1))
                            continue
                        } catch StdioProxyError.connectionClosed {
                            log.critical("Connection closed, terminating...")
                            exit(EXIT_FAILURE)
                        }
                    } catch {
                        log.error("Connection error: \(error)")
                        log.info("Will retry connection in 5 seconds...")
                        try await Task.sleep(for: .seconds(5))
                    }
                }
            }

            // Wait for any task to complete (or throw)
            try await taskGroup.next()
        }
    } catch {
        log.critical(
            "Server error: \(error)",
            metadata: [
                "error_description": .string(error.localizedDescription)
            ])
        exit(EXIT_FAILURE)
    }
}

// Keep the program running
RunLoop.main.run()
