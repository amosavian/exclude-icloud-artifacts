import Darwin

/// A folder that should be kept out of iCloud Drive sync.
///
/// `folder` and all conditions support shell-style globs (`fnmatch`), e.g.
/// `cmake-build-*` or `*.csproj`.
struct ExclusionRule: Sendable, Decodable {
    /// Name (or glob pattern) of the artifact folder, e.g. ".build".
    let folder: String

    /// If non-empty, the folder is excluded only when one of these entries
    /// exists next to it. Guards generic names like "build" or "target"
    /// against false positives on ordinary folders.
    let ifSiblingExists: [String]

    /// If non-empty, the folder is excluded only when one of these entries
    /// exists inside it, e.g. "pyvenv.cfg" for virtualenvs or the
    /// CACHEDIR.TAG marker of the Cache Directory Tagging Specification.
    let ifChildExists: [String]

    init(_ folder: String, ifSiblingExists: [String] = [], ifChildExists: [String] = []) {
        self.folder = folder
        self.ifSiblingExists = ifSiblingExists
        self.ifChildExists = ifChildExists
    }

    private enum CodingKeys: String, CodingKey {
        case folder, ifSiblingExists, ifChildExists
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        folder = try container.decode(String.self, forKey: .folder)
        ifSiblingExists = try container.decodeIfPresent([String].self, forKey: .ifSiblingExists) ?? []
        ifChildExists = try container.decodeIfPresent([String].self, forKey: .ifChildExists) ?? []
    }

    /// Cheap name-only check, used as a prefilter before any I/O.
    func nameMatches(_ name: String) -> Bool {
        Self.matches(pattern: folder, name)
    }

    /// Full check. `siblings` is the listing of the folder's parent;
    /// `children` lazily lists the folder itself.
    func matches(
        directoryNamed name: String,
        siblings: Set<String>,
        children: () -> Set<String>
    ) -> Bool {
        guard nameMatches(name) else { return false }
        if !ifSiblingExists.isEmpty,
           !Self.matches(anyPattern: ifSiblingExists, in: siblings) {
            return false
        }
        if !ifChildExists.isEmpty,
           !Self.matches(anyPattern: ifChildExists, in: children()) {
            return false
        }
        return true
    }

    private static func matches(pattern: String, _ name: String) -> Bool {
        guard pattern.contains(where: { "*?[".contains($0) }) else {
            return pattern == name
        }
        return fnmatch(pattern, name, 0) == 0
    }

    private static func matches(anyPattern patterns: [String], in entries: Set<String>) -> Bool {
        patterns.contains { pattern in
            guard pattern.contains(where: { "*?[".contains($0) }) else {
                return entries.contains(pattern)
            }
            return entries.contains { fnmatch(pattern, $0, 0) == 0 }
        }
    }
}
