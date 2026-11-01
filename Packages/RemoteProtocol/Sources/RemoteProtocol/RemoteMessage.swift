import Foundation

/// One message of the phone↔remote protocol, version 2: `{"version": 2, "kind": …, "payload": {…}}`.
///
/// Each kind has its own payload, so no field changes meaning with the kind. The kind names all differ
/// from version 1's (`statusRead`, `bolusRequest`, `bolusStatus`, `cancelBolus`, `dismissAlert`,
/// `dismissAck`, …), so neither version can mistake the other's message for one of its own.
public enum RemoteMessage: Sendable, Hashable {
    // Phone to remote.
    case status(StatusPayload)
    case config(WatchConfig)
    case history(HistoryPayload)
    case bolusOutcome(BolusOutcomePayload)
    case dismissResult(DismissResultPayload)
    case incompatible(IncompatiblePayload)
    // Remote to phone.
    case poll(PollPayload)
    case bolus(BolusRequestPayload)
    case cancel(CancelPayload)
    case dismiss(DismissPayload)

    public static let version = 2

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case status, config, history, bolusOutcome, dismissResult, incompatible
        case poll, bolus, cancel, dismiss

        /// Sent by the phone; otherwise by the remote.
        public var fromPhone: Bool {
            switch self {
            case .status, .config, .history, .bolusOutcome, .dismissResult, .incompatible: return true
            case .poll, .bolus, .cancel, .dismiss: return false
            }
        }
    }

    public var kind: Kind {
        switch self {
        case .status: return .status
        case .config: return .config
        case .history: return .history
        case .bolusOutcome: return .bolusOutcome
        case .dismissResult: return .dismissResult
        case .incompatible: return .incompatible
        case .poll: return .poll
        case .bolus: return .bolus
        case .cancel: return .cancel
        case .dismiss: return .dismiss
        }
    }

    public var wire: WireValue {
        let payload: WireValue
        switch self {
        case .status(let p): payload = p.wire
        case .config(let p): payload = p.wire
        case .history(let p): payload = p.wire
        case .bolusOutcome(let p): payload = p.wire
        case .dismissResult(let p): payload = p.wire
        case .incompatible(let p): payload = p.wire
        case .poll(let p): payload = p.wire
        case .bolus(let p): payload = p.wire
        case .cancel(let p): payload = p.wire
        case .dismiss(let p): payload = p.wire
        }
        return .object(["version": .int(Self.version), "kind": .string(kind.rawValue), "payload": payload])
    }

    /// What an inbound message turned out to be.
    public enum Received: Sendable, Hashable {
        case message(RemoteMessage)
        /// A version 1 message: the other side runs the old app.
        case legacy(LegacyV1.Message)
        /// A version this build doesn't speak (a newer one).
        case otherVersion(Int)
        /// Version 2, but unreadable. Dropped and counted; nothing is guessed from it.
        case malformed(DecodeError)
        /// Not a message of any version.
        case unrecognized
    }

    public static func receive(_ value: WireValue) -> Received {
        guard case .object(let object) = value else { return .unrecognized }
        switch object["version"] {
        case .int(Self.version):
            do {
                return .message(try decode(object))
            } catch {
                return .malformed(error)
            }
        case .int(LegacyV1.version):
            return LegacyV1.Message(object).map(Received.legacy) ?? .unrecognized
        case .int(let other):
            return other > 0 ? .otherVersion(other) : .unrecognized
        case nil:
            // Version 1 remotes always sent a version, but the old watch never read one, so be tolerant.
            return LegacyV1.Message(object).map(Received.legacy) ?? .unrecognized
        default:
            return .unrecognized
        }
    }

    private static func decode(_ object: [String: WireValue]) throws(DecodeError) -> RemoteMessage {
        guard case .string(let name)? = object["kind"] else { throw .missing(field: "kind") }
        guard let kind = Kind(rawValue: name) else { throw .unknownToken(field: "kind", token: name) }
        guard let payload = object["payload"] else { throw .missing(field: "payload") }
        switch kind {
        case .status: return .status(try StatusPayload(wire: payload))
        case .config: return .config(try WatchConfig(wire: payload))
        case .history: return .history(try HistoryPayload(wire: payload))
        case .bolusOutcome: return .bolusOutcome(try BolusOutcomePayload(wire: payload))
        case .dismissResult: return .dismissResult(try DismissResultPayload(wire: payload))
        case .incompatible: return .incompatible(try IncompatiblePayload(wire: payload))
        case .poll: return .poll(try PollPayload(wire: payload))
        case .bolus: return .bolus(try BolusRequestPayload(wire: payload))
        case .cancel: return .cancel(try CancelPayload(wire: payload))
        case .dismiss: return .dismiss(try DismissPayload(wire: payload))
        }
    }
}

extension RemoteMessage {
    /// The request ID of a version 2 bolus request that couldn't be read, so it can be answered as failed
    /// instead of leaving the remote waiting. `nil` for anything else.
    public static func unreadableBolusRequestId(_ value: WireValue) -> String? {
        guard case .object(let o) = value, o["version"] == .int(version), o["kind"] == .string(Kind.bolus.rawValue),
            case .object(let payload)? = o["payload"], case .string(let id)? = payload["requestId"], !id.isEmpty,
            id.count <= WireLimits.maxIdLength
        else { return nil }
        if case .message = receive(value) { return nil }
        return id
    }
}
