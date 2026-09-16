import Foundation
import Testing
@testable import CodexMeter

@Suite("Window classification")
struct WindowClassificationTests {
    @Test("Classifies window with positive usage as active immediately")
    func positiveUsageIsActive() {
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 42,
            resetsAt: Date().addingTimeInterval(10_000),
            state: .active
        )
        let classifiedState = WindowClassifier.classify(
            previous: nil,
            current: currentWindow,
            elapsedSeconds: 0
        )
        #expect(classifiedState == .active)
    }

    @Test("Classifies single observation at zero percent as unknown")
    func singleZeroObservationIsUnknown() {
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: Date().addingTimeInterval(18_000),
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: nil,
            current: currentWindow,
            elapsedSeconds: 0
        )
        #expect(classifiedState == .unknown)
    }

    @Test("Classifies observations spaced less than threshold as unknown")
    func tooCloseObservationsAreUnknown() {
        let baseDate = Date()
        let previousWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_000),
            state: .unknown
        )
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_001),
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: previousWindow,
            current: currentWindow,
            elapsedSeconds: 1.5
        )
        #expect(classifiedState == .unknown)
    }

    @Test("Classifies two observations with sliding resetsAt as dormant")
    func slidingResetsAtIsDormant() {
        let baseDate = Date()
        let elapsedInterval: TimeInterval = 6.0
        let previousWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_000),
            state: .unknown
        )
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_000 + elapsedInterval),
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: previousWindow,
            current: currentWindow,
            elapsedSeconds: elapsedInterval
        )
        #expect(classifiedState == .dormant)
    }

    @Test("Classifies two observations with anchored resetsAt as active")
    func anchoredResetsAtIsActive() {
        let baseDate = Date()
        let elapsedInterval: TimeInterval = 6.0
        let previousWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(14_000),
            state: .unknown
        )
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(14_000),
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: previousWindow,
            current: currentWindow,
            elapsedSeconds: elapsedInterval
        )
        #expect(classifiedState == .active)
    }

    @Test("Classifies ambiguous reset drift as unknown")
    func ambiguousResetDriftIsUnknown() {
        let baseDate = Date()
        let elapsedInterval: TimeInterval = 6.0
        let previousWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_000),
            state: .unknown
        )
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: baseDate.addingTimeInterval(18_030),
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: previousWindow,
            current: currentWindow,
            elapsedSeconds: elapsedInterval
        )
        #expect(classifiedState == .unknown)
    }

    @Test("Classifies missing resetsAt as unknown")
    func missingResetsAtIsUnknown() {
        let previousWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: nil,
            state: .unknown
        )
        let currentWindow = QuotaWindow(
            durationMinutes: 300,
            usedPercent: 0,
            resetsAt: nil,
            state: .unknown
        )
        let classifiedState = WindowClassifier.classify(
            previous: previousWindow,
            current: currentWindow,
            elapsedSeconds: 6.0
        )
        #expect(classifiedState == .unknown)
    }
}
