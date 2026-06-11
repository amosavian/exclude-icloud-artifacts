import Dispatch
import Foundation
import Logging
import System

/// Mutable rescan bookkeeping. All access is confined to the watcher's
/// serial event queue (FSEvents callbacks and the deferred-rescan timer both
/// run there), so no locking is needed.
private final class RescanThrottle: @unchecked Sendable {
    /// When the most recent rescan finished; nil until the first one.
    var lastFinished: Date?
    /// Overflow scopes waiting for the trailing rescan.
    var pending: Set<FilePath> = []
    var timerScheduled = false
    /// A rescan is currently running on the scan queue.
    var scanInFlight = false
}

/// Event-queue-confined memo of ancestors confirmed tagged via xattr.
/// Bounded; wholesale reset when full (refills in one event batch).
/// Staleness from a manual `xattr -d` heals on agent restart.
private final class TaggedAncestorCache: @unchecked Sendable {
    private var paths: Set<FilePath> = []

    func contains(_ path: FilePath) -> Bool {
        paths.contains(path)
    }

    func insert(_ path: FilePath) {
        if paths.count >= 256 { paths.removeAll(keepingCapacity: true) }
        paths.insert(path)
    }
}

/// Catch-up sweep followed by an FSEvents watch that tags new artifact
/// folders as they appear. Runs until killed (LaunchAgent mode).
struct Watcher {
    let configuration: Configuration
    private let tagger: Tagger
    private let tag = SyncExclusionTag()
    private let logger = Logger(label: "exclude-icloud-artifacts")
    private let queue = DispatchQueue(label: "exclude-icloud-artifacts", qos: .background)
    /// Sweeps and rescans run here, never on the event queue: a slow or
    /// blocked scan (fileproviderd can hang an open(2) indefinitely) must
    /// not stall event delivery.
    private let scanQueue = DispatchQueue(label: "exclude-icloud-artifacts.scan", qos: .utility)
    private let throttle = RescanThrottle()
    private let taggedAncestors = TaggedAncestorCache()

    /// Minimum seconds between overflow rescans. The kernel's event buffer
    /// overflows on every batch during heavy builds, and each rescan walks
    /// whole roots - without a cooldown that is sustained CPU burn. Tags
    /// landing up to a cooldown late are fine: the cloud copy of anything
    /// uploaded meanwhile is removed when the tag lands.
    private let rescanCooldown: TimeInterval

    init(configuration: Configuration, rescanCooldown: TimeInterval = 60) {
        self.configuration = configuration
        self.tagger = Tagger(configuration: configuration)
        self.rescanCooldown = rescanCooldown
    }

    func run() -> Never {
        let stream = FSEventStream(
            paths: configuration.roots,
            latency: configuration.latency,
            queue: queue
        ) { handle($0) }

        do {
            try stream.start()
        } catch {
            logger.error("could not start FSEvents stream: \(error)")
            exit(1)
        }
        scanQueue.async { [self] in
            // A full walk is needed only on first install or after a config
            // change; plain agent restarts skip it. Runtime gaps are covered
            // by FSEvents overflow rescans.
            guard configuration.needsStartupSweep() else {
                logger.info("startup sweep skipped (config unchanged since last sweep)")
                return
            }
            tagger.sweep()
            configuration.recordSweep()
            logger.info("initial sweep complete")
            queue.async { [throttle] in
                // The sweep walked everything; start the rescan cooldown so
                // launch-time overflow flags don't immediately repeat it.
                throttle.lastFinished = Date()
            }
        }
        let roots = configuration.roots.map(\.string).joined(separator: ", ")
        logger.info("watching \(roots) (latency \(Int(configuration.latency))s)")
        dispatchMain()
    }

    func handle(_ event: FSEvent) {
        if event.flags.contains(.mustScanSubDirs) {
            rescanSubtree(at: event.path)
            return
        }
        // Per-directory mode: the event names the directory in which changes
        // occurred. Its entries are the tagging candidates; the directory
        // itself may also be a fresh artifact (its first contents - e.g. a
        // child-marker like pyvenv.cfg - arrive as changes inside it).
        let directory = event.path
        guard !hasArtifactAncestorByName(directory) else { return } // no I/O
        guard directory.isDirectory, // may have vanished since the event
              !tag.isSet(on: directory), // changes inside an excluded tree
              !isCoveredByTaggedAncestor(directory)
        else { return }
        if tagIfArtifact(directory) { return }

        let entries = ArtifactScanner.list(directory)
        for entry in entries.directories {
            let candidate = directory.appending(entry)
            // Unconditional name match needs no guards and no listings;
            // tagIfNeeded handles the already-tagged case.
            if configuration.unguardedExactNames.contains(entry) {
                applyTag(candidate)
                continue
            }
            // Only name/sibling rules here - child-marker rules (e.g. the
            // `*` + CACHEDIR.TAG catch-all) would readdir every sibling
            // subdirectory on every event. They fire via the marked dir's
            // own event instead (or a sweep, for trees moved in wholesale).
            let matches = configuration.eventSiblingRules.contains { rule in
                rule.matches(directoryNamed: entry, siblings: entries.names, children: { [] })
            }
            if matches { applyTag(candidate) }
        }
    }

