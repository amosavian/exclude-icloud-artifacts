import Foundation
import Logging
import System
import Yams

/// Shape of config.yaml. Every key is optional; defaults apply per key.
struct ConfigFile: Decodable {
    var roots: [String]?
    var latency: Double?
    var presets: [String]?
    var rules: [ExclusionRule]?
}

struct Configuration: Sendable {
    /// iCloud-synced folders to keep clean.
    let roots: [FilePath]
    let rules: [ExclusionRule]

    /// Seconds FSEvents coalesces events before waking us.
    /// Higher = fewer wakeups = less battery.
    let latency: Double

    static let defaultRoots = ["~/Documents", "~/Desktop"]
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
            return Configuration(file: file)
        } catch {
            logger.error("cannot load \(path): \(error)")
            exit(1)
        }
    }

    init(file: ConfigFile) {
        let logger = Logger(label: "exclude-icloud-artifacts")
        roots = (file.roots ?? Self.defaultRoots).map {
            FilePath(($0 as NSString).expandingTildeInPath)
        }
        latency = file.latency ?? 10

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
    }
}
