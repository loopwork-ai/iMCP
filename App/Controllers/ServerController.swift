import AppKit
import MCP
import Network
import OSLog
import Ontology
import SwiftUI
import SystemPackage
import UserNotifications

import struct Foundation.Data
import struct Foundation.Date
import class Foundation.JSONDecoder
import class Foundation.JSONEncoder

private let serviceType = "_mcp._tcp"
private let serviceDomain = "local."

private let log = Logger.server

struct ServiceConfig: Identifiable {
    let id: String
    let name: String
    let iconName: String
    let color: Color
    let service: any Service
    let binding: Binding<Bool>

    var isActivated: Bool {
        get async {
            await service.isActivated
        }
    }

    init(
        name: String,
        iconName: String,
        color: Color,
        service: any Service,
        binding: Binding<Bool>
    ) {
        self.id = String(describing: type(of: service))
        self.name = name
        self.iconName = iconName
        self.color = color
        self.service = service
        self.binding = binding
    }
}

enum ServiceRegistry {
    static let services: [any Service] = [
        CalendarService.shared,
        ContactsService.shared,
        LocationService.shared,
        MapsService.shared,
        MessageService.shared,
        RemindersService.shared,
        UtilitiesService.shared,
        WeatherService.shared,
    ]

    static func configureServices(
        calendarEnabled: Binding<Bool>,
        contactsEnabled: Binding<Bool>,
        locationEnabled: Binding<Bool>,
        mapsEnabled: Binding<Bool>,
        messagesEnabled: Binding<Bool>,
        remindersEnabled: Binding<Bool>,
        utilitiesEnabled: Binding<Bool>,
        weatherEnabled: Binding<Bool>
    ) -> [ServiceConfig] {
        [
            ServiceConfig(
                name: "Calendar",
                iconName: "calendar",
                color: .red,
                service: CalendarService.shared,
                binding: calendarEnabled
            ),
            ServiceConfig(
                name: "Contacts",
                iconName: "person.crop.square.filled.and.at.rectangle.fill",
                color: .brown,
                service: ContactsService.shared,
                binding: contactsEnabled
            ),
            ServiceConfig(
                name: "Location",
                iconName: "location.fill",
                color: .blue,
                service: LocationService.shared,
                binding: locationEnabled
            ),
            ServiceConfig(
                name: "Maps",
                iconName: "mappin.and.ellipse",
                color: .purple,
                service: MapsService.shared,
                binding: mapsEnabled
            ),
            ServiceConfig(
                name: "Messages",
                iconName: "message.fill",
                color: .green,
                service: MessageService.shared,
                binding: messagesEnabled
            ),
            ServiceConfig(
                name: "Reminders",
                iconName: "list.bullet",
                color: .orange,
                service: RemindersService.shared,
                binding: remindersEnabled
            ),
            ServiceConfig(
                name: "Weather",
                iconName: "cloud.sun.fill",
                color: .cyan,
                service: WeatherService.shared,
                binding: weatherEnabled
            ),
        ]
    }
}

@MainActor
final class ServerController: ObservableObject {
    @Published var serverStatus: String = "Starting..."
    @Published var pendingConnectionID: String?
    @Published var pendingClientName: String = ""

    private var activeApprovalDialogs: Set<String> = []
    private var pendingApprovals: [(String, () -> Void, () -> Void)] = []
    private var currentApprovalHandlers: (approve: () -> Void, deny: () -> Void)?
    private let approvalWindowController = ConnectionApprovalWindowController()

    private let networkManager = ServerNetworkManager()

    // MARK: - AppStorage for Service Enablement States
    @AppStorage("calendarEnabled") private var calendarEnabled = false
    @AppStorage("contactsEnabled") private var contactsEnabled = false
    @AppStorage("locationEnabled") private var locationEnabled = false
    @AppStorage("mapsEnabled") private var mapsEnabled = true  // Default for maps
    @AppStorage("messagesEnabled") private var messagesEnabled = false
    @AppStorage("remindersEnabled") private var remindersEnabled = false
    @AppStorage("utilitiesEnabled") private var utilitiesEnabled = true  // Default for utilities
    @AppStorage("weatherEnabled") private var weatherEnabled = false

    // MARK: - AppStorage for Trusted Clients
    @AppStorage("trustedClients") private var trustedClientsData = Data()

