import Foundation
import Darwin

/// The custom URL scheme Input Source Pro registers (see `CFBundleURLTypes` in
/// `Info.plist`). Used to trigger actions from the command line, e.g.
/// `open "inputsourcepro://import?path=/path/to/settings.json"`.
enum AppURLScheme {
    static let scheme = "inputsourcepro"
}

/// The parsed meaning of an incoming `inputsourcepro://` URL.
///
/// Parsing never throws: URLs that aren't ours resolve to `.unsupported`, and a
/// recognized `import` action with no usable `path` resolves to
/// `.importInvalidPath`, so the caller can surface a helpful error instead of
/// failing silently.
enum AppURLAction: Equatable {
    /// Not an `inputsourcepro` URL, or an unrecognized action — ignore silently.
    case unsupported
    /// An `import` action whose `path` query item was missing, empty, or — after
    /// tilde expansion — not an absolute path (see `path(from:)`).
    case importInvalidPath
    /// A well-formed `import` action carrying the settings file to load, plus
    /// whether the caller asked to suppress the success alert (`silent=1`). A
    /// failed import still alerts even when `silent` is `true`, so an unattended
    /// run can't fail invisibly.
    case importSettings(fileURL: URL, silent: Bool)

    init(url: URL) {
        guard url.scheme?.lowercased() == AppURLScheme.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            self = .unsupported
            return
        }

        switch Self.action(from: components) {
        case "import":
            guard let path = Self.path(from: components) else {
                self = .importInvalidPath
                return
            }
            // `URL(fileURLWithPath:)` (not `URL(string:)`) so paths with spaces
            // and other non-URL characters resolve to a valid `file://` URL.
            self = .importSettings(
                fileURL: URL(fileURLWithPath: path),
                silent: Self.silent(from: components)
            )
        default:
            self = .unsupported
        }
    }

    /// The action name, tolerating both the host form
    /// (`inputsourcepro://import?...`) and the path form
    /// (`inputsourcepro:import?...` / `inputsourcepro:///import?...`). Only the
    /// first segment is the action; any trailing path (`.../import/extra`) is
    /// ignored, so a recognized action with extra junk still resolves.
    private static func action(from components: URLComponents) -> String {
        if let host = components.host, !host.isEmpty {
            return host.lowercased()
        }
        let firstPathComponent = components.path
            .split(separator: "/")
            .first
            .map(String.init) ?? ""
        return firstPathComponent.lowercased()
    }

    /// The `path` query item, expanded and validated. `URLComponents` already
    /// percent-decodes the value, so it must not be decoded again. A leading `~`
    /// is expanded. Returns `nil` when the item is absent, empty, or — after
    /// expansion — not an absolute path: a GUI app launched via `open` runs with
    /// CWD `/`, so a relative path could never resolve to what the caller meant.
    private static func path(from components: URLComponents) -> String? {
        guard let raw = components.queryItems?
            .first(where: { $0.name == "path" })?
            .value,
            !raw.isEmpty
        else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return expanded
    }

    /// The `silent` query flag. `true` only for an explicit `silent=1` or
    /// `silent=true` (case-insensitive); absent, empty, or any other value is
    /// `false`. When set, a successful import skips its confirmation alert —
    /// errors still surface so an unattended import can't fail invisibly.
    private static func silent(from components: URLComponents) -> Bool {
        guard let raw = components.queryItems?
            .first(where: { $0.name == "silent" })?
            .value?
            .lowercased()
        else {
            return false
        }
        return raw == "1" || raw == "true"
    }
}


/// Read untrusted backups without blocking the UI or accepting devices/FIFOs.
enum SettingsBackupFileReader {
    static let maximumBytes = 4 * 1024 * 1024

    enum Failure: LocalizedError {
        case notRegularFile, tooLarge

        var errorDescription: String? {
            switch self {
            case .notRegularFile: return "Select a regular settings file.".i18n()
            case .tooLarge: return "Settings files must be no larger than 4 MiB.".i18n()
            }
        }
    }

    static func read(from url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try readBounded(from: url)
        }.value
    }

    static func readBounded(from url: URL) throws -> Data {
        guard url.isFileURL else { throw Failure.notRegularFile }
        // Nonblocking open prevents a FIFO from hanging before fstat can reject it.
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        guard info.st_size <= maximumBytes else { throw Failure.tooLarge }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Enforce the cap while reading too, in case the file grows after fstat.
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumBytes - result.count + 1))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            if count == 0 { return result }
            guard result.count + count <= maximumBytes else { throw Failure.tooLarge }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}
