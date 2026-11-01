import Foundation

/// A Bluetooth session as text, one event per line, so a real session can be written down on the phone
/// and replayed through an observer in tests.
///
///     # comment
///     peripheral tx 6D0C2C5A-3B3E-4E2B-9E3A-0E9E1A2B3C4D DexcomAB
///     0 bluetooth poweredOn
///     0.4 found known=- connected=tx
///     1.2 value tx control 2500beb24d00f22d4d000100000083c0
///
/// Times are seconds from the start of the session. A peripheral's name runs to the end of its line
/// (`-` for none). Event lines: `bluetooth <state>`,
/// `restored <alias,...>`, `found known=<alias|-> connected=<alias,...|->`, `discovered <alias>`,
/// `connected <alias>`, `ready <alias>`, `setupFailed <alias> <message>`,
/// `disconnected <alias> remote|local|error [message]`, `failedToConnect <alias> [message]`,
/// `value <alias> authentication|control|backfill <hex>`, `tick`.
public struct DexcomSessionLog: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let offset: TimeInterval
        public let event: DexcomEvent
    }

    public enum ParseError: Error, Equatable {
        case badLine(Int, String)
    }

    public private(set) var entries: [Entry] = []
    private var aliases: [UUID: String] = [:]
    private var peripherals: [String: DexcomPeripheral] = [:]

    public init() {}

    public init(parsing text: String) throws {
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard parse(line) else { throw ParseError.badLine(index + 1, line) }
        }
    }

    /// Appends an event, naming each new peripheral `p1`, `p2`, ...
    public mutating func append(_ event: DexcomEvent, at offset: TimeInterval) {
        for peripheral in event.peripherals where aliases[peripheral.id] == nil {
            let alias = "p\(aliases.count + 1)"
            aliases[peripheral.id] = alias
            peripherals[alias] = peripheral
        }
        entries.append(Entry(offset: offset, event: event))
    }

    /// Keeps the newest `count` entries, so a recording that runs for days stays bounded.
    public mutating func dropOldest(keeping count: Int) {
        guard entries.count > count else { return }
        entries.removeFirst(entries.count - count)
    }

    public var text: String {
        let declarations = peripherals.sorted { $0.key < $1.key }.map { alias, peripheral in
            "peripheral \(alias) \(peripheral.id.uuidString) \(peripheral.name ?? "-")"
        }
        return (declarations + entries.map { "\(Self.format($0.offset)) \(describe($0.event))" })
            .joined(separator: "\n") + "\n"
    }

    /// Feeds every entry through `observer`, started at `start`, and returns what it asked for and read.
    public func replay<Observer: DexcomObserver>(into observer: inout Observer, from start: Date) -> Replay {
        var replay = Replay(commands: observer.start(now: start))
        for entry in entries {
            let now = start.addingTimeInterval(entry.offset)
            let observation = observer.handle(entry.event, now: now)
            replay.commands += observation.commands
            replay.readings += observation.readings
            replay.statuses.append(observer.status(now: now))
        }
        return replay
    }

    public struct Replay: Sendable, Equatable {
        public var commands: [DexcomCommand]
        public var readings: [DexcomReading] = []
        /// The observer's status after each entry.
        public var statuses: [DexcomLinkStatus] = []
    }

    // MARK: - Parsing

    private mutating func parse(_ line: String) -> Bool {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if words.first == "peripheral" {
            guard words.count >= 4, let id = UUID(uuidString: words[2]) else { return false }
            let name = words.dropFirst(3).joined(separator: " ")
            let peripheral = DexcomPeripheral(id: id, name: name == "-" ? nil : name)
            peripherals[words[1]] = peripheral
            aliases[id] = words[1]
            return true
        }
        guard words.count >= 2, let offset = TimeInterval(words[0]), let event = event(Array(words.dropFirst()))
        else { return false }
        entries.append(Entry(offset: offset, event: event))
        return true
    }

    private func event(_ words: [String]) -> DexcomEvent? {
        let rest = Array(words.dropFirst())
        let message = rest.dropFirst().joined(separator: " ")
        func peripheral(_ index: Int = 0) -> DexcomPeripheral? {
            rest.indices.contains(index) ? peripherals[rest[index]] : nil
        }
        func list(_ text: String) -> [DexcomPeripheral]? {
            guard text != "-" else { return [] }
            let names = text.split(separator: ",")
            let found = names.compactMap { peripherals[String($0)] }
            return found.count == names.count ? found : nil
        }
        switch words[0] {
        case "bluetooth":
            return rest.first.flatMap(DexcomBluetoothState.init(rawValue:)).map { .bluetooth($0) }
        case "restored":
            return rest.first.flatMap(list).map { .restored($0) }
        case "found":
            guard rest.count == 2, rest[0].hasPrefix("known="), rest[1].hasPrefix("connected="),
                let connected = list(String(rest[1].dropFirst("connected=".count)))
            else { return nil }
            let knownAlias = String(rest[0].dropFirst("known=".count))
            guard knownAlias == "-" || peripherals[knownAlias] != nil else { return nil }
            return .found(known: peripherals[knownAlias], systemConnected: connected)
        case "discovered": return peripheral().map { .discovered($0) }
        case "connected": return peripheral().map { .connected($0) }
        case "ready": return peripheral().map { .ready($0) }
        case "setupFailed": return peripheral().map { .setupFailed($0, message) }
        case "failedToConnect": return peripheral().map { .failedToConnect($0, message.isEmpty ? nil : message) }
        case "disconnected":
            guard let target = peripheral(), rest.count >= 2 else { return nil }
            let detail = rest.dropFirst(2).joined(separator: " ")
            switch rest[1] {
            case "remote": return .disconnected(target, .remote)
            case "local": return .disconnected(target, .local)
            case "error": return .disconnected(target, .error(detail))
            default: return nil
            }
        case "value":
            guard rest.count == 3, let target = peripheral(),
                let characteristic = DexcomCharacteristic(rawValue: rest[1]),
                let value = Data(hexadecimalString: rest[2])
            else { return nil }
            return .value(target, characteristic, value)
        case "tick": return .tick
        default: return nil
        }
    }

    // MARK: - Writing

    private func describe(_ event: DexcomEvent) -> String {
        func name(_ peripheral: DexcomPeripheral) -> String { aliases[peripheral.id] ?? "-" }
        func names(_ list: [DexcomPeripheral]) -> String { list.isEmpty ? "-" : list.map(name).joined(separator: ",") }
        switch event {
        case .bluetooth(let state): return "bluetooth \(state.rawValue)"
        case .restored(let list): return "restored \(names(list))"
        case .found(let known, let connected):
            return "found known=\(known.map(name) ?? "-") connected=\(names(connected))"
        case .discovered(let peripheral): return "discovered \(name(peripheral))"
        case .connected(let peripheral): return "connected \(name(peripheral))"
        case .ready(let peripheral): return "ready \(name(peripheral))"
        case .setupFailed(let peripheral, let message): return "setupFailed \(name(peripheral)) \(message)"
        case .failedToConnect(let peripheral, let message):
            return "failedToConnect \(name(peripheral))" + (message.map { " \($0)" } ?? "")
        case .disconnected(let peripheral, let reason):
            switch reason {
            case .remote: return "disconnected \(name(peripheral)) remote"
            case .local: return "disconnected \(name(peripheral)) local"
            case .error(let message): return "disconnected \(name(peripheral)) error \(message)"
            }
        case .value(let peripheral, let characteristic, let value):
            return "value \(name(peripheral)) \(characteristic.rawValue) \(value.hexadecimalString)"
        case .tick: return "tick"
        }
    }

    private static func format(_ offset: TimeInterval) -> String {
        let rounded = (offset * 1000).rounded() / 1000
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }
}

extension DexcomEvent {
    var peripherals: [DexcomPeripheral] {
        switch self {
        case .restored(let list): return list
        case .found(let known, let connected): return [known].compactMap { $0 } + connected
        case .discovered(let peripheral), .connected(let peripheral), .ready(let peripheral),
            .setupFailed(let peripheral, _), .disconnected(let peripheral, _), .failedToConnect(let peripheral, _),
            .value(let peripheral, _, _):
            return [peripheral]
        case .bluetooth, .tick: return []
        }
    }
}
