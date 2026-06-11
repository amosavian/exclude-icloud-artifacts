import CoreServices
import Foundation
import System

struct FSEvent {
    struct Flags: OptionSet {
        let rawValue: FSEventStreamEventFlags

        static let mustScanSubDirs = Flags(rawValue: .init(kFSEventStreamEventFlagMustScanSubDirs))
        static let created = Flags(rawValue: .init(kFSEventStreamEventFlagItemCreated))
        static let renamed = Flags(rawValue: .init(kFSEventStreamEventFlagItemRenamed))
        static let isDirectory = Flags(rawValue: .init(kFSEventStreamEventFlagItemIsDir))
    }

    let path: FilePath
    let flags: Flags
}

enum FSEventStreamError: Error {
    case createFailed
    case startFailed
}

/// Thin wrapper around a CoreServices FSEventStream that delivers
/// per-directory events to a handler on the given queue. Deliberately NOT
/// using kFSEventStreamCreateFlagFileEvents: per-file records overflow the
/// event queue during heavy builds (tens of thousands of ops per second),
/// and every overflow forces an expensive catch-up rescan. Per-directory
/// records coalesce all of that pressure away.
final class FSEventStream {
    private let paths: [FilePath]
    private let latency: Double
    private let queue: DispatchQueue
    private let handler: (FSEvent) -> Void
    private var stream: FSEventStreamRef?

    init(
        paths: [FilePath],
        latency: Double,
        queue: DispatchQueue,
        handler: @escaping (FSEvent) -> Void
    ) {
        self.paths = paths
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() throws {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths.map(\.string) as CFArray,
            FSEventStreamEventId.max, // kFSEventStreamEventIdSinceNow
            latency,
            createFlags
        ) else {
            throw FSEventStreamError.createFailed
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw FSEventStreamError.startFailed
        }
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info else { return }
        let stream = Unmanaged<FSEventStream>.fromOpaque(info).takeUnretainedValue()
        let paths = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
        for index in 0..<numEvents {
            guard let path = paths[index] as? String else { continue }
            stream.handler(FSEvent(
                path: FilePath(path),
                flags: FSEvent.Flags(rawValue: eventFlags[index])
            ))
        }
    }
}