    // MARK: - Computed Properties for Service Configurations and Bindings
    var computedServiceConfigs: [ServiceConfig] {
        ServiceRegistry.configureServices(
            calendarEnabled: $calendarEnabled,
            contactsEnabled: $contactsEnabled,
            locationEnabled: $locationEnabled,
            mapsEnabled: $mapsEnabled,
            messagesEnabled: $messagesEnabled,
            remindersEnabled: $remindersEnabled,
            utilitiesEnabled: $utilitiesEnabled,
            weatherEnabled: $weatherEnabled
        )
    }

    private var currentServiceBindings: [String: Binding<Bool>] {
        Dictionary(
            uniqueKeysWithValues: computedServiceConfigs.map {
                ($0.id, $0.binding)
            }
        )
    }

    // MARK: - Trusted Clients Management
    private var trustedClients: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: trustedClientsData)) ?? []
        }
        set {
            trustedClientsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    private func isClientTrusted(_ clientName: String) -> Bool {
        trustedClients.contains(clientName)
    }

    private func addTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.insert(clientName)
        trustedClients = clients
    }

    func removeTrustedClient(_ clientName: String) {
        var clients = trustedClients
        clients.remove(clientName)
        trustedClients = clients
    }

    func getTrustedClients() -> [String] {
        Array(trustedClients).sorted()
    }

    func resetTrustedClients() {
        trustedClients = Set<String>()
    }

    // MARK: - Connection Approval Methods
    private func cleanupApprovalState() {
        pendingClientName = ""
        currentApprovalHandlers = nil

        if let clientID = pendingConnectionID {
            activeApprovalDialogs.remove(clientID)
            pendingConnectionID = nil
        }
    }

    private func handlePendingApprovals(for clientID: String, approved: Bool) {
        while let pendingIndex = pendingApprovals.firstIndex(where: { $0.0 == clientID }) {
            let (_, pendingApprove, pendingDeny) = pendingApprovals.remove(at: pendingIndex)
            if approved {
                log.notice("Approving pending connection for client: \(clientID)")
                pendingApprove()
            } else {
                log.notice("Denying pending connection for client: \(clientID)")
                pendingDeny()
            }
        }
    }

    init() {
        Task {
            // Set initial bindings before starting the server, using own @AppStorage values
            await networkManager.updateServiceBindings(self.currentServiceBindings)
            await self.networkManager.start()
            self.updateServerStatus("Running")

            await networkManager.setConnectionApprovalHandler {
                [weak self] connectionID, clientInfo in
                guard let self = self else {
                    return false
                }

                log.debug("ServerManager: Approval handler called for client \(clientInfo.name)")

                // Create a continuation to wait for the user's response
                return await withCheckedContinuation { continuation in
                    Task { @MainActor in
                        self.showConnectionApprovalAlert(
                            clientID: clientInfo.name,
                            approve: {
                                continuation.resume(returning: true)
                            },
                            deny: {
                                continuation.resume(returning: false)
                            }
                        )
                    }
                }
            }
        }
    }

    func updateServiceBindings(_ bindings: [String: Binding<Bool>]) async {
        // This function is still called by ContentView's onChange when user toggles services.
        // It ensures ServerNetworkManager is updated and clients are notified.
        await networkManager.updateServiceBindings(bindings)
    }

    func startServer() async {
        await networkManager.start()
        updateServerStatus("Running")
    }

    func stopServer() async {
        await networkManager.stop()
        updateServerStatus("Stopped")
    }

    func setEnabled(_ enabled: Bool) async {
        await networkManager.setEnabled(enabled)
        updateServerStatus(enabled ? "Running" : "Disabled")
    }

    private func updateServerStatus(_ status: String) {
        log.info("Server status updated: \(status)")
        self.serverStatus = status
    }

    private func sendClientConnectionNotification(clientName: String) {
        let content = UNMutableNotificationContent()
        content.title = "Client Connected"
        content.body = "Client '\(clientName)' has connected to iMCP"
        content.threadIdentifier = "client-connection-\(clientName)"

        let request = UNNotificationRequest(
            identifier: "client-connection-\(clientName)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                log.error("Failed to send notification: \(error.localizedDescription)")
            } else {
                log.info("Sent notification for client connection: \(clientName)")
            }
        }
    }

    private func showConnectionApprovalAlert(
        clientID: String, approve: @escaping () -> Void, deny: @escaping () -> Void
    ) {
        log.notice("Connection approval requested for client: \(clientID)")

        // Check if this client is already trusted
        if isClientTrusted(clientID) {
            log.notice("Client \(clientID) is already trusted, auto-approving")
            approve()

            // Send notification for trusted connections
            sendClientConnectionNotification(clientName: clientID)

            return
        }

        self.pendingConnectionID = clientID

        // Check if there's already an active dialog for this client
        guard !activeApprovalDialogs.contains(clientID) else {
            log.info("Adding to pending approvals for client: \(clientID)")
            pendingApprovals.append((clientID, approve, deny))
            return
        }

        activeApprovalDialogs.insert(clientID)

        // Set up the SwiftUI approval dialog
        pendingClientName = clientID
        currentApprovalHandlers = (approve: approve, deny: deny)

        approvalWindowController.showApprovalWindow(
            clientName: clientID,
            onApprove: { alwaysTrust in
                if alwaysTrust {
                    self.addTrustedClient(clientID)

                    // Request notification permissions so that the user can be notified when a trusted client connects
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                        if let error = error {
                            log.error("Failed to request notification permissions: \(error.localizedDescription)")
                        } else {
                            log.info("Notification permissions granted: \(granted)")
                        }
                    }
                }

                approve()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: true)
            },
            onDeny: {
                deny()
                self.cleanupApprovalState()
                self.handlePendingApprovals(for: clientID, approved: false)
            }
        )

        NSApp.activate(ignoringOtherApps: true)

        // Handle any pending approvals for the same client after this one completes
        // We'll check for pending approvals when the dialog is dismissed
    }
}

