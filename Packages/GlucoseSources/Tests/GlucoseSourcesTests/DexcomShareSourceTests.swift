import Foundation
import ShareClient
import Testing
import faBolusCore
import os

@testable import GlucoseSources

/// Counts the Share clients built (each one is a fresh sign-in) and the sign-ins they were built with.
final class ClientLog: Sendable {
    private let made = OSAllocatedUnfairLock<[ShareCredentials]>(initialState: [])
    var builds: [ShareCredentials] { made.withLock { $0 } }
    func factory(failure: ShareError? = nil) -> DexcomSharePoller.ClientFactory {
        { [self] credentials in
            made.withLock { $0.append(credentials) }
            return FakeShareClient(failure: failure)
        }
    }
}

/// Never touches the network; answers every fetch with no readings, or with `failure`.
struct FakeShareClient: ShareGlucoseFetching {
    let failure: ShareError?
    func fetchLast(_ n: Int, callback: @escaping @Sendable (ShareError?, [ShareGlucose]?) -> Void) {
        callback(failure, failure == nil ? [] : nil)
    }
}

/// The Share client and its session are kept across polls, rebuilt only when the sign-in changes or a
/// fetch fails, polling backs off on failure, and the region picks the server.
@Suite("Dexcom Share source")
struct DexcomShareSourceTests {
    let alice = ShareCredentials(username: "u", password: "p", region: .us)

    func account() throws -> ShareAccount {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "u", password: "p", region: .us)
        return account
    }

    @Test("one sign-in for two polls with the same credentials")
    func clientCachedAcrossPolls() async throws {
        let log = ClientLog()
        let poller = DexcomSharePoller(account: try account(), makeClient: log.factory())
        _ = try await poller.fetch(with: alice)
        _ = try await poller.fetch(with: alice)
        #expect(log.builds.count == 1)
    }

    @Test("a changed username, password or region signs in again")
    func credentialChangeRebuildsClient() async throws {
        let log = ClientLog()
        let poller = DexcomSharePoller(account: try account(), makeClient: log.factory())
        _ = try await poller.fetch(with: alice)
        _ = try await poller.fetch(with: ShareCredentials(username: "u2", password: "p", region: .us))
        #expect(log.builds.count == 2)
        _ = try await poller.fetch(with: ShareCredentials(username: "u2", password: "p2", region: .us))
        #expect(log.builds.count == 3)
        _ = try await poller.fetch(with: ShareCredentials(username: "u2", password: "p2", region: .apac))
        #expect(log.builds.count == 4)
        _ = try await poller.fetch(with: ShareCredentials(username: "u2", password: "p2", region: .apac))
        #expect(log.builds.count == 4)
    }

    @Test("a fetch error drops the client, so the next poll signs in again")
    func fetchErrorInvalidatesClient() async throws {
        let log = ClientLog()
        let poller = DexcomSharePoller(account: try account(), makeClient: log.factory(failure: .fetchError))
        await #expect(throws: GlucosePollError.self) { _ = try await poller.fetch(with: alice) }
        await #expect(throws: GlucosePollError.self) { _ = try await poller.fetch(with: alice) }
        #expect(log.builds.count == 2)
    }

    @Test("Share errors become reasons the user can act on")
    func errorReasons() {
        #expect(
            DexcomSharePoller.problem(.loginError(errorCode: "SSO_AuthenticatePasswordInvalid"))
                == .signInFailed("wrong username or password"))
        #expect(
            DexcomSharePoller.problem(.loginError(errorCode: "SSO_AuthenticateMaxAttemptsExceeed"))
                == .signInFailed("too many attempts; Dexcom locked the account for a while"))
        #expect(DexcomSharePoller.problem(.fetchError) == .network("no readings returned"))
    }

    @Test("no saved sign-in: needs setup, not an endpoint failure")
    func needsSetup() async {
        let poller = DexcomSharePoller(
            account: ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore()),
            makeClient: ClientLog().factory())
        await #expect(throws: GlucosePollError.needsSetup) { _ = try await poller.poll() }
    }

    @Test("backoff doubles per failure up to 8 times and resets on success")
    func backoff() {
        #expect(PollingGlucoseSource.effectiveInterval(base: 60, failures: 0) == 60)
        #expect(PollingGlucoseSource.effectiveInterval(base: 60, failures: 1) == 120)
        #expect(PollingGlucoseSource.effectiveInterval(base: 60, failures: 3) == 480)
        #expect(PollingGlucoseSource.effectiveInterval(base: 60, failures: 10) == 480)
    }

    @Test("the region picks the server")
    func regions() {
        #expect(ShareRegion.apac.server == .APAC)
        #expect(KnownShareServers.APAC.rawValue == "https://share.dexcom.jp")
        #expect(ShareRegion.ous.server == .Worldwide)
        #expect(ShareRegion.us.server == .US)
    }

    @Test("in-range readings become samples, LOW is kept apart, zero and over-range are dropped")
    func partition() {
        let readings: [(mgdl: Int, date: Date, trend: GlucoseTrend?)] = [
            (120, t0, .flat), (35, t0.addingTimeInterval(60), .flat), (0, t0.addingTimeInterval(120), .flat),
            (500, t0.addingTimeInterval(180), .flat)
        ]
        let (samples, belowRange) = GlucoseSourceBuffer.partition(readings, sourceID: "dexcom-share")
        #expect(samples.map(\.mgdl) == [120])
        #expect(belowRange == [t0.addingTimeInterval(60)])
    }
}

