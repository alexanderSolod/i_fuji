import simd
import XCTest
@testable import FilmLab

final class ColorScienceTests: XCTestCase {
    // MARK: Spec 2.3 test vectors

    func testAppleLogGray() {
        XCTAssertEqual(AppleLog.encode(0.18), 0.488, accuracy: 0.002)
        XCTAssertEqual(AppleLog.decode(AppleLog.encode(0.18)), 0.18, accuracy: 1e-12)
    }

    func testFLog2Gray() {
        XCTAssertEqual(FLog2.encode(0.18), 0.391, accuracy: 0.002)
    }

    func testFLog2Breakpoint() {
        XCTAssertEqual(FLog2.encode(0.000889), 0.100686, accuracy: 1e-5)
        XCTAssertEqual(FLog2.encode(FLog2.cut1), FLog2.cut2, accuracy: 1e-5)
    }

    func testRoundTrips() {
        var x = 1e-4
        while x <= 10 {
            XCTAssertEqual(FLog2.decode(FLog2.encode(x)), x, accuracy: x * 1e-6, "F-Log2 \(x)")
            XCTAssertEqual(AppleLog.decode(AppleLog.encode(x)), x, accuracy: x * 1e-6, "Apple Log \(x)")
            x *= 1.05
        }
    }

    func testAppleLogLowSegmentRoundTrip() {
        for x in stride(from: -0.05, through: 0.02, by: 0.001) {
            XCTAssertEqual(AppleLog.decode(AppleLog.encode(x)), x, accuracy: 1e-7)
        }
    }

    func testCurvesMatchPython() throws {
        let j = try Fixtures.json("curves.json")
        let lin = Fixtures.doubles(j["linear"])
        for (x, e) in zip(lin, Fixtures.doubles(j["applelog_encode"])) {
            XCTAssertEqual(AppleLog.encode(x), e, accuracy: 1e-8)
        }
        for (x, e) in zip(lin, Fixtures.doubles(j["flog2_encode"])) {
            XCTAssertEqual(FLog2.encode(x), e, accuracy: 1e-8)
        }
        let codes = Fixtures.doubles(j["applelog_codes"])
        for (p, e) in zip(codes, Fixtures.doubles(j["applelog_decode"])) {
            XCTAssertEqual(AppleLog.decode(p), e, accuracy: max(abs(e) * 1e-8, 1e-8))
        }
        for (p, e) in zip(codes, Fixtures.doubles(j["flog2_decode"])) {
            XCTAssertEqual(FLog2.decode(p), e, accuracy: max(abs(e) * 1e-8, 1e-8))
        }
    }

    // MARK: Gamut

    func testRec2020ToFGamutIsIdentity() {
        let m = Gamut.rec2020ToFGamut
        for c in 0..<3 {
            for r in 0..<3 {
                XCTAssertEqual(m[c][r], c == r ? 1 : 0, accuracy: 1e-9)
            }
        }
    }

    func testRec709RoundTrip() {
        let m = Gamut.rec2020ToRec709 * Gamut.rec709ToRec2020
        XCTAssertEqual(m[0][0], 1, accuracy: 1e-9)
        XCTAssertEqual(m[1][0], 0, accuracy: 1e-9)
        // Known value: Rec.709 -> Rec.2020 [0][0] = 0.6274
        XCTAssertEqual(Gamut.rec709ToRec2020[0][0], 0.6274, accuracy: 1e-4)
    }

    // MARK: .cube parsing

