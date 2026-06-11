import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

@Suite struct IsDatalessTests {
    // The positive case cannot be unit-tested: SF_DATALESS is set only by
    // the kernel/fileproviderd when a file provider evicts content. The flag
    // read is verified manually against real evicted files.

    @Test func regularFileIsNotDataless() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let file = dir.appending("regular.txt")
        FileManager.default.createFile(atPath: file.string, contents: Data("x".utf8))
        #expect(!file.isDataless)
    }

    @Test func directoryIsNotDataless() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        #expect(!dir.isDataless)
    }

    @Test func missingPathIsNotDataless() {
        #expect(!FilePath("/nonexistent/eia-test-path").isDataless)
    }
}

@Suite struct ListEntriesTests {
    @Test func separatesDirectoriesAndRegularFiles() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        try FileManager.default.createDirectory(
            atPath: dir.appending("sub").string, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: dir.appending("file.txt").string, contents: Data("hello".utf8))
        try FileManager.default.createSymbolicLink(
            atPath: dir.appending("link").string, withDestinationPath: dir.appending("sub").string)

        let entries = dir.listEntries()
        #expect(entries.names.sorted() == ["file.txt", "link", "sub"])
        #expect(entries.directories == ["sub"])
        #expect(entries.regularFiles == ["file.txt"])
    }

    @Test func allocatedBytesReflectsContent() throws {
        let dir = try makeTempDir()
        defer { removeDir(dir) }
        let file = dir.appending("data.bin")
        FileManager.default.createFile(
            atPath: file.string, contents: Data(repeating: 7, count: 10_000))
        #expect(file.allocatedBytes >= 10_000)
        #expect(FilePath("/nonexistent/eia-x").allocatedBytes == 0)
    }
}

@Suite struct IsWithinTests {
    @Test func descendantIsWithinAncestor() {
        #expect(FilePath("/a/b/c").isWithin(FilePath("/a/b")))
        #expect(FilePath("/a/b/c").isWithin(FilePath("/a")))
    }

    @Test func pathIsWithinItself() {
        #expect(FilePath("/a/b").isWithin(FilePath("/a/b")))
    }

    @Test func componentBoundariesAreRespected() {
        // /a/bc is not under /a/b - string prefix is not enough.
        #expect(!FilePath("/a/bc").isWithin(FilePath("/a/b")))
        #expect(!FilePath("/a").isWithin(FilePath("/a/b")))
        #expect(!FilePath("/x/b").isWithin(FilePath("/a/b")))
    }
}
