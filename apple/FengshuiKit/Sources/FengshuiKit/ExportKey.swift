import CryptoKit
import Foundation

/// The identity of a Health-export row (DECISIONS D-06). The export has no
/// HealthKit UUIDs, so rows imported from it use
/// `"export:" + sha1(hk_type|start|end|source_name|value|value_text)`.
/// HealthKit sync computes the same key to adopt those rows instead of duplicating them.
/// Must match `fengshui_engine.export_key.export_key`.
public enum ExportKey {
    public static func make(hkType: String, start: Double, end: Double, sourceName: String?,
                            value: Double?, valueText: String?) -> String {
        // floor(x + 0.5) to match the Python side exactly.
        let parts = [hkType, String(Int64((start + 0.5).rounded(.down))), String(Int64((end + 0.5).rounded(.down))),
                     sourceName ?? "", value.map(formatValue) ?? "", valueText ?? ""]
        let digest = Insecure.SHA1.hash(data: Data(parts.joined(separator: "|").utf8))
        return "export:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Shortest round-trip decimal, matching Python's `repr(float)` for the values Health uses
    /// (integers print without ".0" so "72" == 72.0 on both sides).
    static func formatValue(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }
}
