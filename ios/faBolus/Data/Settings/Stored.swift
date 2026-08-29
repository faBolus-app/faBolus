import Foundation

/// A `UserDefaults`-backed value addressed by an explicit key string, with an optional post-write
/// side-effect hook. Keeps the key + the read/write plumbing together so renaming a property cannot
/// silently drift from its stored key (the old `{ didSet { d.set(value, forKey: "literal") } }`
/// hazard in `AppSettings`).
///
/// ## Why `AppSettings` uses COMPOSITION, not the `@Stored("key") var x: T` attribute-sugar form
///
/// `AppSettings` is `@Observable` (`@MainActor @Observable public final class`). Applying `Stored`
/// directly as a property-wrapper ATTRIBUTE on an `@Observable`-tracked property is unsafe:
///
/// - **It fails to compile** — `@Observable`'s `@ObservationTracked` peer macro tries to instrument
///   the SAME property the compiler is already transforming for the attached property wrapper
///   (`_x: Stored<T>`), and the two macro expansions conflict.
/// - **If forced to compile via `@ObservationIgnored`,** it SILENTLY disables `@Observable`'s
///   automatic SwiftUI-view-invalidation tracking for that property — every Settings toggle backed
///   this way would stop live-updating other open views when changed elsewhere.
///
/// The fix: `AppSettings` never applies `@Stored` as an attribute. Instead it holds a PRIVATE,
/// ordinary (non-attribute) stored field of type `Stored<T>` and exposes it through a plain computed
/// property. The private field carries NO attribute, so `@Observable` instruments IT. Reading/writing
/// the public accessor still round-trips through that field, so reactivity is preserved.
///
/// `Stored` stays declared `@propertyWrapper` so it CAN be used with the ordinary attribute-sugar
/// form on a future NON-`@Observable` type — `AppSettings` itself just doesn't use that sugar.
@propertyWrapper
public struct Stored<Value> {
    /// The exact UserDefaults key literal — frozen, same "renaming breaks stored data" contract as
    /// `SettingDescriptor.key` (`SettingsCatalog.swift`).
    public let key: String
    private let defaultValue: Value
    /// The backing store. Defaults to `.standard`; `AppSettings.init(defaults:)` repoints every
    /// converted property's backing field at its own injected `defaults` argument (test suites inject
    /// a fresh throwaway suite) before any read/write happens, mirroring the existing `d` indirection.
    public var store: UserDefaults
    /// The escape hatch for a property whose old `didSet` had a side effect (`syncWidgetConfig()` /
    /// `applyFreshness()` / etc). Left `nil` while `AppSettings.init()` runs its own property
    /// assignments (wired up only once `init` finishes) so a property's side effect does NOT
    /// spuriously fire during construction — the same guarantee Swift's own "observers don't fire on a
    /// property's first init-time assignment" rule gave the pre-conversion hand-rolled `didSet` code.
    ///
    /// **Deliberately NOT invoked from `wrappedValue`'s own setter below.** If a side effect (e.g.
    /// `applyFreshness()`) reads the SAME `@Observable`-tracked property being set (a common case —
    /// `applyFreshness()` reads `glucoseStaleMinutes`, `syncWidgetConfig()` reads `carbIncrement`/
    /// `defaultBolusMode`), firing it from INSIDE this setter would re-enter that property's storage
    /// while `@Observable`'s generated `_modify` accessor still holds an exclusive access on it — a
    /// genuine Swift runtime "Simultaneous accesses… modification requires exclusive access" crash.
    /// The caller (`AppSettings`'s property setter) instead calls `wrappedValue = newValue` and
    /// `onChange?(newValue)` as two SEPARATE statements — by the time the second one runs, the first
    /// statement's exclusive access has already ended, so `onChange` is free to read any property
    /// (including this one) safely.
    public var onChange: ((Value) -> Void)?
    private let readValue: (UserDefaults, String) -> Value?
    private let writeValue: (UserDefaults, String, Value) -> Void

    public var wrappedValue: Value {
        get { readValue(store, key) ?? defaultValue }
        set { writeValue(store, key, newValue) }
    }

    /// Full designated initializer — takes explicit read/write closures. Callers use the typed
    /// convenience initializers below (Bool/Int/Double/String/`RawRepresentable<String>` enum); this
    /// one exists so a future shape (e.g. a JSON-encoded type) can still opt in without a new wrapper.
    public init(
        wrappedValue: Value, _ key: String, store: UserDefaults = .standard,
        onChange: ((Value) -> Void)? = nil,
        read: @escaping (UserDefaults, String) -> Value?,
        write: @escaping (UserDefaults, String, Value) -> Void
    ) {
        self.defaultValue = wrappedValue
        self.key = key
        self.store = store
        self.onChange = onChange
        self.readValue = read
        self.writeValue = write
    }
}

extension Stored where Value == Bool {
    public init(
        wrappedValue: Bool, _ key: String, store: UserDefaults = .standard,
        onChange: ((Bool) -> Void)? = nil
    ) {
        self.init(
            wrappedValue: wrappedValue, key, store: store, onChange: onChange,
            read: { d, k in d.object(forKey: k) as? Bool },
            write: { d, k, v in d.set(v, forKey: k) })
    }
}

extension Stored where Value == Int {
    public init(
        wrappedValue: Int, _ key: String, store: UserDefaults = .standard,
        onChange: ((Int) -> Void)? = nil
    ) {
        self.init(
            wrappedValue: wrappedValue, key, store: store, onChange: onChange,
            read: { d, k in d.object(forKey: k) as? Int },
            write: { d, k, v in d.set(v, forKey: k) })
    }
}

extension Stored where Value == Double {
    public init(
        wrappedValue: Double, _ key: String, store: UserDefaults = .standard,
        onChange: ((Double) -> Void)? = nil
    ) {
        self.init(
            wrappedValue: wrappedValue, key, store: store, onChange: onChange,
            read: { d, k in d.object(forKey: k) as? Double },
            write: { d, k, v in d.set(v, forKey: k) })
    }
}

extension Stored where Value == String {
    public init(
        wrappedValue: String, _ key: String, store: UserDefaults = .standard,
        onChange: ((String) -> Void)? = nil
    ) {
        self.init(
            wrappedValue: wrappedValue, key, store: store, onChange: onChange,
            read: { d, k in d.string(forKey: k) },
            write: { d, k, v in d.set(v, forKey: k) })
    }
}

/// RawRepresentable-backed enums (`BolusMode`, `AppMode`) — stored as their `String` raw value, same
/// encoding the pre-conversion `d.set(x.rawValue, forKey:)` / `BolusMode(rawValue: d.string(forKey:))`
/// idiom used.
extension Stored where Value: RawRepresentable, Value.RawValue == String {
    public init(
        wrappedValue: Value, _ key: String, store: UserDefaults = .standard,
        onChange: ((Value) -> Void)? = nil
    ) {
        self.init(
            wrappedValue: wrappedValue, key, store: store, onChange: onChange,
            read: { d, k in d.string(forKey: k).flatMap(Value.init(rawValue:)) },
            write: { d, k, v in d.set(v.rawValue, forKey: k) })
    }
}
