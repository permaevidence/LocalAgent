import Foundation

/// Tracks (mtime, size, readAt) snapshots per absolute path for the lifetime of the process.
/// Write/edit tools assert the snapshot still matches the on-disk state before modifying a file,
/// catching cases where the file changed externally since the agent last read it.
///
/// Snapshots are in-memory only. They reset on app restart, which is correct — the invariant
/// is "don't modify a file you haven't read this session."
actor FileTimeTracker {
    static let shared = FileTimeTracker()

    struct Snapshot {
        let mtime: Date
        let size: Int64
        let readAt: Date
    }

    private var snapshots: [String: Snapshot] = [:]

    private init() {}

    /// Record that the agent just read `path`, stamping the current on-disk (mtime, size).
    func recordRead(path: String) {
        guard let (mtime, size) = Self.currentStat(path: path) else { return }
        snapshots[path] = Snapshot(mtime: mtime, size: size, readAt: Date())
    }

    /// Verify the file has not changed since the agent last read it.
    /// Throws if the file was never read in this session, or if mtime/size drifted.
    func assertFresh(path: String) throws {
        guard let snap = snapshots[path] else {
            throw FileTimeError.notRead(path: path)
        }
        guard let (mtime, size) = Self.currentStat(path: path) else {
            // File was read before but now missing — caller will handle as appropriate.
            return
        }
        if size != snap.size || !mtime.isApproximatelyEqual(to: snap.mtime) {
            throw FileTimeError.stale(
                path: path,
                snapshotMtime: snap.mtime,
                currentMtime: mtime,
                snapshotSize: snap.size,
                currentSize: size
            )
        }
    }

    /// Clear the snapshot for a path (used after a successful write so the next read can re-snapshot).
    func forget(path: String) {
        snapshots.removeValue(forKey: path)
    }

    /// Returns `(mtime, size)` if the file exists and is readable, otherwise nil.
    private static func currentStat(path: String) -> (Date, Int64)? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let attrs,
              let mtime = attrs[.modificationDate] as? Date,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return (mtime, size)
    }
}

enum FileTimeError: LocalizedError {
    case notRead(path: String)
    case stale(path: String, snapshotMtime: Date, currentMtime: Date, snapshotSize: Int64, currentSize: Int64)

    var errorDescription: String? {
        switch self {
        case .notRead(let path):
            return "You must read \(path) with read_file before overwriting or editing it. Use read_file first."
        case .stale(let path, let snapMtime, let curMtime, let snapSize, let curSize):
            let fmt = ISO8601DateFormatter()
            return """
            \(path) changed since last read.
            Last read: mtime=\(fmt.string(from: snapMtime)) size=\(snapSize)
            Current:   mtime=\(fmt.string(from: curMtime)) size=\(curSize)
            Re-read the file before modifying it.
            """
        }
    }
}

private extension Date {
    /// Filesystem mtime resolution varies; treat dates within 1ms as equal.
    func isApproximatelyEqual(to other: Date) -> Bool {
        abs(timeIntervalSince(other)) < 0.001
    }
}
