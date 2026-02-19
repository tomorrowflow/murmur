import Cocoa
import SwiftUI

enum ManagerTab: Int {
    case settings = 0
    case shortcuts = 1
    case audioDevices = 2
    case openClaw = 3
}

class UnifiedManagerWindow: NSWindowController {
    private var tabViewController: NSTabViewController!
    private var settingsController: SettingsWindowController?
    private var shortcutsViewController: ShortcutsSettingsViewController?
    private var audioDevicesViewController: AudioDevicesViewController?
    private var openClawViewController: OpenClawSettingsViewController?

    override init(window: NSWindow?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 850, height: 750),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Super Voice Assistant"
        window.minSize = NSSize(width: 600, height: 550)

        super.init(window: window)

        setupTabView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTabView() {
        tabViewController = NSTabViewController()
        tabViewController.tabStyle = .toolbar

        // Settings Tab
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        let settingsViewController = NSViewController()
        settingsViewController.view = settingsController!.window!.contentView!
        let settingsTab = NSTabViewItem(viewController: settingsViewController)
        settingsTab.label = "Settings"
        settingsTab.image = NSImage(systemSymbolName: "gear", accessibilityDescription: "Settings")
        tabViewController.addTabViewItem(settingsTab)

        // Shortcuts Tab
        shortcutsViewController = ShortcutsSettingsViewController()
        let shortcutsTab = NSTabViewItem(viewController: shortcutsViewController!)
        shortcutsTab.label = "Shortcuts"
        shortcutsTab.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Shortcuts")
        tabViewController.addTabViewItem(shortcutsTab)

        // Audio Devices Tab
        audioDevicesViewController = AudioDevicesViewController()
        let audioDevicesTab = NSTabViewItem(viewController: audioDevicesViewController!)
        audioDevicesTab.label = "Audio Devices"
        audioDevicesTab.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Audio Devices")
        tabViewController.addTabViewItem(audioDevicesTab)

        // OpenClaw Tab
        openClawViewController = OpenClawSettingsViewController()
        let openClawTab = NSTabViewItem(viewController: openClawViewController!)
        openClawTab.label = "OpenClaw"
        openClawTab.image = NSImage(systemSymbolName: "network", accessibilityDescription: "OpenClaw")
        tabViewController.addTabViewItem(openClawTab)

        window?.contentViewController = tabViewController
    }

    func showWindow(tab: ManagerTab? = nil) {
        if let tab = tab {
            tabViewController.selectedTabViewItemIndex = tab.rawValue
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
