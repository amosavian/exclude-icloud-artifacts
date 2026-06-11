import Foundation
import Logging
import System

/// Walks the trees under the configured roots, calling `visit` on every
/// artifact folder matching a rule, without descending into matches.
struct ArtifactScanner {
    let configuration: Configuration

    static func list(_ path: FilePath) -> DirectoryEntries {
        path.listEntries()
    }

    func scan(_ visit: (FilePath) -> Void) {
        for root in configuration.roots {
            scan(under: root, visit)
        }
    }

    /// Walks a single subtree only - the scoped catch-up used after an
    /// FSEvents queue overflow names the invalidated directory.
    func scan(under root: FilePath, _ visit: (FilePath) -> Void) {
        scan(directory: root, entries: Self.list(root), visit)
    }

    private func scan(directory: FilePath, entries: DirectoryEntries, _ visit: (FilePath) -> Void) {
        for entry in entries.directories {
            let path = directory.appending(entry)

            // The child listing doubles as the recursion listing; compute it
            // at most once, and only when a rule actually needs it.
            var cachedChildren: DirectoryEntries?
            let children: () -> [String] = {
                if cachedChildren == nil { cachedChildren = Self.list(path) }
                return cachedChildren!.names
            }

            let isArtifact = configuration.unguardedExactNames.contains(entry)
                || configuration.rules.contains { rule in
                    rule.matches(directoryNamed: entry, siblings: entries.names, children: children)
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
        for entry in ArtifactScanner.list(path).names {
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
