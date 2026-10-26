import XCTest
@testable import VibeLight

/// Saved data VibeLight can't read must survive untouched, and the user's new
/// changes must still be saved. Before: one unreadable saved computer (or
/// Restart PC entry) froze its whole list forever, an unreadable preset slot
/// was written back as empty by any other preset save, and damaged saved
/// numbers crashed the Resolution and Bitrate rows. These pin the rules; every
/// fixture uses documentation addresses and never touches the app's real
/// defaults.
final class SavedDataRecoveryTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "vibelight.tests.saved-data-recovery.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func contains(_ haystack: Data, _ needle: Data) -> Bool {
        haystack.range(of: needle) != nil
    }

    // MARK: - Saved computers (DAT-added-hosts-latch-forever)

    // A record a future build wrote (name is a number here) — exact bytes,
    // odd spacing and key order included, so "byte for byte" means something.
    private let badHost = #"{ "ip" : "198.51.100.7", "name" : 42, "fromTheFuture" : [1, {"x": "]"}] }"#

    func testUnreadableSavedComputerSurvivesAddingAnotherByteForByte() throws {
        let stored = json(#"[{"name":"Den PC","ip":"192.0.2.10"}, "# + badHost + "]")
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: stored))
        XCTAssertEqual(loaded.records.map(\.ip), ["192.0.2.10"])
        XCTAssertEqual(loaded.unreadable, [json(badHost)])

        var hosts = loaded.records
        hosts.append(AppState.AddedHost(name: "Office", ip: "203.0.113.5", uuid: nil, serverCert: nil, mac: nil))
        let saved = try XCTUnwrap(SavedDataRecovery.encodeList(hosts, preserving: loaded.unreadable))

        XCTAssertTrue(contains(saved, json(badHost)), "the unreadable record must be written back byte for byte")
        let reloaded = try XCTUnwrap(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: saved))
        XCTAssertEqual(reloaded.records.map(\.ip), ["192.0.2.10", "203.0.113.5"], "the added computer must persist")
        XCTAssertEqual(reloaded.unreadable, [json(badHost)])
    }

    func testRemovingAComputerRemovesOnlyThatComputer() throws {
        let stored = json(#"[{"name":"A","ip":"192.0.2.1"},{"name":"B","ip":"192.0.2.2"},"# + badHost + "]")
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: stored))
        let remaining = loaded.records.filter { $0.ip != "192.0.2.1" }
        let saved = try XCTUnwrap(SavedDataRecovery.encodeList(remaining, preserving: loaded.unreadable))
        let reloaded = try XCTUnwrap(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: saved))
        XCTAssertEqual(reloaded.records.map(\.ip), ["192.0.2.2"])
        XCTAssertEqual(reloaded.unreadable, [json(badHost)])
    }

    func testSavedComputerListThatIsNotAnArrayIsReportedUnreadable() {
        XCTAssertNil(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: json(#"{"name":"A"}"#)))
        XCTAssertNil(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: json(#"[{"name":"A","ip":"#)))
        // UTF-16 bytes can't be spliced into a UTF-8 array, so they count as unreadable too.
        let utf16 = #"[{"name":"A","ip":"192.0.2.1"}]"#.data(using: .utf16LittleEndian)!
        XCTAssertNil(SavedDataRecovery.decodeList(AppState.AddedHost.self, from: utf16))
    }

    // MARK: - Whole-blob backup (all stores, incl. DAT-settings-reset-overwrites-original)

    func testUnreadableBlobIsBackedUpOnceAndAnEarlierBackupIsNeverOverwritten() {
        let key = "vibelight.addedHosts.unreadable"
        XCTAssertTrue(SavedDataRecovery.backUpOnce(json("first damaged"), to: key, in: defaults))
        XCTAssertFalse(SavedDataRecovery.backUpOnce(json("later, more damaged"), to: key, in: defaults))
        XCTAssertEqual(defaults.data(forKey: key), json("first damaged"))
    }

    // MARK: - Restart PC configs (DAT-buddy-config-latch-silent)

    func testUnreadableRestartPCEntrySurvivesPairingAnotherComputer() throws {
        let badValue = #"{"port": "not a number", "paired": true}"#
        let stored = json(#"{"192.0.2.10": {"port": 59999, "paired": true}, "198.51.100.7": "# + badValue + "}")
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeMap(AppState.MoonDeckConfig.self, from: stored))
        XCTAssertEqual(loaded.records.keys.sorted(), ["192.0.2.10"])
        XCTAssertEqual(loaded.unreadable, ["198.51.100.7": json(badValue)])

        var configs = loaded.records
        configs["203.0.113.5"] = AppState.MoonDeckConfig(port: 59999, paired: true, pinnedCert: Data([1, 2, 3]))
        let saved = try XCTUnwrap(SavedDataRecovery.encodeMap(configs, preserving: loaded.unreadable))

        XCTAssertTrue(contains(saved, json(badValue)), "the unreadable entry must be written back byte for byte")
        let reloaded = try XCTUnwrap(SavedDataRecovery.decodeMap(AppState.MoonDeckConfig.self, from: saved))
        XCTAssertEqual(reloaded.records.keys.sorted(), ["192.0.2.10", "203.0.113.5"], "the new pairing must persist")
        XCTAssertEqual(reloaded.records["203.0.113.5"]?.pinnedCert, Data([1, 2, 3]))
        XCTAssertEqual(reloaded.unreadable, ["198.51.100.7": json(badValue)])
    }

    func testRestartPCMapThatIsNotAnObjectIsReportedUnreadable() {
        XCTAssertNil(SavedDataRecovery.decodeMap(AppState.MoonDeckConfig.self, from: json("[1,2]")))
        XCTAssertNil(SavedDataRecovery.decodeMap(AppState.MoonDeckConfig.self, from: json(#"{"a":"#)))
    }

    // MARK: - Presets (DAT-preset-recovery-loss)

    private func preset(_ name: String, fps: Int = 60) -> StreamPreset {
        StreamPreset(id: name, name: name, settings: StreamSettings(fps: fps))
    }

    private let badSlot = #"{"id": 7, "name": "4K 60", "settings": {}}"#

    func testUnreadablePresetSlotSurvivesSavingADifferentSlot() throws {
        let good = String(data: try JSONEncoder().encode(preset("Couch", fps: 120)), encoding: .utf8)!
        let stored = json("[\(good), \(badSlot), null, null, null, null]")
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeSlots(StreamPreset.self, from: stored, count: 6))
        XCTAssertEqual(loaded.slots[0]?.name, "Couch")
        XCTAssertNil(loaded.slots[1], "an unreadable slot shows as empty")
        XCTAssertEqual(loaded.raw[1], json(badSlot))

        var slots = loaded.slots
        slots[3] = preset("Desk", fps: 144)   // save into another slot
        let saved = try XCTUnwrap(SavedDataRecovery.encodeSlots(slots, preserving: loaded.raw))

        XCTAssertTrue(contains(saved, json(badSlot)), "the unreadable slot must be written back byte for byte")
        let reloaded = try XCTUnwrap(SavedDataRecovery.decodeSlots(StreamPreset.self, from: saved, count: 6))
        XCTAssertEqual(reloaded.slots.map { $0?.name }, ["Couch", nil, nil, "Desk", nil, nil])
        XCTAssertEqual(reloaded.raw[1], json(badSlot), "still in slot 2, not moved")
    }

    func testSavingIntoAnUnreadablePresetSlotReplacesIt() throws {
        let stored = json("[null, \(badSlot), null, null, null, null]")
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeSlots(StreamPreset.self, from: stored, count: 6))
        var slots = loaded.slots
        slots[1] = preset("New")
        let saved = try XCTUnwrap(SavedDataRecovery.encodeSlots(slots, preserving: loaded.raw))
        XCTAssertFalse(contains(saved, json(badSlot)))
        let reloaded = try XCTUnwrap(SavedDataRecovery.decodeSlots(StreamPreset.self, from: saved, count: 6))
        XCTAssertEqual(reloaded.slots[1]?.name, "New")
        XCTAssertTrue(reloaded.raw.allSatisfy { $0 == nil })
    }

    func testEmptyPresetSlotsStayEmptyAndShortBlobsPadToSixSlots() throws {
        let loaded = try XCTUnwrap(SavedDataRecovery.decodeSlots(StreamPreset.self, from: json("[null, null]"), count: 6))
        XCTAssertEqual(loaded.slots.count, 6)
        XCTAssertTrue(loaded.slots.allSatisfy { $0 == nil })
        XCTAssertTrue(loaded.raw.allSatisfy { $0 == nil }, "null is an empty slot, not an unreadable one")
        XCTAssertNil(SavedDataRecovery.decodeSlots(StreamPreset.self, from: json("{}"), count: 6))
    }

    // MARK: - Damaged saved numbers (DAT-stored-size-overflow)

    func testIntMaxSavedSizeFrameRateAndBitrateLoadClamped() throws {
        let max = Int.max
        let stored = json(#"{"width": \#(max), "height": \#(max), "fps": \#(max), "bitrateKbps": \#(max)}"#)
        let s = try JSONDecoder().decode(StreamSettings.self, from: stored)
        XCTAssertEqual(s.width, 7680)
        XCTAssertEqual(s.height, 4320)
        XCTAssertEqual(s.fps, 240)
        XCTAssertEqual(s.bitrateKbps, 200_000)

        let negative = json(#"{"width": -5, "height": 0, "fps": -1, "bitrateKbps": -9}"#)
        let n = try JSONDecoder().decode(StreamSettings.self, from: negative)
        XCTAssertEqual([n.width, n.height, n.fps, n.bitrateKbps], [256, 144, 1, 10_000])
    }

    func testPresetHoldingIntMaxValuesDecodesClamped() throws {
        let max = Int.max
        let stored = json(#"{"id":"p","name":"Broken","settings":{"width":\#(max),"height":\#(max),"bitrateKbps":\#(max)}}"#)
        let p = try JSONDecoder().decode(StreamPreset.self, from: stored)
        XCTAssertEqual(p.settings.width, 7680)
        XCTAssertEqual(p.settings.bitrateKbps, 200_000)
    }

    func testResolutionListSortDoesNotTrapOnAHugeSize() {
        XCTAssertEqual(AppState.pixelCount(Int.max, Int.max), Int.max)
        XCTAssertEqual(AppState.pixelCount(Int.max, -2), Int.min)
        XCTAssertEqual(AppState.pixelCount(1920, 1080), 2_073_600)
        let sorted = [(Int.max, 3), (1280, 720)].sorted { AppState.pixelCount($0.0, $0.1) < AppState.pixelCount($1.0, $1.1) }
        XCTAssertEqual(sorted.first?.0, 1280)
    }

    // MARK: - Frame Rate arrows (QUA-fps-offgrid-jump)

    func testFrameRateArrowsFromAnOffGridValueStepToTheNearestPresetInThatDirection() {
        let presets = [30, 60, 90, 120, 144, 165, 240]
        func step(_ fps: Int, _ forward: Bool) -> Int {
            AppState.steppedFPS(from: fps, forward: forward, presets: presets)
        }
        XCTAssertEqual(step(100, true), 120, "Right from 100 used to give 90")
        XCTAssertEqual(step(100, false), 90, "Left from 100 used to give 30")
        XCTAssertEqual(step(200, false), 165, "Left from 200 used to give 30")
        XCTAssertEqual(step(200, true), 240)
        XCTAssertEqual(step(10, false), 30)
        XCTAssertEqual(step(300, true), 240)
        // On-grid behaviour is unchanged.
        XCTAssertEqual(step(60, true), 90)
        XCTAssertEqual(step(30, false), 30)
        XCTAssertEqual(step(240, true), 240)
    }

    // MARK: - Restart PC port (NET-negative-buddy-port)

    func testRestartPCPortFieldRejectsPortsOutsideOneTo65535() {
        for bad in ["-1", "0", "70000", "65536", "port", "1.5"] {
            XCTAssertNil(MoonDeckBuddyClient.port(fromField: bad), "\(bad) is not a port")
        }
        XCTAssertEqual(MoonDeckBuddyClient.port(fromField: ""), MoonDeckBuddyClient.defaultPort)
        XCTAssertEqual(MoonDeckBuddyClient.port(fromField: " 59999 "), 59999)
        XCTAssertEqual(MoonDeckBuddyClient.port(fromField: "1"), 1)
        XCTAssertEqual(MoonDeckBuddyClient.port(fromField: "65535"), 65535)
    }

    func testStoredNegativeRestartPCPortThrowsInsteadOfCrashing() async {
        XCTAssertNil(MoonDeckBuddyClient.requestURL(host: "192.0.2.10", port: -1, path: "/apiVersion"))
        XCTAssertNotNil(MoonDeckBuddyClient.requestURL(host: "192.0.2.10", port: 59999, path: "/apiVersion"))
        // The real request path: a negative port used to reach URLComponents'
        // port setter, which raises an exception that ends the app.
        do {
            try await MoonDeckBuddyClient().checkReachable(host: "192.0.2.10", port: -1)
            XCTFail("a negative port must be refused")
        } catch {
            XCTAssertEqual(error as? MoonDeckBuddyClient.MDError, .badResponse("port -1 is not a valid port"))
        }
    }
}
