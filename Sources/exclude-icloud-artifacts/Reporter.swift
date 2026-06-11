import Foundation
import System

/// Prints a size-sorted table of all artifact folders and their sync status.
struct Reporter {
    let configuration: Configuration

    func run() {
        let tag = SyncExclusionTag()
        var rows: [(size: Int64, status: String, path: FilePath)] = []
        ArtifactScanner(configuration: configuration).scan { path in
            rows.append((
                size: allocatedSize(path),
                status: tag.isSet(on: path) ? "excluded" : "SYNCING",
                path: path
            ))
        }
        rows.sort { $0.size > $1.size }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false

        var total: Int64 = 0
        for row in rows {
            total += row.size
            let size = formatter.string(fromByteCount: row.size)
            let status = row.status.padding(toLength: 9, withPad: " ", startingAt: 0)
            print("\(size.leftPadded(to: 12))  \(status) \(row.path.string)")
        }
        print("\n\(formatter.string(fromByteCount: total).leftPadded(to: 12))  total")
    }

    /// Iterative readdir walk summing st_blocks - several times faster than
    /// a FileManager enumerator, which allocates URLs and resource
    /// dictionaries per item.
    private func allocatedSize(_ path: FilePath) -> Int64 {
        var total: Int64 = 0
        var stack = [path]
        while let directory = stack.popLast() {
            let entries = ArtifactScanner.list(directory)
            for file in entries.regularFiles {
                total += directory.appending(file).allocatedBytes
            }
            for subdirectory in entries.directories {
                stack.append(directory.appending(subdirectory))
            }
        }
        return total
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
