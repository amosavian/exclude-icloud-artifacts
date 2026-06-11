import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

/// Drives Watcher.handle with synthetic FSEvents and observes the xattr on
/// disk - the same contract production has with the real event stream.
/// Without per-file events, FSEvents reports the directory in which changes
/// occurred; the handler evaluates that directory and its entries.
@Suite struct WatcherEventTests {
    private let tag = SyncExclusionTag()

    private func makeWatcher(root: FilePath, rules: [ExclusionRule]) -> Watcher {
        // Short cooldown so throttle tests finish quickly.
        Watcher(
            configuration: Configuration(file: ConfigFile(
                roots: [root.string], latency: nil, presets: [], rules: rules)),
            rescanCooldown: 0.5)
    }

    /// Rescans run asynchronously on the watcher's scan queue; poll for the
    /// tag instead of asserting immediately.
    private func waitForTag(on path: FilePath, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tag.isSet(on: path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return tag.isSet(on: path)
    }

    /// For negative assertions: give the async machinery time to (wrongly)
    /// act before checking nothing happened.
    private func settle() {
        Thread.sleep(forTimeInterval: 0.25)
    }

    private func makeDir(_ path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.string, withIntermediateDirectories: true)
    }

    @Test func tagsNewArtifactReportedViaParentDirectory() throws {
        // mkdir node_modules produces an event for its parent.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let parent = root.appending("proj")
        let dir = parent.appending("node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: parent, flags: []))
        #expect(tag.isSet(on: dir))
    }

    @Test func tagsArtifactWhenChangesHappenInsideIt() throws {
        // First writes into a fresh artifact dir produce an event for the
        // artifact dir itself - important for child-marker guards whose
        // marker lands after the directory is created.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let venv = root.appending("proj/venv")
        try makeDir(venv)
        FileManager.default.createFile(
            atPath: venv.appending("pyvenv.cfg").string, contents: Data())

        let rule = ExclusionRule("venv", ifChildExists: ["pyvenv.cfg"])
        let watcher = makeWatcher(root: root, rules: [rule])
        watcher.handle(FSEvent(path: venv, flags: []))
        #expect(tag.isSet(on: venv))
    }

    @Test func ignoresNonMatchingEntries() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let parent = root.appending("proj")
        try makeDir(parent.appending("src"))

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: parent, flags: []))
        #expect(!tag.isSet(on: parent.appending("src")))
        #expect(!tag.isSet(on: parent))
    }

    @Test func neverTagsMatchingFiles() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let parent = root.appending("proj")
        try makeDir(parent)
        let file = parent.appending("node_modules")
        FileManager.default.createFile(atPath: file.string, contents: Data())

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: parent, flags: []))
        #expect(!tag.isSet(on: file))
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
        watcher.handle(FSEvent(path: root.appending("plain"), flags: []))
        watcher.handle(FSEvent(path: root.appending("crate"), flags: []))
        #expect(!tag.isSet(on: bare))
        #expect(tag.isSet(on: crate))
    }

    @Test func skipsEventsInsideArtifactTreeByNameAlone() throws {
        // Preflight: a path component naming an unconditional artifact folder
        // (here an UNTAGGED node_modules - its tag may still be in flight)
        // must short-circuit with no tagging inside.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let inner = root.appending("node_modules/pkg")
        try makeDir(inner.appending(".build"))

        let watcher = makeWatcher(
            root: root,
            rules: [ExclusionRule("node_modules"), ExclusionRule(".build")])
        watcher.handle(FSEvent(path: inner, flags: []))
        #expect(!tag.isSet(on: inner.appending(".build")))
    }

    @Test func ignoresChangesUnderGuardedTaggedAncestor() throws {
        // Guarded names (rust target) never hit the name preflight; coverage
        // must come from the xattr walk + tagged-ancestor cache.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let target = root.appending("crate/target")
        try makeDir(target.appending("debug"))
        FileManager.default.createFile(
            atPath: root.appending("crate/Cargo.toml").string, contents: Data())
        try tag.set(on: target)
        try makeDir(target.appending("debug/node_modules"))

        let rule = ExclusionRule("target", ifSiblingExists: ["Cargo.toml"])
        let watcher = makeWatcher(root: root, rules: [rule, ExclusionRule("node_modules")])
        // Twice: second event exercises the cache-hit path.
        watcher.handle(FSEvent(path: target.appending("debug"), flags: []))
        watcher.handle(FSEvent(path: target.appending("debug"), flags: []))
        #expect(!tag.isSet(on: target.appending("debug/node_modules")))
    }

    @Test func childMarkerRulesFireViaOwnEventOnly() throws {
        // The `*` + CACHEDIR.TAG catch-all must not force listings of every
        // sibling subdirectory: parent events skip it, the marked dir's own
        // event (marker written inside it) tags it.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let cached = root.appending("proj/render-cache")
        try makeDir(cached)
        FileManager.default.createFile(
            atPath: cached.appending("CACHEDIR.TAG").string, contents: Data())

        let rule = ExclusionRule("*", ifChildExists: ["CACHEDIR.TAG"])
        let watcher = makeWatcher(root: root, rules: [rule])
        watcher.handle(FSEvent(path: root.appending("proj"), flags: []))
        #expect(!tag.isSet(on: cached), "parent event must not evaluate child markers")

        watcher.handle(FSEvent(path: cached, flags: []))
        #expect(tag.isSet(on: cached), "own event evaluates child markers")
    }

    @Test func ignoresChangesUnderTaggedAncestor() throws {
        // Changes during a build inside an already-excluded tree are covered
        // by the ancestor's tag and must trigger no listings or tagging.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let build = root.appending(".build")
        let inner = build.appending("checkouts/dep")
        try makeDir(inner.appending("node_modules"))
        try tag.set(on: build)

        let watcher = makeWatcher(
            root: root,
            rules: [ExclusionRule(".build"), ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: inner, flags: []))
        #expect(!tag.isSet(on: inner.appending("node_modules")))
    }

    @Test func ignoresChangesInsideTaggedDirectoryItself() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let tagged = root.appending("node_modules")
        try makeDir(tagged.appending(".build"))
        try tag.set(on: tagged)

        let watcher = makeWatcher(
            root: root,
            rules: [ExclusionRule(".build"), ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: tagged, flags: []))
        #expect(!tag.isSet(on: tagged.appending(".build")))
    }

    @Test func ignoresVanishedPaths() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: root.appending("ghost"), flags: []))
        #expect(!tag.isSet(on: root))
    }

    @Test func queueOverflowAtRootRescansThatRoot() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("proj/node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: root, flags: [.mustScanSubDirs]))
        #expect(waitForTag(on: dir))
    }

    @Test func queueOverflowRescansOnlyTheAffectedSubtree() throws {
        // The kernel names the subtree it dropped events for; artifacts
        // elsewhere must not be touched (that is what made overflow sweeps
        // burn CPU during builds).
        let root = try makeTempDir()
        defer { removeDir(root) }
        let affected = root.appending("projA/node_modules")
        let untouched = root.appending("projB/node_modules")
        try makeDir(affected)
        try makeDir(untouched)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: root.appending("projA"), flags: [.mustScanSubDirs]))
        #expect(waitForTag(on: affected))
        settle()
        #expect(!tag.isSet(on: untouched))
    }

    @Test func queueOverflowTagsTheOverflowDirectoryItself() throws {
        // The invalidated subtree can be a brand-new artifact folder whose
        // create event was among the dropped ones.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let dir = root.appending("proj/node_modules")
        try makeDir(dir.appending("pkg"))

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: dir, flags: [.mustScanSubDirs]))
        #expect(waitForTag(on: dir))
    }

    @Test func queueOverflowUnderTaggedAncestorIsIgnored() throws {
        // Overflows during a build happen inside the already-excluded build
        // tree; the ancestor's tag covers everything beneath it.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let build = root.appending(".build")
        let inner = build.appending("checkouts/dep/node_modules")
        try makeDir(inner)
        try tag.set(on: build)

        let watcher = makeWatcher(
            root: root,
            rules: [ExclusionRule(".build"), ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: build.appending("checkouts"), flags: [.mustScanSubDirs]))
        settle()
        #expect(!tag.isSet(on: inner))
    }

    @Test func queueOverflowRescansAreThrottled() throws {
        // Kernel-buffer overflows arrive with every event batch during a
        // build; rescanning whole roots each time is what burns CPU. After
        // an immediate first rescan, further overflows within the cooldown
        // are deferred and coalesced into one trailing rescan.
        let root = try makeTempDir()
        defer { removeDir(root) }
        let first = root.appending("projA/node_modules")
        try makeDir(first)
        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])

        watcher.handle(FSEvent(path: root, flags: [.mustScanSubDirs])) // immediate
        #expect(waitForTag(on: first))
        Thread.sleep(forTimeInterval: 0.15) // completion bookkeeping lands

        let second = root.appending("projB/node_modules")
        try makeDir(second)
        watcher.handle(FSEvent(path: root, flags: [.mustScanSubDirs])) // deferred
        Thread.sleep(forTimeInterval: 0.1)
        #expect(!tag.isSet(on: second), "overflow within cooldown must not rescan immediately")

        // The deferred rescan must still happen (trailing edge).
        #expect(waitForTag(on: second, timeout: 3), "trailing rescan must catch up")
    }

    @Test func queueOverflowOutsideRootsIsIgnored() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let elsewhere = try makeTempDir()
        defer { removeDir(elsewhere) }
        let dir = elsewhere.appending("node_modules")
        try makeDir(dir)

        let watcher = makeWatcher(root: root, rules: [ExclusionRule("node_modules")])
        watcher.handle(FSEvent(path: elsewhere, flags: [.mustScanSubDirs]))
        settle()
        #expect(!tag.isSet(on: dir))
    }
}
