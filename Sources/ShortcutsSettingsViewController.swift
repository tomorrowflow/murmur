import Cocoa
import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
    @AppStorage("ptt.openClaw.enabled") private var openClawPTTEnabled = true
    @AppStorage("ptt.stt.enabled") private var sttPTTEnabled = true
    @AppStorage("ptt.stt.sendReturn") private var sttPTTSendReturn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    shortcutRow("Recording (STT)", for: .startRecording)
                    shortcutRow("Read Selected Text (TTS)", for: .readSelectedText)
                    shortcutRow("Paste Last Transcription", for: .pasteLastTranscription)
                    shortcutRow("Show History", for: .showHistory)
                    shortcutRow("OpenClaw Interface", for: .openclawRecording)
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
        openClawPTTEnabled = true
        sttPTTEnabled = true
        sttPTTSendReturn = true
    }
}

class ShortcutsSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: ShortcutsSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        self.view = hostingView
    }
}
