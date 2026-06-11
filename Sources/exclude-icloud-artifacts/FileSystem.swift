import Darwin
import System

/// One readdir pass worth of directory contents. Plain arrays: sibling
/// lists are small, so linear scans beat paying a hash per entry.
struct DirectoryEntries {
    /// Every entry name (files and directories) - the shape rule guards need.
    var names: [String] = []
    /// Names of entries that are directories (symlinks excluded).
    var directories: [String] = []
    /// Names of plain files (DT_REG), for size accounting.
    var regularFiles: [String] = []
}

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

    /// Single-readdir directory listing that also captures which entries are
    /// directories via d_type - no per-entry lstat. Symlinks are not
    /// directories here, matching lstat semantics.
    func listEntries() -> DirectoryEntries {
        var result = DirectoryEntries()
        guard let dir = withPlatformString({ opendir($0) }) else { return result }
        defer { closedir(dir) }
        while let entry = readdir(dir) {
            var ent = entry.pointee
            let name = withUnsafeBytes(of: &ent.d_name) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            result.names.append(name)
            switch Int32(ent.d_type) {
            case DT_DIR:
                result.directories.append(name)
            case DT_REG:
                result.regularFiles.append(name)
            case DT_UNKNOWN: // filesystem without d_type support
                if appending(name).isDirectory { result.directories.append(name) }
            default:
                break
            }
        }
        return result
    }

    /// True when the path equals `ancestor` or lies beneath it. Component-
    /// wise, so "/a/bc" is not within "/a/b".
    func isWithin(_ ancestor: FilePath) -> Bool {
        root == ancestor.root && components.starts(with: ancestor.components)
    }

    /// True when a file provider has evicted this item's content to the
    /// cloud (SF_DATALESS): the local entry is a placeholder without bytes.
    /// lstat-only - never triggers a download.
    var isDataless: Bool {
        var status = stat()
        let ok = withPlatformString { lstat($0, &status) == 0 }
        return ok && (status.st_flags & UInt32(SF_DATALESS)) != 0
    }

    /// On-disk size in bytes (lstat st_blocks); 0 when unreadable.
    var allocatedBytes: Int64 {
        var status = stat()
        let ok = withPlatformString { lstat($0, &status) == 0 }
        return ok ? Int64(status.st_blocks) * 512 : 0
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

/// A boolean extended attribute: present-and-equal-to-`enabledValue` means on.
/// Conformers supply the two statics; the read/write logic is shared.
protocol ExtendedAttribute: Sendable {
    /// The xattr name, including any File Provider flag suffix (e.g. `#P`).
    static var attributeName: String { get }
    /// The byte value that means "set"; the attribute is considered on only
    /// when its stored value equals this exactly.
    static var enabledValue: [UInt8] { get }
}

extension ExtendedAttribute {
    func isSet(on path: FilePath) -> Bool {
        path.extendedAttribute(Self.attributeName) == Self.enabledValue
    }

    func set(on path: FilePath) throws {
        try path.setExtendedAttribute(Self.attributeName, to: Self.enabledValue)
    }
}

/// The extended attribute that tells fileproviderd to keep an item out of
/// sync (macOS 12.3+). Honored for every File Provider domain: iCloud Drive,
/// plus Dropbox, Google Drive, and OneDrive under ~/Library/CloudStorage.
struct SyncExclusionTag: ExtendedAttribute {
    static let attributeName = "com.apple.fileprovider.ignore#P"
    static let enabledValue: [UInt8] = [UInt8(ascii: "1")]
}
