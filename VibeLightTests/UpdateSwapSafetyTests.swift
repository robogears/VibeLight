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

    /// What `unpackAndValidate` records for a bundle at download time.
    private func stagedRecord(for app: URL) throws -> UpdateService.StagedUpdate {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        return UpdateService.StagedUpdate(app: app, version: info?["CFBundleShortVersionString"] as? String,
                                          fingerprint: try UpdateService.bundleFingerprint(of: app))
    }

    private func assertStagedChanged(_ staged: UpdateService.StagedUpdate,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UpdateService.revalidateStagedBundle(staged), file: file, line: line) { error in
            guard case UpdateError.stagedChanged = error else {
                return XCTFail("expected .stagedChanged, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: FS-update-swap-unchecked-stage

    func testUntouchedStagePassesTheRestartCheck() throws {
        let app = try makeBundle(at: root.appendingPathComponent("stage/VibeLight.app"))
        XCTAssertNoThrow(try UpdateService.revalidateStagedBundle(try stagedRecord(for: app)))
    }

    func testStageRemovedFromTempIsRefused() throws {
        let app = try makeBundle(at: root.appendingPathComponent("stage/VibeLight.app"))
        let staged = try stagedRecord(for: app)
        try FileManager.default.removeItem(at: app)          // macOS pruned the temp folder
        assertStagedChanged(staged)
    }

    func testDamagedResourceIsRefused() throws {
        let app = try makeBundle(at: root.appendingPathComponent("stage/VibeLight.app"))
        let staged = try stagedRecord(for: app)
        try FileManager.default.removeItem(at: app.appendingPathComponent("Contents/Resources/art.txt"))
        assertStagedChanged(staged)
    }

    func testDifferentButValidlySignedBundleIsRefused() throws {
        // A consistent bundle that isn't the one checked at download (an older
        // leftover in the same place): signature fine, fingerprint isn't.
        let app = try makeBundle(at: root.appendingPathComponent("stage/VibeLight.app"))
        let staged = try stagedRecord(for: app)
        try makeBundle(at: app, executable: "/usr/bin/false")
        assertStagedChanged(staged)
    }

    func testVersionOrIdentityChangeIsRefused() throws {
        let app = try makeBundle(at: root.appendingPathComponent("stage/VibeLight.app"))
        let staged = try stagedRecord(for: app)
        try writeInfo(app, version: "0.2.9", identifier: "com.vibelight.app"); try sign(app)
        assertStagedChanged(staged)
        try writeInfo(app, version: "0.3.1", identifier: "com.example.other"); try sign(app)
        assertStagedChanged(staged)
    }

    // MARK: FS-update-rollback-opens-self-deleting-copy

    func testSweepSparesTheFolderTheRunningAppLivesIn() throws {
        let fm = FileManager.default
        let running = root.appendingPathComponent("vibelight-update-AAA/VibeLight.app")
        try fm.createDirectory(at: running, withIntermediateDirectories: true)
        let otherStage = root.appendingPathComponent("vibelight-update-BBB")
        try fm.createDirectory(at: otherStage, withIntermediateDirectories: true)
        let zip = root.appendingPathComponent("vibelight-update-CCC.zip")
        try Data().write(to: zip)
        let unrelated = root.appendingPathComponent("someone-elses-file")
        try Data().write(to: unrelated)

        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let swept = UpdateService.staleArtifacts(in: entries, runningBundle: running)
            .map(\.lastPathComponent).sorted()
        XCTAssertEqual(swept, ["vibelight-update-BBB", "vibelight-update-CCC.zip"])
    }

    func testSweepRecognisesTheRunningAppThroughTheVarSymlink() throws {
        // Temp paths arrive as /var/folders/… from FileManager and as
        // /private/var/folders/… from a resolved bundle URL.
        let folder = root.appendingPathComponent("vibelight-update-AAA")
        let running = folder.appendingPathComponent("VibeLight.app")
        try FileManager.default.createDirectory(at: running, withIntermediateDirectories: true)
        let resolved = running.resolvingSymlinksInPath()
        XCTAssertEqual(UpdateService.staleArtifacts(in: [folder], runningBundle: resolved), [])
        XCTAssertEqual(UpdateService.staleArtifacts(in: [folder.resolvingSymlinksInPath()],
                                                    runningBundle: running), [])
    }

    func testSweepStillClearsAFolderWhoseNameIsOnlyAPrefixOfTheRunningOne() {
        let running = root.appendingPathComponent("vibelight-update-AAAB/VibeLight.app")
        let lookalike = root.appendingPathComponent("vibelight-update-AAA")
        XCTAssertEqual(UpdateService.staleArtifacts(in: [lookalike], runningBundle: running), [lookalike])
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
