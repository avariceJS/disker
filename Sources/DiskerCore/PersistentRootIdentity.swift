import Darwin
import Foundation

/// A filesystem-provided identity suitable for recognizing one selected root
/// across unmount and remount when the volume supports persistent object IDs.
/// This is metadata only; it does not establish ownership of the root.
public struct PersistentRootIdentity: Codable, Equatable, Sendable {
    public let volumeUUID: String
    public let objectNumber: UInt32
    public let generation: UInt32
    public let objectType: UInt32

    public init(volumeUUID: String, objectNumber: UInt32, generation: UInt32, objectType: UInt32) {
        self.volumeUUID = volumeUUID
        self.objectNumber = objectNumber
        self.generation = generation
        self.objectType = objectType
    }

    public static func read(from path: String) -> PersistentRootIdentity? {
        guard path.hasPrefix("/") else { return nil }
        guard let descriptor = openDirectoryNoFollow(path) else { return nil }
        defer { close(descriptor) }
        return read(from: descriptor, path: path)
    }

    private static func openDirectoryNoFollow(_ path: String) -> Int32? {
        let components = Array(URL(fileURLWithPath: path).standardizedFileURL.pathComponents.dropFirst())
        guard !components.contains("."), !components.contains("..") else { return nil }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        for component in components {
            var enumerated = stat()
            let metadataResult = component.withCString {
                fstatat(descriptor, $0, &enumerated, AT_SYMLINK_NOFOLLOW)
            }
            guard metadataResult == 0,
                  enumerated.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                return nil
            }
            let next = component.withCString {
                openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                close(descriptor)
                return nil
            }
            var opened = stat()
            let openedSuccessfully = fstat(next, &opened) == 0
            let identityMatches = openedSuccessfully
                && opened.st_mode & S_IFMT == S_IFDIR
                && opened.st_dev == enumerated.st_dev
                && opened.st_ino == enumerated.st_ino
            close(descriptor)
            guard identityMatches else {
                close(next)
                return nil
            }
            descriptor = next
        }
        return descriptor
    }

    /// Reads the persistent ID from an already opened, no-follow root
    /// descriptor. The path check rejects a root that was replaced while the
    /// descriptor was being examined.
    static func read(from descriptor: Int32, path: String) -> PersistentRootIdentity? {
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_mode & S_IFMT == S_IFDIR else { return nil }

        var attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_OBJPERMANENTID)
        var buffer = [UInt8](repeating: 0, count: 64)
        let result = buffer.withUnsafeMutableBytes { bytes in
            fgetattrlist(
                descriptor,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                UInt32(FSOPT_NOFOLLOW)
            )
        }
        guard result == 0, buffer.count >= 4 + MemoryLayout<fsobj_id_t>.size else { return nil }
        let returnedLength = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        }
        guard returnedLength >= 4 + MemoryLayout<fsobj_id_t>.size,
              returnedLength <= buffer.count else { return nil }
        let objectID = buffer.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: 4, as: fsobj_id_t.self)
        }
        guard objectID.fid_objno != 0 else { return nil }

        var currentPathMetadata = stat()
        let pathResult = path.withCString { lstat($0, &currentPathMetadata) }
        guard pathResult == 0,
              currentPathMetadata.st_mode & S_IFMT == S_IFDIR,
              currentPathMetadata.st_dev == opened.st_dev,
              currentPathMetadata.st_ino == opened.st_ino else { return nil }

        guard let volumeUUID = try? URL(fileURLWithPath: path, isDirectory: true)
            .resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
              !volumeUUID.isEmpty else { return nil }

        return PersistentRootIdentity(
            volumeUUID: volumeUUID,
            objectNumber: objectID.fid_objno,
            generation: objectID.fid_generation,
            objectType: UInt32(opened.st_mode & S_IFMT)
        )
    }
}
