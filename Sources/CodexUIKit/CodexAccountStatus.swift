import CodexAppServerKit
import Foundation
import Observation

@MainActor
@Observable
public final class CodexAccountStatus {
    public struct Configuration: Sendable {
        public init() {}
    }

    public var phase: CodexUIKitPhase
    public var account: CodexAccount?
    public var rateLimits: CodexRateLimits
    public var configuration: CodexConfiguration
    public var lastErrorDescription: String?

    @ObservationIgnored
    private let server: CodexAppServer

    public init(server: CodexAppServer, options: Configuration = .init()) {
        self.server = server
        phase = .idle
        rateLimits = .init()
        self.configuration = .init()
        _ = options
    }

    public func refresh() async {
        phase = .loading
        lastErrorDescription = nil
        do {
            async let account = server.account()
            async let rateLimits = server.rateLimits()
            async let configuration = server.configuration()

            self.account = try await account
            self.rateLimits = try await rateLimits
            self.configuration = try await configuration
            phase = .loaded
        } catch {
            let message = error.localizedDescription
            lastErrorDescription = message
            phase = .failed(message)
        }
    }
}
