import Cocoa
import SwiftUI

struct ReadAloudSettingsView: View {
    @StateObject private var viewModel = ReadAloudSettingsViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Ollama") {
                    HStack(spacing: 8) {
                        Text("Ollama URL")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.ollamaURL, prompt: Text("http://localhost:11434"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Model")
                            .frame(width: 120, alignment: .leading)
                        if viewModel.availableModels.isEmpty {
                            TextField("", text: $viewModel.ollamaModel, prompt: Text("e.g. llama3.2, qwen2.5"))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("", selection: $viewModel.ollamaModel) {
                                if viewModel.ollamaModel.isEmpty || !viewModel.availableModels.contains(viewModel.ollamaModel) {
                                    Text("Select a model...").tag("")
                                }
                                ForEach(viewModel.availableModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                        }
                        Button(action: { viewModel.refreshModels() }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .help("Refresh model list from Ollama")
                        .disabled(viewModel.isLoadingModels)
                        if viewModel.isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .labelsHidden()
                }

                Section {
                    Text("Reading and answers are always in English. Non-English text will be translated to English before being read aloud.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                } header: {
                    Text("Language")
                }

                Section("Web Search") {
                    Toggle(isOn: $viewModel.webSearchEnabled) {
                        HStack {
                            Text("Web Search")
                                .frame(width: 120, alignment: .leading)
                            Text("Enrich answers with live web results")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    if viewModel.webSearchEnabled {
                        HStack(spacing: 8) {
                            Text("Ollama API Key")
                                .frame(width: 120, alignment: .leading)
                            SecureField("", text: $viewModel.ollamaAPIKey, prompt: Text("From ollama.com"))
                                .textFieldStyle(.roundedBorder)
                        }
                        .labelsHidden()

                        Text("Required for web search. Get a key from ollama.com.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Section("After Answer") {
                    HStack(spacing: 8) {
                        Text("Resume Behavior")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.resumeBehavior) {
                            Text("Ask to continue").tag("ask")
                            Text("Auto-resume (2s)").tag("auto")
                            Text("Stop").tag("stop")
                        }
                        .labelsHidden()
                    }

                    Text("Controls what happens after an answer is spoken.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

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

                    Text("Cleans up the assistant's final message before it's spoken. Regex strips code blocks, paths, markdown, and PIDs. Ollama rewrites it as a spoken summary using the model above.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Draft Editing") {
                    HStack(spacing: 8) {
                        Text("Default Editor")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.draftEditingEditor) {
                            Text("Auto-detect").tag("auto")
                            Text("TextMate").tag("textmate")
                            Text("Obsidian").tag("obsidian")
                        }
                        .labelsHidden()
                    }

                    Text("Cmd+Opt+D starts draft editing. Auto-detect checks TextMate first, then Obsidian.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if viewModel.draftEditingEditor == "obsidian" || viewModel.draftEditingEditor == "auto" {
                        Text("Obsidian requires the Murmur Bridge plugin installed in your vault.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Text("Plugin Status")
                                .frame(width: 120, alignment: .leading)
                            Circle()
                                .fill(viewModel.obsidianPluginReachable ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(viewModel.obsidianPluginReachable ? "Connected" : "Not reachable")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Button(action: { viewModel.checkObsidianPlugin() }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help("Check connection to Murmur Bridge plugin")
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            viewModel.load()
            viewModel.refreshModels()
        }
        .onChange(of: viewModel.ollamaURL) { _ in
            viewModel.refreshModels()
        }
    }
}

class ReadAloudSettingsViewModel: ObservableObject {
    // Changes to these properties are persisted to UserDefaults immediately
    // via didSet — no explicit Save action is exposed. `isLoading` suppresses
    // the write-back during initial population so load() stays idempotent.
    private var isLoading = false

    @Published var ollamaURL: String = "" { didSet { persist(ollamaURL, forKey: "readAloud.ollamaURL") } }
    @Published var ollamaModel: String = "" { didSet { persist(ollamaModel, forKey: "readAloud.ollamaModel") } }
    @Published var webSearchEnabled: Bool = false { didSet { persist(webSearchEnabled, forKey: "readAloud.webSearchEnabled") } }
    @Published var ollamaAPIKey: String = "" { didSet { persist(ollamaAPIKey, forKey: "readAloud.ollamaAPIKey") } }
    @Published var resumeBehavior: String = "ask" { didSet { persist(resumeBehavior, forKey: "readAloud.resumeBehavior") } }
    @Published var draftEditingEditor: String = "auto" { didSet { persist(draftEditingEditor, forKey: "draftEditing.editor") } }
    @Published var recapPreprocessMode: String = "none" { didSet { persist(recapPreprocessMode, forKey: "recap.preprocessMode") } }
    @Published var obsidianPluginReachable: Bool = false
    @Published var availableModels: [String] = []
    @Published var isLoadingModels: Bool = false

    private func persist(_ value: Any, forKey key: String) {
        guard !isLoading else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    func load() {
        isLoading = true
        defer { isLoading = false }
        let defaults = UserDefaults.standard
        ollamaURL = defaults.string(forKey: "readAloud.ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "readAloud.ollamaModel") ?? ""
        webSearchEnabled = defaults.bool(forKey: "readAloud.webSearchEnabled")
        ollamaAPIKey = defaults.string(forKey: "readAloud.ollamaAPIKey") ?? ""
        resumeBehavior = defaults.string(forKey: "readAloud.resumeBehavior") ?? "ask"
        draftEditingEditor = defaults.string(forKey: "draftEditing.editor") ?? "auto"
        recapPreprocessMode = defaults.string(forKey: "recap.preprocessMode") ?? "none"
    }

    func checkObsidianPlugin() {
        Task {
            let reachable = ObsidianAdapter.isCompanionRunning()
            await MainActor.run {
                self.obsidianPluginReachable = reachable
            }
        }
    }

    func refreshModels() {
        isLoadingModels = true
        let url = ollamaURL
        Task {
            let models = await OllamaClient.listModels(baseURL: url)
            await MainActor.run {
                self.availableModels = models
                self.isLoadingModels = false
            }
        }
    }
}

class ReadAloudSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: ReadAloudSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        self.view = hostingView
    }
}
