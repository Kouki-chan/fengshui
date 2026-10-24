import Foundation

/// The shared time key: floor(unix_seconds_utc / 60). Must match
/// `fengshui_engine.minute.minute_id` exactly (watch, phone and server).
public enum MinuteID {
    public static func from(_ unixSeconds: Double) -> Int64 {
        Int64((unixSeconds / 60).rounded(.down))
    }

    public static func from(_ date: Date) -> Int64 {
        from(date.timeIntervalSince1970)
    }

    public static func start(_ minuteID: Int64) -> Double {
        Double(minuteID) * 60
    }
}
