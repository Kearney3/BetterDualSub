//
//  BetterDualSubApp.swift
//  BetterDualSub
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

enum FontWeightOption: String, CaseIterable, Identifiable {
    case regular = "Regular"
    case medium = "Medium"
    case bold = "Bold"
    case heavy = "Heavy"

    var id: String { rawValue }

    var titleKey: String { "appearance.weight." + rawValue.lowercased() }

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

enum BackgroundStyleOption: String, CaseIterable, Identifiable {
    case transparent = "Transparent"
    case blur = "Blur"
    case custom = "Custom"

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .transparent: "menu.background.transparent"
        case .blur: "menu.background.blur"
        case .custom: "menu.background.custom"
        }
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

@main
struct BetterDualSubApp: App {
    @StateObject private var subManager = SubtitleManager.shared
    @Environment(\.openWindow) private var openWindow
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppLocalization.languagePreferenceKey) private var language = AppLocalization.defaultLanguage

    var body: some Scene {
        // The scene-level action stays valid when the control center is closed, unlike one captured by its own view.
        let _ = { AppDelegate.openControlCenterAction = { openWindow(id: "control-center") } }()
        WindowGroup("BetterDualSub", id: "control-center") {
            ControlCenterView()
                .environmentObject(subManager)
                .environment(\.locale, Locale(identifier: language))
        }
        .defaultSize(width: 1120, height: 760)
    }
}

