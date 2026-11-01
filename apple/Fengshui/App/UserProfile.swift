import GRDB
import SwiftUI

/// The user's profile (Settings → Profile, DECISIONS D-24): what they tell HealthBot about
/// themselves, used for their goals on Today and, if they allow it, as context for Claude.
/// Stored in the local preferences table; never synced to the server.
struct UserProfile: Codable, Equatable, Sendable {
    enum Sex: String, Codable, CaseIterable, Identifiable {
        case unspecified = "Prefer not to say", female = "Female", male = "Male", other = "Other"
        var id: String { rawValue }
    }

    var name = ""
    var birthYear: Int?
    var sex = Sex.unspecified
    var heightCm: Double?
    var weightKg: Double?
    var goals: [String] = []
    var stepGoal = 8_000
    var sleepGoalHours = 8.0
    /// Anything else HealthBot should know (shift work, a new baby, training for a race…).
    var notes = ""
    var shareWithClaude = true

    static let key = "user_profile"
    static let goalOptions = ["Sleep better", "Move more", "Sit less", "Lower stress", "Build fitness",
                              "Lose weight", "Keep a steady routine"]

    init() {}

    /// Every field is optional on disk, so profiles saved by older versions still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UserProfile()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        birthYear = try c.decodeIfPresent(Int.self, forKey: .birthYear)
        sex = (try? c.decodeIfPresent(Sex.self, forKey: .sex)) ?? d.sex
        heightCm = try c.decodeIfPresent(Double.self, forKey: .heightCm)
        weightKg = try c.decodeIfPresent(Double.self, forKey: .weightKg)
        goals = try c.decodeIfPresent([String].self, forKey: .goals) ?? d.goals
        stepGoal = try c.decodeIfPresent(Int.self, forKey: .stepGoal) ?? d.stepGoal
        sleepGoalHours = try c.decodeIfPresent(Double.self, forKey: .sleepGoalHours) ?? d.sleepGoalHours
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? d.notes
        shareWithClaude = try c.decodeIfPresent(Bool.self, forKey: .shareWithClaude) ?? d.shareWithClaude
    }

    var firstName: String { name.split(separator: " ").first.map(String.init) ?? "" }

    var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "" : String(letters).uppercased()
    }

    static func load(_ db: AppDatabase) -> UserProfile {
        ((try? db.preference(key, as: UserProfile.self)) ?? nil) ?? UserProfile()
    }

    func save(_ db: AppDatabase, now: Date) throws { try db.setPreference(Self.key, self, now: now) }

    /// Fills empty fields from Apple Health (date of birth, sex, latest height and weight).
    mutating func prefill(_ db: AppDatabase) {
        let found = try? db.writer.read { db -> (String?, String?, Double?, Double?) in
            let dob = try String.fetchOne(db, sql: "SELECT value FROM characteristics WHERE key = 'date_of_birth'")
            let sex = try String.fetchOne(db, sql: "SELECT value FROM characteristics WHERE key = 'biological_sex'")
            let latest = { (label: String) in
                try Row.fetchOne(db, sql: """
                    SELECT value, unit FROM processed_samples WHERE label = ? AND deleted = 0 AND value IS NOT NULL
                    ORDER BY start_ts DESC LIMIT 1
                    """, arguments: [label])
            }
            let height = try latest("height").map { r -> Double in
                let v: Double = r["value"]
                return (r["unit"] as String?) == "m" ? v * 100 : v
            }
            let weight = try latest("body_mass").map { r -> Double in
                let v: Double = r["value"]
                return (r["unit"] as String?) == "lb" ? v * 0.453_592 : v
            }
            return (dob, sex, height, weight)
        }
        guard let (dob, s, height, weight) = found else { return }
        if birthYear == nil, let y = dob.flatMap({ Int($0.prefix(4)) }) { birthYear = y }
        if sex == .unspecified, let s { sex = ["female": .female, "male": .male, "other": .other][s] ?? .unspecified }
        if heightCm == nil { heightCm = height }
        if weightKg == nil { weightKg = weight }
    }

    /// One short paragraph for Claude, or nil when sharing is off or nothing is filled in.
    func claudeContext(now: Date, timeZone: TimeZone) -> String? {
        guard shareWithClaude, self != UserProfile() else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var parts: [String] = []
        if !firstName.isEmpty { parts.append("Name: \(firstName)") }
        if let y = birthYear { parts.append("Age: about \(cal.component(.year, from: now) - y)") }
        if sex != .unspecified { parts.append("Sex: \(sex.rawValue.lowercased())") }
        if let h = heightCm { parts.append("Height: \(Int(h.rounded())) cm") }
        if let w = weightKg { parts.append("Weight: \(Int(w.rounded())) kg") }
        if !goals.isEmpty { parts.append("Goals: \(goals.joined(separator: ", "))") }
        parts.append("Daily step goal: \(stepGoal)")
        parts.append("Sleep goal: \(sleepGoalHours.formatted()) h")
        let note = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { parts.append("Notes from the user: \(note)") }
        return "About me (from my HealthBot profile; use it to personalise, don't repeat it back): "
            + parts.joined(separator: ". ") + "."
    }
}

