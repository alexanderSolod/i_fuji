import CoreGraphics

/// Color space of the shared stage's output (Fujifilm LUTs output Rec.709).
/// Used for both the viewfinder layer and exported images so they match.
/// Open question in docs/DEVELOPMENT_LOG.md: whether to tag as ITU-R 709 (BT.709 TRC)
/// or as sRGB to match how other apps (Blackmagic Camera) display the same LUT.
enum OutputColor {
    static let colorSpace = CGColorSpace(name: CGColorSpace.itur_709)!
}