// MARK: - Connection Management Components

/// Manages a single MCP connection
actor MCPConnectionManager {
    private let connectionID: UUID
    private let connection: NWConnection
    private let server: MCP.Server
    private var transport: NetworkTransport
    private let parentManager: ServerNetworkManager

    init(connectionID: UUID, connection: NWConnection, parentManager: ServerNetworkManager) {
        self.connectionID = connectionID
        self.connection = connection
        self.parentManager = parentManager

        self.transport = NetworkTransport(
            connection: connection,
            logger: nil
        )

        // Create the MCP server
        self.server = MCP.Server(
            name: Bundle.main.name ?? "iMCP",
            version: Bundle.main.shortVersionString ?? "unknown",
            capabilities: MCP.Server.Capabilities(
                tools: .init(listChanged: true)
            )
        )
    }

    func start(approvalHandler: @escaping (MCP.Client.Info) async -> Bool) async throws {
        do {
            log.notice("Starting MCP server for connection: \(self.connectionID)")
            try await server.start(transport: transport) { [weak self] clientInfo, capabilities in
                guard let self = self else { throw MCPError.connectionClosed }

                log.info("Received initialize request from client: \(clientInfo.name)")

                // Request user approval
                let approved = await approvalHandler(clientInfo)
                log.info(
                    "Approval result for connection \(connectionID): \(approved ? "Approved" : "Denied")"
                )

                if !approved {
                    await self.parentManager.removeConnection(self.connectionID)
                    throw MCPError.connectionClosed
                }
            }

            log.notice("MCP Server started successfully for connection: \(self.connectionID)")

            // Register handlers after successful approval
            await registerHandlers()

            // Monitor connection health
            await startHealthMonitoring()
        } catch {
            log.error("Failed to start MCP server: \(error.localizedDescription)")
            throw error
        }
    }

    private func registerHandlers() async {
        await parentManager.registerHandlers(for: server, connectionID: connectionID)
    }

    private func startHealthMonitoring() async {
        // Set up a connection health monitoring task
        Task {
            outer: while await parentManager.isRunning() {
                switch connection.state {
                case .ready, .setup, .preparing, .waiting:
                    break
                case .cancelled:
                    log.error("Connection \(self.connectionID) was cancelled, removing")
                    await parentManager.removeConnection(connectionID)
                    break outer
                case .failed(let error):
                    log.error(
                        "Connection \(self.connectionID) failed with error \(error), removing"
                    )
                    await parentManager.removeConnection(connectionID)
                    break outer
                @unknown default:
                    log.debug("Connection \(self.connectionID) in unknown state, skipping")
                }

                // Check again after 30 seconds
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
            }
        }
    }

    func notifyToolListChanged() async {
        do {
            log.info("Notifying client that tool list changed")
            try await server.notify(ToolListChangedNotification.message())
        } catch {
            log.error("Failed to notify client of tool list change: \(error)")

            // If the error is related to connection issues, clean up the connection
            if let nwError = error as? NWError,
                nwError.errorCode == 57 || nwError.errorCode == 54
            {
                log.debug("Connection appears to be closed")
                await parentManager.removeConnection(connectionID)
            }
        }
    }

    func stop() async {
        await server.stop()
        connection.cancel()
    }
}

