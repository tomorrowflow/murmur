import Cocoa
import SwiftUI
import SharedModels

private let fieldLabelWidth: CGFloat = 120
private let eyeIconWidth: CGFloat = 24

struct OpenClawSettingsView: View {
    @StateObject private var viewModel = OpenClawSettingsViewModel()
    @State private var tokenVisible = false
    @State private var passwordVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Connection") {
                    HStack(spacing: 8) {
                        Text("URL")
                            .frame(width: fieldLabelWidth, alignment: .leading)
                        Color.clear.frame(width: eyeIconWidth, height: 1)
                        TextField("", text: $viewModel.url, prompt: Text("wss://..."))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()
                    HStack(spacing: 8) {
                        Text("Token")
                            .frame(width: fieldLabelWidth, alignment: .leading)
                        Button(action: { tokenVisible.toggle() }) {
                            Image(systemName: tokenVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                                .frame(width: eyeIconWidth)
                        }
                        .buttonStyle(.plain)
                        if tokenVisible {
                            TextField("", text: $viewModel.token)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("", text: $viewModel.token)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .labelsHidden()
                    HStack(spacing: 8) {
                        Text("Password")
                            .frame(width: fieldLabelWidth, alignment: .leading)
                        Button(action: { passwordVisible.toggle() }) {
                            Image(systemName: passwordVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                                .frame(width: eyeIconWidth)
                        }
                        .buttonStyle(.plain)
                        if passwordVisible {
                            TextField("", text: $viewModel.password, prompt: Text("optional"))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField("", text: $viewModel.password, prompt: Text("optional"))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .labelsHidden()
                    HStack(spacing: 8) {
                        Text("Session Key")
                            .frame(width: fieldLabelWidth, alignment: .leading)
                        Color.clear.frame(width: eyeIconWidth, height: 1)
                        TextField("", text: $viewModel.sessionKey, prompt: Text("voice-assistant"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()
                }

                Section("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.statusColor)
                            .frame(width: 10, height: 10)
                            .opacity(viewModel.isPulsing ? 0.4 : 1.0)
                            .animation(
                                viewModel.isPulsing
                                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                    : .default,
                                value: viewModel.isPulsing
                            )
                        Text(viewModel.statusText)
                            .foregroundColor(.secondary)
                    }

                    if !viewModel.displayDeviceId.isEmpty {
                        HStack {
                            Text("Device ID:")
                                .foregroundColor(.secondary)
                            Text(viewModel.displayDeviceId)
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                if viewModel.isConnectedOrConnecting {
                    Button("Disconnect") {
                        viewModel.disconnect()
                    }
                    .padding()
                } else {
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .disabled(viewModel.url.isEmpty || viewModel.token.isEmpty)
                    .padding()
                }
            }
        }
        .onAppear {
            viewModel.loadCredentials()
            viewModel.startObserving()
        }
        .onDisappear {
            viewModel.stopObserving()
        }
    }
}

class OpenClawSettingsViewModel: ObservableObject {
    @Published var url: String = ""
    @Published var token: String = ""
    @Published var password: String = ""
    @Published var sessionKey: String = "voice-assistant"

    @Published var statusText: String = "Not configured"
    @Published var statusColor: Color = .gray
    @Published var isPulsing: Bool = false
    @Published var displayDeviceId: String = ""
    @Published var isConnectedOrConnecting: Bool = false

    private var pollTimer: Timer?

    func loadCredentials() {
        let defaults = UserDefaults.standard
        url = defaults.string(forKey: "openClaw.url") ?? ""
        token = defaults.string(forKey: "openClaw.token") ?? ""
        password = defaults.string(forKey: "openClaw.password") ?? ""
        sessionKey = defaults.string(forKey: "openClaw.sessionKey") ?? "voice-assistant"
        refreshStatus()
    }

    func saveCredentials() {
        let defaults = UserDefaults.standard
        defaults.set(url, forKey: "openClaw.url")
        defaults.set(token, forKey: "openClaw.token")
        defaults.set(password, forKey: "openClaw.password")
        defaults.set(sessionKey, forKey: "openClaw.sessionKey")
    }

    func connect() {
        saveCredentials()
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.connectOpenClaw(
            url: url,
            token: token,
            password: password.isEmpty ? nil : password,
            sessionKey: sessionKey
        )
        refreshStatus()
    }

    func disconnect() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.disconnectOpenClaw()
        refreshStatus()
    }

    func startObserving() {
        // Set up the onStatusChange callback on the manager
        if let appDelegate = NSApp.delegate as? AppDelegate,
           let manager = appDelegate.openClawManagerPublic {
            manager.onStatusChange = { [weak self] _, _, _ in
                DispatchQueue.main.async {
                    self?.refreshStatus()
                }
            }
        }

        // Poll periodically to catch status changes (e.g. during pairing)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        refreshStatus()
    }

    func stopObserving() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refreshStatus() {
        guard let appDelegate = NSApp.delegate as? AppDelegate,
              let manager = appDelegate.openClawManagerPublic else {
            statusText = url.isEmpty || token.isEmpty ? "Not configured" : "Disconnected"
            statusColor = .gray
            isPulsing = false
            isConnectedOrConnecting = false
            displayDeviceId = ""
            return
        }

        displayDeviceId = String(manager.deviceId.prefix(16)) + "..."
        isConnectedOrConnecting = manager.isConnected || manager.isPendingPairing

        if manager.isAuthenticated {
            statusText = "Connected"
            statusColor = .green
            isPulsing = false
        } else if manager.isPendingPairing {
            statusText = "Pending device approval \u{2014} approve in OpenClaw"
            statusColor = .yellow
            isPulsing = true
        } else if manager.isConnected {
            statusText = "Connecting..."
            statusColor = .orange
            isPulsing = false
        } else {
            statusText = "Disconnected"
            statusColor = .gray
            isPulsing = false
        }
    }
}

class OpenClawSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: OpenClawSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        self.view = hostingView
    }
}
