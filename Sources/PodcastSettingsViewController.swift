import Cocoa
import SwiftUI

struct PodcastSettingsView: View {
    @StateObject private var viewModel = PodcastSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Connection") {
                    HStack(spacing: 8) {
                        Text("podcastd URL")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.wsURL, prompt: Text("wss://podcastd.internal.domain"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Audio Base URL")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.audioBaseURL, prompt: Text("https://podcastd.internal.domain"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()
                }

                Section("Hosts") {
                    HStack(spacing: 8) {
                        Text("Host A Name")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.hostAName, prompt: Text("Alex"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Host B Name")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.hostBName, prompt: Text("Jordan"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()
                }

                Section("Model") {
                    HStack(spacing: 8) {
                        Text("VibeVoice Model")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.selectedModel) {
                            Text("Large Q8 (~12 GB) — Best quality").tag("large-fp")
                            Text("Large Q4 (~7 GB) — Good quality").tag("large-q4")
                            Text("1.5B (~6 GB) — Faster").tag("1.5b-fp")
                            Text("1.5B Q4 (~4 GB) — Fastest").tag("1.5b-q4")
                        }
                        .labelsHidden()
                    }
                    Text("Pre-quantized Large checkpoints (Q8/Q4). 1.5B Q4 uses dynamic LLM quantization.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Features") {
                    Toggle(isOn: $viewModel.webSearchEnabled) {
                        HStack {
                            Text("Web Search on Interrupt")
                                .frame(width: 200, alignment: .leading)
                            Text("Enrich interrupt answers with live web results")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("Status") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.statusColor)
                            .frame(width: 10, height: 10)
                        Text(viewModel.statusText)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Save") {
                    viewModel.save()
                }
                .padding()
            }
        }
        .onAppear {
            viewModel.load()
        }
    }
}

class PodcastSettingsViewModel: ObservableObject {
    @Published var wsURL: String = ""
    @Published var audioBaseURL: String = ""
    @Published var hostAName: String = ""
    @Published var hostBName: String = ""
    @Published var selectedModel: String = "large-q4"
    @Published var webSearchEnabled: Bool = false
    @Published var statusText: String = "Not configured"
    @Published var statusColor: Color = .gray

    func load() {
        let defaults = UserDefaults.standard
        wsURL = defaults.string(forKey: "podcast.wsURL") ?? ""
        audioBaseURL = defaults.string(forKey: "podcast.audioBaseURL") ?? ""
        hostAName = defaults.string(forKey: "podcast.hostAName") ?? ""
        hostBName = defaults.string(forKey: "podcast.hostBName") ?? ""
        selectedModel = defaults.string(forKey: "podcast.model") ?? "large-q4"
        webSearchEnabled = defaults.bool(forKey: "podcast.webSearchEnabled")
        refreshStatus()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(wsURL, forKey: "podcast.wsURL")
        defaults.set(audioBaseURL, forKey: "podcast.audioBaseURL")
        defaults.set(hostAName, forKey: "podcast.hostAName")
        defaults.set(hostBName, forKey: "podcast.hostBName")
        defaults.set(selectedModel, forKey: "podcast.model")
        defaults.set(webSearchEnabled, forKey: "podcast.webSearchEnabled")
        refreshStatus()
    }

    func refreshStatus() {
        if wsURL.isEmpty {
            statusText = "Not configured"
            statusColor = .gray
        } else {
            statusText = "Configured"
            statusColor = .green
        }
    }
}

class PodcastSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: PodcastSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 350)
        self.view = hostingView
    }
}
