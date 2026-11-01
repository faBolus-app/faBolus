import Foundation
import ShareClient

/// Which Dexcom Share server an account is on.
public enum ShareRegion: String, Sendable, CaseIterable {
    case us
    /// Outside the US.
    case ous
    /// Japan and Asia-Pacific (`share.dexcom.jp`).
    case apac

    public var server: KnownShareServers {
        switch self {
        case .us: return .US
        case .ous: return .Worldwide
        case .apac: return .APAC
        }
    }
}

public struct ShareCredentials: Sendable, Equatable {
    public let username: String
    public let password: String
    public let region: ShareRegion

    public init(username: String, password: String, region: ShareRegion) {
        self.username = username
        self.password = password
        self.region = region
    }
}

public enum ShareCredentialsError: Error, Equatable {
    case missingUsername
    case missingPassword
}

/// The Dexcom Share sign-in the user enters in settings. The username and region are settings; the
/// password is a secret. The Share source reads these on every poll, so a change takes effect on the
/// next poll, which signs in again with the new values.
public struct ShareAccount: Sendable {
    static let passwordAccount = "dexcomshare.password"

    private let settings: GlucoseSourceSettings
    private let secrets: any SecretStore

    public init(settings: GlucoseSourceSettings, secrets: any SecretStore) {
        self.settings = settings
        self.secrets = secrets
    }

    /// The saved sign-in, or `nil` until both a username and a password are saved.
    public var credentials: ShareCredentials? {
        guard let username = settings.string(.shareUsername), let password = secrets.secret(for: Self.passwordAccount)
        else { return nil }
        return ShareCredentials(username: username, password: password, region: region)
    }

    /// The saved username, to fill the form.
    public var username: String? { settings.string(.shareUsername) }

    /// The saved region; US until one is chosen.
    public var region: ShareRegion { settings.string(.shareRegion).flatMap(ShareRegion.init(rawValue:)) ?? .us }

    /// Whether a password is saved. The form shows that one is, without reading it back.
    public var hasPassword: Bool { secrets.secret(for: Self.passwordAccount) != nil }

    /// Saves a sign-in, trimming spaces around the username and password (pasted values often carry
    /// them). A `nil` password keeps the saved one, so the username or region can change without
    /// typing the password again.
    @discardableResult
    public func save(username: String, password: String?, region: ShareRegion) throws -> ShareCredentials {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else { throw ShareCredentialsError.missingUsername }
        let typed = password?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pass = typed?.isEmpty == false ? typed : secrets.secret(for: Self.passwordAccount) else {
            throw ShareCredentialsError.missingPassword
        }
        try secrets.setSecret(pass, for: Self.passwordAccount)
        settings.set(user, .shareUsername)
        settings.set(region.rawValue, .shareRegion)
        return ShareCredentials(username: user, password: pass, region: region)
    }

    /// Signs out: removes the username, region and password.
    public func clear() throws {
        try secrets.setSecret(nil, for: Self.passwordAccount)
        settings.set(nil as String?, .shareUsername)
        settings.set(nil as String?, .shareRegion)
    }
}
