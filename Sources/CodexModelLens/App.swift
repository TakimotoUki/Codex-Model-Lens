import SwiftUI
import AppKit
import QuartzCore
import UserNotifications
import ModelLensCore
@preconcurrency import ScreenCaptureKit

@main
struct ModelLensApp: App {
    @State private var store: LensStore
    @NSApplicationDelegateAdaptor(LensAppDelegate.self) private var appDelegate

    init() {
        let args = CommandLine.arguments
        if args.contains("--preview-path") { FileHandle.standardError.write(Data("Preview: app initialized.\n".utf8)) }
        let directory: URL
        var legacy: URL?
        if let index = args.firstIndex(of: "--data-directory"), args.indices.contains(index + 1) {
            directory = URL(fileURLWithPath: args[index + 1])
        } else {
            directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Model Lens", isDirectory: true)
            // Recover each missing file and merge evidence even when the directory
            // already exists. Never overwrite newer settings or damaged archives.
            legacy = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Data")
        }
        let initialStore = LensStore(dataDirectory: directory, legacyDirectory: legacy)
        _store = State(initialValue: initialStore)
        LensAppDelegate.bootstrapStore = initialStore
    }

    var body: some Scene {
        Window("Codex Model Lens", id: "main") {
            LensRootView(store: store, delegate: appDelegate)
        }
        .defaultSize(width: 1280, height: 850)
        .defaultLaunchBehavior(CommandLine.arguments.contains("--preview-path") && !CommandLine.arguments.contains("--preview-menu") ? .presented : .suppressed)
        .restorationBehavior(.disabled)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("检测设置…") { store.showingSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("检测") {
                Button("立即刷新") { Task { await store.refresh() } }.keyboardShortcut("r", modifiers: .command)
                Button(store.monitoring ? "暂停自动检测" : "恢复自动检测") { store.monitoring.toggle() }
                Divider()
                Button("导出 JSON 历史…") { store.export(csv: false) }
                Button("导出 CSV 表格…") { store.export(csv: true) }
                Button("导入模型证据…") { store.importEvidence() }
                Button("请求诊断与证据导出…") { store.showRequestDiagnostics() }
            }
        }
    }
}

struct LensRootView: View {
    @Bindable var store: LensStore
    let delegate: LensAppDelegate
    var body: some View {
        ContentView(store: store)
            .frame(minWidth: 1060, minHeight: 700).tint(.blue)
            .onChange(of: store.latestScan.scannedAt) { _, _ in
                let args = CommandLine.arguments
                if args.contains("--preview-path") {
                    func value(_ key: String) -> String? {
                        guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
                        return args[i + 1]
                    }
                    if let filter = value("--preview-filter").flatMap(TaskFilter.init(rawValue:)) { store.filter = filter }
                    if let search = value("--preview-search") { store.search = search }
                    store.selection = value("--preview-task") ?? store.visibleThreads.first?.id
                    if args.contains("--preview-requests") { store.showRequestDiagnostics() }
                    if args.contains("--preview-diagnostics") { store.showingDiagnostics = true }
                    if args.contains("--preview-probe") { store.showingProbe = true }
                    store.monitoring = false
                }
                delegate.capturePreviewIfRequested()
            }
    }
}

