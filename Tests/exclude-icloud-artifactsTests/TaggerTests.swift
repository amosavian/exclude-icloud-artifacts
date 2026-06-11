import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

/// Creates a unique temp directory; caller cleans up via defer.
func makeTempDir() throws -> FilePath {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("eia-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return FilePath(url.path)
}

func removeDir(_ path: FilePath) {
    try? FileManager.default.removeItem(atPath: path.string)
}

@Suite struct SyncExclusionTagTests {
    @Test func setAndReadBack() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let tag = SyncExclusionTag()
        #expect(!tag.isSet(on: dir))
        try tag.set(on: dir)
        #expect(tag.isSet(on: dir))
    }

    @Test func differentValueIsNotConsideredSet() throws {
        // Only the exact byte value "1" means excluded; anything else (e.g.
        // a leftover "0") must read as not set so the tagger repairs it.
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        try dir.setExtendedAttribute(
            SyncExclusionTag.attributeName, to: [UInt8(ascii: "0")])
        #expect(!SyncExclusionTag().isSet(on: dir))
    }
}

@Suite struct TaggerBehaviorTests {
    private let tag = SyncExclusionTag()

    private func makeTagger() -> Tagger {
        Tagger(configuration: Configuration(file: ConfigFile()))
    }

    @Test func tagsUntaggedDirectory() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        makeTagger().tagIfNeeded(dir)
        #expect(tag.isSet(on: dir))
    }

    @Test func ignoresPlainFiles() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let file = dir.appending("file.txt")
        FileManager.default.createFile(atPath: file.string, contents: Data())
        makeTagger().tagIfNeeded(file)
        #expect(!tag.isSet(on: file))
    }

    @Test func alreadyTaggedIsLeftAlone() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        try tag.set(on: dir)
        makeTagger().tagIfNeeded(dir)
        #expect(tag.isSet(on: dir))
    }

    @Test func sweepTagsEveryArtifactUnderRoot() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let first = root.appending("p1/node_modules")
        let second = root.appending("p2/.build")
        for dir in [first, second] {
            try FileManager.default.createDirectory(
                atPath: dir.string, withIntermediateDirectories: true)
        }
        let config = Configuration(file: ConfigFile(
            roots: [root.string],
            latency: nil,
            presets: [],
            rules: [ExclusionRule("node_modules"), ExclusionRule(".build")]))
        Tagger(configuration: config).sweep()
        #expect(tag.isSet(on: first))
        #expect(tag.isSet(on: second))
    }
}

/// With skipCloudOnly enabled, folders whose subtree contains cloud-evicted
/// (dataless) items must never be tagged: tagging removes the server copy,
/// which for evicted content is the only full copy.
///
/// Only the tag-when-local branch is unit-testable: SF_DATALESS is set
/// exclusively by the kernel/fileproviderd, so no test fixture can fabricate
/// an evicted file. The skip branches were verified manually against real
/// evicted files (see the plan's Task 3 amendment).
@Suite struct TaggerCloudOnlyGuardTests {
    private let tag = SyncExclusionTag()

    @Test func tagsFullyLocalContent() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }
        let artifact = root.appending("node_modules")
        try FileManager.default.createDirectory(
            atPath: artifact.appending("pkg").string, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: artifact.appending("pkg/payload.bin").string, contents: Data("x".utf8))

        // Nothing in a temp dir is evicted, so the guard walk finds nothing
        // and the artifact is tagged.
        let guarded = Configuration(file: ConfigFile(skipCloudOnly: true))
        Tagger(configuration: guarded).tagIfNeeded(artifact)
        #expect(tag.isSet(on: artifact))
    }
}
