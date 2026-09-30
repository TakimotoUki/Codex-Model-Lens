import SwiftUI
import AppKit
import UserNotifications
import ModelLensCore

@MainActor @Observable
final class PomodoroController {
    var state = PomodoroState()
    var remaining = 0
    var reminder: String?
    var storageError: String?
    var showDurationEditor = false
    var onTick: (() -> Void)?
    private var ticker: Task<Void, Never>?
    private let url: URL
    private let notificationID = "model-lens-pomodoro"
    init(directory: URL) {
        url = directory.appendingPathComponent("pomodoro.json")
        if let data = try? Data(contentsOf: url), let restored = try? JSONDecoder().decode(PomodoroState.self, from: data) { state = restored }
        state.focusMinutes = max(1, min(240, state.focusMinutes)); state.restMinutes = max(1, min(120, state.restMinutes))
        if state.phase == .idle { state.stop() }
        else if state.pausedSeconds != nil { state.deadline = nil }
        else if state.deadline == nil { state.stop() }
        update(); startTickerIfNeeded()
        if state.isRunning { scheduleReminder() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }
    var text: String { String(format: "%02d:%02d", remaining / 60, remaining % 60) }
    var title: String { state.phase == .rest ? "休息" : "专注" }
    func start(rest: Bool = false) {
        reminder = nil; state.start(rest ? .rest : .focus); save(); update(); startTickerIfNeeded()
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted && state.isRunning { scheduleReminder() }
        }
    }
    func togglePause() {
        if state.isPaused { state.resume(); scheduleReminder() } else { state.pause(); removeScheduledReminder() }
        save(); update(); startTickerIfNeeded()
    }
    func stop() { state.stop(); ticker?.cancel(); ticker = nil; removeScheduledReminder(); save(); update() }
    func saveDurations() { state.focusMinutes = max(1, min(240, state.focusMinutes)); state.restMinutes = max(1, min(120, state.restMinutes)); save() }
    func startForPreview() { update(); startTickerIfNeeded() }
    private func startTickerIfNeeded() {
        ticker?.cancel(); ticker = nil
        guard state.isRunning else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }; self.update()
                if !self.state.isRunning { return }
            }
        }
    }
    private func update() {
        if let phase = state.finishIfDue() {
            reminder = phase == .focus ? "专注结束，休息一下。" : "休息结束，可以开始下一轮。"
            remaining = 0; ticker?.cancel(); ticker = nil; save()
            Task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                if settings.authorizationStatus != .authorized && settings.authorizationStatus != .provisional {
                    NSSound.beep()
                    let alert = NSAlert(); alert.messageText = "番茄钟"; alert.informativeText = reminder ?? "计时结束"
                    alert.addButton(withTitle: "好"); NSApp.activate(); alert.runModal()
                }
            }
        } else { remaining = state.remaining() }
        onTick?()
    }
    private func scheduleReminder() {
        removeScheduledReminder()
        guard state.isRunning, let deadline = state.deadline else { return }
        let content = UNMutableNotificationContent()
        content.title = state.phase == .focus ? "专注结束" : "休息结束"
        content.body = state.phase == .focus ? "辛苦了，休息一下。" : "准备好后，开始下一轮专注。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, deadline.timeIntervalSinceNow), repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notificationID, content: content, trigger: trigger)) { _ in }
    }
    private func removeScheduledReminder() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationID]) }
    private func save() {
        do {
            try PrivateMetadata.save(state, to: url)
            storageError = nil
        } catch { storageError = "计时状态保存失败" }
    }
}
