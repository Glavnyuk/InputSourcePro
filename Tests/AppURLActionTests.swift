import XCTest
import Darwin
@testable import Input_Source_Pro

final class AppURLActionTests: XCTestCase {
    private func action(_ string: String) -> AppURLAction {
        guard let url = URL(string: string) else {
            XCTFail("Invalid test URL: \(string)")
            return .unsupported
        }
        return AppURLAction(url: url)
    }

    func testHostFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPathFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro:import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testTripleSlashFormImportWithPath() {
        XCTAssertEqual(
            action("inputsourcepro:///import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSchemeAndActionAreCaseInsensitive() {
        XCTAssertEqual(
            action("InputSourcePro://IMPORT?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPercentEncodedPathIsDecodedOnce() {
        guard case let .importSettings(fileURL, _) =
            action("inputsourcepro://import?path=/tmp/my%20config.json")
        else {
            return XCTFail("Expected importSettings")
        }
        XCTAssertEqual(fileURL.path, "/tmp/my config.json")
    }

    func testTildeIsExpanded() {
        guard case let .importSettings(fileURL, _) =
            action("inputsourcepro://import?path=~/settings.json")
        else {
            return XCTFail("Expected importSettings")
        }
        XCTAssertFalse(fileURL.path.contains("~"))
        XCTAssertEqual(fileURL.path, NSHomeDirectory() + "/settings.json")
    }

    func testMissingPathQueryItem() {
        XCTAssertEqual(action("inputsourcepro://import"), .importInvalidPath)
    }

    func testEmptyPathQueryItem() {
        XCTAssertEqual(action("inputsourcepro://import?path="), .importInvalidPath)
    }

    func testRelativePathIsRejected() {
        // A GUI app launched via `open` runs with CWD `/`, so a relative path
        // could never resolve to what the caller meant — reject it outright.
        XCTAssertEqual(action("inputsourcepro://import?path=settings.json"), .importInvalidPath)
        XCTAssertEqual(action("inputsourcepro://import?path=./settings.json"), .importInvalidPath)
    }

    func testHostFormTrailingPathSegmentsAreIgnored() {
        // Only the first segment is the action; trailing junk is ignored so a
        // recognized action with extra path still resolves.
        XCTAssertEqual(
            action("inputsourcepro://import/extra?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testPathFormTrailingPathSegmentsAreIgnored() {
        // Same leniency through the host-less path-form branch (`split("/").first`),
        // which the host-form case above never reaches.
        XCTAssertEqual(
            action("inputsourcepro:import/extra?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSilentFlagOneIsParsed() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json&silent=1"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: true)
        )
    }

    func testSilentFlagTrueIsParsedCaseInsensitively() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json&silent=TRUE"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: true)
        )
    }

    func testSilentDefaultsToFalseWhenAbsent() {
        XCTAssertEqual(
            action("inputsourcepro://import?path=/tmp/settings.json"),
            .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false)
        )
    }

    func testSilentZeroEmptyAndOtherValuesAreFalse() {
        // Only an explicit `1`/`true` enables silent; anything else keeps the
        // confirming behaviour so a typo can't silently swallow the alert.
        for value in ["0", "yes", "false", ""] {
            XCTAssertEqual(
                action("inputsourcepro://import?path=/tmp/settings.json&silent=\(value)"),
                .importSettings(fileURL: URL(fileURLWithPath: "/tmp/settings.json"), silent: false),
                "silent=\(value) should not enable silent mode"
            )
        }
    }

    func testUnknownActionIsUnsupported() {
        XCTAssertEqual(action("inputsourcepro://export?path=/tmp/settings.json"), .unsupported)
    }

    func testForeignSchemeIsUnsupported() {
        XCTAssertEqual(action("https://import?path=/tmp/settings.json"), .unsupported)
    }
}


final class SettingsBackupFileReaderTests: XCTestCase {
    private func inTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testRegularFilePreservesBytes() throws {
        try inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("settings.json")
            let data = Data("{\"schemaVersion\":1}".utf8)
            try data.write(to: file)
            XCTAssertEqual(try SettingsBackupFileReader.readBounded(from: file), data)
        }
    }

    func testSizeBoundaryAndOversize() throws {
        try inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("settings.json")
            let data = Data(repeating: 32, count: SettingsBackupFileReader.maximumBytes)
            try data.write(to: file)
            XCTAssertEqual(try SettingsBackupFileReader.readBounded(from: file).count, data.count)
            try (data + Data([32])).write(to: file)
            XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: file)) { error in
                guard case SettingsBackupFileReader.Failure.tooLarge = error else {
                    return XCTFail("Expected a size-limit error, got \(error)")
                }
            }
        }
    }

    func testRejectsDirectoryDeviceAndRemoteURL() throws {
        try inTemporaryDirectory { directory in
            XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: directory))
        }
        XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: URL(fileURLWithPath: "/dev/null")))
        XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: URL(string: "https://example.com/settings.json")!))
    }

    func testRejectsSymlinkAndMissingFile() throws {
        try inTemporaryDirectory { directory in
            let file = directory.appendingPathComponent("settings.json")
            let symlink = directory.appendingPathComponent("link.json")
            XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: file))
            try Data("{}".utf8).write(to: file)
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: file)
            XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: symlink))
        }
    }

    func testRejectsFIFOWithoutWaitingForWriter() throws {
        try inTemporaryDirectory { directory in
            let fifo = directory.appendingPathComponent("pipe.json")
            XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
            XCTAssertThrowsError(try SettingsBackupFileReader.readBounded(from: fifo))
        }
    }

    func testAsyncReadReturnsSameBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = Data("{}".utf8)
        try expected.write(to: file)
        let actual = try await SettingsBackupFileReader.read(from: file)
        XCTAssertEqual(actual, expected)
    }
}
