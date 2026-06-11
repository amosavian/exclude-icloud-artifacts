import CryptoKit
import Darwin
import Foundation
import Logging
import System
import Yams

/// Shape of config.yaml. Every key is optional; defaults apply per key.
struct ConfigFile: Decodable {
    var roots: [String]?
    var latency: Double?
    var skipCloudOnly: Bool?
    var presets: [String]?
    var rules: [ExclusionRule]?
}

struct Configuration: Sendable {
    /// iCloud-synced folders to keep clean.
    let roots: [FilePath]
    let rules: [ExclusionRule]

    /// Folder names from unconditional rules (no sibling/child guard):
    /// membership alone implies exclusion, with no I/O needed. Used as a
    /// fast path in matching and for the watcher's preflight skip.
    let unguardedExactNames: Set<String>
    private let unguardedGlobNames: [String]

    /// Rules safe to evaluate for the *siblings* of a changed directory:
    /// everything except child-marker rules. Child-marker rules (e.g. the
    /// `*` + CACHEDIR.TAG catch-all) would force a listing of every sibling
    /// subdirectory on every event; they fire instead via the marked
    /// directory's own event, when its contents (the marker) change.
    let eventSiblingRules: [ExclusionRule]

    /// Where the last completed sweep's fingerprint is recorded.
    let sweepStampPath: FilePath

    /// Seconds FSEvents coalesces events before waking us.
    /// Higher = fewer wakeups = less battery.
    let latency: Double

    /// Skip folders whose subtree contains cloud-evicted (dataless) items
    /// instead of tagging them. Tagging removes any already-uploaded copy
    /// from the server, which for evicted content is the only full copy.
    /// Off by default: artifact folders are regenerable, so they are
    /// excluded (and cleaned from the cloud) even when evicted.
    let skipCloudOnly: Bool

    static let defaultRoots = ["~/Documents", "~/Desktop", "~/Library/CloudStorage"]
    static let defaultPresets = ["swift", "node", "python", "java", "rust", "general"]

    static var defaultConfigPath: FilePath {
        FilePath(NSHomeDirectory() + "/.config/exclude-icloud-artifacts/config.yaml")
    }

    /// Loads config.yaml from `configPath` (must exist when given explicitly)
    /// or from the default location (defaults apply when absent).
    static func load(configPath: FilePath?) -> Configuration {
        let logger = Logger(label: "exclude-icloud-artifacts")
        let path = configPath ?? defaultConfigPath
        guard path.exists else {
            if let configPath {
                logger.error("config file not found: \(configPath)")
                exit(1)
            }
            return Configuration(file: ConfigFile())
        }
        do {
            let yaml = try String(contentsOfFile: path.string, encoding: .utf8)
            let file = try YAMLDecoder().decode(ConfigFile.self, from: yaml)
            return Configuration(file: file, source: path)
        } catch {
            logger.error("cannot load \(path): \(error)")
            exit(1)
        }
    }

    init(file: ConfigFile, source: FilePath? = nil) {
        let logger = Logger(label: "exclude-icloud-artifacts")
        roots = (file.roots ?? Self.defaultRoots).map {
            FilePath(($0 as NSString).expandingTildeInPath)
        }
        latency = file.latency ?? 10
        skipCloudOnly = file.skipCloudOnly ?? false

        var rules: [ExclusionRule] = []
        for name in file.presets ?? Self.defaultPresets {
            if let preset = Preset.all[name] {
                rules += preset
            } else {
                let known = Preset.all.keys.sorted().joined(separator: ", ")
                logger.warning("unknown preset '\(name)' ignored (known: \(known))")
            }
        }
        rules += file.rules ?? []
        // Wildcard rules force a directory listing per candidate; keep them
        // last so exact-name rules can short-circuit first.
        self.rules = rules.sorted { !$0.folder.contains("*") && $1.folder.contains("*") }

        var exact: Set<String> = []
        var globs: [String] = []
        for rule in self.rules where rule.ifSiblingExists.isEmpty && rule.ifChildExists.isEmpty {
            if rule.folder.contains(where: { "*?[".contains($0) }) {
                globs.append(rule.folder)
            } else {
                exact.insert(rule.folder)
            }
        }
        unguardedExactNames = exact
        unguardedGlobNames = globs
        eventSiblingRules = self.rules.filter { $0.ifChildExists.isEmpty }
        sweepStampPath = (source ?? Self.defaultConfigPath)
            .removingLastComponent()
            .appending("sweep-stamp")
    }

    /// Syscall-free check: does this folder name alone guarantee exclusion?
    func nameIsUnguardedArtifact(_ name: String) -> Bool {
        unguardedExactNames.contains(name)
            || unguardedGlobNames.contains { fnmatch($0, name, 0) == 0 }
    }
}

// MARK: - Sweep stamp

extension Configuration {
    /// Stable digest of everything that affects what a sweep would tag:
    /// roots, rules, and the eviction guard. Latency is deliberately
    /// excluded - it changes batching, not outcomes.
    var sweepFingerprint: String {
        var canonical = roots.map(\.string).joined(separator: "\n")
        canonical += "\nskipCloudOnly:\(skipCloudOnly)\n"
        for rule in rules {
            canonical += "\(rule.folder)|\(rule.ifSiblingExists.joined(separator: ","))"
            canonical += "|\(rule.ifChildExists.joined(separator: ","))\n"
        }
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A startup sweep is needed only when no sweep has ever run for this
    /// exact configuration - i.e. first install or a config change. Plain
    /// agent restarts skip the walk entirely.
    func needsStartupSweep() -> Bool {
        (try? String(contentsOfFile: sweepStampPath.string, encoding: .utf8))
            != sweepFingerprint
    }

    func recordSweep() {
        let dir = sweepStampPath.removingLastComponent()
        try? FileManager.default.createDirectory(
            atPath: dir.string, withIntermediateDirectories: true)
        try? sweepFingerprint.write(
            toFile: sweepStampPath.string, atomically: true, encoding: .utf8)
    }
}
