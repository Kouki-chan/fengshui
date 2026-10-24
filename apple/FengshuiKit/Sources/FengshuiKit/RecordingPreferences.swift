import Foundation

/// What the watch records (spec §7.2). Chosen at first launch on the phone, stored in
/// `preferences` (key `recording`), mirrored to the watch via updateApplicationContext.
public struct RecordingPreferences: Codable, Equatable, Sendable {
    public var accelerometer = true          // tier 1
    public var gyroscope = true              // tier 2 / 3
    public var barometer = true
    public var compass = true
    public var sessionHeartRate = true       // tier 3
    public var snapshotIntervalMin = 60      // tier 2: 30 / 60 / 120
    public var snapshotSeconds = 5.0         // tier 2 length, 3–10 s
    public var sessionsAllowed = true

    public static let key = "recording"
    public static let allowedIntervals = [30, 60, 120]
    public static let snapshotRange = 3.0...10.0

    public init() {}

    /// Clamp to the allowed values (a stale or hand-edited context can't break the watch).
    public func sanitized() -> RecordingPreferences {
        var p = self
        if !Self.allowedIntervals.contains(p.snapshotIntervalMin) { p.snapshotIntervalMin = 60 }
        p.snapshotSeconds = min(max(p.snapshotSeconds, Self.snapshotRange.lowerBound), Self.snapshotRange.upperBound)
        return p
    }

    public var snapshotSensorsEnabled: Bool { gyroscope || barometer || compass }

    public func asContext() throws -> [String: Any] {
        ["recording": String(data: try JSONEncoder.sortedKeys.encode(self), encoding: .utf8)!]
    }

    public static func from(context: [String: Any]) -> RecordingPreferences? {
        guard let s = context["recording"] as? String else { return nil }
        return (try? JSONDecoder().decode(Self.self, from: Data(s.utf8)))?.sanitized()
    }
}

extension JSONEncoder {
    public static var sortedKeys: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }
}
