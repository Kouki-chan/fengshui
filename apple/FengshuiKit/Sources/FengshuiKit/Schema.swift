import Foundation

/// Schema v1 SQL, shared byte-for-byte with the Python engine (DECISIONS D-04).
public enum Schema {
    public static let latestVersion = 1

    public static func sql(version: Int = latestVersion) throws -> String {
        guard let url = Bundle.module.url(forResource: "schema_v\(version)", withExtension: "sql") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
