import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

/// Drives Watcher.handle with synthetic FSEvents and observes the xattr on
/// disk - the same contract production has with the real event stream.
@Suite struct WatcherEventTests {
    private let tag = SyncExclusionTag()

    private func makeWatcher(root: FilePath, rules: [ExclusionRule]) -> Watcher {
        Watcher(configuration: Configuration(file: ConfigFile(
            roots: [root.string], latency: nil, presets: [], rules: rules)))
    }

    private func makeDir(_ path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.string, withIntermediateDirectories: true)
    }

    @Test func tagsCreatedArtifactDirectory() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("proj/node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.created, .isDirectory]))
        #expect(tag.isSet(on: dir))
    }

    @Test func tagsRenamedInArtifactDirectory() throws {
        // mv of an existing tree into the watched root arrives as .renamed.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.renamed, .isDirectory]))
        #expect(tag.isSet(on: dir))
    }

    @Test func ignoresEventsWithoutDirectoryFlag() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.created]))
        #expect(!tag.isSet(on: dir))
    }

    @Test func ignoresNonCreateRenameEvents() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.isDirectory]))
        #expect(!tag.isSet(on: dir))
    }

    @Test func ignoresNonMatchingDirectoryNames() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("src")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.created, .isDirectory]))
        #expect(!tag.isSet(on: dir))
    }

    @Test func honorsSiblingGuardForEvents() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let rule = ExclusionRule("target", ifSiblingExists: ["Cargo.toml"])
        let bare = root.appending("plain/target")
        let crate = root.appending("crate/target")
        try makeDir(bare)
        try makeDir(crate)
        FileManager.default.createFile(
            atPath: root.appending("crate/Cargo.toml").string, contents: Data())

        let watcher = makeWatcher(root: root, rules: [rule])
        watcher.handle(FSEvent(path: bare, flags: [.created, .isDirectory]))
        watcher.handle(FSEvent(path: crate, flags: [.created, .isDirectory]))
        #expect(!tag.isSet(on: bare))
        #expect(tag.isSet(on: crate))
    }

    @Test func skipsDirectoriesUnderTaggedAncestor() throws {
        // Dirs created during a build inside an already-excluded tree are
        // covered by the ancestor's tag and must not be tagged again.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let build = root.appending(".build")
        let inner = build.appending("checkouts/dep/node_modules")
        try makeDir(inner)
        try tag.set(on: build)

        let watcher = makeWatcher(
            root: root,
            rules: [ExclusionRule(".build"), ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: inner, flags: [.created, .isDirectory]))
        #expect(!tag.isSet(on: inner))
    }

    @Test func queueOverflowFallsBackToFullSweep() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("proj/node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: root, flags: [.mustScanSubDirs]))
        #expect(tag.isSet(on: dir))
    }
}
