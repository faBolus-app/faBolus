import Testing
import Foundation
@testable import faBolus

/// Deinit must remove both Darwin observers; otherwise a re-created receiver double-dispatches one
/// widget tap onto `handlePending()` / cancel. Counts are deltas against the ambient app-hosted
/// receiver so a naive "exactly one repost" assertion cannot pass.
@MainActor
@Suite(.serialized) struct WidgetBolusReceiverLifecycleTests {

    /// Counts Foundation notification deliveries without capturing a local `var` in an escaping closure
    /// (mirrors the shared `EchoRecorder`'s class-based recorder pattern).
    @MainActor
    final class Counter {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private func makeModel() -> AppModel {
        let backend = MockBackend()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("widget-receiver-lifecycle-\(UUID().uuidString).json")
        return AppModel(source: backend, ledgerStoreURL: url)
    }

    /// Post the widget's Darwin notification, then wait until `counter` stops changing for `quietWindow`
    /// (bounded by `timeout`), and return its value at that point. Darwin notifications round-trip
    /// through `notifyd` even within one process, so delivery is never synchronous with the post call.
    private func postDarwinAndSettle(
        _ name: String, counter: Counter,
        quietWindow: TimeInterval = 0.25, timeout: TimeInterval = 3.0
    ) async -> Int {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
        let deadline = Date().addingTimeInterval(timeout)
        var lastCount = counter.count
        var lastChange = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if counter.count != lastCount {
                lastCount = counter.count
                lastChange = Date()
            } else if Date().timeIntervalSince(lastChange) >= quietWindow {
                break
            }
        }
        return counter.count
    }

    @Test func deallocatedReceiverDoesNotLeaveAStaleDarwinObserverThatDoubleDispatchesPending() async {
        let counter = Counter()
        let obs = NotificationCenter.default.addObserver(forName: .widgetBolusPending, object: nil, queue: .main) { _ in
            counter.bump()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        // Measure the ambient per-post delta before creating any receiver of our own.
        let c0 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        let c1 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        let ambientDelta = c1 - c0

        var receiver: WidgetBolusReceiver? = WidgetBolusReceiver(model: makeModel())
        let c2 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        #expect(
            c2 - c1 == ambientDelta + 1,
            "the live receiver's own Darwin observer should add exactly one extra repost per post")

        receiver = nil  // deinit must remove BOTH Darwin observers, not just deallocate the Swift object
        _ = receiver

        // A brand-new instance — mirrors a scene teardown/re-appear creating a fresh receiver.
        let receiver2 = WidgetBolusReceiver(model: makeModel())
        let c3 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        #expect(
            c3 - c2 == ambientDelta + 1,
            "a stale (deallocated) receiver's un-removed Darwin observer would add a SECOND extra repost here — the exact duplicate-dispatch bug"
        )
        _ = receiver2
    }

    @Test func deallocatedReceiverDoesNotLeaveAStaleDarwinObserverThatDoubleDispatchesCancel() async {
        let counter = Counter()
        let obs = NotificationCenter.default.addObserver(forName: .widgetBolusCancel, object: nil, queue: .main) { _ in
            counter.bump()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let c0 = await postDarwinAndSettle(WidgetBolusStore.darwinCancel, counter: counter)
        let c1 = await postDarwinAndSettle(WidgetBolusStore.darwinCancel, counter: counter)
        let ambientDelta = c1 - c0

        var receiver: WidgetBolusReceiver? = WidgetBolusReceiver(model: makeModel())
        let c2 = await postDarwinAndSettle(WidgetBolusStore.darwinCancel, counter: counter)
        #expect(c2 - c1 == ambientDelta + 1)

        receiver = nil
        _ = receiver

        let receiver2 = WidgetBolusReceiver(model: makeModel())
        let c3 = await postDarwinAndSettle(WidgetBolusStore.darwinCancel, counter: counter)
        #expect(
            c3 - c2 == ambientDelta + 1,
            "the cancel channel must mirror the pending channel's teardown — both Darwin observers are removed in deinit"
        )
        _ = receiver2
    }

    /// Repeats create/deallocate across three generations, so a partial fix (e.g. removing only one of
    /// the two Darwin observers, or only the pending channel) would accumulate extra reposts and be
    /// caught — a single before/after pair could hide a leak that only compounds over repeated scene
    /// churn (backgrounding/foregrounding many times over a session).
    @Test func repeatedCreateDeallocateNeverAccumulatesExtraDarwinObservers() async {
        let counter = Counter()
        let obs = NotificationCenter.default.addObserver(forName: .widgetBolusPending, object: nil, queue: .main) { _ in
            counter.bump()
        }
        defer { NotificationCenter.default.removeObserver(obs) }

        let c0 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        let c1 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        let ambientDelta = c1 - c0

        for _ in 0..<3 {
            var receiver: WidgetBolusReceiver? = WidgetBolusReceiver(model: makeModel())
            _ = receiver
            receiver = nil
        }
        let finalReceiver = WidgetBolusReceiver(model: makeModel())
        let c2 = await postDarwinAndSettle(WidgetBolusStore.darwinPending, counter: counter)
        #expect(
            c2 - c1 == ambientDelta + 1,
            "three prior generations must all have torn down cleanly — exactly one extra live observer remains")
        _ = finalReceiver
    }
}
