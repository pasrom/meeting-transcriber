import SwiftUI

struct ContextMCPSettingsSection: View {
    @Bindable var settings: AppSettings
    @State private var editing: MCPSource?
    @State private var tested: [UUID: String] = [:]

    var body: some View {
        Section("Context & MCP") {
            Toggle("Use MCP context when generating meeting notes", isOn: $settings.meetingContextEnabled)
                .accessibilityIdentifier(A11yID.meetingContextToggle)
            Text(providerDescription)
                .foregroundStyle(.secondary)
                .font(.caption)
            ForEach(settings.mcpSources) { source in
                LabeledContent(source.name) {
                    HStack {
                        Text(sourceDetail(source))
                            .foregroundStyle(.secondary)
                        Button("Edit…") { editing = source }
                    }
                }
            }
            Button("Add MCP Source…") { editing = MCPSource() }
                .disabled(settings.mcpSources.count >= ContextLimits.servers)
        }
        .sheet(item: $editing) { source in
            ContextMCPSourceEditor(settings: settings, source: source) { result in
                tested[source.id] = result
            }
        }
    }

    private func sourceDetail(_ source: MCPSource) -> String {
        let state = source.enabled ? "Enabled" : "Disabled"
        let details = [source.transport.label, state, tested[source.id] ?? ""].filter { !$0.isEmpty }
        return details.joined(separator: " · ")
    }

    private var providerDescription: String {
        guard settings.protocolProvider == .openAICompatible else {
            return "MCP enrichment requires an OpenAI-compatible notes connection."
        }
        if let url = URL(string: settings.openAIEndpoint), MCPSource.isLoopback(url) {
            return "Notes destination: loopback. Enrichment sends an extra planning request with the transcript and approved tool descriptions."
        }
        return "Notes destination: remote or unknown. Approve each source before forwarding tool metadata or evidence to this connection."
    }
}

private struct ContextMCPSourceEditor: View {
    @Environment(\.dismiss)
    private var dismiss
    let settings: AppSettings
    var setTestStatus: (String?) -> Void

    @State private var source: MCPSource
    @State private var argumentsText: String
    @State private var credentialText = ""
    @State private var replaceSecrets = false
    @State private var tools: [MCPTool] = []
    @State private var feedback = ""
    @State private var testTask: Task<Void, Never>?
    @State private var approvedTest: MCPSource?
    @State private var confirmRemoval = false

    init(settings: AppSettings, source: MCPSource, setTestStatus: @escaping (String?) -> Void) {
        self.settings = settings
        self.setTestStatus = setTestStatus
        _source = State(initialValue: source)
        let args = try? ContextJSON.encodedText(source.arguments)
        _argumentsText = State(initialValue: args ?? "[]")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                connectionSection
                permissionsSection
                toolSection
            }
            .formStyle(.grouped)
            if !feedback.isEmpty {
                Text(feedback).font(.callout).padding(.horizontal)
            }
            HStack {
                if stored != nil {
                    Button("Remove Source…", role: .destructive) { confirmRemoval = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if save() != nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(testTask != nil)
            }
            .padding()
        }
        .frame(width: 610, height: 580)
        .onDisappear { testTask?.cancel() }
        .confirmationDialog("Remove this MCP source?", isPresented: $confirmRemoval) {
            Button("Remove Source", role: .destructive) {
                settings.mcpSources.removeAll { $0.id == source.id }
                ContextMCPKeychain.remove(source)
                setTestStatus(nil)
                dismiss()
            }
        }
    }

    private var stored: MCPSource? {
        settings.mcpSources.first { $0.id == source.id }
    }

