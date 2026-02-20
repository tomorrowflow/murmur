import Cocoa
import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

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