    /// Tags a directory, honoring the eviction guard's thread budget: with
    /// skipCloudOnly on, tagIfNeeded walks the candidate's whole subtree, so
    /// it must not run on the event queue.
    private func applyTag(_ path: FilePath) {
        if configuration.skipCloudOnly {
            scanQueue.async { [self] in tagger.tagIfNeeded(path) }
        } else {
            tagger.tagIfNeeded(path)
        }
    }

    /// Syscall-free preflight: an ancestor component naming an unconditional
    /// artifact folder means this path is covered - that folder is already
    /// tagged or its tag is in flight from its own event. Components above
    /// the watched roots are fixed system/home names that never match, so
    /// the whole path is checked without building intermediate paths.
    private func hasArtifactAncestorByName(_ path: FilePath) -> Bool {
        for component in path.components.dropLast()
        where configuration.nameIsUnguardedArtifact(component.string) {
            return true
        }
        return false
    }

    /// The kernel dropped events somewhere under `path` (queue overflow).
    /// Runs at most once per cooldown; further overflows are coalesced into
    /// one trailing rescan so sustained build load cannot pile up scans.
    private func rescanSubtree(at path: FilePath) {
        if throttle.scanInFlight {
            throttle.pending.insert(path)
            scheduleTrailingRescan(after: rescanCooldown)
            return
        }
        if let last = throttle.lastFinished {
            let remaining = rescanCooldown - Date().timeIntervalSince(last)
            if remaining > 0 {
                throttle.pending.insert(path)
                scheduleTrailingRescan(after: remaining)
                return
            }
        }
        throttle.scanInFlight = true
        scanQueue.async { [self] in
            performRescan(at: path)
            queue.async { [throttle] in
                throttle.lastFinished = Date()
                throttle.scanInFlight = false
            }
        }
    }

    private func scheduleTrailingRescan(after delay: TimeInterval) {
        guard !throttle.timerScheduled else { return }
        throttle.timerScheduled = true
        logger.info("event queue overflowed; rescan throttled for \(Int(delay + 0.5))s")
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            throttle.timerScheduled = false
            drainPendingRescans()
        }
    }

    /// Runs every pending overflow scope in one scan-queue task, so a
    /// multi-root pile-up catches up in a single pass instead of one scope
    /// per cooldown window.
    private func drainPendingRescans() {
        guard !throttle.scanInFlight else {
            scheduleTrailingRescan(after: rescanCooldown)
            return
        }
        let scopes = throttle.pending
        throttle.pending.removeAll()
        guard !scopes.isEmpty else { return }
        throttle.scanInFlight = true
        scanQueue.async { [self] in
            for scope in scopes {
                performRescan(at: scope)
            }
            queue.async { [throttle] in
                throttle.lastFinished = Date()
                throttle.scanInFlight = false
            }
        }
    }

    /// Runs on the scan queue only.
    private func performRescan(at path: FilePath) {
        logger.info("event queue overflowed; rescanning \(path)")

        // Overflow at or above a root invalidates that whole root.
        let affectedRoots = configuration.roots.filter { $0.isWithin(path) }
        if !affectedRoots.isEmpty {
            let scanner = ArtifactScanner(configuration: configuration)
            for root in affectedRoots {
                scanner.scan(under: root, tagger.tagIfNeeded)
            }
            return
        }

        guard configuration.roots.contains(where: { path.isWithin($0) }),
              !hasArtifactAncestorByName(path),
              path.isDirectory,
              !isCoveredByTaggedAncestor(path)
        else { return }
        // The subtree itself may be a fresh artifact folder whose create
        // event was among the dropped ones; its tag then covers everything.
        guard !tagIfArtifact(path) else { return }
        ArtifactScanner(configuration: configuration).scan(under: path, tagger.tagIfNeeded)
    }

    /// Full rule evaluation for one directory (sibling and child guards
    /// included), tagging on match. Returns whether a rule matched.
    private func tagIfArtifact(_ path: FilePath) -> Bool {
        guard let name = path.lastComponent?.string else { return false }
        if configuration.unguardedExactNames.contains(name) {
            applyTag(path)
            return true
        }
        let siblings = ArtifactScanner.list(path.removingLastComponent()).names
        var cachedChildren: DirectoryEntries?
        let children: () -> [String] = {
            if cachedChildren == nil { cachedChildren = ArtifactScanner.list(path) }
            return cachedChildren!.names
        }
        let matches = configuration.rules.contains { rule in
            rule.matches(directoryNamed: name, siblings: siblings, children: children)
        }
        if matches { applyTag(path) }
        return matches
    }

    private func isCoveredByTaggedAncestor(_ path: FilePath) -> Bool {
        var current = path.removingLastComponent()
        while !configuration.roots.contains(current), !current.components.isEmpty {
            // Guarded artifact names (target, build, vendor, ...) never hit
            // the name preflight, so cargo/gradle builds would pay a getxattr
            // walk per event without this memo of confirmed-tagged ancestors.
            if taggedAncestors.contains(current) { return true }
            if tag.isSet(on: current) {
                taggedAncestors.insert(current)
                return true
            }
            current = current.removingLastComponent()
        }
        return false
    }
}