    func testParseWithDomainCommentsAndTitle() throws {
        let text = """
        # Comment line
        TITLE "My LUT"

        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.1 0.2
        DOMAIN_MAX 1.0 2.0 3.0
        # data
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.title, "My LUT")
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.domainMin, SIMD3(0, 0.1, 0.2))
        XCTAssertEqual(lut.domainMax, SIMD3(1, 2, 3))
        // red varies fastest
        XCTAssertEqual(lut.entry(r: 1, g: 0, b: 0), SIMD3(1, 0, 0))
        XCTAssertEqual(lut.entry(r: 0, g: 1, b: 0), SIMD3(0, 1, 0))
        XCTAssertEqual(lut.entry(r: 0, g: 0, b: 1), SIMD3(0, 0, 1))
        // identity LUT with a domain maps domain -> 0..1
        let out = lut.apply(SIMD3(0.5, 1.05, 1.6))
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.z, 0.5, accuracy: 1e-9)
    }

    func testParseInputRangeAndCRLF() throws {
        let text = "LUT_3D_SIZE 2\r\nLUT_3D_INPUT_RANGE 0 4\r\n" + String(repeating: "0.5 0.5 0.5\r\n", count: 8)
        let lut = try CubeLUT.parse(text)
        XCTAssertEqual(lut.domainMax, SIMD3(repeating: 4))
        XCTAssertEqual(lut.values.count, 8)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try CubeLUT.parse("LUT_1D_SIZE 4\n0 0 0")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .oneDimensional) }
        XCTAssertThrowsError(try CubeLUT.parse("0 0 0\n")) { XCTAssertEqual($0 as? CubeLUT.ParseError, .missingSize) }
        XCTAssertThrowsError(try CubeLUT.parse("LUT_3D_SIZE 2\n0 0 0\n")) {
            XCTAssertEqual($0 as? CubeLUT.ParseError, .entryCount(expected: 8, found: 1))
        }
    }

    func testTrilinearEdges() throws {
        let lut = try Fixtures.testLUT()
        // Exact grid points and out-of-range inputs clamp to edge entries.
        XCTAssertEqual(lut.apply(.zero), lut.entry(r: 0, g: 0, b: 0))
        XCTAssertEqual(lut.apply(.one), lut.entry(r: 16, g: 16, b: 16))
        XCTAssertEqual(lut.apply(SIMD3(-1, 2, 0.5)), lut.entry(r: 0, g: 16, b: 8))
    }

    func testTrilinearMatchesPython() throws {
        let lut = try Fixtures.testLUT()
        let j = try Fixtures.json("lut_samples.json")
        let inputs = Fixtures.triples(j["inputs"])
        let outputs = Fixtures.triples(j["outputs"])
        XCTAssertEqual(inputs.count, 10_000)
        var maxErr = 0.0
        for (i, o) in zip(inputs, outputs) {
            maxErr = max(maxErr, simd_reduce_max(simd_abs(lut.apply(i) - o)))
        }
        XCTAssertLessThan(maxErr, 1e-5)
    }

    // MARK: Shared stage (CPU) and Neutral

    func testSharedStageCPUMatchesPython() throws {
        let lut = try Fixtures.testLUT()
        let j = try Fixtures.json("stage_image.json")
        let input = Fixtures.triples(j["input"])
        for ev in [0.0, 0.7, -1.3] {
            let expected = Fixtures.triples(j[String(format: "output_ev%+.1f", ev)])
            var maxErr = 0.0
            for (i, e) in zip(input, expected) {
                maxErr = max(maxErr, simd_reduce_max(simd_abs(SharedStage.apply(i, lut: lut, exposureStops: ev) - e)))
            }
            XCTAssertLessThan(maxErr, 1e-5, "EV \(ev)")
        }
    }

    func testNeutralLUTMatchesPython() throws {
        let lut = NeutralLUT.make(size: 33)
        let j = try Fixtures.json("neutral_lut_samples.json")
        let idx = (j["indices_rgb"] as? [[Int]]) ?? []
        let values = Fixtures.triples(j["values"])
        XCTAssertFalse(idx.isEmpty)
        for (i, v) in zip(idx, values) {
            let e = lut.entry(r: i[0], g: i[1], b: i[2])
            XCTAssertLessThan(simd_reduce_max(simd_abs(e - v)), 1e-6)
        }
    }

    func testYCbCrMatchesPython() throws {
        let j = try Fixtures.json("preview_ycbcr.json")
        for (key, full) in [("video_range", false), ("full_range", true)] {
            let d = try XCTUnwrap(j[key] as? [String: Any])
            let y = Fixtures.doubles(d["y"]), cb = Fixtures.doubles(d["cb"]), cr = Fixtures.doubles(d["cr"])
            let lin = Fixtures.triples(d["linear"])
            let conv = YCbCrConversion.bt2020(bitDepth: 10, fullRange: full)
            for i in 0..<y.count {
                let rgb = conv.rgb(y: y[i], cb: cb[i], cr: cr[i])
                let l = SIMD3(AppleLog.decode(rgb.x), AppleLog.decode(rgb.y), AppleLog.decode(rgb.z))
                XCTAssertLessThan(simd_reduce_max(simd_abs(l - lin[i]) / simd_max(simd_abs(lin[i]), SIMD3(repeating: 1e-3))), 1e-6)
            }
        }
    }

    func testDisplayNames() {
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "XH2S_FLog2_FGamut_to_Classic-Chrome_BT.709_33grid_V.1.00.cube"), "Classic Chrome")
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "FLog2_ETERNA-BleachBypass_33grid.cube"), "Eterna Bleach Bypass")
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "F-Log2_Eterna.cube"), "Eterna")
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "FLog2_PRO-Neg.Std_WDR.cube"), "PRO Neg. Std")
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "FLog2_Classic-Neg.cube"), "Classic Neg.")
        XCTAssertEqual(SimulationLibrary.displayName(forFileName: "my_custom_look.cube"), "my custom look")
    }
}
