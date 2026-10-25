import Foundation

/// Free-account builds stop launching about 7 days after install (spec §1a). Reads the
/// expiration date from the embedded provisioning profile (absent in the simulator and in
/// App Store builds) and schedules a reminder 1 day before.
enum SigningExpiry {
    static let identifier = "signing_expiry"

    static func expirationDate(bundle: Bundle = .main) -> Date? {
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return nil }
        return parse(profile: data)
    }

    /// The profile is CMS-signed; its plist sits in clear text between <?xml and </plist>.
    static func parse(profile data: Data) -> Date? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = data.subdata(in: start.lowerBound..<end.upperBound)
        let obj = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
        return obj?["ExpirationDate"] as? Date
    }

    static func daysLeft(_ expiry: Date, now: Date) -> Int {
        Int((expiry.timeIntervalSince(now) / 86400).rounded(.down))
    }

    static func scheduleReminder(expiry: Date, now: Date, center: NotificationCenter, timeZone: TimeZone) async {
        await center.removePending([identifier])
        let fire = expiry.addingTimeInterval(-86400)
        guard fire > now else { return }
        try? await center.add(LocalNotification(identifier: identifier, title: "Fengshui needs reinstalling tomorrow",
                                                body: "The free developer signing expires in 1 day. Open Xcode and run Fengshui on your iPhone again — your data is kept.",
                                                fireDate: fire), timeZone: timeZone)
    }
}
