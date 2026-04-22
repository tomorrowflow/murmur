import Cocoa
import SwiftUI

/// Posted when the LAN-exposure toggle changes. Observed in main.swift to
/// restart the HTTP listener on the new bind address.
extension Notification.Name {
    static let claudeExposeToLanDidChange = Notification.Name("claudeExposeToLanDidChange")
}

struct ClaudeSettingsView: View {
    @StateObject private var viewModel = ClaudeSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Claude Code Recap") {
                    HStack(spacing: 8) {
                        Text("Preprocess")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.recapPreprocessMode) {
                            Text("None (raw text)").tag("none")
                            Text("Regex cleanup").tag("regex")
                            Text("Ollama (LLM summary)").tag("ollama")
                        }
                        .labelsHidden()
                    }

                    Text("Cleans up the assistant's final message before it's spoken. Regex strips code blocks, paths, markdown, and PIDs. Ollama rewrites it as a spoken summary using the Ollama model configured under Read Aloud.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Tool Approvals") {
                    Toggle(isOn: $viewModel.autoApproveTools) {
                        HStack {
                            Text("Auto-approve tool requests")
                                .frame(width: 220, alignment: .leading)
                            Text("Claude Code runs tools without asking")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("When enabled, the PreToolUse hook auto-approves permission prompts. Every auto-approval is logged in History → Approvals. Requires the hook wired in ~/.claude/settings.json — see README.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Network") {
                    Toggle(isOn: $viewModel.exposeToLan) {
                        HStack {
                            Text("Expose HTTP API to LAN")
                                .frame(width: 220, alignment: .leading)
                            Text(viewModel.exposeToLan ? "Listening on 0.0.0.0:7878" : "Localhost only (127.0.0.1:7878)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("Off: only hooks on this Mac can reach Murmur. On: LAN hosts can POST to Murmur, but remote IPs must be approved below before any request is processed.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Approved Hosts") {
                    if !viewModel.exposeToLan {
                        Text("Enable \"Expose HTTP API to LAN\" above to allow remote hosts. Localhost hooks work regardless.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else if viewModel.pending.isEmpty && viewModel.approved.isEmpty {
                        Text("No hosts yet. Unknown remote hosts hitting the endpoint will appear here.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        if !viewModel.pending.isEmpty {
                            pendingSection
                        }
                        if !viewModel.approved.isEmpty {
                            approvedSection
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            viewModel.load()
            viewModel.reloadHosts()
        }
        .onReceive(NotificationCenter.default.publisher(for: ClaudeHostRegistry.didChangeNotification)) { _ in
            viewModel.reloadHosts()
        }
    }

    // MARK: - Pending

    @ViewBuilder
    private var pendingSection: some View {
        Text("Pending (\(viewModel.pending.count))")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
        ForEach(viewModel.pending, id: \.ip) { host in
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundColor(.orange)
                    .font(.system(size: 11))
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.ip)
                        .font(.system(size: 12).monospacedDigit())
                    if let label = host.label, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Text("\(host.attemptCount) attempt\(host.attemptCount == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
                Button("Approve") { viewModel.approve(ip: host.ip) }
                    .controlSize(.small)
                Button("Deny") { viewModel.deny(ip: host.ip) }
                    .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Approved

    @ViewBuilder
    private var approvedSection: some View {
        if !viewModel.pending.isEmpty {
            Divider().padding(.vertical, 4)
        }
        Text("Approved")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
        ForEach(viewModel.approved, id: \.ip) { host in
            ApprovedHostRow(
                host: host,
                onLabelCommit: { label in viewModel.rename(ip: host.ip, label: label) },
                onRemove: { viewModel.remove(ip: host.ip) }
            )
        }
    }
}

// MARK: - Approved host row

/// One approved-host row with its own local text state so keystrokes don't
/// round-trip through the registry + notification + list reload (which
/// would yank the cursor mid-edit). Commits the label on submit (Enter) or
/// when focus moves away.
private struct ApprovedHostRow: View {
    let host: ClaudeHostRegistry.ApprovedHost
    let onLabelCommit: (String) -> Void
    let onRemove: () -> Void

    @State private var label: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.system(size: 11))
            Text(host.ip)
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 140, alignment: .leading)
            TextField("Label (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($focused)
                .onSubmit {
                    onLabelCommit(label)
                    focused = false
                }
                .onChange(of: focused) { isFocused in
                    if !isFocused && label != host.label {
                        onLabelCommit(label)
                    }
                }
            Button("Remove") { onRemove() }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
        .onAppear { label = host.label }
    }
}

// MARK: - View model

class ClaudeSettingsViewModel: ObservableObject {
    private var isLoading = false

    @Published var recapPreprocessMode: String = "none" { didSet { persist(recapPreprocessMode, forKey: "recap.preprocessMode") } }
    @Published var autoApproveTools: Bool = false { didSet { persist(autoApproveTools, forKey: "claude.autoApproveTools") } }
    @Published var exposeToLan: Bool = false {
        didSet {
            persist(exposeToLan, forKey: "claude.exposeToLan")
            if !isLoading {
                NotificationCenter.default.post(name: .claudeExposeToLanDidChange, object: nil)
            }
        }
    }

    @Published var pending: [ClaudeHostRegistry.PendingHost] = []
    @Published var approved: [ClaudeHostRegistry.ApprovedHost] = []

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        let defaults = UserDefaults.standard
        recapPreprocessMode = defaults.string(forKey: "recap.preprocessMode") ?? "none"
        autoApproveTools = defaults.bool(forKey: "claude.autoApproveTools")
        exposeToLan = defaults.bool(forKey: "claude.exposeToLan")
    }

    func reloadHosts() {
        pending = ClaudeHostRegistry.shared.pendingHosts.sorted { $0.firstSeen > $1.firstSeen }
        approved = ClaudeHostRegistry.shared.approvedHosts.sorted { $0.approvedAt > $1.approvedAt }
    }

    func approve(ip: String) {
        ClaudeHostRegistry.shared.approve(ip: ip)
        reloadHosts()
    }

    func deny(ip: String) {
        ClaudeHostRegistry.shared.denyPending(ip: ip)
        reloadHosts()
    }

    func remove(ip: String) {
        ClaudeHostRegistry.shared.remove(ip: ip)
        reloadHosts()
    }

    func rename(ip: String, label: String) {
        ClaudeHostRegistry.shared.updateLabel(ip: ip, label: label)
        // Don't reload here — it'd clobber the text field while the user is
        // typing. Notification arrives from the registry; we absorb it.
    }
}

// MARK: - View controller

class ClaudeSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: ClaudeSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 500)
        self.view = hostingView
    }
}
