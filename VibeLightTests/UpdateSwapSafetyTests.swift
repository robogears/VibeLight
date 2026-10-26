import XCTest
@testable import VibeLight

/// The updater's and relocator's decisions about which copy of the app to keep,
/// open or replace. Every bundle here is a throwaway fake built in this test's
/// own temporary folder and ad-hoc signed there — nothing touches the installed
/// app, /Applications, or the real "vibelight-update-" folders in temp.
final class UpdateSwapSafetyTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateSwapSafetyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Fixtures

    /// A minimal signed app bundle: Info.plist, one executable, one resource.
    @discardableResult
    private func makeBundle(at app: URL, version: String = "0.3.1",
                            identifier: String = "com.vibelight.app",
                            executable: String = "/usr/bin/true") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let exe = app.appendingPathComponent("Contents/MacOS/VibeLight")
        try? fm.removeItem(at: exe)
        try fm.copyItem(at: URL(fileURLWithPath: executable), to: exe)
        try Data("menu art".utf8).write(to: app.appendingPathComponent("Contents/Resources/art.txt"))
        try writeInfo(app, version: version, identifier: identifier)
        try sign(app)
        return app
    }

    private func writeInfo(_ app: URL, version: String, identifier: String) throws {
        let info: NSDictionary = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "VibeLight",
            "CFBundlePackageType": "APPL",
        ]
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }

    private func sign(_ app: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", app.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "fixture signing failed")
    }

    // MARK: FS-relocate-replaces-newer-copy

    func testRelocationNeverReplacesANewerOrEqualInstall() {
        XCTAssertFalse(AppRelocator.shouldReplaceInstalledCopy(runningVersion: "0.2.4", installedVersion: "0.2.7"))
        XCTAssertFalse(AppRelocator.shouldReplaceInstalledCopy(runningVersion: "0.2.7", installedVersion: "0.2.7"))
        XCTAssertFalse(AppRelocator.shouldReplaceInstalledCopy(runningVersion: "0.2.9", installedVersion: "0.2.10"))
    }

    func testRelocationReplacesAnOlderMissingOrUnreadableInstall() {
        XCTAssertTrue(AppRelocator.shouldReplaceInstalledCopy(runningVersion: "0.2.7", installedVersion: "0.2.4"))
        XCTAssertTrue(AppRelocator.shouldReplaceInstalledCopy(runningVersion: "0.2.7", installedVersion: nil))
    }

    func testInstalledVersionIsReadFromTheBundleAtThatPath() throws {
        let app = root.appendingPathComponent("Applications/VibeLight.app")
        XCTAssertNil(AppRelocator.installedVersion(at: app))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        try writeInfo(app, version: "0.2.7", identifier: "com.vibelight.app")
        XCTAssertEqual(AppRelocator.installedVersion(at: app), "0.2.7")
    }
}
