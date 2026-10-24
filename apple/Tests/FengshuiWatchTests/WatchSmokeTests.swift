import FengshuiKit
import XCTest

final class WatchSmokeTests: XCTestCase {
    func testCodecAvailableOnWatch() throws {
        let c = RawChunk(sensor: .accel, startTS: 0, rateHz: 50, samples: [[1, 2, 3], [4, 5, 6]])
        XCTAssertEqual(try RawCodec.decode(RawCodec.encode(c)), c)
    }
}
