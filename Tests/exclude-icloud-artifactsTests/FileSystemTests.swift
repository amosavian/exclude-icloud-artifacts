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
