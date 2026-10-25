import Foundation
import Network

/// HTTP client for the Mac server (spec §12). JSON in/out; blobs base64.
struct ServerClient: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case notConfigured, http(Int, String), versionMismatch(String)
        var description: String {
            switch self {
            case .notConfigured: "server URL or token not set"
            case .http(let c, let m): "HTTP \(c): \(m)"
            case .versionMismatch(let m): m
            }
        }
    }

    let baseURL: URL
    let token: String
    let session: URLSession

    init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    func health() async throws -> [String: Any] {
        try await request("GET", "health", body: nil, auth: false)
    }

    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await request("POST", path, body: body)
    }

    func get(_ path: String, query: [String: String]) async throws -> [String: Any] {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await send(URLRequest(url: c.url!), auth: true)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]?, auth: Bool = true) async throws -> [String: Any] {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        if let body {
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await send(r, auth: auth)
    }

    private func send(_ req: URLRequest, auth: Bool) async throws -> [String: Any] {
        var r = req
        r.timeoutInterval = 120
        if auth { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            if code == 409 { throw Failure.versionMismatch(msg) }
            throw Failure.http(code, String(msg.prefix(300)))
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

/// Wi-Fi check (sync over Wi-Fi only, spec §12), behind a protocol for tests.
protocol NetworkStatus: Sendable {
    var onWiFi: Bool { get }
}

final class PathNetworkStatus: NetworkStatus, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var wifi = false

    init() {
        monitor.pathUpdateHandler = { [weak self] p in
            guard let self else { return }
            let w = p.status == .satisfied && (p.usesInterfaceType(.wifi) || p.usesInterfaceType(.wiredEthernet))
            self.lock.withLock { self.wifi = w }
        }
        monitor.start(queue: DispatchQueue(label: "fengshui.path"))
    }

    var onWiFi: Bool { lock.withLock { wifi } }
}

struct FixedNetworkStatus: NetworkStatus { var onWiFi: Bool }

/// Bonjour `_fengshui._tcp` discovery with a manual URL fallback in Settings (spec §12).
enum ServerDiscovery {
    static func find(timeout: TimeInterval = 5) async -> URL? {
        await withCheckedContinuation { cont in
            let browser = NWBrowser(for: .bonjour(type: "_fengshui._tcp", domain: nil), using: .tcp)
            let done = Once()
            browser.browseResultsChangedHandler = { results, _ in
                guard let r = results.first else { return }
                // Resolve the service by connecting once and reading the remote endpoint.
                let conn = NWConnection(to: r.endpoint, using: .tcp)
                conn.stateUpdateHandler = { state in
                    if case .ready = state, case let .hostPort(host, port)? = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let i = h.firstIndex(of: "%") { h = String(h[..<i]) }      // strip interface scope
                        if h.contains(":") { h = "[\(h)]" }
                        conn.cancel()
                        browser.cancel()
                        if done.claim() { cont.resume(returning: URL(string: "http://\(h):\(port)")) }
                    }
                }
                conn.start(queue: .main)
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                if done.claim() { cont.resume(returning: nil) }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func claim() -> Bool { lock.withLock { defer { used = true }; return !used } }
    }
}
