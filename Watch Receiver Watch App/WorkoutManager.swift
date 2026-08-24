//
//  WorkoutManager.swift
//  Watch Receiver Watch App
//

import Foundation
import HealthKit
import Combine
import SwiftUI

@MainActor
final class WorkoutManager: NSObject, ObservableObject {

    private let healthStore = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    @Published private(set) var isSessionActive: Bool = false

    // MARK: - Authorization

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            print("[Workout] HealthKit not available on this device")
            return
        }
        let share: Set<HKSampleType> = [HKObjectType.workoutType()]
        do {
            try await healthStore.requestAuthorization(toShare: share, read: [])
            print("[Workout] HealthKit authorization granted")
        } catch {
            print("[Workout] HealthKit authorization error: \(error)")
        }
    }

    // MARK: - Session lifecycle

    func startSession() {
        guard session == nil else {
            print("[Workout] Session already active")
            return
        }

        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .outdoor

        do {
            let workoutSession = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            let workoutBuilder = workoutSession.associatedWorkoutBuilder()
            workoutBuilder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: config
            )

            workoutSession.delegate = self
            workoutBuilder.delegate = self

            self.session = workoutSession
            self.builder = workoutBuilder

            let now = Date()
            workoutSession.startActivity(with: now)
            workoutBuilder.beginCollection(withStart: now) { success, error in
                if let error { print("[Workout] beginCollection error: \(error)") }
            }

            print("[Workout] Session started")
        } catch {
            print("[Workout] Failed to create session: \(error)")
        }
    }

    func stopSession() {
        guard let session else {
            print("[Workout] No active session to stop")
            return
        }
        session.end()
        print("[Workout] Session ended")
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        Task { @MainActor in
            self.isSessionActive = (toState == .running)
            print("[Workout] State \(fromState.rawValue) → \(toState.rawValue)")

            if toState == .ended {
                let capturedBuilder = self.builder
                self.session = nil
                self.builder = nil
                capturedBuilder?.endCollection(withEnd: date) { _, error in
                    if let error { print("[Workout] endCollection error: \(error)") }
                    capturedBuilder?.finishWorkout { _, error in
                        if let error { print("[Workout] finishWorkout error: \(error)") }
                    }
                }
            }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didFailWithError error: Error
    ) {
        print("[Workout] Session failed: \(error)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {}
}
