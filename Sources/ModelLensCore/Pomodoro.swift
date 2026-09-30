import Foundation

public struct PomodoroState: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case idle, focus, rest }
    public var focusMinutes: Int = 25
    public var restMinutes: Int = 5
    public var phase: Phase = .idle
    public var deadline: Date?
    public var pausedSeconds: Int?
    public init() {}
    public var isRunning: Bool { deadline != nil && phase != .idle }
    public var isPaused: Bool { pausedSeconds != nil && phase != .idle }
    public func remaining(at now: Date = Date()) -> Int {
        if let pausedSeconds { return max(0, min(14_400, pausedSeconds)) }
        return deadline.map { let seconds = $0.timeIntervalSince(now); return seconds.isFinite ? Int(ceil(max(0, min(14_400, seconds)))) : 0 } ?? 0
    }
    public mutating func start(_ phase: Phase = .focus, at now: Date = Date()) {
        focusMinutes = max(1, min(240, focusMinutes)); restMinutes = max(1, min(120, restMinutes))
        self.phase = phase; pausedSeconds = nil
        deadline = phase == .idle ? nil : now.addingTimeInterval(Double((phase == .rest ? restMinutes : focusMinutes) * 60))
    }
    public mutating func pause(at now: Date = Date()) {
        guard isRunning else { return }; pausedSeconds = remaining(at: now); deadline = nil
    }
    public mutating func resume(at now: Date = Date()) {
        guard let seconds = pausedSeconds, phase != .idle else { return }
        deadline = now.addingTimeInterval(Double(max(0, min(14_400, seconds)))); pausedSeconds = nil
    }
    public mutating func stop() { phase = .idle; deadline = nil; pausedSeconds = nil }
    // Finish once, including after sleep; a break starts only when the user chooses it.
    public mutating func finishIfDue(at now: Date = Date()) -> Phase? {
        guard let deadline, now >= deadline, phase != .idle else { return nil }
        let finished = phase; stop(); return finished
    }
}
