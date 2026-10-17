import Foundation

/// Reads one piece of text aloud. `speak` returns when speech has finished or been stopped.
@MainActor
protocol SpeechEngine: AnyObject {
    func speak(_ text: String) async
    func stop()
}

/// Where `AlertCenter` sends alerts to be read aloud.
@MainActor
protocol AlertSpeaker: AnyObject {
    /// Queues `text`. A `key` already queued or spoken this session is dropped.
    func enqueue(_ text: String, key: String)
    /// Stops speaking and drops everything queued.
    func stop()
}

/// Speaks alerts one at a time, in order, and drops duplicates.
@MainActor
final class SpeechQueue: AlertSpeaker {
    /// If more than this many are waiting, the oldest waiting ones are dropped.
    let maxPending: Int
    private let engine: any SpeechEngine
    private var pending: [(text: String, key: String)] = []
    private var handled: Set<String> = []
    private var drainTask: Task<Void, Never>?

    init(engine: any SpeechEngine, maxPending: Int = 4) {
        self.engine = engine
        self.maxPending = maxPending
    }

    var isIdle: Bool { drainTask == nil && pending.isEmpty }

    func enqueue(_ text: String, key: String) {
        guard !text.isEmpty, handled.insert(key).inserted else { return }
        pending.append((text, key))
        if pending.count > maxPending { pending.removeFirst(pending.count - maxPending) }
        guard drainTask == nil else { return }
        drainTask = Task { [weak self] in await self?.drain() }
    }

    func stop() {
        pending.removeAll()
        drainTask?.cancel()
        drainTask = nil
        engine.stop()
    }

    /// Returns when nothing is speaking or waiting. For tests.
    func waitUntilIdle() async {
        await drainTask?.value
    }

    private func drain() async {
        while !Task.isCancelled, !pending.isEmpty {
            let next = pending.removeFirst()
            await engine.speak(next.text)
        }
        if !Task.isCancelled { drainTask = nil }
    }
}
