import Cocoa
import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
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
    }
}

class ShortcutsSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: ShortcutsSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        self.view = hostingView
    }
}
