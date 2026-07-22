import Foundation
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import CommonCrypto
import Security
import faBolusCore

/// Builds and applies `FaBolusBackup` files. The app-settings section covers non-secret preferences
/// (AppSettings + CGM config + the remote name/id indices); the optional secrets section covers
/// Keychain items (CGM logins, pump pairing secret + PIN) and is only included when the user opts in;
/// the pump section is supplied by `AppModel` (read from the pump). Everything stays on-device except
/// the file the user chooses to save (e.g. to iCloud Drive) — faBolus has no servers.
@MainActor
enum SettingsBackup {
    /// Non-secret CGM follower config (GlucoseSourceConfig, un-prefixed keys).
    private static let cgmConfigKeys = [
        "librelinkup.username", "librelinkup.region",
        "dexcomshare.username", "dexcomshare.region",
        "nightscout.url", "dexcomg6.transmitterId",
    ]
    /// Keychain CGM credential accounts (CredentialStore).
    private static let cgmSecretAccounts = [
        "librelinkup.password", "dexcomshare.password", "nightscout.token", "nightscout.apisecret",
    ]

    // MARK: App settings (non-secret)

    static func appSettingsSnapshot() -> [String: BackupValue] {
        var m = AppSettings.shared.backupSnapshot()
        for k in cgmConfigKeys where GlucoseSourceConfig.string(k) != nil {
            m["cgm.\(k)"] = .string(GlucoseSourceConfig.string(k)!)
        }
        let d = UserDefaults.standard
        if let sel = d.string(forKey: "selectedGlucoseSourceId") { m["selectedGlucoseSourceId"] = .string(sel) }
        if let cid = d.string(forKey: "phoneRemoteClientId") { m["phoneRemoteClientId"] = .string(cid) }
        if let names = d.dictionary(forKey: "macRemotePairedNames") as? [String: String],
           let data = try? JSONEncoder().encode(names) { m["macRemotePairedNames"] = .data(data) }
        return m
    }

    static func applyAppSettings(_ m: [String: BackupValue]) {
        AppSettings.shared.applyBackup(m)   // the AppSettings keys (triggers didSet + live UI update)
        let d = UserDefaults.standard
        for k in cgmConfigKeys {
            if case .string(let v)? = m["cgm.\(k)"] { GlucoseSourceConfig.set(v, k) }
        }
        if case .string(let v)? = m["selectedGlucoseSourceId"] { d.set(v, forKey: "selectedGlucoseSourceId") }
        if case .string(let v)? = m["phoneRemoteClientId"] { d.set(v, forKey: "phoneRemoteClientId") }
        if case .data(let data)? = m["macRemotePairedNames"],
           let names = try? JSONDecoder().decode([String: String].self, from: data) {
            d.set(names, forKey: "macRemotePairedNames")
        }
    }

    // MARK: Secrets (opt-in) — CGM logins + pump pairing secret/PIN (Keychain)

    static func secretsSnapshot() -> SecretsBackup {
        var items: [String: String] = [:]
        for a in cgmSecretAccounts { if let v = CredentialStore.get(account: a) { items["cgm.\(a)"] = v } }
        if let secret = PairingStore.load() { items["pump.jpakeDerivedSecret"] = Data(secret).base64EncodedString() }
        if let pin = PairingStore.loadPin() { items["pump.mobiPin"] = pin }
        return SecretsBackup(items: items)
    }

    static func applySecrets(_ s: SecretsBackup) {
        for a in cgmSecretAccounts { if let v = s.items["cgm.\(a)"] { CredentialStore.set(v, account: a) } }
        if let b64 = s.items["pump.jpakeDerivedSecret"], let data = Data(base64Encoded: b64) {
            PairingStore.save([UInt8](data))
        }
        if let pin = s.items["pump.mobiPin"] { PairingStore.savePin(pin) }
    }

    // MARK: Assemble

    static func meta(pumpModel: String) -> FaBolusBackup.Meta {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
        return FaBolusBackup.Meta(createdAt: Date(), appVersion: version,
                                  pumpModel: pumpModel, deviceName: UIDevice.current.name)
    }

    /// Suggested export filename (a `.json` file — no custom UTType needed).
    static func suggestedFilename() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "faBolus-backup-\(f.string(from: Date()))"
    }
}

/// Optional password encryption for a backup file: PBKDF2-HMAC-SHA256 (200k iterations) derives a key
/// from the user's password; the JSON is sealed with AES-GCM. Used when the backup includes secrets so
/// the file isn't plaintext. Wrong password fails to open (authenticated) — there's no recovery, so the
/// UI warns to remember it.
enum BackupCrypto {
    enum CryptoError: Error { case badPassword, malformed }

    private struct Envelope: Codable {
        var fabolusEncrypted = true
        var v = 1
        var iterations: Int
        var salt: Data
        var box: Data   // AES.GCM.SealedBox.combined (nonce + ciphertext + tag)
    }

    /// True if `data` is an encrypted faBolus backup envelope (vs. a plain backup JSON).
    static func isEncrypted(_ data: Data) -> Bool {
        struct Probe: Codable { let fabolusEncrypted: Bool? }
        return (try? JSONDecoder().decode(Probe.self, from: data))?.fabolusEncrypted == true
    }

    static func encrypt(_ plaintext: Data, password: String) throws -> Data {
        let salt = randomData(16)
        let iterations = 200_000
        let key = try deriveKey(password: password, salt: salt, iterations: iterations)
        guard let combined = try AES.GCM.seal(plaintext, using: key).combined else { throw CryptoError.malformed }
        return try JSONEncoder().encode(Envelope(iterations: iterations, salt: salt, box: combined))
    }

    static func decrypt(_ data: Data, password: String) throws -> Data {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let key = try deriveKey(password: password, salt: env.salt, iterations: env.iterations)
        do { return try AES.GCM.open(try AES.GCM.SealedBox(combined: env.box), using: key) }
        catch { throw CryptoError.badPassword }
    }

    private static func randomData(_ count: Int) -> Data {
        var d = Data(count: count)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return d
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let status = salt.withUnsafeBytes { saltBuf in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count,
                                 saltBuf.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &derived, derived.count)
        }
        guard status == kCCSuccess else { throw CryptoError.malformed }
        return SymmetricKey(data: Data(derived))
    }
}

/// A `FileDocument` wrapper for SwiftUI `.fileExporter` (write) / `.fileImporter` reads the URL directly.
struct BackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
