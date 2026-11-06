import Foundation
import XCTest
@testable import FilmLab

enum Fixtures {
    static var directory: URL {
        Bundle(for: BundleToken.self).url(forResource: "fixtures", withExtension: nil)!
    }

    static func json(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func doubles(_ any: Any?) -> [Double] {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
    }

    static func triples(_ any: Any?) -> [SIMD3<Double>] {
        (any as? [[Any]])?.map { row in
            let v = row.compactMap { ($0 as? NSNumber)?.doubleValue }
            return SIMD3(v[0], v[1], v[2])
        } ?? []
    }

    static func testLUT() throws -> CubeLUT {
        try CubeLUT.parse(contentsOf: directory.appendingPathComponent("test_lut_17.cube"))
    }

    private final class BundleToken {}
}
