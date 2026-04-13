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
        } catch {
            print("[LandingZone] bootstrap failed: \(error)")
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
