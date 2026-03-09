import AVFoundation
import Cocoa
import SwiftUI
import UniformTypeIdentifiers

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
                        Text("Host A Voice")
                            .frame(width: 120, alignment: .leading)
                        Text(viewModel.speaker1VoiceStatus)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if viewModel.isUploadingSpeaker1 {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Upload...") {
                            viewModel.pickAndUploadVoiceSample(speaker: 1)
                        }
                        .disabled(viewModel.isUploadingSpeaker1 || viewModel.audioBaseURL.isEmpty)
                        Button(action: { viewModel.togglePlayVoiceSample(speaker: 1) }) {
                            Image(systemName: viewModel.playingSpeaker == 1 ? "stop.fill" : "play.fill")
                                .font(.system(size: 11))
                        }
                        .disabled(viewModel.speaker1VoiceStatus == "Using default voice" || viewModel.audioBaseURL.isEmpty)
                        .help(viewModel.playingSpeaker == 1 ? "Stop" : "Play sample")
                        Button("Clear") {
                            viewModel.clearVoiceSample(speaker: 1)
                        }
                        .disabled(viewModel.speaker1VoiceStatus == "Using default voice" || viewModel.audioBaseURL.isEmpty)
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Host B Name")
                            .frame(width: 120, alignment: .leading)
                        TextField("", text: $viewModel.hostBName, prompt: Text("Jordan"))
                            .textFieldStyle(.roundedBorder)
                    }
                    .labelsHidden()

                    HStack(spacing: 8) {
                        Text("Host B Voice")
                            .frame(width: 120, alignment: .leading)
                        Text(viewModel.speaker2VoiceStatus)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if viewModel.isUploadingSpeaker2 {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Button("Upload...") {
                            viewModel.pickAndUploadVoiceSample(speaker: 2)
                        }
                        .disabled(viewModel.isUploadingSpeaker2 || viewModel.audioBaseURL.isEmpty)
                        Button(action: { viewModel.togglePlayVoiceSample(speaker: 2) }) {
                            Image(systemName: viewModel.playingSpeaker == 2 ? "stop.fill" : "play.fill")
                                .font(.system(size: 11))
                        }
                        .disabled(viewModel.speaker2VoiceStatus == "Using default voice" || viewModel.audioBaseURL.isEmpty)
                        .help(viewModel.playingSpeaker == 2 ? "Stop" : "Play sample")
                        Button("Clear") {
                            viewModel.clearVoiceSample(speaker: 2)
                        }
                        .disabled(viewModel.speaker2VoiceStatus == "Using default voice" || viewModel.audioBaseURL.isEmpty)
                    }
                    .labelsHidden()
                }

                Section("Model") {
                    HStack(spacing: 8) {
                        Text("VibeVoice Model")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.selectedModel) {
                            Text("Large (~19 GB) — Best quality").tag("large-fp")
                            Text("Large Q8 (~12 GB) — Great quality").tag("large-q8")
                            Text("Large Q4 (~7 GB) — Good quality").tag("large-q4")
                            Text("1.5B (~6 GB) — Fastest").tag("1.5b-fp")
                        }
                        .labelsHidden()
                    }
                    Text("Larger models produce better quality but take longer and use more VRAM.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Section("Length") {
                    HStack(spacing: 8) {
                        Text("Podcast Length")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $viewModel.podcastLength) {
                            Text("Auto (based on content)").tag("auto")
                            Text("Short (~8 min)").tag("short")
                            Text("Medium (~15 min)").tag("medium")
                            Text("Long (~30 min)").tag("long")
                        }
                        .labelsHidden()
                    }
                    Text("Auto scales duration with the source content length. Fixed options target a specific runtime.")
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

class PodcastSettingsViewModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var wsURL: String = ""
    @Published var audioBaseURL: String = ""
    @Published var hostAName: String = ""
    @Published var hostBName: String = ""
    @Published var selectedModel: String = "large-q4"
    @Published var podcastLength: String = "auto"
    @Published var webSearchEnabled: Bool = false
    @Published var statusText: String = "Not configured"
    @Published var statusColor: Color = .gray
    @Published var speaker1VoiceStatus: String = "Using default voice"
    @Published var speaker2VoiceStatus: String = "Using default voice"
    @Published var isUploadingSpeaker1: Bool = false
    @Published var isUploadingSpeaker2: Bool = false
    @Published var playingSpeaker: Int? = nil
    private var samplePlayer: AVAudioPlayer?

    func load() {
        let defaults = UserDefaults.standard
        wsURL = defaults.string(forKey: "podcast.wsURL") ?? ""
        audioBaseURL = defaults.string(forKey: "podcast.audioBaseURL") ?? ""
        hostAName = defaults.string(forKey: "podcast.hostAName") ?? ""
        hostBName = defaults.string(forKey: "podcast.hostBName") ?? ""
        selectedModel = defaults.string(forKey: "podcast.model") ?? "large-q4"
        podcastLength = defaults.string(forKey: "podcast.length") ?? "auto"
        webSearchEnabled = defaults.bool(forKey: "podcast.webSearchEnabled")
        refreshStatus()
        fetchVoiceSampleStatus()
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(wsURL, forKey: "podcast.wsURL")
        defaults.set(audioBaseURL, forKey: "podcast.audioBaseURL")
        defaults.set(hostAName, forKey: "podcast.hostAName")
        defaults.set(hostBName, forKey: "podcast.hostBName")
        defaults.set(selectedModel, forKey: "podcast.model")
        defaults.set(podcastLength, forKey: "podcast.length")
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

    func fetchVoiceSampleStatus() {
        guard !audioBaseURL.isEmpty,
              let url = URL(string: "\(audioBaseURL)/voice-samples") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                if let s1 = json["speaker1"] as? [String: Any], s1["uploaded"] as? Bool == true {
                    self?.speaker1VoiceStatus = s1["filename"] as? String ?? "Custom sample"
                } else {
                    self?.speaker1VoiceStatus = "Using default voice"
                }
                if let s2 = json["speaker2"] as? [String: Any], s2["uploaded"] as? Bool == true {
                    self?.speaker2VoiceStatus = s2["filename"] as? String ?? "Custom sample"
                } else {
                    self?.speaker2VoiceStatus = "Using default voice"
                }
            }
        }.resume()
    }

    func pickAndUploadVoiceSample(speaker: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .wav, .mp3, .aiff,
            .init(filenameExtension: "m4a")!,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a voice sample for Host \(speaker == 1 ? "A" : "B")"

        guard panel.runModal() == .OK, let fileURL = panel.url else { return }
        uploadVoiceSample(speaker: speaker, fileURL: fileURL)
    }

    func uploadVoiceSample(speaker: Int, fileURL: URL) {
        guard !audioBaseURL.isEmpty,
              let url = URL(string: "\(audioBaseURL)/voice-samples") else { return }

        if speaker == 1 { isUploadingSpeaker1 = true } else { isUploadingSpeaker2 = true }

        guard let fileData = try? Data(contentsOf: fileURL) else {
            if speaker == 1 { isUploadingSpeaker1 = false } else { isUploadingSpeaker2 = false }
            return
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // Speaker field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"speaker\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(speaker)\r\n".data(using: .utf8)!)
        // Audio file
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"audio\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if speaker == 1 { self?.isUploadingSpeaker1 = false } else { self?.isUploadingSpeaker2 = false }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                    self?.fetchVoiceSampleStatus()
                }
            }
        }.resume()
    }

    func clearVoiceSample(speaker: Int) {
        guard !audioBaseURL.isEmpty,
              let url = URL(string: "\(audioBaseURL)/voice-samples/\(speaker)") else { return }

        // Stop playback if clearing the currently playing sample
        if playingSpeaker == speaker { stopSamplePlayback() }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200, error == nil {
                    self?.fetchVoiceSampleStatus()
                }
            }
        }.resume()
    }

    func togglePlayVoiceSample(speaker: Int) {
        // If already playing this speaker, stop
        if playingSpeaker == speaker {
            stopSamplePlayback()
            return
        }

        // Stop any current playback
        stopSamplePlayback()

        guard !audioBaseURL.isEmpty,
              let url = URL(string: "\(audioBaseURL)/voice-samples/\(speaker)/audio") else { return }

        playingSpeaker = speaker

        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                DispatchQueue.main.async { self?.playingSpeaker = nil }
                return
            }
            DispatchQueue.main.async {
                do {
                    self?.samplePlayer = try AVAudioPlayer(data: data)
                    self?.samplePlayer?.delegate = self
                    self?.samplePlayer?.play()
                } catch {
                    NSLog("Voice sample playback failed: \(error)")
                    self?.playingSpeaker = nil
                }
            }
        }.resume()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.playingSpeaker = nil
            self.samplePlayer = nil
        }
    }

    private func stopSamplePlayback() {
        samplePlayer?.stop()
        samplePlayer = nil
        playingSpeaker = nil
    }
}

class PodcastSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: PodcastSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 450)
        self.view = hostingView
    }
}
