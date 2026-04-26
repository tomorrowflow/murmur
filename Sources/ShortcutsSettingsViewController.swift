import Cocoa
import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
    @AppStorage("ptt.openClaw.enabled") private var openClawPTTEnabled = true
    @AppStorage("ptt.stt.enabled") private var sttPTTEnabled = true
    @AppStorage("ptt.stt.sendReturn") private var sttPTTSendReturn = true
    @AppStorage("ptt.stt.promptRefinement") private var sttPromptRefinement = false
    @AppStorage("ptt.maxRecordingSeconds") private var maxRecordingSeconds = 300
    @AppStorage("ptt.cursorAnchoredOverlay") private var cursorAnchoredOverlay = false
    @AppStorage("ptt.autoStopAfterSilence") private var autoStopAfterSilence = false
    @AppStorage("ptt.silenceTimeoutSeconds") private var silenceTimeoutSeconds: Double = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    shortcutRow("Recording (STT)", for: .startRecording)
                    shortcutRow("Read Selected Text (TTS)", for: .readSelectedText)
                    shortcutRow("Paste Last Transcription", for: .pasteLastTranscription)
                    shortcutRow("Show History", for: .showHistory)
                    shortcutRow("OpenClaw Interface", for: .openclawRecording)
                    shortcutRow("Podcast Tool", for: .podcastToggle)
                    shortcutRow("Draft Editing", for: .draftEditing)
                }

                Section("Push-to-Talk (Double-Tap & Hold)") {
                    Toggle(isOn: $openClawPTTEnabled) {
                        HStack {
                            Text("OpenClaw")
                                .frame(width: 220, alignment: .leading)
                            Text("Left Option key")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: $sttPTTEnabled) {
                        HStack {
                            Text("Recording (STT)")
                                .frame(width: 220, alignment: .leading)
                            Text("Right Option key")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    Toggle(isOn: $sttPTTSendReturn) {
                        HStack {
                            Text("Send Return after paste")
                                .frame(width: 220, alignment: .leading)
                            Text("Auto-submit in chat inputs")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!sttPTTEnabled)

                    Toggle(isOn: $sttPromptRefinement) {
                        HStack {
                            Text("Prompt Refinement")
                                .frame(width: 220, alignment: .leading)
                            Text("Clean up speech via Ollama before pasting — only for recordings longer than 5s (uses LLM from Read Aloud settings)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!sttPTTEnabled)

                    Toggle(isOn: $cursorAnchoredOverlay) {
                        HStack {
                            Text("Cursor-anchored indicator")
                                .frame(width: 220, alignment: .leading)
                            Text("Show recording waveform near text cursor instead of top overlay")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!sttPTTEnabled)

                    Picker(selection: $maxRecordingSeconds) {
                        Text("3 minutes").tag(180)
                        Text("5 minutes").tag(300)
                        Text("10 minutes").tag(600)
                        Text("Unlimited").tag(0)
                    } label: {
                        Text("Max Recording Duration")
                            .frame(width: 220, alignment: .leading)
                    }

                    Toggle(isOn: $autoStopAfterSilence) {
                        HStack {
                            Text("Auto-stop after silence")
                                .frame(width: 220, alignment: .leading)
                            Text("End recording N seconds after you stop speaking, then transcribe")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .disabled(!sttPTTEnabled)

                    if autoStopAfterSilence {
                        HStack {
                            Text("Silence timeout")
                                .frame(width: 220, alignment: .leading)
                            Slider(value: $silenceTimeoutSeconds, in: 1.0...10.0, step: 0.5)
                            Text("\(String(format: "%.1f", silenceTimeoutSeconds))s")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        .disabled(!sttPTTEnabled)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Reset All to Defaults") {
                    resetAllShortcuts()
                }
                .padding()
            }
        }
    }

    private func shortcutRow(_ label: String, for name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(label)
                .frame(width: 220, alignment: .leading)
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private func resetAllShortcuts() {
        KeyboardShortcuts.setShortcut(.init(.c, modifiers: [.command, .option]), for: .startRecording)
        KeyboardShortcuts.setShortcut(.init(.s, modifiers: [.command, .option]), for: .readSelectedText)

        KeyboardShortcuts.setShortcut(.init(.v, modifiers: [.command, .option]), for: .pasteLastTranscription)
        KeyboardShortcuts.setShortcut(.init(.a, modifiers: [.command, .option]), for: .showHistory)
        KeyboardShortcuts.setShortcut(.init(.o, modifiers: [.command, .option]), for: .openclawRecording)
        KeyboardShortcuts.setShortcut(.init(.p, modifiers: [.command, .option]), for: .podcastToggle)
        KeyboardShortcuts.setShortcut(.init(.d, modifiers: [.command, .option]), for: .draftEditing)
        openClawPTTEnabled = true
        sttPTTEnabled = true
        sttPTTSendReturn = true
        sttPromptRefinement = false
        cursorAnchoredOverlay = false
        maxRecordingSeconds = 300
    }
}

class ShortcutsSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: ShortcutsSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        self.view = hostingView
    }
}
