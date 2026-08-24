//
//  SmartAlarmSession.swift
//  Watch Receiver Watch App
//

import Foundation
import WatchKit

/// Wraps a scheduled smart-alarm `WKExtendedRuntimeSession`.
///
/// The session is scheduled to start exactly when the match timer will expire.
/// When it starts, the system wakes the app (even from suspension) and allows
/// repeating haptics via `notifyUser` — the only way a watch app can buzz the
/// wrist from the background. An active session also makes wrist-raise return
/// to the app instead of the watch face ("Show Last App: While in Session").
/// Requires the `alarm` value in `WKBackgroundModes`.
@MainActor
final class SmartAlarmSession: NSObject {

    /// The scheduled session started, i.e. the timer expired. Fires whether
    /// the app is frontmost or backgrounded; haptics are already sounding.
    var onAlarmFired: (() -> Void)?

    /// The session ended for any reason other than `cancel()` — the ~30 min
    /// system cap, a scheduling error, etc. — so the owner can fall back.
    var onSessionInvalidated: (() -> Void)?

    private(set) var isRunning = false
    private var session: WKExtendedRuntimeSession?

    private func log(_ msg: String) {
        print("Alarm ▶︎ \(msg)")
    }

    /// Schedule the alarm to fire at `date`, replacing any previous schedule.
    /// Must be called while the app is active; `date` at most 36h out.
    func schedule(at date: Date) {
        cancel()
        let s = WKExtendedRuntimeSession()
        s.delegate = self
        s.start(at: date)
        session = s
        log("smart-alarm session scheduled for \(date)")
    }

    /// Cancel the schedule / silence the alarm.
    func cancel() {
        guard let s = session else { return }
        session = nil
        isRunning = false
        s.invalidate()
    }
}

extension SmartAlarmSession: WKExtendedRuntimeSessionDelegate {

    nonisolated func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in
            guard s === self.session else { return }  // superseded schedule
            self.isRunning = true
            self.log("session started — notifying user")
            // .notification is the longest, most attention-grabbing haptic;
            // repeated at 0.7s it reads as near-continuous buzzing until the
            // session is invalidated by an acknowledgement.
            s.notifyUser(hapticType: .notification) { haptic in
                haptic.pointee = .notification
                return 0.7
            }
            self.onAlarmFired?()
        }
    }

    nonisolated func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {
        // System cap (~30 min) approaching. Nothing to do: the owner's
        // auto-silence deadline is far shorter than the cap.
    }

    nonisolated func extendedRuntimeSession(_ s: WKExtendedRuntimeSession,
                                            didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
                                            error: Error?) {
        Task { @MainActor in
            guard s === self.session else { return }  // cancelled or superseded by us
            self.session = nil
            self.isRunning = false
            self.log("session invalidated reason=\(reason.rawValue) error=\(error.map { "\($0)" } ?? "none")")
            self.onSessionInvalidated?()
        }
    }
}
