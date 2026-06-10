import Darwin
import System

extension FilePath {
    /// True when the path is a directory itself (symlinks are not followed).
    var isDirectory: Bool {
        var status = stat()
        let ok = withPlatformString { lstat($0, &status) == 0 }
        return ok && (status.st_mode & S_IFMT) == S_IFDIR
    }

    var exists: Bool {
        withPlatformString { access($0, F_OK) == 0 }
    }

    /// Value of the named extended attribute, nil when absent.
    func extendedAttribute(_ name: String) -> [UInt8]? {
        withPlatformString { path in
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0 else { return size == 0 ? [] : nil }
            var value = [UInt8](repeating: 0, count: size)
            let read = getxattr(path, name, &value, size, 0, 0)
            return read >= 0 ? Array(value.prefix(read)) : nil
        }
    }

    func setExtendedAttribute(_ name: String, to value: [UInt8]) throws {
        let result = withPlatformString {
            setxattr($0, name, value, value.count, 0, 0)
        }
        guard result == 0 else { throw Errno(rawValue: errno) }
    }
}

/// The extended attribute that tells the File Provider (iCloud Drive) to
/// keep an item out of sync (macOS 12.3+).
struct SyncExclusionTag: Sendable {
    static let attributeName = "com.apple.fileprovider.ignore#P"
    private static let enabled: [UInt8] = [UInt8(ascii: "1")]

    func isSet(on path: FilePath) -> Bool {
        path.extendedAttribute(Self.attributeName) == Self.enabled
    }

    func set(on path: FilePath) throws {
        try path.setExtendedAttribute(Self.attributeName, to: Self.enabled)
    }
}
