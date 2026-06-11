import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

@Suite struct ArtifactScannerTests {
    /// Builds a Configuration whose only root is `root`, with the given rules
    /// and no presets.
    private func configuration(root: FilePath, rules: [ExclusionRule]) -> Configuration {
        Configuration(file: ConfigFile(
            roots: [root.string],
            latency: nil,
            presets: [],
            rules: rules))
    }

    private func makeDir(_ path: FilePath) throws {
        try FileManager.default.createDirectory(
            atPath: path.string, withIntermediateDirectories: true)
    }

    private func makeFile(_ path: FilePath) {
        FileManager.default.createFile(atPath: path.string, contents: Data())
    }

    /// Collects matched paths as a Set of strings for order-independent checks.
    private func scanned(_ config: Configuration) -> Set<String> {
        var hits: Set<String> = []
        ArtifactScanner(configuration: config).scan { hits.insert($0.string) }
        return hits
    }

    @Test func findsNestedArtifactFolder() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let project = root.appending("Project")
        try makeDir(project.appending("node_modules"))

        let hits = scanned(configuration(root: root, rules: [ExclusionRule("node_modules")]))
        #expect(hits == [project.appending("node_modules").string])
    }

    @Test func doesNotDescendIntoMatchedFolder() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        // node_modules containing a nested node_modules: only the outer one
        // should be reported - the scanner must not recurse into a match.
        let outer = root.appending("node_modules")
        try makeDir(outer.appending("node_modules"))

        let hits = scanned(configuration(root: root, rules: [ExclusionRule("node_modules")]))
        #expect(hits == [outer.string])
    }

    @Test func ignoresPlainFiles() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        // A *file* named node_modules must never be reported (matches only dirs).
        makeFile(root.appending("node_modules"))

        let hits = scanned(configuration(root: root, rules: [ExclusionRule("node_modules")]))
        #expect(hits.isEmpty)
    }

    @Test func siblingGuardRespectedDuringScan() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        // target next to Cargo.toml -> excluded; a lone target -> not.
        let crate = root.appending("crate")
        try makeDir(crate.appending("target"))
        makeFile(crate.appending("Cargo.toml"))
        let other = root.appending("other")
        try makeDir(other.appending("target"))

        let rule = ExclusionRule("target", ifSiblingExists: ["Cargo.toml"])
        let hits = scanned(configuration(root: root, rules: [rule]))
        #expect(hits == [crate.appending("target").string])
    }

    @Test func childMarkerGuardRespectedDuringScan() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        // Wildcard + CACHEDIR.TAG: any dir holding the marker is excluded.
        let cached = root.appending("weird-cache")
        try makeDir(cached)
        makeFile(cached.appending("CACHEDIR.TAG"))
        try makeDir(root.appending("plain"))

        let rule = ExclusionRule("*", ifChildExists: ["CACHEDIR.TAG"])
        let hits = scanned(configuration(root: root, rules: [rule]))
        #expect(hits == [cached.string])
    }

    @Test func scansEveryConfiguredRoot() throws {
        let first = try makeTempDir()
        defer { removeDir(first) }
        let second = try makeTempDir()
        defer { removeDir(second) }
        try makeDir(first.appending("node_modules"))
        try makeDir(second.appending("node_modules"))

        let config = Configuration(file: ConfigFile(
            roots: [first.string, second.string],
            latency: nil,
            presets: [],
            rules: [ExclusionRule("node_modules")]))
        #expect(scanned(config).count == 2)
    }

    @Test func neverMatchesSymlinkedDirectories() throws {
        // README contract: symlinks are never followed. A symlink named like
        // an artifact must not be reported (its target may be real data).
        let root = try makeTempDir()
        defer { removeDir(root) }
        let real = root.appending("real")
        try makeDir(real)
        try FileManager.default.createSymbolicLink(
            atPath: root.appending("node_modules").string,
            withDestinationPath: real.string)

        let hits = scanned(configuration(root: root, rules: [ExclusionRule("node_modules")]))
        #expect(hits.isEmpty)
    }

    @Test func missingRootYieldsNoHits() {
        let config = configuration(
            root: FilePath("/nonexistent/eia-scan-root"),
            rules: [ExclusionRule("node_modules")])
        #expect(scanned(config).isEmpty)
    }
}