extension Notification.Name {
    static let adjustSubtitleDelay = Notification.Name("adjustSubtitleDelay")
    static let manualPlaybackCommand = Notification.Name("manualPlaybackCommand")
    static let navigateToControlCenter = Notification.Name("navigateToControlCenter")
    static let subtitleShortcutsChanged = Notification.Name("subtitleShortcutsChanged")
    static let subtitleDelayStepChanged = Notification.Name("subtitleDelayStepChanged")
    static let subtitleDisplayChanged = Notification.Name("subtitleDisplayChanged")
    static let appLanguageChanged = Notification.Name("appLanguageChanged")
    static let statusBarVisibilityChanged = Notification.Name("statusBarVisibilityChanged")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var observers: [NSObjectProtocol] = []
    /// `NSApp.delegate` is SwiftUI's wrapper, so `as? AppDelegate` always fails; reach the real instance through this.
    nonisolated(unsafe) static weak var shared: AppDelegate?
    nonisolated(unsafe) static var openControlCenterAction: (() -> Void)?
    var openControlCenterWindow: (() -> Void)? { AppDelegate.openControlCenterAction }
    private var overlayPanel: OverlayPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Each process creates its own always-on-top subtitle panel. A second launch would
        // leave a stationary copy behind when the user drags the other process's subtitles.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }) {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        AppDelegate.shared = self
        let panel = OverlayPanel()
        panel.orderFrontRegardless()
        overlayPanel = panel
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The subtitle window is shown by default on every launch, even if it was hidden last time.
        UserDefaults.standard.set(true, forKey: OverlayController.visibleKey)
        updateStatusItemVisibility()
        installHotKeyHandler()
        registerDelayHotKeys()
        // Window restoration can leave only the overlay open (e.g. the control center was closed last time).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.hasVisibleControlCenter else { return }
            self.showControlCenter(page: nil)
        }

        observers.append(NotificationCenter.default.addObserver(
            forName: .subtitleShortcutsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.registerDelayHotKeys()
            self?.refreshStatusMenu()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .appLanguageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatusMenu()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .subtitleDisplayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatusMenu()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .subtitleDelayStepChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshStatusMenu()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .statusBarVisibilityChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateStatusItemVisibility()
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // The subtitle overlay is always "visible", so `flag` is useless; look for the control center itself.
        if !hasVisibleControlCenter { showControlCenter(page: nil) }
        return true
    }

    private func refreshStatusMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: "  BetterDualSub v\(Bundle.main.appVersion)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        if let icon = NSImage(named: "AppIcon") {
            icon.size = NSSize(width: 18, height: 18)
            header.image = icon
        }
        menu.addItem(header)
        menu.addItem(.separator())

        menu.addItem(menuItem("menu.openApp", symbol: "macwindow", action: #selector(openControlCenter)))
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: AppLocalization.string("menu.section.subtitles")))
        menu.addItem(menuItem("menu.openFile", symbol: "doc.badge.plus", action: #selector(openSRT)))
        menu.addItem(menuItem("menu.downloadFromPage", symbol: "arrow.down.circle", action: #selector(openMoviePage)))
        menu.addItem(menuItem("menu.extractFromEpisode", symbol: "film.stack", action: #selector(openLocalPackage)))

        menu.addItem(.sectionHeader(title: AppLocalization.string("menu.section.timing")))
        let delayMenu = NSMenu()
        let actions: [SubtitleShortcutAction] = [.primaryEarlier, .primaryLater, .primaryReset,
                                                .secondaryEarlier, .secondaryLater, .secondaryReset]
        for action in actions {
            let title: String
            let symbol: String
            switch action {
            case .primaryEarlier: title = AppLocalization.format("menu.delay.primaryEarlier", SubtitleDelayStep.milliseconds); symbol = "backward"
            case .primaryLater: title = AppLocalization.format("menu.delay.primaryLater", SubtitleDelayStep.milliseconds); symbol = "forward"
            case .secondaryEarlier: title = AppLocalization.format("menu.delay.secondaryEarlier", SubtitleDelayStep.milliseconds); symbol = "backward"
            case .secondaryLater: title = AppLocalization.format("menu.delay.secondaryLater", SubtitleDelayStep.milliseconds); symbol = "forward"
            case .primaryReset, .secondaryReset: title = AppLocalization.string(action.titleKey); symbol = "arrow.counterclockwise"
            case .manualPlayPause, .manualBack, .manualForward, .toggleLock: continue
            }
            let shortcut = "  \(SubtitleShortcutPreferences.chord(for: action.id).displayName)"
            let command = NSMenuItem(
                title: title + shortcut,
                action: #selector(adjustDelay(_:)),
                keyEquivalent: ""
            )
            command.target = self
            command.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            command.representedObject = ["track": action.track, "delta": action.delta] as [String: Any]
            if action == .primaryReset { delayMenu.addItem(.separator()) }
            delayMenu.addItem(command)
            if action == .primaryReset { delayMenu.addItem(.separator()) }
        }
        let delayItem = NSMenuItem(title: AppLocalization.string("menu.delay.title"), action: nil, keyEquivalent: "")
        delayItem.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)

        menu.addItem(.sectionHeader(title: AppLocalization.string("menu.section.display")))
        let backgroundMenu = NSMenu()
        let selectedBackground = UserDefaults.standard.string(forKey: "backgroundStyle") ?? BackgroundStyleOption.transparent.rawValue
        for option in BackgroundStyleOption.allCases {
            let item = NSMenuItem(title: AppLocalization.string(option.titleKey), action: #selector(changeBackgroundStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            if selectedBackground == option.rawValue { item.state = .on }
            backgroundMenu.addItem(item)
        }
        let backgroundItem = NSMenuItem(title: AppLocalization.string("menu.background.title"), action: nil, keyEquivalent: "")
        backgroundItem.image = NSImage(systemSymbolName: "rectangle.dashed", accessibilityDescription: nil)
        backgroundItem.submenu = backgroundMenu
        menu.addItem(backgroundItem)

        let windowItem = menuItem("menu.window.show", symbol: "macwindow.badge.plus", action: #selector(toggleSubtitleWindow))
        windowItem.state = OverlayController.isVisible ? .on : .off
        menu.addItem(windowItem)
        let lockItem = menuItem("menu.window.lock", symbol: "lock", action: #selector(toggleOverlayLock))
        lockItem.state = OverlayController.isLocked ? .on : .off
        menu.addItem(lockItem)
        menu.addItem(menuItem("menu.window.reset", symbol: "arrow.up.left.and.down.right.magnifyingglass", action: #selector(resetSubtitlePosition)))

        menu.addItem(.separator())
        menu.addItem(menuItem("menu.settings", symbol: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(menuItem("menu.quit", symbol: "power", action: #selector(quitApp), key: "q"))
        statusItem?.menu = menu
    }

    private func updateStatusItemVisibility() {
        let shouldShow = UserDefaults.standard.object(forKey: "showStatusBarItem") as? Bool ?? true
        guard shouldShow else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "captions.bubble", accessibilityDescription: "BetterDualSub")
            statusItem = item
        }
        refreshStatusMenu()
    }

    private func menuItem(_ key: String, symbol: String, action: Selector, key shortcut: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: AppLocalization.string(key), action: action, keyEquivalent: shortcut)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.target = self
        return item
    }

    @objc private func openControlCenter() {
        showControlCenter(page: "guide")
    }

    @objc private func openSettings() {
        showControlCenter(page: "general")
    }

    @objc private func openMoviePage() {
        showControlCenter(page: "movie")
    }

    @objc private func openLocalPackage() {
        showControlCenter(page: "localPackage")
    }

    @objc private func openSRT() {
        showControlCenter(page: "localFile")
    }

    /// Page a freshly opened control center should show; it may not be listening for notifications yet.
    nonisolated(unsafe) static var pendingControlCenterPage: String?

    var hasVisibleControlCenter: Bool {
        NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("control-center") == true && ($0.isVisible || $0.isMiniaturized) }
    }

    /// `page == nil` keeps whatever page the window was showing.
    func showControlCenter(page: String?, afterOpen: (() -> Void)? = nil) {
        AppDelegate.pendingControlCenterPage = page
        NSApp.activate()
        // A closed window can linger in NSApp.windows without content, so only reuse one that is on screen.
        func existingWindow() -> NSWindow? {
            NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("control-center") == true && ($0.isVisible || $0.isMiniaturized) }
        }
        if let existing = existingWindow() {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
        } else {
            openControlCenterWindow?()
        }
        // Navigate once the view exists (the new window reads the pending page itself on appear), and raise it again
        // because the app may not have been active when the menu item was chosen.
        for delay in [0.1, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let page { NotificationCenter.default.post(name: .navigateToControlCenter, object: nil, userInfo: ["page": page]) }
                existingWindow()?.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { afterOpen?() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { AppDelegate.pendingControlCenterPage = nil }
    }

    @objc private func adjustDelay(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: Any],
              let track = values["track"] as? String,
              let delta = values["delta"] as? Int else { return }
        NotificationCenter.default.post(
            name: .adjustSubtitleDelay,
            object: nil,
            userInfo: ["track": track, "delta": delta]
        )
    }

    private func installHotKeyHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        guard InstallEventHandler(
            GetApplicationEventTarget(),
            subtitleHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &hotKeyHandler
        ) == noErr else {
            hotKeyHandler = nil
            return
        }
    }

    private func registerDelayHotKeys() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        guard hotKeyHandler != nil else { return }

        var registered = Set<String>()
        for action in SubtitleShortcutAction.allCases {
            let chord = SubtitleShortcutPreferences.chord(for: action.id)
            guard registered.insert("\(chord.keyCode):\(chord.modifiers)").inserted else { continue }
            let identifier = EventHotKeyID(signature: OSType(0x45585355), id: UInt32(action.id))
            var reference: EventHotKeyRef?
            if RegisterEventHotKey(
                UInt32(chord.keyCode),
                chord.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            ) == noErr, let reference {
                hotKeys.append(reference)
            }
        }
    }

    @objc private func changeBackgroundStyle(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "backgroundStyle")
        updateCheckmark(in: sender.menu, selectedItem: sender)
        NotificationCenter.default.post(name: .subtitleDisplayChanged, object: nil)
    }

    @objc private func toggleSubtitleWindow() {
        OverlayController.setVisible(!OverlayController.isVisible)
    }

    @objc private func toggleOverlayLock() {
        OverlayController.setLocked(!OverlayController.isLocked)
    }

    @objc private func resetSubtitlePosition() {
        OverlayController.resetPosition()
    }

    private func updateCheckmark(in menu: NSMenu?, selectedItem: NSMenuItem) {
        guard let menu else { return }
        for item in menu.items {
            item.state = item == selectedItem ? .on : .off
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func handleHotKey(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard status == noErr, let action = SubtitleShortcutAction(rawValue: Int(identifier.id)) else { return status }
        if action == .toggleLock {
            OverlayController.setLocked(!OverlayController.isLocked)
            return noErr
        }
        if action.isManualPlayback {
            NotificationCenter.default.post(name: .manualPlaybackCommand, object: nil, userInfo: ["action": action.rawValue])
            return noErr
        }
        NotificationCenter.default.post(name: .adjustSubtitleDelay, object: nil,
                                        userInfo: ["track": action.track, "delta": action.delta])
        return noErr
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

private func subtitleHotKeyHandler(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    return delegate.handleHotKey(event)
}
