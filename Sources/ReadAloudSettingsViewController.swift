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
            viewModel.refreshModels()
        }
        .onChange(of: viewModel.ollamaURL) { _ in
            viewModel.refreshModels()
        }
    }
}

class ReadAloudSettingsViewModel: ObservableObject {
    @Published var ollamaURL: String = ""
    @Published var ollamaModel: String = ""
    @Published var webSearchEnabled: Bool = false
    @Published var ollamaAPIKey: String = ""
    @Published var resumeBehavior: String = "ask"
    @Published var availableModels: [String] = []
    @Published var isLoadingModels: Bool = false

    func load() {
        let defaults = UserDefaults.standard
        ollamaURL = defaults.string(forKey: "readAloud.ollamaURL") ?? "http://localhost:11434"
        ollamaModel = defaults.string(forKey: "readAloud.ollamaModel") ?? ""
        webSearchEnabled = defaults.bool(forKey: "readAloud.webSearchEnabled")
        ollamaAPIKey = defaults.string(forKey: "readAloud.ollamaAPIKey") ?? ""
        resumeBehavior = defaults.string(forKey: "readAloud.resumeBehavior") ?? "ask"
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(ollamaURL, forKey: "readAloud.ollamaURL")
        defaults.set(ollamaModel, forKey: "readAloud.ollamaModel")
        defaults.set(webSearchEnabled, forKey: "readAloud.webSearchEnabled")
        defaults.set(ollamaAPIKey, forKey: "readAloud.ollamaAPIKey")
        defaults.set(resumeBehavior, forKey: "readAloud.resumeBehavior")
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
