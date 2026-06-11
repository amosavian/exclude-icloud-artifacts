import Dispatch
import Logging
import System

/// Catch-up sweep followed by an FSEvents watch that tags new artifact
/// folders as they appear. Runs until killed (LaunchAgent mode).
struct Watcher {
    let configuration: Configuration
    private let tagger: Tagger
    private let tag = SyncExclusionTag()
    private let logger = Logger(label: "exclude-icloud-artifacts")

    init(configuration: Configuration) {
        self.configuration = configuration
        self.tagger = Tagger(configuration: configuration)
    }

    func run() -> Never {
        let queue = DispatchQueue(label: "exclude-icloud-artifacts", qos: .background)
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
        tagger.sweep() // catch up on anything created while not running
        let roots = configuration.roots.map(\.string).joined(separator: ", ")
        logger.info("watching \(roots) (latency \(Int(configuration.latency))s)")
        dispatchMain()
    }

    func handle(_ event: FSEvent) {
        if event.flags.contains(.mustScanSubDirs) {
            // The kernel event queue overflowed; catch up with a full sweep.
            tagger.sweep()
            return
        }
        guard event.flags.contains(.isDirectory),
              !event.flags.isDisjoint(with: [.created, .renamed]),
              let name = event.path.lastComponent?.string,
              configuration.rules.contains(where: { $0.nameMatches(name) })
        else { return }

        // Already inside a tagged folder (e.g. dirs created during a build
        // in an excluded .build)? The ancestor's tag covers it; skip before
        // doing any directory listing.
        guard !isCoveredByTaggedAncestor(event.path) else { return }

        let parent = event.path.removingLastComponent()
        let siblings = ArtifactScanner.list(parent)
        var cachedChildren: Set<String>?
        let children: () -> Set<String> = {
            if cachedChildren == nil { cachedChildren = ArtifactScanner.list(event.path) }
            return cachedChildren!
        }
        let matches = configuration.rules.contains { rule in
            rule.matches(directoryNamed: name, siblings: siblings, children: children)
        }
        guard matches else { return }

        tagger.tagIfNeeded(event.path)
    }

    private func isCoveredByTaggedAncestor(_ path: FilePath) -> Bool {
        var current = path.removingLastComponent()
        while !configuration.roots.contains(current), !current.components.isEmpty {
            if tag.isSet(on: current) { return true }
            current = current.removingLastComponent()
        }
        return false
    }
}
