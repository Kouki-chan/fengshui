import Foundation

/// One HealthKit object type Fengshui reads. The list itself is generated from
/// the SDK headers (HealthTypeCatalog+Generated.swift, DECISIONS D-10).
struct HealthTypeInfo: Hashable, Sendable {
    enum Kind: String, Sendable {
        case quantity, category, characteristic, correlation, scoredAssessment, document
        case workout, series, stateOfMind, audiogram, electrocardiogram
    }

    let identifier: String
    let kind: Kind
    let label: String
    /// Unit string from the SDK header comment; used when preferredUnits has none.
    let defaultUnit: String?

    /// Types that become rows in processed_samples (characteristics go to their own table;
    /// correlations are read through their member quantity types).
    var isSampleType: Bool {
        ![.characteristic, .correlation, .document].contains(kind) && identifier != "HKWorkoutRouteTypeIdentifier"
    }
}

enum HealthTypeCatalog {
    static func info(_ identifier: String) -> HealthTypeInfo? { byIdentifier[identifier] }

    static let byIdentifier: [String: HealthTypeInfo] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.identifier, $0) })

    static var sampleTypes: [HealthTypeInfo] { all.filter(\.isSampleType) }

    /// Spec §6.1: background delivery for these only.
    static let backgroundDelivery: [String] = [
        "HKCategoryTypeIdentifierSleepAnalysis",
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierStepCount",
        "HKWorkoutTypeIdentifier",
        "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
        "HKQuantityTypeIdentifierRestingHeartRate",
    ]

    /// Fallback units where the header comment has none.
    static func unit(for t: HealthTypeInfo) -> String? {
        if let u = t.defaultUnit { return u }
        switch t.identifier {
        case "HKQuantityTypeIdentifierUVExposure": return "count"
        default: return nil
        }
    }
}