/// The avatar used for the profile: initials on the theme gradient, or a person glyph.
struct ProfileAvatar: View {
    @Environment(\.theme) private var theme
    let initials: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(theme.heroGradient)
            if initials.isEmpty {
                Image(systemName: "person.fill").font(.system(size: size * 0.45, weight: .semibold))
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(theme.onHero)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Settings → Profile.
struct ProfileView: View {
    let env: AppEnvironment
    @Environment(\.theme) private var theme
    @Environment(UIState.self) private var ui: UIState?
    @Environment(\.dismiss) private var dismiss
    @State private var profile = UserProfile()
    @State private var saved = UserProfile()
    @State private var loaded = false
    @State private var weightText = ""

    private static let usesMetric = Locale.current.measurementSystem == .metric
    private static let heights = Array(stride(from: 120.0, through: 220.0, by: 1.0))

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ProfileAvatar(initials: profile.initials, size: 56)
                    TextField("Your name", text: $profile.name)
                        .font(.title3.weight(.semibold))
                        .textContentType(.name)
                        .accessibilityIdentifier("profile.name")
                }
                .padding(.vertical, 4)
            }
            Section {
                Picker("Born", selection: $profile.birthYear) {
                    Text("Not set").tag(Int?.none)
                    ForEach((1920...thisYear - 10).reversed(), id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                }
                Picker("Sex", selection: $profile.sex) {
                    ForEach(UserProfile.Sex.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Height", selection: $profile.heightCm) {
                    Text("Not set").tag(Double?.none)
                    ForEach(Self.heights, id: \.self) { Text(Self.heightText($0)).tag(Double?.some($0)) }
                }
                HStack {
                    Text("Weight")
                    TextField("Not set", text: $weightText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("profile.weight")
                    Text(Self.usesMetric ? "kg" : "lb").foregroundStyle(.secondary)
                }
            } header: { Text("About you") } footer: {
                Text("Filled in from Apple Health where available. You can change anything here.")
            }
            Section("Goals") {
                ForEach(UserProfile.goalOptions, id: \.self) { g in
                    Button { toggle(g) } label: {
                        HStack {
                            Text(g).foregroundStyle(.primary)
                            Spacer()
                            if profile.goals.contains(g) { Image(systemName: "checkmark").foregroundStyle(theme.tint) }
                        }
                    }
                    .accessibilityIdentifier("profile.goal.\(g)")
                }
                Stepper("Steps a day: \(profile.stepGoal.formatted())", value: $profile.stepGoal, in: 2_000...30_000, step: 500)
                    .accessibilityIdentifier("profile.stepGoal")
                Stepper("Sleep: \(profile.sleepGoalHours.formatted()) h a night", value: $profile.sleepGoalHours,
                        in: 5...11, step: 0.5)
                    .accessibilityIdentifier("profile.sleepGoal")
            }
            Section {
                TextField("Shift work, training for a race, a new baby…", text: $profile.notes, axis: .vertical)
                    .lineLimit(3...6)
                    .accessibilityIdentifier("profile.notes")
            } header: { Text("Anything else HealthBot should know") }
            Section {
                Toggle("Share my profile with HealthBot", isOn: $profile.shareWithClaude)
                    .accessibilityIdentifier("profile.share")
            } footer: {
                Text(profile.shareWithClaude
                     ? "HealthBot uses this profile with each question, so answers and Today's snippets fit your goals."
                     : "HealthBot won't send your profile with questions. Your goals are still used on this iPhone.")
            }
        }
        .themedList()
        .keyboardDoneButton()
        .navigationTitle("Profile")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(current == saved).accessibilityIdentifier("profile.save")
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            var p = UserProfile.load(env.db)
            p.prefill(env.db)
            profile = p
            saved = UserProfile.load(env.db)
            weightText = p.weightKg.map { Self.weightText($0) } ?? ""
        }
    }

    private var thisYear: Int { Calendar.current.component(.year, from: env.clock.now) }

    /// The profile with the weight field applied.
    private var current: UserProfile {
        var p = profile
        let v = Double(weightText.replacingOccurrences(of: ",", with: "."))
        p.weightKg = v.map { Self.usesMetric ? $0 : $0 * 0.453_592 }
        return p
    }

    private func toggle(_ goal: String) {
        if let i = profile.goals.firstIndex(of: goal) { profile.goals.remove(at: i) } else { profile.goals.append(goal) }
    }

    private func save() {
        hideKeyboard()
        let p = current
        try? p.save(env.db, now: env.clock.now)
        saved = p
        profile = p
        ui?.reloadProfile()
        dismiss()  // back to Settings
    }

    static func heightText(_ cm: Double) -> String {
        if usesMetric { return "\(Int(cm)) cm" }
        let inches = Int((cm / 2.54).rounded())
        return "\(inches / 12)′ \(inches % 12)″"
    }

    static func weightText(_ kg: Double) -> String {
        let v = usesMetric ? kg : kg / 0.453_592
        return String(format: "%.0f", v)
    }
}
