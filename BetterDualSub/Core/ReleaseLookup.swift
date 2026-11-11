import Foundation

/// Asking GitHub for the latest release and reading its answer, apart from the networking, so it can be tested.
nonisolated enum ReleaseLookup {
    static let latestURL = URL(string: "https://api.github.com/repos/Kearney3/BetterDualSub/releases/latest")!

    struct Release: Equatable, Sendable {
        let version: AppVersion
        let page: URL
    }

    enum Outcome: Equatable, Sendable {
        /// The latest release, and the tag GitHub gives this answer, to ask next time only whether it changed.
        case release(Release, etag: String?)
        /// Nothing was published since the answer `etag` came with.
        case unchanged
        /// Too many requests from this network; `retryAt` is when GitHub accepts them again, if it said.
        case rateLimited(retryAt: Date?)
        case failed(status: Int)
        /// An answer that is not a release with a version tag.
        case unreadable
    }

    /// The request; with the `etag` of the last answer GitHub replies 304 when nothing changed, which does not count
    /// against the hourly limit for requests without an account.
    static func request(etag: String?) -> URLRequest {
        // The system cache would answer a conditional request itself and hide a new release.
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag, !etag.isEmpty { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// Reads a response; `header` returns a response header by name.
    static func outcome(status: Int, data: Data, header: (String) -> String?) -> Outcome {
        switch status {
        case 200:
            guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
                  let version = AppVersion(release.tagName), let page = URL(string: release.htmlURL),
                  page.scheme == "https" else { return .unreadable }
            return .release(Release(version: version, page: page), etag: header("ETag"))
        case 304:
            return .unchanged
        case 403 where header("X-RateLimit-Remaining") == "0", 429:
            let reset = header("X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
            let after = header("Retry-After").flatMap(TimeInterval.init).map { Date(timeIntervalSinceNow: $0) }
            return .rateLimited(retryAt: reset ?? after)
        default:
            return .failed(status: status)
        }
    }

    /// Whether an automatic check should run: none was made yet, or the last one is at least `interval` old. A last
    /// check in the future (the clock was set back) counts as none.
    static func isDue(lastCheck: Date?, now: Date = Date(), interval: TimeInterval) -> Bool {
        guard let lastCheck, lastCheck <= now else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
