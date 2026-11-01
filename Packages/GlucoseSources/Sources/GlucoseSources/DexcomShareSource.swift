import Foundation
import ShareClient
import faBolusCore

/// The part of the vendored `ShareClient` the Share source uses, so tests can count sign-ins without
/// the network.
public protocol ShareGlucoseFetching: Sendable {
    func fetchLast(_ n: Int, callback: @escaping @Sendable (ShareError?, [ShareGlucose]?) -> Void)
}

extension ShareClient: ShareGlucoseFetching {}

/// Dexcom Share, the cloud follower: the Dexcom app uploads, this reads it back. Slower and less
/// reliable than direct Bluetooth, but works away from the sensor. Uses the vendored `ShareClient`
/// (LoopKit/dexcom-share-client-swift), which signs in, keeps its session and signs in again when the
/// session expires.
public enum DexcomShareSource {
    public static let id = "dexcom-share"
    public static let priority = 20

    public static func make(account: ShareAccount) -> PollingGlucoseSource {
        PollingGlucoseSource(id: id, priority: priority, poller: DexcomSharePoller(account: account))
    }
}

/// Polls Dexcom Share with the saved sign-in.
///
/// The client, and so its session, is kept between polls. A new client means a new two-request
/// sign-in, which every minute during a failover risks Dexcom's "max attempts exceeded" lockout just
/// when the backup is needed. It is replaced only when the saved sign-in changes or a fetch fails.
public actor DexcomSharePoller: GlucosePoller {
    public typealias ClientFactory = @Sendable (ShareCredentials) -> any ShareGlucoseFetching

    /// The last 4 hours at 5-minute intervals: enough to fill the chart when failing over.
    static let readingCount = 48

    private let account: ShareAccount
    private let makeClient: ClientFactory
    private var client: (any ShareGlucoseFetching)?
    private var clientCredentials: ShareCredentials?

    public init(
        account: ShareAccount,
        makeClient: @escaping ClientFactory = {
            ShareClient(username: $0.username, password: $0.password, shareServer: $0.region.server)
        }
    ) {
        self.account = account
        self.makeClient = makeClient
    }

    public func poll() async throws -> GlucosePoll {
        guard let credentials = account.credentials else { throw GlucosePollError.needsSetup }
        return try await fetch(with: credentials)
    }

    func fetch(with credentials: ShareCredentials) async throws -> GlucosePoll {
        if client == nil || clientCredentials != credentials {
            client = makeClient(credentials)
            clientCredentials = credentials
        }
        guard let client else { return GlucosePoll(samples: []) }
        do {
            let raw: [ShareReading] = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[ShareReading], Error>) in
                client.fetchLast(Self.readingCount) { error, values in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let readings = (values ?? []).map {
                        ShareReading(mgdl: Int($0.glucose), date: $0.timestamp, trend: Int($0.trend))
                    }
                    continuation.resume(returning: readings)
                }
            }
            let (samples, belowRange) = GlucoseSourceBuffer.partition(
                raw.map { (mgdl: $0.mgdl, date: $0.date, trend: CgmTrend.dexcom($0.trend)) },
                sourceID: DexcomShareSource.id)
            return GlucosePoll(samples: samples, belowRange: belowRange)
        } catch let error as ShareError {
            // The next poll signs in again; the backoff keeps that from repeating every minute.
            self.client = nil
            clientCredentials = nil
            throw GlucosePollError.unavailable(Self.problem(error))
        }
    }

    /// Only the plain fields leave ShareClient's callback.
    struct ShareReading: Sendable {
        let mgdl: Int
        let date: Date
        let trend: Int
    }

    static func problem(_ error: ShareError) -> GlucoseSourceProblem {
        switch error {
        case .loginError(let code):
            switch code {
            case "SSO_AuthenticateAccountNotFound", "AccountPasswordInvalid", "SSO_AuthenticatePasswordInvalid":
                return .signInFailed("wrong username or password")
            case "SSO_AuthenticateMaxAttemptsExceeed":
                return .signInFailed("too many attempts; Dexcom locked the account for a while")
            default:
                return .signInFailed(code)
            }
        case .httpError(let underlying): return .network(underlying.localizedDescription)
        case .fetchError: return .network("no readings returned")
        case .dataError, .dateError: return .network("unreadable reply")
        }
    }
}