/// The Share credential flow: entry, change, and what the poller signs in with afterwards.
@Suite("Dexcom Share credentials")
struct ShareCredentialsTests {
    @Test("saving trims the fields and stores the password as a secret")
    func entry() throws {
        let secrets = InMemorySecretStore()
        let account = ShareAccount(settings: isolatedSettings(), secrets: secrets)
        #expect(account.credentials == nil)
        try account.save(username: "  alice@example.com ", password: " hunter2\n", region: .ous)
        #expect(
            account.credentials == ShareCredentials(username: "alice@example.com", password: "hunter2", region: .ous))
        #expect(secrets.secret(for: ShareAccount.passwordAccount) == "hunter2")
        #expect(account.username == "alice@example.com")
        #expect(account.hasPassword)
    }

    @Test("a username and a password are required")
    func required() {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        #expect(throws: ShareCredentialsError.missingUsername) {
            try account.save(username: " ", password: "p", region: .us)
        }
        #expect(throws: ShareCredentialsError.missingPassword) {
            try account.save(username: "u", password: "", region: .us)
        }
        #expect(throws: ShareCredentialsError.missingPassword) {
            try account.save(username: "u", password: nil, region: .us)
        }
        #expect(account.credentials == nil)
    }

    @Test("changing the username or region keeps the saved password; a new password replaces it")
    func change() throws {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "u", password: "p", region: .us)
        try account.save(username: "u2", password: nil, region: .apac)
        #expect(account.credentials == ShareCredentials(username: "u2", password: "p", region: .apac))
        try account.save(username: "u2", password: "  ", region: .apac)
        #expect(account.credentials?.password == "p")
        try account.save(username: "u2", password: "p2", region: .apac)
        #expect(account.credentials?.password == "p2")
    }

    @Test("signing out removes everything")
    func clear() throws {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "u", password: "p", region: .apac)
        try account.clear()
        #expect(account.credentials == nil)
        #expect(account.username == nil)
        #expect(!account.hasPassword)
        #expect(account.region == .us)
    }

    @Test("after a change the next poll signs in with the new credentials; without one it reuses the session")
    func pollerFollowsTheChange() async throws {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "u", password: "p", region: .us)
        let log = ClientLog()
        let poller = DexcomSharePoller(account: account, makeClient: log.factory())
        _ = try await poller.poll()
        _ = try await poller.poll()
        try account.save(username: "u", password: "new", region: .us)
        _ = try await poller.poll()
        #expect(log.builds.map(\.password) == ["p", "new"])
    }

    @Test("signing out stops the polls with needs-setup")
    func pollAfterClear() async throws {
        let account = ShareAccount(settings: isolatedSettings(), secrets: InMemorySecretStore())
        try account.save(username: "u", password: "p", region: .us)
        let poller = DexcomSharePoller(account: account, makeClient: ClientLog().factory())
        _ = try await poller.poll()
        try account.clear()
        await #expect(throws: GlucosePollError.needsSetup) { _ = try await poller.poll() }
    }
}
