import Foundation

/// Version 1, as far as this side needs it: recognizing a message from the old app and answering it once
/// in a form the old app shows. Nothing in a version 1 message is acted on but a cancel, which is never
/// gated.
public enum LegacyV1 {
    public static let version = 1

    /// Every kind version 1 had.
    public static let kinds: Set<String> = [
        "statusRead", "bolusRequest", "bolusConfirm", "bolusStatus", "cancelBolus", "dismissAlert", "dismissAck",
        "suspendPump", "resumePump"
    ]

    /// The old app's cancel.
    public static let cancelKind = "cancelBolus"

    public struct Message: Sendable, Hashable {
        public var kind: String
        public var requestId: String?

        init?(_ object: [String: WireValue]) {
            guard case .string(let kind)? = object["kind"], LegacyV1.kinds.contains(kind) else { return nil }
            self.kind = kind
            if case .string(let id)? = object["requestId"], !id.isEmpty, id.count <= WireLimits.maxIdLength {
                requestId = id
            }
        }

        public init(kind: String, requestId: String?) {
            self.kind = kind
            self.requestId = requestId
        }
    }

    /// What the old watch shows on its status line, where version 1 put the pump's connection state.
    public static let updateWatchLabel = "Update watch app"
    public static let updateWatchMessage = "Update the faBolus watch app to bolus from the watch."

    /// The one reply to a version 1 message from the old watch app. A bolus request is answered as failed,
    /// so the old watch doesn't wait on it; anything else gets a status that disables bolusing and shows
    /// "Update watch app" where the old watch shows the pump's connection state. The old watch sends
    /// nothing in reply to either, so this can't start a loop.
    public static func reply(to message: Message) -> WireValue? {
        guard let requestId = message.requestId else { return nil }
        if message.kind == "bolusRequest" {
            return .object([
                "version": .int(version), "kind": .string("bolusStatus"), "requestId": .string(requestId),
                "status": .string("failed"), "message": .string(updateWatchMessage)
            ])
        }
        return .object([
            "version": .int(version), "kind": .string("statusRead"), "requestId": .string(requestId),
            "message": .string(updateWatchLabel), "canBolus": .bool(false),
            "bolusBlockReason": .string("accessDenied"), "garminBolusEnabled": .bool(false),
            "remotesReadOnly": .bool(true)
        ])
    }
}