/// Manages Bonjour service discovery and advertisement
actor NetworkDiscoveryManager {
    private let serviceType: String
    private let serviceDomain: String
    var listener: NWListener
    private let browser: NWBrowser

    init(serviceType: String, serviceDomain: String) throws {
        self.serviceType = serviceType
        self.serviceDomain = serviceDomain

        // Set up network parameters
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        // Create the listener with service discovery
        self.listener = try NWListener(using: parameters)
        self.listener.service = NWListener.Service(type: serviceType, domain: serviceDomain)

        // Set up browser for debugging/monitoring
        self.browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: serviceDomain),
            using: parameters
        )

        log.info("Network discovery manager initialized with Bonjour service type: \(serviceType)")
    }

    func start(
        stateHandler: @escaping @Sendable (NWListener.State) -> Void,
        connectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) {
        // Set up state handler
        listener.stateUpdateHandler = stateHandler

        // Set up connection handler
        listener.newConnectionHandler = connectionHandler

        // Start the listener and browser
        listener.start(queue: .main)
        browser.start(queue: .main)

        log.info("Started network discovery and advertisement")
    }

    func stop() {
        listener.cancel()
        browser.cancel()
        log.info("Stopped network discovery and advertisement")
    }

    func restartWithRandomPort() async throws {
        // Cancel the current listener
        listener.cancel()

        // Create new parameters with a random port
        let parameters: NWParameters = NWParameters.tcp  // Explicit type
        parameters.acceptLocalOnly = true
        parameters.includePeerToPeer = false

        if let tcpOptions = parameters.defaultProtocolStack.internetProtocol
            as? NWProtocolIP.Options
        {
            tcpOptions.version = .v4
        }

        // Create a new listener with the updated parameters
        let newListener: NWListener = try NWListener(using: parameters)  // Explicit type
        let service = NWListener.Service(type: self.serviceType, domain: self.serviceDomain)  // Explicitly create service
        newListener.service = service

        // Update the state handler and connection handler
        if let currentStateHandler = listener.stateUpdateHandler {
            newListener.stateUpdateHandler = currentStateHandler
        }

        if let currentConnectionHandler = listener.newConnectionHandler {
            newListener.newConnectionHandler = currentConnectionHandler
        }

        // Start the new listener
        newListener.start(queue: .main)

        self.listener = newListener  // Update the instance member

        log.notice("Restarted listener with a dynamic port")
    }
}

