import Foundation
import CoreLocation

/// Optional **location gate** for the eating nudge (Phase 5). Learns the coarse places where you
/// actually eat (recorded when you act on a nudge / bolus for a meal) and reports whether you're at
/// one now, so the engine can suppress nudges when you're clearly *not* at a meal place (e.g. driving,
/// at the gym). Privacy-first: **off by default**, coarse locations only, everything stays on-device,
/// and it uses significant-location changes (very low battery) rather than continuous GPS.
///
/// `isAtMealPlace()` returns `nil` (⇒ the engine won't gate) until at least a few places are learned,
/// so it never blocks nudges before it has any idea where you eat.
@MainActor
final class EatingLocationGate: NSObject, CLLocationManagerDelegate {
    /// A learned meal place (coarse lat/lon). Rounded so we never persist a precise fix.
    private struct Place: Codable { let lat: Double; let lon: Double; var hits: Int }

    private let manager = CLLocationManager()
    private let radiusMeters: CLLocationDistance = 150
    private let minPlacesBeforeGating = 3
    private let storeKey = "eatingMealPlaces"
    private var places: [Place]
    private var lastLocation: CLLocation?
    private var enabled = false

    override init() {
        places = Self.load(storeKey)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Turn the gate on/off. On enable, ask for When-In-Use and start low-power monitoring.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startMonitoringSignificantLocationChanges()
            manager.requestLocation()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    /// `true`/`false` once enough places are learned and a recent fix exists; otherwise `nil` (unknown —
    /// the engine treats `nil` as "don't gate").
    func isAtMealPlace() -> Bool? {
        guard enabled, places.count >= minPlacesBeforeGating, let loc = lastLocation,
              Date().timeIntervalSince(loc.timestamp) < 30 * 60 else { return nil }
        return places.contains { CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: loc) <= radiusMeters }
    }

    /// Call when the user confirms a meal here (acted on a nudge / bolused for carbs) so the gate learns
    /// this as a meal place. Merges into a nearby existing place if there is one.
    func recordMealHere() {
        guard enabled, let loc = lastLocation else { return }
        if let i = places.firstIndex(where: {
            CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: loc) <= radiusMeters
        }) {
            places[i].hits += 1
        } else {
            places.append(Place(lat: (loc.coordinate.latitude * 1000).rounded() / 1000,
                                lon: (loc.coordinate.longitude * 1000).rounded() / 1000, hits: 1))
        }
        Self.save(places, storeKey)
    }

    /// Wipe learned places (Settings → reset).
    func reset() { places = []; Self.save(places, storeKey) }
    var learnedPlaceCount: Int { places.count }

    // MARK: CLLocationManagerDelegate (delivered on the main run loop → assume main isolation)
    nonisolated func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        MainActor.assumeIsolated { self.lastLocation = locs.last }
    }
    nonisolated func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
    nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        MainActor.assumeIsolated {
            let s = self.manager.authorizationStatus
            if self.enabled, s == .authorizedWhenInUse || s == .authorizedAlways {
                self.manager.startMonitoringSignificantLocationChanges(); self.manager.requestLocation()
            }
        }
    }

    // MARK: persistence (on-device only)
    private static func load(_ key: String) -> [Place] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode([Place].self, from: d) else { return [] }
        return p
    }
    private static func save(_ places: [Place], _ key: String) {
        if let d = try? JSONEncoder().encode(places) { UserDefaults.standard.set(d, forKey: key) }
    }
}
