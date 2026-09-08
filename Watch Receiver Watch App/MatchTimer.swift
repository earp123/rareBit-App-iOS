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

    // MARK: - Pause reminder tuning

    /// How often the wrist is reminded that the countdown is still paused.
    private static let pauseReminderInterval: Duration = .seconds(20)

    /// Gap between the three taps of one reminder. Tight enough that the
    /// burst reads as a single triple tap, but not so tight that three
    /// `.notification` haptics — which are long — smear into one buzz.
    private static let pauseReminderTapGap: Duration = .milliseconds(300)

    /// Reminders give up after this long so a watch left paused on the bench
    /// doesn't tap all night.
    private static let maxPauseReminderDuration: TimeInterval = 30 * 60

    // MARK: - Settings

    private static let countUpThroughPauseKey = "countUpContinuesWhilePaused"

    /// When enabled, pausing stops the countdown only — the count-up keeps
    /// tracking wall-clock time through the stoppage, so it ends up ahead of
    /// the countdown's elapsed time by the total time paused. Disabled
    /// restores the original behaviour where both clocks freeze together.
    @Published var countUpContinuesWhilePaused: Bool {
        didSet {
            UserDefaults.standard.set(countUpContinuesWhilePaused,
                                      forKey: Self.countUpThroughPauseKey)
            applyCountUpPolicy()
        }
    }

    @Published private(set) var matchDuration: TimeInterval = 45 * 60
    @Published var period: Int = 1   // 1 or 2

    @Published private(set) var state: MatchTimerState = .idle
    @Published private(set) var displaySeconds: TimeInterval = 45 * 60

    /// Wall-clock time elapsed in the current period. Normally the mirror of
    /// the countdown, but a pause can let it run on, in which case it exceeds
    /// `matchDuration - displaySeconds` — and eventually `matchDuration`
    /// itself — by the time spent paused. That's the point: total elapsed
    /// time including stoppages.
    @Published private(set) var elapsedSeconds: TimeInterval = 0

    /// True from the moment the interval expires until the user acknowledges it.
    @Published private(set) var isAlarming: Bool = false

    /// The instant the current run effectively started (now minus time
    /// accumulated before any pause). Non-nil only while running. Lets the UI
    /// hand the countdown to system-rendered `Text(timerInterval:)`, which
    /// keeps ticking in the always-on dim state and across app suspensions.
    @Published private(set) var elapsedAnchor: Date?

    /// When the current run will hit zero. Non-nil only while running.
    var endDate: Date? { elapsedAnchor?.addingTimeInterval(matchDuration) }

    /// A match is under way — including while paused, which still needs the
    /// workout session for background runtime and reminder haptics.
    var isActive: Bool { state == .running || state == .paused }

    private var runStartDate: Date = .now
    private var accumulatedSeconds: TimeInterval = 0

    /// Count-up zero point: `now` minus the time counted so far, so the
    /// current value is just `Date().timeIntervalSince(countUpAnchor)`.
    /// Non-nil whenever the count-up is advancing — which, with
    /// `countUpContinuesWhilePaused`, outlives the countdown's own run.
    private var countUpAnchor: Date?
    private var frozenCountUp: TimeInterval = 0

    private var cancellable: AnyCancellable?
    private var alarmTask: Task<Void, Never>?
    private var autoSilenceTask: Task<Void, Never>?
    private var pauseReminderTask: Task<Void, Never>?

    /// Plays the expiry haptics even when the app is backgrounded, and makes
    /// wrist-raise return to the app while it's sounding.
    private let alarmSession = SmartAlarmSession()

    init() {
        let defaults = UserDefaults.standard
        countUpContinuesWhilePaused =
            defaults.object(forKey: Self.countUpThroughPauseKey) as? Bool ?? true

        alarmSession.onAlarmFired = { [weak self] in self?.alarmSessionDidFire() }
        alarmSession.onSessionInvalidated = { [weak self] in self?.alarmSessionDidEnd() }
    }

    // MARK: - Actions

    func start() {
        stopAlarm()
        stopPauseReminder()
        runStartDate = Date()
        elapsedAnchor = runStartDate.addingTimeInterval(-accumulatedSeconds)
        state = .running
        resumeCountUp()   // no-op when a pause already left it running
        syncTicker()

        if let end = endDate, end > Date() {
            alarmSession.schedule(at: end)
        }
    }

    func pause() {
        accumulatedSeconds += Date().timeIntervalSince(runStartDate)
        state = .paused
        elapsedAnchor = nil
        alarmSession.cancel()
        if !countUpContinuesWhilePaused { freezeCountUp() }
        syncTicker()
        startPauseReminder()
    }

    func reset() {
        stopAlarm()
        stopPauseReminder()
        state = .idle
        accumulatedSeconds = 0
        displaySeconds = matchDuration
        elapsedAnchor = nil
        countUpAnchor = nil
        frozenCountUp = 0
        elapsedSeconds = 0
        syncTicker()
    }

    /// Update the target duration and reset the timer to idle.
    /// Only valid when the timer is not running.
    func setDuration(minutes: Int, seconds: Int) {
        guard state != .running else { return }
        let newDuration = TimeInterval(max(0, min(45, minutes) * 60 + min(59, seconds)))
        // Leaving the edit screen without touching the digits mustn't wipe a
        // stoppage in progress — that screen also carries preferences now,
        // not just match parameters.
        guard newDuration != matchDuration else { return }
        matchDuration = newDuration
        reset()
    }

    /// Silence the expiry alarm. Driven by a screen touch anywhere in the app.
    func acknowledgeAlarm() {
        guard isAlarming else { return }
        stopAlarm()
    }

    // MARK: - Count-up

    private func resumeCountUp() {
        guard countUpAnchor == nil else { return }
        countUpAnchor = Date().addingTimeInterval(-frozenCountUp)
    }

    private func freezeCountUp() {
        guard let anchor = countUpAnchor else { return }
        frozenCountUp = Date().timeIntervalSince(anchor)
        countUpAnchor = nil
        elapsedSeconds = floor(frozenCountUp)
    }

    /// The setting is reachable from the edit screen while paused, so it has
    /// to take effect on the stoppage already in progress.
    private func applyCountUpPolicy() {
        guard state == .paused else { return }
        if countUpContinuesWhilePaused {
            resumeCountUp()
        } else {
            freezeCountUp()
        }
        syncTicker()
    }

    // MARK: - Tick

    /// The ticker drives both clocks, so it runs while either is advancing.
    private func syncTicker() {
        let needed = state == .running || (state == .paused && countUpAnchor != nil)
        if needed { startTicker() } else { stopTicker() }
    }

    private func startTicker() {
        guard cancellable == nil else { return }
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
        if let anchor = countUpAnchor {
            elapsedSeconds = floor(Date().timeIntervalSince(anchor))
        }

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
            freezeCountUp()
            syncTicker()
            startAlarm()
        }
    }

    // MARK: - Pause reminder

    /// While the countdown sits paused, tap the wrist every
    /// `pauseReminderInterval` so a stoppage can't be forgotten. Deliberately
    /// starts one full interval after the pause — the referee just tapped the
    /// screen, they know.
    private func startPauseReminder() {
        stopPauseReminder()
        pauseReminderTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.maxPauseReminderDuration)
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pauseReminderInterval)
                guard !Task.isCancelled,
                      let self,
                      self.state == .paused,
                      Date() < deadline else { return }
                await self.playPauseReminder()
            }
        }
    }

    private func stopPauseReminder() {
        pauseReminderTask?.cancel()
        pauseReminderTask = nil
    }

    /// Three taps — the closest WatchKit gets to a literal triple tap.
    /// `.notification` is the strongest haptic available; the lighter
    /// `.click` was unnoticeable on the wrist. Since that's also what the
    /// `doubleNotification` flag preset and the expiry alarm use, rhythm is
    /// what separates the three cues: a tight burst of exactly three, once
    /// every 20s, against the flag's slow pair and the alarm's continuous buzz.
    private func playPauseReminder() async {
        let device = WKInterfaceDevice.current()
        for tap in 0..<3 {
            device.play(.notification)
            guard tap < 2 else { break }
            try? await Task.sleep(for: Self.pauseReminderTapGap)
            guard !Task.isCancelled else { return }
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
            displaySeconds = 0
            elapsedAnchor = nil
            state = .finished
            freezeCountUp()
            syncTicker()
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
