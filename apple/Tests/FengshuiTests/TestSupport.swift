import FengshuiKit
import Foundation
@testable import Fengshui

/// The repo root on the Mac (the simulator shares the host file system).
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func fixture(_ path: String) -> URL { repoRoot.appendingPathComponent("fixtures/\(path)") }

func sample(_ i: Int, type: String = "HKQuantityTypeIdentifierHeartRate", value: Double? = nil,
            start: Double = 1_792_000_000, source: String = "Synthetic Watch") -> HealthSample {
    HealthSample(uuid: String(format: "00000000-0000-4000-8000-%012d", i), typeIdentifier: type,
                 label: LabelMapper.label(for: type), value: value ?? Double(60 + i % 40), valueText: nil,
                 unit: "count/min", start: start + Double(i) * 60, end: start + Double(i) * 60,
                 sourceName: source, sourceBundle: nil, device: nil, metadataJSON: nil)
}

extension AppDatabase {
    func count(_ sql: String) throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }
}

extension AppDatabase {
    /// Synchronous single-value helpers (callable from async tests without sending Rows).
    func double(_ sql: String) throws -> Double? {
        try writer.read { db in try Double.fetchOne(db, sql: sql) }
    }

    func int64(_ sql: String) throws -> Int64? {
        try writer.read { db in try Int64.fetchOne(db, sql: sql) }
    }
}
