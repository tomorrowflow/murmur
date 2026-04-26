import Cocoa
import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AudioDuckMode.userDefaultsKey) private var duckModeRaw = AudioDuckMode.current.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Startup") {
                    Toggle(isOn: $launchAtLogin) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Launch at Login")
                            Text("Automatically start Murmur when you log in")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                }

                Section("Audio Ducking") {
                    Picker("Mode", selection: $duckModeRaw) {
                        Text("Off").tag(AudioDuckMode.off.rawValue)
                        Text("Duck during recording").tag(AudioDuckMode.recording.rawValue)
                        Text("Pause other media during recording and playback").tag(AudioDuckMode.recordingAndPlayback.rawValue)
                    }
                    .pickerStyle(.radioGroup)

                    Text("Off: Murmur leaves system audio alone.\nDuck during recording: master volume drops while STT is recording, reducing mic bleed from speakers — does not affect playback.\nPause during recording and playback: pauses Spotify/Music/Podcasts (or any app that owns macOS Now Playing) while Murmur is recording or reading aloud, and resumes when finished. Master volume is left alone — your TTS plays at normal level.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to \(enabled ? "enable" : "disable") launch at login: \(error)")
            // Revert the toggle on failure
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

class GeneralSettingsViewController: NSViewController {
    override func loadView() {
        let hostingView = NSHostingView(rootView: GeneralSettingsView())
        hostingView.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
        self.view = hostingView
    }
}
