import Foundation
import simd

/// A 3D LUT parsed from an Adobe/Resolve `.cube` file.
/// Entries are stored in file order: red varies fastest, then green, then blue.
struct CubeLUT: Equatable {
    var title: String?
    var size: Int
    var domainMin: SIMD3<Double>
    var domainMax: SIMD3<Double>
    /// `size^3` RGB triples, flattened, index = r + g*N + b*N*N.
    var values: [SIMD3<Float>]

    enum ParseError: Error, Equatable, LocalizedError {
        case oneDimensional
        case missingSize
        case invalidSize(Int)
        case entryCount(expected: Int, found: Int)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .oneDimensional: return "This is a 1D LUT; a 3D LUT is required."
            case .missingSize: return "No LUT_3D_SIZE found."
            case .invalidSize(let n): return "Invalid LUT_3D_SIZE \(n)."
            case let .entryCount(e, f): return "Expected \(e) entries, found \(f)."
            case .unreadable: return "The file is not readable text."
            }
        }
    }

    static func parse(contentsOf url: URL) throws -> CubeLUT {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ParseError.unreadable
        }
        return try parse(text)
    }

    /// Mirrors `read_cube` in bake_applelog_to_fuji.py.
    static func parse(_ text: String) throws -> CubeLUT {
        var size: Int?
        var dmin = SIMD3<Double>(repeating: 0)
        var dmax = SIMD3<Double>(repeating: 1)
        var title: String?
        var values: [SIMD3<Float>] = []

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isNewline }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tok = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = tok.first else { continue }
            switch first.uppercased() {
            case "LUT_3D_SIZE":
                guard tok.count > 1, let n = Int(tok[1]) else { throw ParseError.missingSize }
                guard n >= 2, n <= 256 else { throw ParseError.invalidSize(n) }
                size = n
                values.reserveCapacity(n * n * n)
            case "LUT_1D_SIZE":
                throw ParseError.oneDimensional
            case "DOMAIN_MIN":
                if let v = triple(tok.dropFirst()) { dmin = v }
            case "DOMAIN_MAX":
                if let v = triple(tok.dropFirst()) { dmax = v }
            case "LUT_3D_INPUT_RANGE":
                if tok.count >= 3, let lo = Double(tok[1]), let hi = Double(tok[2]) {
                    dmin = SIMD3(repeating: lo)
                    dmax = SIMD3(repeating: hi)
                }
            case "TITLE":
                title = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            default:
                if let v = triple(tok[...]) { values.append(SIMD3<Float>(v)) }
            }
        }
        guard let n = size else { throw ParseError.missingSize }
        guard values.count == n * n * n else { throw ParseError.entryCount(expected: n * n * n, found: values.count) }
        return CubeLUT(title: title, size: n, domainMin: dmin, domainMax: dmax, values: values)
    }

    private static func triple<S: Collection>(_ tok: S) -> SIMD3<Double>? where S.Element == Substring {
        let parts = tok.prefix(3).compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return SIMD3(parts[0], parts[1], parts[2])
    }

    func entry(r: Int, g: Int, b: Int) -> SIMD3<Double> {
        SIMD3<Double>(values[r + g * size + b * size * size])
    }

    /// Trilinear interpolation, mirroring `apply_cube` in the Python reference.
    func apply(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let n = Double(size - 1)
        var x = (rgb - domainMin) / (domainMax - domainMin) * n
        x = simd_clamp(x, SIMD3(repeating: 0), SIMD3(repeating: n))
        let i0 = SIMD3<Int>(min(Int(x.x.rounded(.down)), size - 2),
                            min(Int(x.y.rounded(.down)), size - 2),
                            min(Int(x.z.rounded(.down)), size - 2))
        let f = x - SIMD3<Double>(i0)
        func t(_ db: Int, _ dg: Int, _ dr: Int) -> SIMD3<Double> {
            entry(r: i0.x + dr, g: i0.y + dg, b: i0.z + db)
        }
        let c00 = t(0, 0, 0) * (1 - f.x) + t(0, 0, 1) * f.x
        let c01 = t(0, 1, 0) * (1 - f.x) + t(0, 1, 1) * f.x
        let c10 = t(1, 0, 0) * (1 - f.x) + t(1, 0, 1) * f.x
        let c11 = t(1, 1, 0) * (1 - f.x) + t(1, 1, 1) * f.x
        let c0 = c00 * (1 - f.y) + c01 * f.y
        let c1 = c10 * (1 - f.y) + c11 * f.y
        return c0 * (1 - f.z) + c1 * f.z
    }
}
