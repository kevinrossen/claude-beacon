import AppKit
import SwiftUI

/// Borderless panel that sits over the notch and grows to its right when a session is asking you.
final class NotchController {
    private let panel: NSPanel
    private let model = NotchModel()
    private let notchWidth: CGFloat
    private let notchHeight: CGFloat
    private let wing: CGFloat = 70  // extension to the right of the notch

    init() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        notchHeight = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 32
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - l.width - r.width
        } else {
            notchWidth = 180
        }
        let width = notchWidth + wing
        let frame = NSRect(x: screen.frame.midX - notchWidth / 2, y: screen.frame.maxY - notchHeight,
                           width: width, height: notchHeight)
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar + 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: NotchView(model: model, notchWidth: notchWidth, height: notchHeight))
    }

    func setAcknowledge(_ action: @escaping () -> Void) { model.onAcknowledge = action }

    func update(_ state: BeaconState, enabled: Bool) {
        model.state = state
        if enabled && state.waiting > 0 { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }
}

/// Start at login via a per-user LaunchAgent (works for an unbundled, locally built binary).
enum LoginItem {
    static let label = "com.claude-beacon.menubar"
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func set(_ on: Bool) {
        if !on {
            try? FileManager.default.removeItem(at: plistURL)
            return
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [Bundle.main.executablePath ?? exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: plistURL, options: .atomic)
        }
    }
}