    private var connectionSection: some View {
        Section("Connection") {
            TextField("Name", text: $source.name)
            Picker("Transport", selection: $source.transport) {
                ForEach(MCPSource.Transport.allCases, id: \.self) { transport in
                    Text(transport.label).tag(transport)
                }
            }
            TextField(source.transport == .stdio ? "Absolute executable path" : "Endpoint URL", text: $source.location)
            if source.transport == .stdio {
                TextField("Argument array (JSON)", text: $argumentsText)
                if !source.transportAvailable {
                    Text("Local stdio is unavailable in the App Store build.").foregroundStyle(.secondary)
                }
            } else {
                httpAuthentication
            }
            if !source.usesOAuth { staticCredentials }
        }
        .disabled(testTask != nil)
    }

    @ViewBuilder private var httpAuthentication: some View {
        Picker("Authentication", selection: Binding(
            get: { source.httpAuthentication ?? .headers },
            set: { mode in
                source.httpAuthentication = mode == .oauth ? mode : nil
                if mode == .oauth { replaceSecrets = false }
            },
        )) {
            ForEach(MCPSource.HTTPAuthentication.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        if source.usesOAuth {
            TextField("OAuth client ID or metadata URL (optional)", text: Binding(
                get: { source.oauthClientID ?? "" },
                set: { source.oauthClientID = $0 },
            ))
            HStack {
                Button("Sign In in Browser…") { signIn() }
                if stored?.usesOAuth == true && stored?.location == source.location {
                    Button("Forget Sign-In") { forgetSignIn() }
                }
            }
        } else {
            Toggle("Allow plain HTTP on loopback", isOn: $source.allowLocalHTTP)
        }
    }

    @ViewBuilder private var staticCredentials: some View {
        Toggle("Replace saved credentials", isOn: $replaceSecrets)
        if replaceSecrets {
            SecureField(
                source.transport == .stdio ? "Environment (JSON object)" : "Static headers (JSON object)",
                text: $credentialText,
                prompt: Text("{}"),
            )
            Text("Enter a JSON object with string values. Enter {} to clear saved credentials.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            Toggle("Enable source for notes", isOn: $source.enabled)
            if source.transport == .http {
                Toggle("Allow meeting lookup arguments to this HTTP endpoint", isOn: $source.allowQueries)
            }
            if let endpoint = URL(string: settings.openAIEndpoint), !MCPSource.isLoopback(endpoint),
               MCPSource.validEndpoint(endpoint, allowLoopbackHTTP: false) {
                let destination = MCPSource.destinationID(endpoint)
                Toggle("Allow metadata and evidence to \(endpoint.host ?? "this notes provider")", isOn: Binding(
                    get: { source.remoteModelDestination == destination },
                    set: { source.remoteModelDestination = $0 ? destination : nil },
                ))
            }
            Toggle("Keep supplied evidence in the local context record", isOn: $source.retainEvidence)
            Text("Enable only sources you want queried together for automatic notes. Local servers can contact external services.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(testTask != nil)
    }

    private var toolSection: some View {
        Section("Read-only tools") {
            Button("Save and Test Connection") { test() }
                .disabled(testTask != nil || !source.transportAvailable)
            if testTask != nil { ProgressView() }
            Text("Review the server and approve each retrieval tool. Read-only hints come from the server and cannot guarantee its behavior.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(tools, id: \.name) { tool in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(tool.name, isOn: Binding(
                        get: { source.approvals[tool.name] == tool.fingerprint },
                        set: { source.approvals[tool.name] = $0 ? tool.fingerprint : nil },
                    ))
                    .disabled(!tool.permitsReadOnlyApproval || approvedTest == nil)
                    if !tool.description.isEmpty { Text(String(tool.description.prefix(512))).font(.caption) }
                    if let annotations = tool.annotationSummary { Text(annotations).font(.caption).foregroundStyle(.secondary) }
                    if !tool.permitsReadOnlyApproval {
                        Text("Tool reports write access or uses an unsupported schema.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if tools.isEmpty, !source.approvals.isEmpty {
                Button("Revoke All Tool Approvals", role: .destructive) { source.approvals = [:] }
            }
        }
    }

    private func save() -> MCPSource? {
        var next = source
        next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
        next.location = next.location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizeAuthentication(&next) else { return nil }
        guard !next.name.isEmpty, next.name.utf8.count <= 100, next.location.utf8.count <= 2048 else {
            feedback = "Enter a name and a valid connection address."
            return nil
        }
        if next.transport == .stdio {
            guard next.transportAvailable, next.location.hasPrefix("/"),
                  let arguments = try? JSONDecoder().decode([String].self, from: Data(argumentsText.utf8)),
                  arguments.count <= 64, arguments.allSatisfy({ argument in
                      argument.utf8.count <= 4096 && !ContextDataSafety.containsSensitive(argument, secrets: [])
                          && argument.range(
                              of: #"(?i)^--?(?:key|api.?key|token|secret|password|authorization)(?:=|$)"#,
                              options: .regularExpression,
                          ) == nil
                  }) else {
                feedback = "Enter an absolute executable path and a JSON string array. Put secrets in the environment."
                return nil
            }
            next.arguments = arguments
        } else {
            guard next.endpoint != nil else {
                feedback = "Enter an HTTPS endpoint. Plain HTTP requires loopback and its own permission."
                return nil
            }
            next.arguments = []
        }

        let previous = stored
        let connectionChanged = previous.map { connectionDiffers($0, from: next) } ?? true
        // Existing secrets stay bound to the old address or executable.
        if (replaceSecrets && !next.usesOAuth) || connectionChanged {
            let credentials = next.usesOAuth ? MCPSecrets() : readCredentials(transport: next.transport)
            guard let credentials else { return nil }
            // Use a fresh Keychain account for the new connection revision.
            // A failed save leaves both the previous config and credentials usable.
            next.connectionRevision = UUID()
            if !credentials.values.isEmpty, !ContextMCPKeychain.save(credentials, for: next) {
                feedback = "Credentials could not be saved in Keychain."
                return nil
            }
            next.approvals = [:]
            if previous != nil, connectionChanged { next.remoteModelDestination = nil }
        }
        if let index = settings.mcpSources.firstIndex(where: { $0.id == next.id }) {
            settings.mcpSources[index] = next
        } else {
            settings.mcpSources.append(next)
        }
        if let previous, previous.connectionRevision != next.connectionRevision {
            ContextMCPKeychain.remove(previous)
            tools = []
            approvedTest = nil
            setTestStatus(nil)
        }
        source = next
        credentialText = ""
        replaceSecrets = false
        return next
    }

    private func connectionDiffers(_ previous: MCPSource, from next: MCPSource) -> Bool {
        previous.location != next.location || previous.arguments != next.arguments || previous.transport != next.transport
            || previous.allowLocalHTTP != next.allowLocalHTTP || previous.httpAuthentication != next.httpAuthentication
            || previous.oauthClientID != next.oauthClientID
    }

    private func normalizeAuthentication(_ next: inout MCPSource) -> Bool {
        guard next.usesOAuth else {
            next.httpAuthentication = nil
            next.oauthClientID = nil
            return true
        }
        next.allowLocalHTTP = false
        if let id = next.oauthClientID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            guard MCPOAuthClient.validClientID(id) else {
                feedback = "Enter the OAuth client ID exactly as registered."
                return false
            }
            next.oauthClientID = id
        } else {
            next.oauthClientID = nil
        }
        return true
    }

    private func signIn() {
        guard let saved = save(), let endpoint = saved.endpoint, saved.usesOAuth else { return }
        feedback = "Opening OAuth sign-in…"
        testTask = Task { @MainActor in
            defer { testTask = nil }
            do {
                let listener = try MCPOAuthLoopback()
                defer { listener.stop() }
                let redirect = try await listener.start()
                let client = MCPOAuthClient()
                let flow = try await client.begin(endpoint: endpoint, redirect: redirect, clientID: saved.oauthClientID)
                feedback = "Complete sign-in in your browser."
                let code = try await listener.authorize(flow)
                let credentials = try await client.finish(flow, code: code)
                try Task.checkCancellation()
                let signedIn = try replaceAuthorization(for: saved, with: MCPSecrets(oauth: credentials))
                feedback = "Signed in. Discovering tools…"
                try await testConnection(signedIn)
            } catch is CancellationError {
                // The editor closed.
            } catch {
                feedback = message(for: error, source: saved)
                setTestStatus("Test failed")
            }
        }
    }

    private func forgetSignIn() {
        guard let saved = save(), saved.usesOAuth else { return }
        do {
            _ = try replaceAuthorization(for: saved, with: MCPSecrets())
            feedback = "Saved OAuth credentials were removed from this Mac."
        } catch {
            feedback = message(for: error, source: saved)
        }
    }

    private func replaceAuthorization(for saved: MCPSource, with credentials: MCPSecrets) throws -> MCPSource {
        guard let index = settings.mcpSources.firstIndex(of: saved) else { throw ContextFailure.revoked }
        var next = saved
        next.connectionRevision = UUID()
        next.approvals = [:]
        if credentials.oauth != nil, !ContextMCPKeychain.save(credentials, for: next) { throw MCPOAuthError.storage }
        settings.mcpSources[index] = next
        ContextMCPKeychain.remove(saved)
        source = next
        tools = []
        approvedTest = nil
        setTestStatus(nil)
        return next
    }

    private func readCredentials(transport: MCPSource.Transport) -> MCPSecrets? {
        guard replaceSecrets else { return MCPSecrets() }
        guard credentialText.utf8.count <= 16 * 1024,
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(credentialText.utf8)) else {
            feedback = "Credentials must be a JSON object with string values."
            return nil
        }
        return transport == .stdio ? MCPSecrets(environment: fields) : MCPSecrets(headers: fields)
    }

    private func discover(_ saved: MCPSource, secrets: MCPSecrets, deadline: ContinuousClock.Instant) async throws -> [MCPTool] {
        let client = try ContextMCPClient(source: saved, secrets: secrets, deadline: deadline) {
            settings.mcpSources.contains(saved)
        }
        do {
            let tools = try await client.discover()
            await client.close()
            try Task.checkCancellation()
            return tools
        } catch {
            await client.close()
            throw error
        }
    }

    func test() {
        guard let saved = save() else { return }
        feedback = ""
        tools = []
        approvedTest = nil
        testTask = Task { @MainActor in
            defer { testTask = nil }
            do {
                try await testConnection(saved)
            } catch is CancellationError {
                // The editor closed.
            } catch {
                feedback = message(for: error, source: saved)
                setTestStatus("Test failed")
            }
        }
    }

    private func testConnection(_ saved: MCPSource) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        let credentials: MCPSecrets
        if saved.usesOAuth {
            let settings = self.settings
            credentials = try await MCPOAuthTokenStore.shared.usable(saved, deadline: deadline) { source in
                settings.mcpSources.contains(source)
            }
        } else {
            credentials = await Task.detached { ContextMCPKeychain.load(saved) }.value
        }
        let discovered = try await discover(saved, secrets: credentials, deadline: deadline)
        tools = discovered.filter { tool in
            !ContextDataSafety.containsSensitive(tool.name, secrets: credentials.values)
                && !ContextDataSafety.containsSensitive(tool.description, secrets: credentials.values)
        }
        let signatures = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0.fingerprint) })
        source.approvals = source.approvals.filter { signatures[$0.key] == $0.value }
        approvedTest = saved
        feedback = "Connection succeeded. \(tools.count) tool(s) available for review."
        setTestStatus("Connected")
    }

    private func message(for error: any Error, source: MCPSource) -> String {
        if let oauth = error as? MCPOAuthError, let description = oauth.errorDescription { return description }
        if error as? ContextFailure == .authentication {
            return source.usesOAuth ? "The server rejected this authorization. Sign in again."
                : "Authentication failed. Check the saved headers or choose OAuth sign-in."
        }
        return "Connection or tool discovery failed. Check the endpoint or executable."
    }
}
