// exclude-icloud-artifacts
// Keeps build-artifact folders under cloud-synced roots (~/Documents,
// ~/Desktop, and ~/Library/CloudStorage by default) out of iCloud Drive,
// Dropbox, Google Drive, and OneDrive sync by tagging them with the File
// Provider ignore xattr (macOS 12.3+).
//
// Modes:
//   (no args)         catch-up sweep, then watch the roots via FSEvents and
//                     tag new artifact folders as they appear (LaunchAgent)
//   --sweep           one-shot: tag all untagged artifact folders, then exit
//   --report          show size and sync status of each artifact folder
//   --config <path>   use this config.yaml instead of
//                     ~/.config/exclude-icloud-artifacts/config.yaml
//
// Energy design: FSEvents is the kernel's change-notification stream (no
// polling, no disk scanning), events are coalesced into batches to minimize
// wakeups, and tagging happens in-process via setxattr(2) - no subprocesses
// are ever spawned.
//
// Build: swift build -c release   /   Install: ./install.sh

import Foundation
import Logging
import System

@main
struct ExcludeICloudArtifacts {
    enum Mode {
        case watch, sweep, report
    }

    static func main() {
        // Diagnostics go to stderr via swift-log's stock handler; stdout
        // stays reserved for command output (--report). The LaunchAgent
        // redirects stderr to a log file, and stderr is unbuffered, so the
        // file stays live.
        LoggingSystem.bootstrap(StreamLogHandler.standardError)

        var mode = Mode.watch
        var configPath: FilePath?

        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            switch argument {
            case "--sweep":
                mode = .sweep
            case "--report":
                mode = .report
            case "--config":
                guard let path = arguments.next() else { usage() }
                configPath = FilePath((path as NSString).expandingTildeInPath)
            default:
                usage()
            }
        }

        let configuration = Configuration.load(configPath: configPath)
        switch mode {
        case .watch:
            Watcher(configuration: configuration).run()
        case .sweep:
            Tagger(configuration: configuration).sweep()
            configuration.recordSweep()
        case .report:
            Reporter(configuration: configuration).run()
        }
    }

    static func usage() -> Never {
        FileHandle.standardError.write(Data(
            "usage: exclude-icloud-artifacts [--sweep|--report] [--config <path>]\n".utf8))
        exit(64)
    }
}
