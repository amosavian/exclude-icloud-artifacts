import Dispatch
import Foundation
import System
import Testing
@testable import exclude_icloud_artifacts

@Suite struct FSEventStreamTests {
    @Test func deliversDirectoryCreationFromOtherProcesses() throws {
        let root = try makeTempDir()
        defer { removeDir(root) }

        let received = DispatchSemaphore(value: 0)
        let stream = FSEventStream(
            paths: [root],
            latency: 0.1,
            queue: DispatchQueue(label: "fsevents-test")
        ) { event in
            // Directory-mode FSEvents reports the dir containing the change
            // (the watched root here); the new dir itself may also appear.
            // Compare last components: FSEvents resolves /var -> /private/var.
            if event.path.lastComponent == root.lastComponent
                || event.path.lastComponent?.string == "fresh-dir" {
                received.signal()
            }
        }
        try stream.start()
        defer { stream.stop() }

        // The stream is created with IgnoreSelf - events caused by this
        // process are suppressed, exactly like production where builds are
        // separate processes. Create the directory via an external mkdir.
        let mkdir = Process()
        mkdir.executableURL = URL(fileURLWithPath: "/bin/mkdir")
        mkdir.arguments = [root.appending("fresh-dir").string]
        try mkdir.run()
        mkdir.waitUntilExit()
        #expect(mkdir.terminationStatus == 0)

        #expect(
            received.wait(timeout: .now() + 10) == .success,
            "no FSEvent for an externally created directory within 10s")
    }
}
