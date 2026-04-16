import Foundation

/// Default destinations for files the agent receives or generates.
/// Created on first launch under `~/Documents/LocalAgent/`.
/// The agent can move files elsewhere via bash or write_file; this is just the default drop.
enum LandingZone {
    static let root: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Documents/LocalAgent", isDirectory: true)
    }()

    enum Kind: String, CaseIterable {
        case telegram
        case email
        case downloads
        case generated

        var directoryName: String { rawValue }
    }

    /// Scratch area for short-lived artifacts (git clones of remote repos, mostly).
    /// Auto-swept on startup and every `scratchSweepInterval` while the app is alive.
    /// Entries older than `scratchTTL` are removed.
    static let scratchReposRoot: URL = root
        .appendingPathComponent("scratch", isDirectory: true)
        .appendingPathComponent("repos", isDirectory: true)

    static let scratchTTL: TimeInterval = 24 * 60 * 60           // 24h
    static let scratchSweepInterval: TimeInterval = 6 * 60 * 60  // 6h

    static func directory(for kind: Kind) -> URL {
        root.appendingPathComponent(kind.directoryName, isDirectory: true)
    }

    /// Idempotently create the root and all subdirectories.
    /// Safe to call on every launch.
    static func bootstrap() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            for kind in Kind.allCases {
                try fm.createDirectory(at: directory(for: kind), withIntermediateDirectories: true)
            }
            try fm.createDirectory(at: scratchReposRoot, withIntermediateDirectories: true)
        } catch {
            print("[LandingZone] bootstrap failed: \(error)")
        }
        sweepScratchNow()
        startScratchSweepLoop()
    }

    /// Remove top-level entries inside `scratchReposRoot` whose mtime is older than `scratchTTL`.
    /// Top-level only — we don't walk inside clones, we delete them wholesale.
    static func sweepScratchNow() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: scratchReposRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-scratchTTL)
        var removed = 0
        for url in entries {
            let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let mtime = rv?.contentModificationDate ?? .distantPast
            if mtime < cutoff {
                do {
                    try fm.removeItem(at: url)
                    removed += 1
                } catch {
                    print("[LandingZone] sweep failed to remove \(url.lastPathComponent): \(error)")
                }
            }
        }
        if removed > 0 {
            print("[LandingZone] scratch sweep: removed \(removed) stale clone(s) from \(scratchReposRoot.path)")
        }
    }

    /// Detached loop that periodically sweeps the scratch dir.
    /// Detached so shutdown doesn't have to wait for a sweep to finish.
    /// Idempotent — guarded so we only ever launch one loop.
    private static let sweepLoopGuard = SweepLoopGuard()
    private static func startScratchSweepLoop() {
        guard sweepLoopGuard.claim() else { return }
        Task.detached {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(scratchSweepInterval * 1_000_000_000))
                if Task.isCancelled { break }
                sweepScratchNow()
            }
        }
    }

    private final class SweepLoopGuard: @unchecked Sendable {
        private var started = false
        private let lock = NSLock()
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if started { return false }
            started = true
            return true
        }
    }

    /// Resolve a unique destination path inside a given kind's directory.
    /// If `filename` collides, appends `-1`, `-2`, ... before the extension.
    static func destinationPath(kind: Kind, filename: String) -> URL {
        let dir = directory(for: kind)
        let base = dir.appendingPathComponent(filename)
        let fm = FileManager.default
        guard fm.fileExists(atPath: base.path) else { return base }
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        for i in 1..<10_000 {
            let candidate = dir
                .appendingPathComponent("\(stem)-\(i)")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Fallback: timestamped
        let ts = Int(Date().timeIntervalSince1970)
        return dir.appendingPathComponent("\(stem)-\(ts)").appendingPathExtension(ext)
    }
}
