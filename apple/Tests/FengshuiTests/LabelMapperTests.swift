import XCTest
@testable import Fengshui

/// Gate: label mapping tested against every HealthKit identifier in the iOS 26 SDK.
final class LabelMapperTests: XCTestCase {
    struct Catalog: Decodable {
        struct T: Decodable { let identifier: String; let label: String; let kind: String }
        let types: [T]
    }

    func testEverySDKIdentifierMatchesPythonLabel() throws {
        let c = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: fixture("hk_identifiers_ios26.json")))
        XCTAssertGreaterThan(c.types.count, 200)
        for t in c.types {
            XCTAssertEqual(LabelMapper.label(for: t.identifier), t.label, t.identifier)
        }
        // The generated Swift catalog is the same list.
        XCTAssertEqual(Set(HealthTypeCatalog.all.map(\.identifier)), Set(c.types.map(\.identifier)))
        XCTAssertEqual(Set(HealthTypeCatalog.all.map(\.label)).count, c.types.count, "labels must be unique")
    }

    func testWorkoutActivityNames() throws {
        let names = try JSONDecoder().decode([String: String].self,
                                             from: Data(contentsOf: fixture("hk_workout_activities.json")))
        for (k, v) in names { XCTAssertEqual(LabelMapper.workoutActivityNames[UInt(k)!], v) }
        XCTAssertEqual(LabelMapper.workoutActivityNames[37], "running")
    }

    func testExamples() {
        XCTAssertEqual(LabelMapper.label(for: "HKQuantityTypeIdentifierHeartRate"), "heart_rate")
        XCTAssertEqual(LabelMapper.label(for: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"), "heart_rate_variability_sdnn")
        XCTAssertEqual(LabelMapper.label(for: "HKQuantityTypeIdentifierVO2Max"), "vo2_max")
        XCTAssertEqual(LabelMapper.label(for: "HKQuantityTypeIdentifierUVExposure"), "uv_exposure")
        XCTAssertEqual(LabelMapper.label(for: "HKQuantityTypeIdentifierDietaryVitaminB12"), "dietary_vitamin_b12")
    }

    func testSleepAndCategoryText() {
        let t = "HKCategoryTypeIdentifierSleepAnalysis"
        XCTAssertEqual((0...5).map { LabelMapper.categoryText(type: t, rawValue: $0) },
                       ["in_bed", "asleep_unspecified", "awake", "asleep_core", "asleep_deep", "asleep_rem"])
        XCTAssertEqual(LabelMapper.categoryText(type: "HKCategoryTypeIdentifierHeadache", rawValue: 2), "severity_mild")
        XCTAssertEqual(LabelMapper.categoryText(type: "HKCategoryTypeIdentifierAppleStandHour", rawValue: 0), "stood")
    }
}
