import Foundation

/// Things that stop a request from completing at all. A non-2xx status is
/// *not* one of these — showing a 404 or a 500 is the whole point of an
/// HTTP client, so `HTTPRequestExecutor.execute` returns a summary for any
/// status code it actually gets back. These cases are reserved for nothing
/// coming back at all.
enum HTTPClientError: LocalizedError {
    case invalidURL(String)
    case unsupportedScheme(String)
    case plainHTTPBlocked(host: String)
    case transport(String)
    case responseTooLarge(Int)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidURL(let value):
            return "That doesn't look like a URL: \(value)"
        case .unsupportedScheme(let scheme):
            return "This app's HTTP client only sends http or https requests, not \(scheme)."
        case .plainHTTPBlocked(let host):
            return "This app's network policy only allows plain HTTP to this Mac itself. "
                + "\(host) would need https, or it may not support that."
        case .transport(let message):
            return "Request failed: \(message)"
        case .responseTooLarge(let limit):
            return "The response passed the configured limit (\(limit) bytes) and was cancelled."
        case .cancelled:
            return "The request was cancelled."
        }
    }
}

/// Sends one `HTTPRequestSpec` and returns what came back. This is the one
/// place a request is actually sent — the UI-bound model and, later, the
/// scripting API both go through it, so the timeout, redirect policy, byte
/// cap, and the plain-HTTP policy check are never duplicated.
///
/// Uses ordinary system TLS trust, with no certificate pinning and no ATS
/// exception beyond what already exists in this app: HTTPS to any host is
/// already permitted; plain HTTP only to this Mac itself. Proxmox's
/// trust-on-first-use pinning exists because Proxmox ships a known
/// self-signed certificate — an arbitrary third-party API gets no such
/// special treatment, the same as the AI assistant's client.
final class HTTPRequestExecutor {
    func execute(_ spec: HTTPRequestSpec, settings: AppSettings) async throws -> HTTPResponseSummary {
        guard let url = HTTPMessage.normalizedURL(from: spec.url), let host = url.host, !host.isEmpty else {
            throw HTTPClientError.invalidURL(spec.url)
        }
        // Only http/https are ever sent — anything else (ftp, file, ws, a
        // custom scheme) falls through the policy check below unnoticed
        // otherwise, since that check only special-cases "http".
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw HTTPClientError.unsupportedScheme(url.scheme ?? spec.url)
        }
        if scheme == "http", !AssistantDestination.isLoopback(host: host) {
            throw HTTPClientError.plainHTTPBlocked(host: host)
        }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method.rawValue
        // `addValue`, not `setValue`: the builder allows more than one row
        // with the same header name, and `setValue` would silently drop
        // every row but the last instead of sending them all.
        for header in spec.headers where !header.name.isEmpty {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if let body = spec.body, !body.isEmpty, !HTTPMethod.bodylessByConvention.contains(spec.method) {
            request.httpBody = body.data(using: .utf8)
        }

        let startedAt = Date()
        let runner = SizeLimitingRedirectRunner(
            followRedirects: settings.httpFollowRedirects,
            maxResponseBytes: settings.httpMaxResponseBytes
        )
        let (data, http) = try await runner.run(request, timeout: settings.httpRequestTimeout)
        let duration = Date().timeIntervalSince(startedAt)

        let headers = http.allHeaderFields.compactMap { key, value -> HTTPHeaderField? in
            guard let name = key as? String else { return nil }
            return HTTPHeaderField(name: name, value: "\(value)")
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        return HTTPResponseSummary(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            finalURL: http.url?.absoluteString ?? url.absoluteString,
            startedAt: startedAt,
            duration: duration
        )
    }
}

/// The `URLSessionDataDelegate` that gives `execute` real control over
/// redirects and a real, streaming byte cap.
///
/// `URLSession.data(for:delegate:)` — the convenient async form — only
/// accepts a `URLSessionTaskDelegate`, with no callback for bytes as they
/// arrive, so a byte cap enforced through it could only ever punish a
/// response after the whole thing was already buffered in memory. This
/// delegate's `didReceive data:` sees every chunk as it lands and cancels
/// the task the moment the running total passes the cap, so a huge or
/// runaway response is never fully downloaded in the first place.
///
/// One of these is created per request, never shared or reused — its
/// accumulator and one-shot continuation would otherwise leak state between
/// requests that have nothing to do with each other.
private final class SizeLimitingRedirectRunner: NSObject, URLSessionDataDelegate {
    private let followRedirects: Bool
    private let maxResponseBytes: Int
    private var accumulated = Data()
    private var exceededLimit = false
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?

    init(followRedirects: Bool, maxResponseBytes: Int) {
        self.followRedirects = followRedirects
        self.maxResponseBytes = maxResponseBytes
    }

    func run(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        // `timeoutIntervalForRequest` alone is an *inactivity* timeout — a
        // server that keeps trickling a byte every few seconds would never
        // trip it. Settings presents this one number as how long a request
        // is given before giving up, so it needs to cap the whole transfer
        // too, not just a gap in it.
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        // A `CheckedContinuation` has no idea the wrapping Swift `Task` was
        // cancelled — cancelling `sendTask` in `HTTPClientModel` would
        // otherwise only stop the UI from waiting, while the real transfer
        // (and any redirects it's still following) kept running to
        // completion in the background. `withTaskCancellationHandler` wires
        // real cancellation through to the data task that is actually doing
        // the work.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        accumulated.append(data)
        if accumulated.count > maxResponseBytes {
            exceededLimit = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            continuation = nil
            session.finishTasksAndInvalidate()
        }
        if exceededLimit {
            continuation?.resume(throwing: HTTPClientError.responseTooLarge(maxResponseBytes))
            return
        }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                continuation?.resume(throwing: HTTPClientError.cancelled)
            } else {
                continuation?.resume(throwing: HTTPClientError.transport(error.localizedDescription))
            }
            return
        }
        guard let http = task.response as? HTTPURLResponse else {
            continuation?.resume(throwing: HTTPClientError.transport("Unexpected response type."))
            return
        }
        continuation?.resume(returning: (accumulated, http))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects && isRedirectAllowed(request) ? request : nil)
    }

    /// The same plain-HTTP policy `execute` checks on the request it builds,
    /// re-applied to where a redirect actually points — a server redirecting
    /// an `https://` request to `http://some-other-host` would otherwise
    /// resend it, headers and all, in cleartext to a host that never agreed
    /// to the policy the first request's URL was checked against.
    private func isRedirectAllowed(_ request: URLRequest) -> Bool {
        guard let url = request.url, let host = url.host, !host.isEmpty else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        if scheme == "http" {
            return AssistantDestination.isLoopback(host: host)
        }
        return true
    }
}
