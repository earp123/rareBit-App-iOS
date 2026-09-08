//
//  TimerView.swift
//  Watch Receiver Watch App
//

import SwiftUI
import WatchKit

struct TimerView: View {
    @EnvironmentObject var matchTimer: MatchTimer

    /// When on, a tap on a running clock logs a delay instead of pausing —
    /// pause moves to a long-press. Off by default: it rewires the single
    /// most-used gesture in the app, so it has to be opted into.
    @AppStorage("stoppageTapEnabled") private var stoppageTapEnabled = false

    // Edit mode state
    @State private var editMode = false
    @State private var editMinutes: Double = 45
    @State private var editSeconds: Double = 0
    @State private var alarmPulse = false
    @FocusState private var editFocus: EditField?

    private enum EditField { case minutes, seconds }

    private var showReset: Bool {
        matchTimer.state == .paused || matchTimer.state == .finished
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if matchTimer.isAlarming {
                alarmView
            } else if editMode {
                editView
            } else {
                normalView
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editMode)
    }

    // MARK: - Normal view

    private var normalView: some View {
        ZStack(alignment: .bottom) {

            // Countdown — owns the whole screen as one tap zone, and sits hard
            // on the bottom edge. Only 2pt of padding: the rounded face
            // already carries ~20pt of descender space under the digits, so
            // anything more reads as floating rather than anchored.
            Text(formattedTime(matchTimer.displaySeconds))
                .font(.system(size: 200, weight: .medium, design: .rounded))
                .foregroundStyle(timeColor)
                .minimumScaleFactor(0.1)
                .lineLimit(1)
                .monospacedDigit()
                .padding(.bottom, 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                // Only armed with the setting on, where it's the sole way to
                // pause. Left off otherwise so the gesture map is unchanged.
                .onLongPressGesture(minimumDuration: 0.6) {
                    guard stoppageTapEnabled else { return }
                    handleLongPress()
                }

            // Everything else lives in a single top bar, which is what frees
            // the whole lower half for the countdown. Reset holds its slot
            // even when hidden (opacity, not removal), so the readouts stay
            // centred rather than shifting on pause.
            VStack {
                HStack {
                    resetButton
                    Spacer()
                    readouts
                    Spacer()
                    settingsButton
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
        }
    }

    /// Count-up, and the stoppage total beneath it when that setting is on.
    /// Not hit-testable — it overlaps the clock's tap zone, and a tap landing
    /// on the numerals has to count the same as one anywhere else.
    private var readouts: some View {
        VStack(spacing: 1) {
            Text(formattedTime(elapsedSeconds))
                .font(.system(size: 24, weight: .medium, design: .rounded))
                .foregroundStyle(.green)
                .monospacedDigit()

            if stoppageTapEnabled {
                // Kept a step below the count-up: it's the secondary figure,
                // and the hierarchy is what makes them readable at a glance.
                Text(stoppageLabel)
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
        }
        .fixedSize()
        .allowsHitTesting(false)
    }

    /// Slides in when paused or finished. Keeps its layout slot either way.
    private var resetButton: some View {
        Button { matchTimer.reset() } label: {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(showReset ? 1 : 0)
        .scaleEffect(showReset ? 1 : 0.5)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: showReset)
        .allowsHitTesting(showReset)
    }

    private var settingsButton: some View {
        Button { enterEditMode() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(matchTimer.state == .running ? 0.2 : 0.75))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(matchTimer.state == .running ? 0.05 : 0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(matchTimer.state == .running)
    }

    // MARK: - Alarm view

    /// Full-screen acknowledge state, replacing the whole layout the moment
    /// the interval expires: every pixel is one big "stop" button, so the
    /// alarm can't fight the normal controls. The pulse is driven by a task
    /// that dies with the view — no repeatForever animation lingering after
    /// acknowledgement (repeatForever is un-cancellable in practice).
    private var alarmView: some View {
        Button {
            matchTimer.acknowledgeAlarm()
        } label: {
            VStack(spacing: 4) {
                Text("00:00")
                    .font(.system(size: 200, weight: .medium, design: .rounded))
                    .foregroundStyle(.red)
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .monospacedDigit()
                    .opacity(alarmPulse ? 0.25 : 1)

                Text("TAP TO STOP")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.45)) { alarmPulse.toggle() }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: - Edit view

    private var editView: some View {
        ZStack(alignment: .bottom) {

            // Digit fields — same full-screen size as normal mode
            HStack(spacing: 0) {
                // Minutes
                Text(String(format: "%d", Int(editMinutes)))
                    .foregroundStyle(editFocus == .minutes ? .yellow : .white.opacity(0.35))
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($editFocus, equals: .minutes)
                    .digitalCrownRotation(
                        $editMinutes,
                        from: 0, through: 45, by: 1,
                        sensitivity: .medium,
                        isContinuous: false
                    )
                    .onTapGesture { editFocus = .minutes }

                Text(":")
                    .foregroundStyle(.white.opacity(0.35))
                    .allowsHitTesting(false)

                // Seconds
                Text(String(format: "%02d", Int(editSeconds)))
                    .foregroundStyle(editFocus == .seconds ? .yellow : .white.opacity(0.35))
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($editFocus, equals: .seconds)
                    .digitalCrownRotation(
                        $editSeconds,
                        from: 0, through: 59, by: 1,
                        sensitivity: .medium,
                        isContinuous: false
                    )
                    .onTapGesture { editFocus = .seconds }
            }
            .font(.system(size: 200, weight: .medium, design: .rounded))
            .minimumScaleFactor(0.1)
            .lineLimit(1)
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // All three pills on one row across the top. Dropping the
            // chevrons freed the middle of that row, which is what the
            // period and stoppage capsules used to be squeezed around.
            VStack(spacing: 3) {
                HStack {
                    periodSelector
                    Spacer()
                    stoppageToggle
                }
                if stoppageTapEnabled {
                    // Pause has moved off the tap; say so, or it just looks
                    // like tapping stopped working.
                    HStack {
                        Spacer()
                        Text("Tap logs delay \u{00B7} Hold pauses")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)

            // Done button — mirrors settings button position
            HStack {
                countUpThroughPauseToggle
                Spacer()
                Button { applyEdit() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 40, height: 40)
                        .background(Color.white)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Actions

    private func handleTap() {
        if matchTimer.isAlarming {
            matchTimer.acknowledgeAlarm()
            return
        }
        switch matchTimer.state {
        case .idle, .paused:
            // Nothing to log before kick-off, so a tap starts the match in
            // both modes.
            matchTimer.start()
        case .running:
            // The whole point of the setting: the match clock keeps running.
            if stoppageTapEnabled {
                matchTimer.toggleStoppage()
            } else {
                matchTimer.pause()
            }
        case .finished:
            break
        }
    }

    /// Start/pause, displaced from the tap by the stoppage setting.
    private func handleLongPress() {
        if matchTimer.isAlarming {
            matchTimer.acknowledgeAlarm()
            return
        }
        switch matchTimer.state {
        case .idle, .paused: matchTimer.start()
        case .running:       matchTimer.pause()
        case .finished:      break
        }
    }

    private func enterEditMode() {
        let total = Int(matchTimer.matchDuration)
        editMinutes = Double(total / 60)
        editSeconds = Double(total % 60)
        editMode = true
        // Give the view a moment to appear before setting focus
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            editFocus = .minutes
        }
    }

    private func applyEdit() {
        matchTimer.setDuration(minutes: Int(editMinutes), seconds: Int(editSeconds))
        editFocus = nil
        editMode = false
    }

    // MARK: - Helpers

    /// Opt-in to tap-logs-delay. Orange matches the readout it governs, the
    /// same way the count-up toggle is green. Only reachable from the edit
    /// screen, which is itself unreachable while running — so the gesture map
    /// can never change out from under a live match.
    private var stoppageToggle: some View {
        Button {
            stoppageTapEnabled.toggle()
            // Switching off with a segment still open (possible while paused)
            // would leave it counting invisibly.
            if !stoppageTapEnabled { matchTimer.closeStoppageIfOpen() }
            WKInterfaceDevice.current().play(.click)
        } label: {
            Text("Stoppage")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(stoppageTapEnabled ? .black : .white.opacity(0.5))
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(stoppageTapEnabled ? Color.orange : Color.white.opacity(0.15))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Whether the count-up keeps tracking wall-clock time while the
    /// countdown is paused. Green matches the count-up readout it governs.
    private var countUpThroughPauseToggle: some View {
        let on = matchTimer.countUpContinuesWhilePaused
        return Button {
            matchTimer.countUpContinuesWhilePaused.toggle()
            WKInterfaceDevice.current().play(.click)
        } label: {
            Image(systemName: on ? "stopwatch.fill" : "stopwatch")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Color.green : .white.opacity(0.4))
                .frame(width: 40, height: 40)
                .background(on ? Color.green.opacity(0.18) : Color.white.opacity(0.12))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var periodSelector: some View {
        HStack(spacing: 4) {
            ForEach([1, 2], id: \.self) { p in
                Button {
                    matchTimer.period = p
                } label: {
                    Text(p == 1 ? "1st" : "2nd")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(matchTimer.period == p ? .black : .white.opacity(0.5))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(matchTimer.period == p ? Color.white : Color.white.opacity(0.15))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// `+MM:SS` of total logged delay. A dot marks a segment still running,
    /// so the ref can tell "counting now" from "counted earlier" at a glance.
    private var stoppageLabel: String {
        let time = formattedTime(matchTimer.stoppageSeconds)
        return matchTimer.isStoppageOpen ? "\u{25CF} +\(time)" : "+\(time)"
    }

    private var elapsedSeconds: TimeInterval {
        // 2nd period: count-up starts at matchDuration (e.g. 45:00) and runs on
        // from there, so a 45-minute half reads 45:00 → 90:00.
        matchTimer.period == 1
            ? matchTimer.elapsedSeconds
            : matchTimer.matchDuration + matchTimer.elapsedSeconds
    }

    private var timeColor: Color {
        switch matchTimer.state {
        case .finished: return .red
        case .paused:   return .yellow
        default:        return .white
        }
    }

    private func formattedTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

#Preview {
    TimerView()
        .environmentObject(MatchTimer())
}
