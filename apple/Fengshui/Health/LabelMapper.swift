import Foundation

/// Swift twin of fengshui_engine.hk_labels (spec §6.1): HealthKit identifier → snake_case
/// label, and category raw values → readable `value_text`.
enum LabelMapper {
    private static let prefixes = [
        "HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKCorrelationTypeIdentifier",
        "HKCharacteristicTypeIdentifier", "HKDocumentTypeIdentifier", "HKScoredAssessmentTypeIdentifier",
        "HKDataTypeIdentifier", "HKDataType", "HKWorkoutActivityType", "HKCategoryValue", "HKBiologicalSex",
        "HKBloodType", "HKFitzpatrickSkinType", "HKWheelchairUse", "HK",
    ]
    private static let special = [
        "HKWorkoutTypeIdentifier": "workout",
        "HKWorkoutRouteTypeIdentifier": "workout_route",
        "HKDataTypeIdentifierHeartbeatSeries": "heartbeat_series",
        "HKElectrocardiogramType": "electrocardiogram",
        "HKAudiogramSampleType": "audiogram",
        "HKAudiogramTypeIdentifier": "audiogram",
        "HKStateOfMindTypeIdentifier": "state_of_mind",
        "HKVisionPrescriptionTypeIdentifier": "vision_prescription",
    ]

    static func label(for identifier: String) -> String {
        if let s = special[identifier] { return s }
        for p in prefixes where identifier.hasPrefix(p) && identifier.count > p.count {
            return snake(String(identifier.dropFirst(p.count)))
        }
        return snake(identifier)
    }

    /// Same two regex passes as Python: ([A-Z]+)([A-Z][a-z]) then ([a-z0-9])([A-Z]).
    static func snake(_ s: String) -> String {
        let c = Array(s)
        var pass1: [Character] = []
        for i in c.indices {
            // Insert "_" between an uppercase run and an Uppercase+lowercase pair.
            if i > 0, i + 1 < c.count, c[i].isUppercase, c[i + 1].isLowercase, c[i - 1].isUppercase {
                pass1.append("_")
            }
            pass1.append(c[i])
        }
        var out = ""
        for i in pass1.indices {
            if i > 0, pass1[i].isUppercase, pass1[i - 1].isLowercase || pass1[i - 1].isNumber {
                out.append("_")
            }
            out.append(pass1[i])
        }
        return out.lowercased()
    }

    static func activityName(_ rawEnumName: String) -> String { label(for: rawEnumName) }

    // MARK: Category values

    static let sleep = ["in_bed", "asleep_unspecified", "awake", "asleep_core", "asleep_deep", "asleep_rem"]
    private static let severity = ["unspecified", "not_present", "mild", "moderate", "severe"]
    private static let severityTypes: Set<String> = [
        "AbdominalCramps", "Acne", "BladderIncontinence", "Bloating", "BreastPain", "ChestTightnessOrPain",
        "Chills", "Constipation", "Coughing", "Diarrhea", "Dizziness", "DrySkin", "Fainting", "Fatigue", "Fever",
        "GeneralizedBodyAche", "HairLoss", "Headache", "Heartburn", "HotFlashes", "LossOfSmell", "LossOfTaste",
        "LowerBackPain", "MemoryLapse", "Nausea", "NightSweats", "PelvicPain", "RapidPoundingOrFlutteringHeartbeat",
        "RunnyNose", "ShortnessOfBreath", "SinusCongestion", "SkippedHeartbeat", "SoreThroat", "VaginalDryness",
        "Vomiting", "Wheezing",
    ]

    /// Readable value for a category sample. Matches the Health export's names
    /// (e.g. severity_mild) so export rows can be adopted (DECISIONS D-06).
    static func categoryText(type identifier: String, rawValue: Int) -> String? {
        let name = identifier.replacingOccurrences(of: "HKCategoryTypeIdentifier", with: "")
        switch name {
        case "SleepAnalysis":
            return sleep.indices.contains(rawValue) ? sleep[rawValue] : nil
        case "AppleStandHour":
            return rawValue == 0 ? "stood" : rawValue == 1 ? "idle" : nil
        case "LowCardioFitnessEvent":
            return rawValue == 1 ? "low_fitness" : nil
        case "AppetiteChanges":
            return ["unspecified", "no_change", "decreased", "increased"][safe: rawValue].map { "appetite_changes_\($0)" }
        case "MenstrualFlow":
            return ["unspecified", "light", "medium", "heavy", "none"][safe: rawValue - 1]
        case _ where severityTypes.contains(name):
            return severity[safe: rawValue].map { "severity_\($0)" }
        default:
            // HKCategoryValueNotApplicable (0) for event-style categories.
            return rawValue == 0 ? "not_applicable" : nil
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
