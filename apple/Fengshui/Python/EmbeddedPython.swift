import Foundation

/// The embedded CPython runtime (spec §8). Initialized lazily on first use;
/// every call goes through `fengshui_engine.bridge.call(name, json)`.
/// Callers serialize engine runs through `EngineRunner`; this type only guards
/// initialization, the GIL handles thread safety of individual calls.
final class EmbeddedPython: @unchecked Sendable {
    static let shared = EmbeddedPython()

    enum Failure: Error, CustomStringConvertible {
        case initialization(String)
        case call(String)
        case engine(String)

        var description: String {
            switch self {
            case .initialization(let m): "Python init failed: \(m)"
            case .call(let m): "Python call failed: \(m)"
            case .engine(let m): "Engine error: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private(set) var startupSeconds: Double?

    /// Bundle layout produced by scripts/build_python_ios.sh.
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func initializeIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if fs_python_is_initialized() != 0 { return }
        let root = bundle.bundlePath
        let start = Date()
        var err: UnsafeMutablePointer<CChar>?
        let rc = fs_python_initialize("\(root)/python", "\(root)/app_packages", &err)
        if rc != 0 {
            let message = err.map { String(cString: $0) } ?? "unknown"
            fs_python_free(err)
            throw Failure.initialization(message)
        }
        startupSeconds = Date().timeIntervalSince(start)
    }

    /// Calls a bridge function and returns its decoded `result` object.
    func call(_ function: String, _ args: [String: Any] = [:]) throws -> Any {
        try initializeIfNeeded()
        let json = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8)!
        var err: UnsafeMutablePointer<CChar>?
        guard let out = fs_python_call(function, json, &err) else {
            let message = err.map { String(cString: $0) } ?? "unknown"
            fs_python_free(err)
            throw Failure.call(message)
        }
        let text = String(cString: out)
        fs_python_free(out)
        guard let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure.call("bad JSON from bridge")
        }
        guard envelope["ok"] as? Bool == true else {
            throw Failure.engine(envelope["error"] as? String ?? "unknown")
        }
        return envelope["result"] ?? NSNull()
    }

    /// Typed variant: decodes the bridge `result` into `T`.
    func call<T: Decodable>(_ function: String, _ args: [String: Any] = [:], as: T.Type) throws -> T {
        let result = try call(function, args)
        let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        return try JSONDecoder().decode(T.self, from: data)
    }
}
