import Foundation

/// The per-session event stream. Frames are numbered so a reconnecting
/// `EventSource` can pick up where it left off.
@MainActor
final class EventBus {
    struct Frame {
        let id: UInt64
        let bytes: Data
    }

    static let replayCapacity = 256

    private var nextID: UInt64 = 1
    private var ring: [Frame] = []
    private var subscribers: [UUID: SSEEmitter] = [:]
    private(set) var isFinished = false

    var subscriberCount: Int { subscribers.count }
    var lastID: UInt64 { nextID - 1 }

    func emit(_ event: String, _ payload: JSONValue) {
        guard !isFinished else { return }
        let id = nextID
        nextID += 1
        let data = (try? String(decoding: payload.serialized(), as: UTF8.self)) ?? "null"
        let frame = Frame(id: id, bytes: SSE.frame(event: event, data: data, id: String(id)))
        ring.append(frame)
        if ring.count > Self.replayCapacity { ring.removeFirst(ring.count - Self.replayCapacity) }
        for (_, emitter) in subscribers { emitter.raw(frame.bytes) }
    }

    /// Attaches an emitter, replaying anything after `lastEventID`.
    func subscribe(_ emitter: SSEEmitter, after lastEventID: UInt64?) -> UUID {
        let token = UUID()
        if let lastEventID {
            for frame in ring where frame.id > lastEventID { emitter.raw(frame.bytes) }
        }
        subscribers[token] = emitter
        return token
    }

    func unsubscribe(_ token: UUID) {
        subscribers.removeValue(forKey: token)
    }

    func finishAll() {
        isFinished = true
        for (_, e) in subscribers { e.finish() }
        subscribers.removeAll()
    }
}
