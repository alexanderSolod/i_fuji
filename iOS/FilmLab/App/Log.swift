import Foundation
import os

/// Logging to os_log plus an in-app ring buffer shown (and shareable) on the debug screen,
/// so device-check results can be copied into docs/DEVELOPMENT_LOG.md.
enum Log {
    private static let logger = Logger(subsystem: "com.filmlab.app", category: "FilmLab")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer: [String] = []
    private static let maxLines = 2000
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { logger.info("\(message, privacy: .public)"); append("I", message) }
    static func debug(_ message: String) { logger.debug("\(message, privacy: .public)"); append("D", message) }
    static func error(_ message: String) { logger.error("\(message, privacy: .public)"); append("E", message) }

    static var lines: [String] { lock.withLock { buffer } }

    private static func append(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        lock.withLock {
            buffer.append(line)
            if buffer.count > maxLines { buffer.removeFirst(buffer.count - maxLines) }
        }
    }
}
