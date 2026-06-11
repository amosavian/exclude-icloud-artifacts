import Foundation
import Logging
import System

/// Walks the trees under the configured roots, calling `visit` on every
/// artifact folder matching a rule, without descending into matches.
struct ArtifactScanner {
    let configuration: Configuration

    static func list(_ path: FilePath) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: path.string)) ?? [])
    }

    func scan(_ visit: (FilePath) -> Void) {
        for root in configuration.roots {
            scan(directory: root, entries: Self.list(root), visit)
        }
    }

    private func scan(directory: FilePath, entries: Set<String>, _ visit: (FilePath) -> Void) {
        for entry in entries {
            let path = directory.appending(entry)
            guard path.isDirectory else { continue }

            // The child listing doubles as the recursion listing; compute it
            // at most once, and only when a rule actually needs it.
            var cachedChildren: Set<String>?
            let children: () -> Set<String> = {
                if cachedChildren == nil { cachedChildren = Self.list(path) }
                return cachedChildren!
            }

            let isArtifact = configuration.rules.contains { rule in
                rule.matches(directoryNamed: entry, siblings: entries, children: children)
            }
            if isArtifact {
                visit(path)
            } else {
                scan(directory: path, entries: cachedChildren ?? Self.list(path), visit)
            }
        }
    }
}

/// Applies the sync-exclusion tag to artifact folders.
struct Tagger: Sendable {
    let configuration: Configuration
    private let tag = SyncExclusionTag()
    private let logger = Logger(label: "exclude-icloud-artifacts")

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func tagIfNeeded(_ path: FilePath) {
        guard path.isDirectory, !tag.isSet(on: path) else { return }
        if configuration.skipCloudOnly, let evicted = firstEvictedItem(in: path) {
            logger.warning(
                "not excluding \(path): \(evicted) is cloud-only (dataless) and excluding would delete its only full copy from the server")
            return
        }
        do {
            try tag.set(on: path)
            logger.info("excluded: \(path)")
        } catch {
            logger.error("setxattr failed for \(path): \(error)")
        }
    }

    /// First dataless item in the subtree, nil when everything is local.
    /// lstat/readdir only; symlinks are not followed (isDirectory is lstat).
    private func firstEvictedItem(in path: FilePath) -> FilePath? {
        if path.isDataless { return path }
        guard path.isDirectory else { return nil }
        for entry in ArtifactScanner.list(path) {
            if let found = firstEvictedItem(in: path.appending(entry)) {
                return found
            }
        }
        return nil
    }

    /// One full pass over the trees, tagging every untagged artifact folder.
    func sweep() {
        ArtifactScanner(configuration: configuration).scan(tagIfNeeded)
    }
}
