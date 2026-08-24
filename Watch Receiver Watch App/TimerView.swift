//
//  TimerView.swift
//  Watch Receiver Watch App
//

import SwiftUI

struct TimerView: View {
    @EnvironmentObject var matchTimer: MatchTimer

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

            // Main countdown timer — fills entire tap zone.
            // Count-up timer floats over the top as an overlay so it
            // doesn't compete for layout space.
            Text(formattedTime(matchTimer.displaySeconds))
                .font(.system(size: 200, weight: .medium, design: .rounded))
                .foregroundStyle(timeColor)
                .minimumScaleFactor(0.1)
                .lineLimit(1)
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { handleTap() }
                .overlay(alignment: .top) {
                    Text(formattedTime(elapsedSeconds))
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.green)
                        .monospacedDigit()
                        .padding(.top, 2)
                }

            // Buttons float at the bottom — intercept their own taps only
            HStack {
                // Reset — slides in when paused or finished
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

                Spacer()

                // Settings
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
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
        }
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

            // Period selector — top left
            VStack {
                HStack {
                    periodSelector
                    Spacer()
                }
                .padding(.leading, 10)
                .padding(.top, 4)
                Spacer()
            }

            // Chevrons float at top and bottom centre
            VStack {
                Button { step(+1) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { step(-1) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.plain)
            }

            // Done button — mirrors settings button position
            HStack {
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

    private func step(_ direction: Int) {
        let target = editFocus ?? .minutes
        switch target {
        case .minutes:
            editMinutes = max(0, min(45, editMinutes + Double(direction)))
        case .seconds:
            editSeconds = max(0, min(59, editSeconds + Double(direction)))
        }
    }

    // MARK: - Helpers

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

    private var elapsedSeconds: TimeInterval {
        let periodElapsed = max(0, matchTimer.matchDuration - matchTimer.displaySeconds)
        // 2nd period: count-up starts at matchDuration (e.g. 45:00) and runs up to 90:00
        return matchTimer.period == 1 ? periodElapsed : matchTimer.matchDuration + periodElapsed
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
