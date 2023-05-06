import Darwin
import Foundation

/// The logged-in account's home path, distinct from `NSHomeDirectory()` in a
/// sandboxed macOS app, where Foundation returns the app container directory.
public enum CurrentUserHomeDirectory {
    public static var path: String? {
        cachedPath
    }

    private static let cachedPath: String? = {
        guard let account = getpwuid(getuid()) else { return nil }
        let path = String(cString: account.pointee.pw_dir)
        guard path.hasPrefix("/"),
              !path.split(separator: "/").contains("..") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }()
}