@MainActor
final class LensAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static var bootstrapStore: LensStore?
    private var hostedWindow: NSWindow?
    private var previewScheduled = false
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var utilities: [UtilityPage: NSWindow] = [:]
    private var lastAnchor: NSRect = .zero
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--preview-path") { FileHandle.standardError.write(Data("Preview: application finished launching.\n".utf8)) }
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        if CommandLine.arguments.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        Self.bootstrapStore?.start()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = MenuBarBrandIcon.image
            button.image?.isTemplate = true; button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self; button.action = #selector(togglePopover)
            button.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: button, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.followAnchor() }
            }
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: button.window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.followAnchor() }
            }
            button.toolTip = "Codex Model Lens · 任务模型、额度与番茄钟"
        }
        popover.behavior = .transient
        popover.animates = true
        Self.bootstrapStore?.pomodoro.onTick = { [weak self] in self?.updateStatusTitle() }
        updateStatusTitle()
        writeIdleAuditIfRequested()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                if window.title == "Codex Model Lens" { Self.bootstrapStore?.mainWindowVisible = false }
            }
        }
        if CommandLine.arguments.contains("--preview-path") { NSApp.activate() }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if CommandLine.arguments.contains("--preview-menu") {
                if let store = Self.bootstrapStore {
                    for _ in 0..<60 where store.isScanning { try? await Task.sleep(for: .milliseconds(500)) }
                }
                showPopover(); capturePreviewIfRequested()
            } else if CommandLine.arguments.contains("--preview-path") {
                if !NSApp.windows.contains(where: { $0.isVisible && $0.title == "Codex Model Lens" }) { showMainWindow() }
                if CommandLine.arguments.contains("--demo") {
                    if let store = Self.bootstrapStore {
                        if CommandLine.arguments.contains("--preview-diagnostics") { store.showingDiagnostics = true }
                        if CommandLine.arguments.contains("--preview-requests") { store.showingRequests = true }
                        if CommandLine.arguments.contains("--preview-settings") { store.showingSettings = true }
                        if CommandLine.arguments.contains("--preview-probe") { store.showingProbe = true }
                    }
                    capturePreviewIfRequested()
                }
            }
            if let index = CommandLine.arguments.firstIndex(of: "--preview-utility"), CommandLine.arguments.indices.contains(index + 1),
               let page = UtilityPage(rawValue: CommandLine.arguments[index + 1]) { showUtility(page); capturePreviewIfRequested() }
            if CommandLine.arguments.contains("--preview-path") {
                FileHandle.standardError.write(Data("Preview: \(NSApp.windows.count) windows, \(NSApp.windows.filter(\.isVisible).count) visible.\n".utf8))
                let entries = NSApp.mainMenu?.items.flatMap { $0.submenu?.items.map(\.title) ?? [] } ?? []
                FileHandle.standardError.write(Data("Preview: menu entries \(entries).\n".utf8))
            }
        }
    }
    func capturePreviewIfRequested() {
        guard !previewScheduled else { return }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--preview-path"), args.indices.contains(index + 1) {
            previewScheduled = true
            let output = args[index + 1]
            Task { @MainActor in
                // Capture this application's own window through the native compositor. AppKit's
                // cacheDisplay omits SwiftUI's composited materials and produces misleading images.
                try? await Task.sleep(for: .seconds(3))
                let utilityPage = args.firstIndex(of: "--preview-utility").flatMap { args.indices.contains($0 + 1) ? UtilityPage(rawValue: args[$0 + 1]) : nil }
                var availableWindow = utilityPage.flatMap { utilities[$0] } ?? NSApp.keyWindow?.sheetParent ?? NSApp.keyWindow ?? popover.contentViewController?.view.window ?? hostedWindow ?? NSApp.windows.first(where: { $0.isVisible })
                for _ in 0..<5 where availableWindow == nil {
                    try? await Task.sleep(for: .seconds(1))
                    availableWindow = popover.contentViewController?.view.window ?? hostedWindow ?? NSApp.windows.first(where: { $0.isVisible })
                }
                guard let window = availableWindow else {
                    FileHandle.standardError.write(Data("Preview: no own window available.\n".utf8))
                    NSApp.terminate(nil); return
                }
                do {
                    // currentProcess exposes only content this process can capture without TCC
                    // consent; never enumerate or capture other applications or the desktop.
                    let content = try await SCShareableContent.currentProcess
                    guard let ownWindow = content.windows.first(where: { Int($0.windowID) == window.windowNumber }) ?? content.windows.filter({ $0.isOnScreen && $0.frame.width >= 390 && $0.frame.height >= 160 }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                        FileHandle.standardError.write(Data("Preview: own window IDs \(content.windows.map { $0.windowID }); AppKit \(window.windowNumber); frame \(window.frame); visible \(window.isVisible).\n".utf8))
                        FileHandle.standardError.write(Data("Own application window is unavailable for capture.\n".utf8))
                        NSApp.terminate(nil); return
                    }
                    let filter = SCContentFilter(desktopIndependentWindow: ownWindow)
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(window.frame.width * window.backingScaleFactor)
                    configuration.height = Int(window.frame.height * window.backingScaleFactor)
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    let screenshot = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    let bitmap = NSBitmapImageRep(cgImage: screenshot)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else {
                        throw NSError(domain: "ModelLensPreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed."])
                    }
                    try png.write(to: URL(fileURLWithPath: output))
                    FileHandle.standardError.write(Data("Preview: screenshot saved.\n".utf8))
                } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)) }
                // A preview sheet must be dismissed before AppKit can finish termination.
                Self.bootstrapStore?.showingRequests = false
                Self.bootstrapStore?.showingSettings = false
                Self.bootstrapStore?.showingDiagnostics = false
                Self.bootstrapStore?.showingProbe = false
                try? await Task.sleep(for: .milliseconds(250))
                NSApp.terminate(nil)
            }
        }
    }
    private func writeIdleAuditIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--idle-audit"), args.indices.contains(index + 1) else { return }
        let destination = args[index + 1]
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            let result: [String: Any] = ["activationPolicy": NSApp.activationPolicy().rawValue,
                "visibleMainWindows": NSApp.windows.filter { $0.isVisible && $0.title == "Codex Model Lens" }.count,
                "statusItemPresent": statusItem != nil, "popoverVisible": popover.isShown,
                "runningTimer": Self.bootstrapStore?.pomodoro.state.isRunning ?? false]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: destination), options: .atomic)
            }
            var ticks: [[String: Any]] = []
            for _ in 0..<3 {
                ticks.append(["time": Date().timeIntervalSince1970, "title": statusItem?.button?.title ?? "",
                              "remaining": Self.bootstrapStore?.pomodoro.remaining ?? 0])
                try? await Task.sleep(for: .seconds(1))
            }
            if let data = try? JSONSerialization.data(withJSONObject: ticks, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: destination + ".ticks.json"), options: .atomic)
            }
        }
    }
    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }
    private func showPopover() {
        guard let button = statusItem?.button, let store = Self.bootstrapStore else { return }
        if popover.contentViewController == nil {
            popover.contentViewController = NSHostingController(rootView: MenuBarView(store: store, delegate: self))
            popover.contentSize = NSSize(width: 390, height: 300)
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        lastAnchor = .zero; followAnchor()
    }
    private func updateStatusTitle() {
        guard let timer = Self.bootstrapStore?.pomodoro else { return }
        statusItem?.button?.title = timer.state.phase == .idle ? "" : " \(timer.text)" + (timer.state.isPaused ? " Ⅱ" : "")
        DispatchQueue.main.async { [weak self] in self?.followAnchor() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    var maximumMenuBodyHeight: CGFloat { max(160, min(680, (statusItem?.button?.window?.screen?.visibleFrame.height ?? 900) - 200)) }
    func resizePopover(height: CGFloat) {
        let target = NSSize(width: 390, height: max(160, min(820, ceil(height))))
        guard abs(popover.contentSize.height - target.height) > 1 else { return }
        popover.contentSize = target
        followAnchor()
    }
    private func followAnchor() {
        guard popover.isShown, let button = statusItem?.button, let statusWindow = button.window,
              let panel = popover.contentViewController?.view.window else { return }
        let anchor = statusWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor != lastAnchor else { return }
        lastAnchor = anchor
        popover.positioningRect = button.bounds
        guard let screen = statusWindow.screen else { return }
        let width = panel.frame.width
        let x = min(screen.visibleFrame.maxX - width - 6, max(screen.visibleFrame.minX + 6, anchor.midX - width / 2))
        let origin = NSPoint(x: x, y: panel.frame.origin.y)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(origin)
        }
    }
    func showUtility(_ page: UtilityPage) {
        popover.performClose(nil); NSApp.activate()
        if let window = utilities[page] { window.makeKeyAndOrderFront(nil); return }
        guard let store = Self.bootstrapStore else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: UtilityView(store: store, page: page, close: { [weak self] in self?.utilities[page]?.close() })))
        window.title = page.title; window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        window.center(); window.makeKeyAndOrderFront(nil); utilities[page] = window
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.bootstrapStore?.networkCapture.isRunning == true {
            let alert = NSAlert(); alert.messageText = "网络采集代理仍在运行"
            alert.informativeText = "退出 Model Lens 会停止采集代理，并中断使用该代理的 Codex 网络连接。请先退出 Codex，再退出本程序。"
            alert.addButton(withTitle: "取消退出"); alert.addButton(withTitle: "仍然退出")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        popover.performClose(nil)
        Self.bootstrapStore?.shutdown()
        guard Self.bootstrapStore?.networkCapture.isRunning == true || Self.bootstrapStore?.networkCapture.busy == true || Self.bootstrapStore?.isProbing == true || Self.bootstrapStore?.usage.loading.isEmpty == false else { return .terminateNow }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
    func showMainWindow() {
        popover.performClose(nil)
        Self.bootstrapStore?.mainWindowVisible = true
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.contentView != nil && $0.title == "Codex Model Lens" }) {
            window.makeKeyAndOrderFront(nil); return
        }
        // The single SwiftUI Window scene registers this public Window menu action.
        // Use it when a launch/reopen event arrives without a restored visible window.
        guard let menu = NSApp.mainMenu else { return }
        for root in menu.items {
            guard let submenu = root.submenu else { continue }
            if let index = submenu.items.firstIndex(where: { $0.title == "Codex Model Lens" && $0.action != nil }) {
                submenu.performActionForItem(at: index); return
            }
        }
        // AppKit hosting also handles launches without a SwiftUI scene restoration event.
        guard let store = Self.bootstrapStore else { return }
        let controller = NSHostingController(rootView: LensRootView(store: store, delegate: self))
        let window = NSWindow(contentViewController: controller)
        window.title = "Codex Model Lens"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1280, height: 850)); window.minSize = NSSize(width: 1060, height: 700)
        window.titlebarAppearsTransparent = true; window.toolbarStyle = .unified
        window.center(); window.makeKeyAndOrderFront(nil)
        hostedWindow = window
    }
}
