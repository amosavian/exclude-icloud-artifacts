import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

@Suite struct ConfigurationDefaultsTests {
    @Test func emptyFileUsesDefaultPresets() {
        let config = Configuration(file: ConfigFile())
        // Default presets include swift; .build must be among the rules.
        #expect(config.rules.contains { $0.folder == ".build" })
        #expect(config.rules.contains { $0.folder == "node_modules" })
    }

    @Test func defaultLatencyIsTen() {
        #expect(Configuration(file: ConfigFile()).latency == 10)
    }

    @Test func skipCloudOnlyDefaultsToFalse() {
        #expect(!Configuration(file: ConfigFile()).skipCloudOnly)
    }

    @Test func tildeInRootsIsExpanded() {
        let config = Configuration(file: ConfigFile(
            roots: ["~/Documents"], latency: nil, presets: [], rules: []))
        #expect(config.roots == [FilePath("\(NSHomeDirectory())/Documents")])
        #expect(!config.roots[0].string.contains("~"))
    }
}

@Suite struct ConfigurationPresetTests {
    @Test func presetsExpandToRules() {
        let config = Configuration(file: ConfigFile(
            roots: [], latency: nil, presets: ["rust"], rules: []))
        // rust preset is exactly one rule: target guarded by Cargo.toml.
        #expect(config.rules.count == 1)
        #expect(config.rules[0].folder == "target")
        #expect(config.rules[0].ifSiblingExists == ["Cargo.toml"])
    }

    @Test func unknownPresetIsIgnoredNotFatal() {
        let config = Configuration(file: ConfigFile(
            roots: [], latency: nil, presets: ["does-not-exist"], rules: []))
        #expect(config.rules.isEmpty)
    }

    @Test func customRulesAppendedToPresets() {
        let custom = ExclusionRule("MyCache")
        let config = Configuration(file: ConfigFile(
            roots: [], latency: nil, presets: ["rust"], rules: [custom]))
        #expect(config.rules.contains { $0.folder == "MyCache" })
        #expect(config.rules.contains { $0.folder == "target" })
    }

    @Test func defaultRootsIncludeCloudStorage() {
        let home = NSHomeDirectory()
        #expect(Configuration(file: ConfigFile()).roots == [
            FilePath("\(home)/Documents"),
            FilePath("\(home)/Desktop"),
            FilePath("\(home)/Library/CloudStorage"),
        ])
    }

    @Test func wildcardRulesSortedLast() {
        // Mix an exact-name rule and a wildcard rule; wildcard must end up last
        // so exact-name matches can short-circuit before any directory listing.
        let config = Configuration(file: ConfigFile(
            roots: [],
            latency: nil,
            presets: [],
            rules: [
                ExclusionRule("*", ifChildExists: ["CACHEDIR.TAG"]),
                ExclusionRule(".build"),
            ]))
        #expect(config.rules.count == 2)
        #expect(config.rules.first?.folder == ".build")
        #expect(config.rules.last?.folder == "*")
    }
}

@Suite struct UnguardedNameIndexTests {
    private var config: Configuration {
        Configuration(file: ConfigFile(
            roots: [], latency: nil, presets: ["node", "rust", "cpp", "general"], rules: []))
    }

    @Test func unconditionalExactNamesGuaranteeExclusion() {
        #expect(config.nameIsUnguardedArtifact("node_modules"))
        #expect(config.nameIsUnguardedArtifact(".cache"))
    }

    @Test func guardedNamesAreNotIndexed() {
        // rust `target` needs a Cargo.toml sibling - name alone proves nothing.
        #expect(!config.nameIsUnguardedArtifact("target"))
        // `*` (CACHEDIR.TAG) is child-guarded and must never match by name.
        #expect(!config.nameIsUnguardedArtifact("anything"))
        #expect(!config.nameIsUnguardedArtifact("src"))
    }

    @Test func unguardedGlobNamesMatch() {
        #expect(config.nameIsUnguardedArtifact("cmake-build-debug"))
        #expect(!config.nameIsUnguardedArtifact("cmake-build"))
    }
}

@Suite struct SweepStampTests {
    private func config(rules: [ExclusionRule], source: FilePath? = nil) -> Configuration {
        Configuration(
            file: ConfigFile(roots: ["/tmp/r"], latency: nil, presets: [], rules: rules),
            source: source)
    }

    @Test func fingerprintIsStableAndLatencyInsensitive() {
        let a = Configuration(file: ConfigFile(
            roots: ["/tmp/r"], latency: 5, presets: ["rust"], rules: []))
        let b = Configuration(file: ConfigFile(
            roots: ["/tmp/r"], latency: 99, presets: ["rust"], rules: []))
        #expect(a.sweepFingerprint == b.sweepFingerprint)
    }

    @Test func fingerprintChangesWithRulesAndRoots() {
        let base = config(rules: [ExclusionRule("node_modules")])
        #expect(base.sweepFingerprint != config(rules: [ExclusionRule(".build")]).sweepFingerprint)
        let otherRoots = Configuration(file: ConfigFile(
            roots: ["/tmp/other"], latency: nil, presets: [], rules: [ExclusionRule("node_modules")]))
        #expect(base.sweepFingerprint != otherRoots.sweepFingerprint)
    }

    @Test func startupSweepNeededOnlyUntilRecorded() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let source = dir.appending("config.yaml")

        let configuration = config(rules: [ExclusionRule("node_modules")], source: source)
        #expect(configuration.needsStartupSweep(), "no stamp yet - must sweep")
        configuration.recordSweep()
        #expect(!configuration.needsStartupSweep(), "same config - no sweep on restart")

        let changed = config(rules: [ExclusionRule(".build")], source: source)
        #expect(changed.needsStartupSweep(), "config changed - sweep again")
    }
}

@Suite struct ConfigurationLoadTests {
    @Test func loadsYamlFromDisk() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let file = dir.appending("config.yaml")
        let yaml = """
            roots: [/private/tmp/eia-root]
            latency: 3
            skipCloudOnly: true
            presets: [rust]
            rules:
              - folder: out
                ifSiblingExists: [proj.toml]
            """
        try yaml.write(toFile: file.string, atomically: true, encoding: .utf8)

        let config = Configuration.load(configPath: file)
        #expect(config.roots == [FilePath("/private/tmp/eia-root")])
        #expect(config.latency == 3)
        #expect(config.skipCloudOnly)
        #expect(config.rules.contains { $0.folder == "target" }) // rust preset
        #expect(config.rules.contains {
            $0.folder == "out" && $0.ifSiblingExists == ["proj.toml"]
        })
    }

    /// config.example.yaml documents the defaults; it must stay parseable and
    /// in sync with the built-in defaults.
    @Test func exampleConfigMatchesBuiltInDefaults() throws {
        let example = FilePath(#filePath)
            .removingLastComponent() // ConfigurationTests.swift
            .removingLastComponent() // exclude-icloud-artifactsTests
            .removingLastComponent() // Tests
            .appending("config.example.yaml")
        try #require(example.exists)

        let fromExample = Configuration.load(configPath: example)
        let defaults = Configuration(file: ConfigFile())
        #expect(fromExample.roots == defaults.roots)
        #expect(fromExample.latency == defaults.latency)
        #expect(fromExample.rules.map(\.folder) == defaults.rules.map(\.folder))
    }
}