/// Notifications through osascript: works without an app bundle (shown as from Script Editor).
func postNotification(title: String, body: String) {
    func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title))"]
    try? p.run()
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var notch: NotchController!
    private var client: BeaconClient?
    private var store: ConfigStore?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var state = BeaconState.empty
    private var connected = false
    private var notified = Set<String>()
    private var firstState = true

    func applicationDidFinishLaunching(_ n: Notification) {
        notch = NotchController()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        guard let store = ConfigStore() else {
            statusItem.button?.image = StatusIcon.offline()
            statusItem.button?.toolTip = "Claude Beacon: missing or incomplete \(ConfigStore.path)"
            return
        }
        self.store = store
        let client = BeaconClient(url: store.url, token: store.token)
        client.onConnection = { [weak self] ok in
            self?.connected = ok
            self?.render()
        }
        client.onState = { [weak self] s in self?.apply(s) }
        notch.setAcknowledge { [weak client] in client?.acknowledge() }
        client.start()
        self.client = client
        render()
    }

    // MARK: state

    private func apply(_ s: BeaconState) {
        state = s
        announce()
        render()
    }

    private func render() {
        guard let store, let button = statusItem.button else { return }
        guard connected else {
            button.image = StatusIcon.offline()
            button.toolTip = "Claude Beacon: cannot reach \(store.url)"
            notch.update(.empty, enabled: false)
            return
        }
        var views = Layout.find(store.settings.layout).slots.map { SlotView.make($0, state) }
        if store.settings.hideEmpty {
            let nonEmpty = views.filter { $0.count > 0 }
            views = nonEmpty.isEmpty ? Array(views.prefix(1)) : nonEmpty
        }
        button.image = StatusIcon.image(views)
        button.toolTip = views.map(\.tooltip).joined(separator: "\n")
        notch.update(state, enabled: store.settings.notch)
    }

    /// Notify once per (session, state change): finished, or started asking.
    private func announce() {
        guard let store else { return }
        var live = Set<String>()
        var fresh: [BeaconSession] = []
        for s in state.sessions where s.isFresh {
            let key = "\(s.session_id)|\(s.updated ?? 0)|\(s.state)"
            live.insert(key)
            // on startup, only announce questions; sessions already idle aren't news
            if !notified.contains(key) && (!firstState || s.isAsking) { fresh.append(s) }
        }
        notified = live
        firstState = false

        switch store.settings.notify {
        case "off": return
        case "asking": fresh = fresh.filter(\.isAsking)
        default: break
        }
        guard !fresh.isEmpty else { return }
        let asking = fresh.filter(\.isAsking), finished = fresh.filter(\.isIdle)
        if fresh.count == 1, let s = fresh.first {
            postNotification(title: s.isAsking ? "\(s.short) is asking you" : "\(s.short) finished",
                             body: (s.title ?? "").isEmpty ? s.project : "\(s.title!) - \(s.project)")
        } else {
            var lines: [String] = []
            if !asking.isEmpty { lines.append("Asking you: " + asking.map(\.short).joined(separator: ", ")) }
            if !finished.isEmpty { lines.append("Finished: " + finished.map(\.short).joined(separator: ", ")) }
            postNotification(title: "\(fresh.count) Claude sessions need a look", body: lines.joined(separator: "\n"))
        }
    }

    // MARK: menu (rebuilt every time it opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let store else {
            menu.addItem(disabled("Missing or incomplete \(ConfigStore.path)"))
            menu.addItem(disabled("It needs: { \"url\": \"http://server:8799\", \"token\": \"...\" }"))
            menu.addItem(.separator())
            menu.addItem(item("Quit Claude Beacon", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
            return
        }

        if !connected {
            menu.addItem(disabled("Cannot reach \(store.url), retrying"))
        } else if state.sessions.isEmpty {
            menu.addItem(disabled("No Claude sessions"))
        } else {
            let multiHost = Set(state.sessions.map(\.host)).count > 1
            section("Asking you", state.asking, multiHost)
            section("Idle", state.idle, multiHost)
            section("Working", state.working, multiHost)
            menu.addItem(.separator())
            let all = item("Mark all seen", #selector(ackAll))
            all.isEnabled = state.sessions.contains(where: \.isFresh)
            menu.addItem(all)
        }

        menu.addItem(.separator())
        menu.addItem(settingsMenu(store))
        menu.addItem(disabled("Claude Beacon \(appVersion)"))
        menu.addItem(item("Quit Claude Beacon", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func section(_ title: String, _ list: [BeaconSession], _ multiHost: Bool) {
        guard !list.isEmpty else { return }
        menu.addItem(disabled("\(title) (\(list.count))"))
        for s in list.sorted(by: { $0.ageNow < $1.ageNow }) {
            var sub: [String] = []
            if let l = s.label, !l.isEmpty, let t = s.title, !t.isEmpty { sub.append("tmux \(l)") }
            sub.append(s.project)
            if multiHost { sub.append(s.host) }
            sub.append(formatAge(s.ageNow))
            let mi = item("\(s.name)    \(sub.joined(separator: " · "))", #selector(ackOne(_:)))
            mi.image = StatusIcon.menuDot(BeaconColor.dot(for: s))
            mi.representedObject = s.session_id
            mi.isEnabled = s.isFresh
            mi.toolTip = s.isFresh ? "Click to mark seen" : nil
            menu.addItem(mi)
        }
    }

    private func settingsMenu(_ store: ConfigStore) -> NSMenuItem {
        let root = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let icons = NSMenuItem(title: "Icons", action: nil, keyEquivalent: "")
        let iconsMenu = NSMenu()
        for l in Layout.all {
            let mi = item(l.label, #selector(chooseLayout(_:)))
            mi.representedObject = l.key
            mi.state = l.key == store.settings.layout ? .on : .off
            iconsMenu.addItem(mi)
        }
        icons.submenu = iconsMenu
        sub.addItem(icons)

        let notify = NSMenuItem(title: "Notifications", action: nil, keyEquivalent: "")
        let notifyMenu = NSMenu()
        for m in notifyModes {
            let mi = item(m.label, #selector(chooseNotify(_:)))
            mi.representedObject = m.key
            mi.state = m.key == store.settings.notify ? .on : .off
            notifyMenu.addItem(mi)
        }
        notify.submenu = notifyMenu
        sub.addItem(notify)

        let hide = item("Hide icons with nothing to show", #selector(toggleHideEmpty))
        hide.state = store.settings.hideEmpty ? .on : .off
        sub.addItem(hide)
        let notchItem = item("Light beside the notch when asked", #selector(toggleNotch))
        notchItem.state = store.settings.notch ? .on : .off
        sub.addItem(notchItem)
        let login = item("Start at login", #selector(toggleLogin))
        login.state = LoginItem.isEnabled ? .on : .off
        sub.addItem(login)
        sub.addItem(.separator())
        sub.addItem(item("Open config file", #selector(openConfig)))

        root.submenu = sub
        return root
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = target ?? self
        return mi
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        return mi
    }

    private func formatAge(_ s: Int) -> String {
        s < 60 ? "\(s)s" : s < 3600 ? "\(s / 60)m" : "\(s / 3600)h"
    }

    // MARK: actions

    @objc private func ackOne(_ sender: NSMenuItem) { client?.acknowledge(sender.representedObject as? String) }
    @objc private func ackAll() { client?.acknowledge() }

    @objc private func chooseLayout(_ sender: NSMenuItem) {
        guard let store, let key = sender.representedObject as? String else { return }
        store.settings.layout = key
        store.save()
        render()
    }

    @objc private func chooseNotify(_ sender: NSMenuItem) {
        guard let store, let key = sender.representedObject as? String else { return }
        store.settings.notify = key
        store.save()
    }

    @objc private func toggleHideEmpty() {
        guard let store else { return }
        store.settings.hideEmpty.toggle()
        store.save()
        render()
    }

    @objc private func toggleNotch() {
        guard let store else { return }
        store.settings.notch.toggle()
        store.save()
        render()
    }

    @objc private func toggleLogin() { LoginItem.set(!LoginItem.isEnabled) }

    @objc private func openConfig() { NSWorkspace.shared.open(URL(fileURLWithPath: ConfigStore.path)) }
}

let appVersion = "0.9"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