actor ServerNetworkManager {
    private var isRunningState: Bool = false
    private var isEnabledState: Bool = true
    private var discoveryManager: NetworkDiscoveryManager?
    private var connections: [UUID: MCPConnectionManager] = [:]
    private var connectionTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingConnections: [UUID: String] = [:]

    typealias ConnectionApprovalHandler = @Sendable (UUID, MCP.Client.Info) async -> Bool
    private var connectionApprovalHandler: ConnectionApprovalHandler?

    // Use ServiceRegistry for services
    private let services = ServiceRegistry.services
    private var serviceBindings: [String: Binding<Bool>] = [:]

    init() {
        do {
            self.discoveryManager = try NetworkDiscoveryManager(
                serviceType: serviceType,
                serviceDomain: serviceDomain
            )
        } catch {
            log.error("Failed to initialize network discovery manager: \(error)")
        }
    }

    func isRunning() -> Bool {
        isRunningState
    }

    func setConnectionApprovalHandler(_ handler: @escaping ConnectionApprovalHandler) {
        log.debug("Setting connection approval handler")
        self.connectionApprovalHandler = handler
    }

    func start() async {
        log.info("Starting network manager")
        isRunningState = true

        guard let discoveryManager = discoveryManager else {
            log.error("Cannot start network manager: discovery manager not initialized")
            return
        }

        // Configure listener state handler
        await discoveryManager.start(
            stateHandler: { [weak self] (state: NWListener.State) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleListenerStateChange(state)
                }
            },
            connectionHandler: { [weak self] (connection: NWConnection) -> Void in
                guard let strongSelf = self else { return }

                Task {
                    await strongSelf.handleNewConnection(connection)
                }
            }
        )

        // Start a monitoring task to check service health periodically
        Task {
            while self.isRunningState {  // Explicit self.
                // Check if the listener is in a ready state
                if let currentDM = self.discoveryManager,  // Explicit self.
                    self.isRunningState  // Ensure still running before proceeding
                {
                    // Fetch the state of the listener explicitly.
                    let listenerState: NWListener.State = await currentDM.listener.state

                    if listenerState != .ready {
                        log.warning(
                            "Listener not in ready state, current state: \\(listenerState)"
                        )

                        let shouldAttemptRestart: Bool
                        switch listenerState {
                        case .failed, .cancelled:
                            shouldAttemptRestart = true
                        default:
                            shouldAttemptRestart = false
                        }

                        if shouldAttemptRestart {
                            log.info(
                                "Attempting to restart listener (state: \\(listenerState)) because it was failed or cancelled."
                            )
                            try? await currentDM.restartWithRandomPort()
                        }
                    }
                }

                // Sleep for 10 seconds before checking again
                try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s
            }
        }
    }

    private func handleListenerStateChange(_ state: NWListener.State) async {
        switch state {
        case .ready:
            log.info("Server ready and advertising via Bonjour as \(serviceType)")
        case .setup:
            log.debug("Server setting up...")
        case .waiting(let error):
            log.warning("Server waiting: \(error)")

            // If the port is already in use, try to restart with a different port
            if error.errorCode == 48 {
                log.error("Port already in use, will try to restart service")

                // Wait a bit and restart
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

                // Try to restart with a different port
                if isRunningState {
                    try? await discoveryManager?.restartWithRandomPort()
                }
            }
        case .failed(let error):
            log.error("Server failed: \(error)")

            // Attempt recovery
            if isRunningState {
                log.info("Attempting to recover from server failure")
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

                // Try to restart the listener
                try? await discoveryManager?.restartWithRandomPort()
            }
        case .cancelled:
            log.info("Server cancelled")
        @unknown default:
            log.warning("Unknown server state")
        }
    }

    func stop() async {
        log.info("Stopping network manager")
        isRunningState = false

        // Stop all connections
        for (id, connectionManager) in connections {
            log.debug("Stopping connection: \(id)")
            await connectionManager.stop()
            connectionTasks[id]?.cancel()
        }

        connections.removeAll()
        connectionTasks.removeAll()
        pendingConnections.removeAll()

        // Stop discovery
        await discoveryManager?.stop()
    }

    func removeConnection(_ id: UUID) async {
        log.debug("Removing connection: \(id)")

        // Stop the connection manager
        if let connectionManager = connections[id] {
            await connectionManager.stop()
        }

        // Cancel any associated tasks
        if let task = connectionTasks[id] {
            task.cancel()
        }

        // Remove from all collections
        connections.removeValue(forKey: id)
        connectionTasks.removeValue(forKey: id)
        pendingConnections.removeValue(forKey: id)
    }

    // Handle new incoming connections
    private func handleNewConnection(_ connection: NWConnection) async {
        let connectionID = UUID()
        log.info("Handling new connection: \(connectionID)")

        // Create a connection manager
        let connectionManager = MCPConnectionManager(
            connectionID: connectionID,
            connection: connection,
            parentManager: self
        )

        // Store the connection manager
        connections[connectionID] = connectionManager

        // Start a task to monitor connection state
        let task = Task {
            // Ensure this task is removed from the registry upon completion (success or handled failure)
            // so the timeout logic below doesn't act on an already completed task.
            defer {
                // This runs on ServerNetworkManager's actor context
                self.connectionTasks.removeValue(forKey: connectionID)
            }

            do {
                // Set up the connection approval handler
                guard let approvalHandler = self.connectionApprovalHandler else {
                    log.error("No connection approval handler set, rejecting connection")
                    await removeConnection(connectionID)
                    return
                }

                // Start the MCP server with our approval handler
                try await connectionManager.start { clientInfo in
                    await approvalHandler(connectionID, clientInfo)
                }

                log.notice("Connection \(connectionID) successfully established")
            } catch {
                log.error("Failed to establish connection \(connectionID): \(error)")
                await removeConnection(connectionID)
            }
        }

        // Store the task
        connectionTasks[connectionID] = task

        // Set up a timeout to ensure the connection becomes ready in a reasonable time
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds

            // Check if the setup task is still in the registry. If so, it implies
            // it hasn't completed its defer block (e.g., it's stuck or genuinely timed out)
            // and wasn't cleaned up by an error path calling removeConnection.
            // Also, ensure the connection object itself still exists.
            if self.connectionTasks[connectionID] != nil,  // Task entry still exists (meaning it hasn't completed defer)
                self.connections[connectionID] != nil
            {  // Connection object still exists
                log.warning(
                    "Connection \(connectionID) setup timed out (task still in registry), closing it"
                )
                await removeConnection(connectionID)
            }
        }
    }

    func registerHandlers(for server: MCP.Server, connectionID: UUID) async {
        // Register prompts/list handler
        await server.withMethodHandler(ListPrompts.self) { _ in
            log.debug("Handling ListPrompts request for \(connectionID)")
            return ListPrompts.Result(prompts: [])
        }

        // Register the resources/list handler
        await server.withMethodHandler(ListResources.self) { _ in
            log.debug("Handling ListResources request for \(connectionID)")
            return ListResources.Result(resources: [])
        }

        // Register tools/list handler
        await server.withMethodHandler(ListTools.self) { [weak self] _ in
            guard let self = self else {
                return ListTools.Result(tools: [])
            }

            log.debug("Handling ListTools request for \(connectionID)")

            var tools: [MCP.Tool] = []
            if await self.isEnabledState {
                for service in await self.services {
                    let serviceId = String(describing: type(of: service))

                    // Get the binding value in an actor-safe way
                    if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                        isServiceEnabled
                    {
                        for tool in service.tools {
                            log.debug("Adding tool: \(tool.name)")
                            tools.append(
                                .init(
                                    name: tool.name,
                                    description: tool.description,
                                    inputSchema: try Value(tool.inputSchema),
                                    annotations: tool.annotations
                                )
                            )
                        }
                    }
                }
            }

            log.info("Returning \(tools.count) available tools for \(connectionID)")
            return ListTools.Result(tools: tools)
        }

        // Register tools/call handler
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self = self else {
                return CallTool.Result(
                    content: [.text("Server unavailable")],
                    isError: true
                )
            }

            log.notice("Tool call received from \(connectionID): \(params.name)")

            guard await self.isEnabledState else {
                log.notice("Tool call rejected: iMCP is disabled")
                return CallTool.Result(
                    content: [.text("iMCP is currently disabled. Please enable it to use tools.")],
                    isError: true
                )
            }

            for service in await self.services {
                let serviceId = String(describing: type(of: service))

                // Get the binding value in an actor-safe way
                if let isServiceEnabled = await self.serviceBindings[serviceId]?.wrappedValue,
                    isServiceEnabled
                {
                    do {
                        guard
                            let value = try await service.call(
                                tool: params.name,
                                with: params.arguments ?? [:]
                            )
                        else {
                            continue
                        }

                        log.notice("Tool \(params.name) executed successfully for \(connectionID)")
                        switch value {
                        case let .data(mimeType?, data) where mimeType.hasPrefix("image/"):
                            return CallTool.Result(
                                content: [
                                    .image(
                                        data: data.base64EncodedString(),
                                        mimeType: mimeType,
                                        metadata: nil
                                    )
                                ], isError: false)
                        default:
                            let encoder = JSONEncoder()
                            encoder.userInfo[Ontology.DateTime.timeZoneOverrideKey] =
                                TimeZone.current
                            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                            let data = try encoder.encode(value)
                            let text = String(data: data, encoding: .utf8)!
                            return CallTool.Result(content: [.text(text)], isError: false)
                        }
                    } catch {
                        log.error(
                            "Error executing tool \(params.name): \(error.localizedDescription)")
                        return CallTool.Result(content: [.text("Error: \(error)")], isError: true)
                    }
                }
            }

            log.error("Tool not found or service not enabled: \(params.name)")
            return CallTool.Result(
                content: [.text("Tool not found or service not enabled: \(params.name)")],
                isError: true
            )
        }
    }

    // Update the enabled state and notify clients
    func setEnabled(_ enabled: Bool) async {
        // Only do something if the state actually changes
        guard isEnabledState != enabled else { return }

        isEnabledState = enabled
        log.info("iMCP enabled state changed to: \(enabled)")

        // Notify all connected clients that the tool list has changed
        for (_, connectionManager) in connections {
            Task {
                await connectionManager.notifyToolListChanged()
            }
        }
    }

    // Update service bindings
    func updateServiceBindings(_ newBindings: [String: Binding<Bool>]) async {
        self.serviceBindings = newBindings

        // Notify clients that tool availability may have changed
        Task {
            for (_, connectionManager) in connections {
                await connectionManager.notifyToolListChanged()
            }
        }
    }
}
