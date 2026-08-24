//
//  MatchTimer.swift
//  Watch Receiver Watch App
//

import Foundation
import Combine
import WatchKit

enum MatchTimerState {
    case idle
    case running
    case paused
    case finished
}

@MainActor
final class MatchTimer: ObservableObject {

    // MARK: - Alarm tuning

    /// Gap between fallback alarm bursts — kept short so the alarm reads as
    /// one continuous, urgent buzz rather than polite periodic reminders.
    private static let alarmBurstGap: Duration = .milliseconds(500)

    /// How long the scheduled smart-alarm session gets to start before the
    /// in-process fallback loop takes over the haptics.
    private static let sessionGracePeriod: Duration = .seconds(2)

    /// The alarm repeats until acknowledged, but gives up after this long so a
    /// watch left on the bench doesn't buzz itself flat.
    private static let maxAlarmDuration: TimeInterval = 5 * 60

    @Published private(set) var matchDuration: TimeInterval = 45 * 60
    @Published var period: Int = 1   // 1 or 2

    @Published private(set) var state: MatchTimerState = .idle
    @Published private(set) var displaySeconds: TimeInterval = 45 * 60

    /// True from the moment the interval expires until the user acknowledges it.
    @Published private(set) var isAlarming: Bool = false

    /// The instant the current run effectively started (now minus time
    /// accumulated before any pause). Non-nil only while running. Lets the UI
    /// hand the countdown to system-rendered `Text(timerInterval:)`, which
    /// keeps ticking in the always-on dim state and across app suspensions.
    @Published private(set) var elapsedAnchor: Date?

    /// When the current run will hit zero. Non-nil only while running.
    var endDate: Date? { elapsedAnchor?.addingTimeInterval(matchDuration) }

    private var runStartDate: Date = .now
    private var accumulatedSeconds: TimeInterval = 0
    private var cancellable: AnyCancellable?
    private var alarmTask: Task<Void, Never>?
    private var autoSilenceTask: Task<Void, Never>?

    /// Plays the expiry haptics even when the app is backgrounded, and makes
    /// wrist-raise return to the app while it's sounding.
    private let alarmSession = SmartAlarmSession()

    init() {
        alarmSession.onAlarmFired = { [weak self] in self?.alarmSessionDidFire() }
        alarmSession.onSessionInvalidated = { [weak self] in self?.alarmSessionDidEnd() }
    }

    // MARK: - Actions

    func start() {
        stopAlarm()
        runStartDate = Date()
        elapsedAnchor = runStartDate.addingTimeInterval(-accumulatedSeconds)
        state = .running
        startTicker()

        if let end = endDate, end > Date() {
            alarmSession.schedule(at: end)
        }
    }

    func pause() {
        accumulatedSeconds += Date().timeIntervalSince(runStartDate)
        state = .paused
        elapsedAnchor = nil
        stopTicker()
        alarmSession.cancel()
    }

    func reset() {
        stopAlarm()
        stopTicker()
        state = .idle
        accumulatedSeconds = 0
        displaySeconds = matchDuration
        elapsedAnchor = nil
    }

    /// Update the target duration and reset the timer to idle.
    /// Only valid when the timer is not running.
    func setDuration(minutes: Int, seconds: Int) {
        guard state != .running else { return }
        let newDuration = TimeInterval(max(0, min(45, minutes) * 60 + min(59, seconds)))
        matchDuration = newDuration
        reset()
    }

    /// Silence the expiry alarm. Driven by a screen touch anywhere in the app.
    func acknowledgeAlarm() {
        guard isAlarming else { return }
        stopAlarm()
    }

    // MARK: - Tick

    private func startTicker() {
        cancellable = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func stopTicker() {
        cancellable = nil
    }

    private func tick() {
        guard state == .running else { return }
        let elapsed = accumulatedSeconds + Date().timeIntervalSince(runStartDate)
        // ceil() ensures each displayed second lasts a full second.
        // Without it the first tick (at 0.5s) would immediately floor to
        // one second less, making the first second appear to skip.
        let remaining = ceil(max(matchDuration - elapsed, 0))
        displaySeconds = remaining
        if remaining == 0 {
            state = .finished
            elapsedAnchor = nil
            stopTicker()
            startAlarm()
        }
    }

    // MARK: - Alarm

    private func startAlarm() {
        guard !isAlarming else { return }
        isAlarming = true

        autoSilenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.maxAlarmDuration))
            guard !Task.isCancelled else { return }
            self?.stopAlarm()
        }

        // The smart-alarm session owns the haptics — it can buzz from the
        // background, the loop below can't. Give the scheduled session a
        // moment to start before falling back (covers scheduling failures
        // and the tick/session race at the expiry instant).
        Task { [weak self] in
            try? await Task.sleep(for: Self.sessionGracePeriod)
            guard let self, self.isAlarming, !self.alarmSession.isRunning else { return }
            self.startFallbackLoop()
        }
    }

    private func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
        autoSilenceTask?.cancel()
        autoSilenceTask = nil
        alarmSession.cancel()
        isAlarming = false
    }

    /// The session started at the scheduled expiry — possibly while this
    /// object was suspended mid-run, so sync timer state before alarming.
    private func alarmSessionDidFire() {
        if state == .running {
            stopTicker()
            displaySeconds = 0
            elapsedAnchor = nil
            state = .finished
        }
        startAlarm()
    }

    /// The session died while the alarm should still be sounding (system cap,
    /// scheduling error). Fall back to the in-process haptic loop.
    private func alarmSessionDidEnd() {
        guard isAlarming, alarmTask == nil else { return }
        startFallbackLoop()
    }

    private func startFallbackLoop() {
        guard alarmTask == nil else { return }
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isAlarming else { return }
                await self.playAlarmBurst()
                try? await Task.sleep(for: Self.alarmBurstGap)
            }
        }
    }

    /// One fallback alarm burst, used only when the smart-alarm session isn't
    /// available (foreground only — these haptics are dropped when backgrounded).
    /// Deliberately heavier than anything in `HapticPreset` (the BLE flag
    /// alerts) so end-of-interval can't be mistaken for a flag.
    private func playAlarmBurst() async {
        let device = WKInterfaceDevice.current()
        device.play(.notification)
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        device.play(.failure)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        device.play(.failure)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        device.play(.failure)
    }
}
