import CryptoKit
import Foundation

/// How VibeLight reads its own saved JSON stores (saved computers, Restart PC
/// configs, presets) without ever losing what it can't read. One rule for every
/// store — "never rewrite a file you couldn't fully read; keep the unreadable
/// original aside":
///
/// - An entry that won't decode is kept as its ORIGINAL bytes and written back,
///   unchanged, beside the entries that did decode. The unreadable entry
///   survives, and the user's new changes are still saved. This replaced two
///   "refuse every write" latches that nothing could ever clear, so one bad
///   record froze a whole list for good (audit DAT-added-hosts-latch-forever,
///   DAT-buddy-config-latch-silent), and a preset path that wrote unreadable
///   slots back as empty (audit DAT-preset-recovery-loss).
/// - A blob that isn't even the right kind of JSON container is copied to a
///   backup key (one per distinct blob) before anything is written over it.
///
/// Pure functions over `Data` so the rules are testable without the app.
enum SavedDataRecovery {

    // MARK: - Backup

    /// Keeps `data` aside before the caller lets a save write over it — once
    /// per distinct blob. The first rescue copy lives at `key` and is never
    /// replaced; a DIFFERENT blob that fails to read later goes beside it under
    /// `key.<sha256 of the blob>`. It used to be dropped when `key` was taken,
    /// and since saves now go ahead (no latch), that newer blob — pinned certs
    /// and all — was then written over with no copy anywhere.
    /// (review of DAT-added-hosts-latch-forever: one-shot backup)
    /// Returns true when it wrote; false when this exact blob is already kept.
    @discardableResult
    static func backUpOnce(_ data: Data, to key: String, in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            defaults.set(data, forKey: key)
            return true
        }
        if defaults.data(forKey: key) == data { return false }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let incidentKey = "\(key).\(digest)"
        guard defaults.object(forKey: incidentKey) == nil else { return false }
        defaults.set(data, forKey: incidentKey)
        return true
    }

    // MARK: - Lists (saved computers)

    /// Decodes a JSON array element by element. Elements that decode become
    /// `records`; the rest are kept as their exact original bytes. nil when the
    /// blob is not a JSON array at all.
    static func decodeList<T: Decodable>(_ type: T.Type, from data: Data) -> (records: [T], unreadable: [Data])? {
        guard let elements = arrayElements(data) else { return nil }
        var records: [T] = []
        var unreadable: [Data] = []
        for element in elements {
            if let record = try? JSONDecoder().decode(T.self, from: element) {
                records.append(record)
            } else {
                unreadable.append(element)
            }
        }
        return (records, unreadable)
    }

    /// The records, followed by the unreadable elements byte for byte.
    static func encodeList<T: Encodable>(_ records: [T], preserving unreadable: [Data]) -> Data? {
        var parts: [Data] = []
        for record in records {
            guard let encoded = try? JSONEncoder().encode(record) else { return nil }
            parts.append(encoded)
        }
        return joinArray(parts + unreadable)
    }

    // MARK: - Maps (Restart PC configs)

    /// Decodes a JSON object value by value; unreadable values are kept as
    /// their exact original bytes under their key. nil when the blob is not a
    /// JSON object.
    static func decodeMap<T: Decodable>(_ type: T.Type, from data: Data)
        -> (records: [String: T], unreadable: [String: Data])? {
        guard let members = objectMembers(data) else { return nil }
        var records: [String: T] = [:]
        var unreadable: [String: Data] = [:]
        for (key, value) in members {
            if let record = try? JSONDecoder().decode(T.self, from: value) {
                records[key] = record
            } else {
                unreadable[key] = value
            }
        }
        return (records, unreadable)
    }

    /// A key present in `records` wins over a preserved unreadable value.
    static func encodeMap<T: Encodable>(_ records: [String: T], preserving unreadable: [String: Data]) -> Data? {
        var values = unreadable
        for (key, record) in records {
            guard let encoded = try? JSONEncoder().encode(record) else { return nil }
            values[key] = encoded
        }
        var out = Data("{".utf8)
        for (n, key) in values.keys.sorted().enumerated() {
            guard let encodedKey = try? JSONEncoder().encode(key), let value = values[key] else { return nil }
            if n > 0 { out.append(UInt8(ascii: ",")) }
            out.append(encodedKey)
            out.append(UInt8(ascii: ":"))
            out.append(value)
        }
        out.append(UInt8(ascii: "}"))
        return out
    }

    // MARK: - Fixed slots (presets)

    /// Decodes a JSON array into `count` slots, where `null` is an empty slot.
    /// A slot that won't decode is empty in `slots` but keeps its original bytes
    /// in `raw` at the same position; elements past `count` are kept raw too.
    /// nil when the blob is not a JSON array.
    static func decodeSlots<T: Decodable>(_ type: T.Type, from data: Data, count: Int)
        -> (slots: [T?], raw: [Data?])? {
        guard let elements = arrayElements(data) else { return nil }
        var slots = [T?](repeating: nil, count: count)
        var raw = [Data?](repeating: nil, count: max(count, elements.count))
        for (i, element) in elements.enumerated() {
            // Checked by hand: JSONDecoder rejects a top-level `null` even as
            // an Optional, which would mark every empty slot unreadable.
            if i < count, element == Data("null".utf8) { continue }
            if i < count, let decoded = try? JSONDecoder().decode(T.self, from: element) {
                slots[i] = decoded
            } else {
                raw[i] = element
            }
        }
        return (slots, raw)
    }

    /// Each slot's record if it has one, else its preserved original bytes,
    /// else `null`. Only putting a record INTO a slot replaces what was there.
    static func encodeSlots<T: Encodable>(_ slots: [T?], preserving raw: [Data?]) -> Data? {
        var parts: [Data] = []
        for i in 0..<max(slots.count, raw.count) {
            if i < slots.count, let record = slots[i] {
                guard let encoded = try? JSONEncoder().encode(record) else { return nil }
                parts.append(encoded)
            } else if i < raw.count, let original = raw[i] {
                parts.append(original)
            } else {
                parts.append(Data("null".utf8))
            }
        }
        return joinArray(parts)
    }

    // MARK: - Splitting a blob into its members' original bytes

    /// The exact bytes of each top-level element of a JSON array, or nil when
    /// `data` is not a well-formed UTF-8 JSON array.
    static func arrayElements(_ data: Data) -> [Data]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let members = topLevelMembers([UInt8](data), open: UInt8(ascii: "["), close: UInt8(ascii: "]")),
              members.count == array.count
        else { return nil }
        return members.map { Data($0) }
    }

    /// Each top-level member of a JSON object as (key, exact value bytes), or
    /// nil when `data` is not a well-formed UTF-8 JSON object.
    static func objectMembers(_ data: Data) -> [(key: String, value: Data)]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let members = topLevelMembers([UInt8](data), open: UInt8(ascii: "{"), close: UInt8(ascii: "}"))
        else { return nil }
        var out: [(key: String, value: Data)] = []
        for member in members {
            guard let colon = firstColonOutsideString(member),
                  let key = try? JSONDecoder().decode(String.self, from: Data(trim(member[..<colon])))
            else { return nil }
            out.append((key, Data(trim(member[(colon + 1)...]))))
        }
        // A duplicate key would make the two views disagree; treat as unreadable.
        guard Set(out.map(\.key)).count == object.count, out.count == object.count else { return nil }
        return out
    }

    private static func joinArray(_ parts: [Data]) -> Data {
        var out = Data("[".utf8)
        for (n, part) in parts.enumerated() {
            if n > 0 { out.append(UInt8(ascii: ",")) }
            out.append(part)
        }
        out.append(UInt8(ascii: "]"))
        return out
    }

    /// Splits the outermost container into its members' byte ranges by
    /// tracking string and nesting state. Only ever run on bytes that
    /// JSONSerialization already accepted, so it need not validate JSON itself.
    /// Rejects anything that isn't plain UTF-8 (a raw NUL means UTF-16/32,
    /// whose bytes can't be spliced into a UTF-8 array).
    private static func topLevelMembers(_ bytes: [UInt8], open: UInt8, close: UInt8) -> [[UInt8]]? {
        guard !bytes.contains(0) else { return nil }
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ",")
        let openers: Set<UInt8> = [UInt8(ascii: "["), UInt8(ascii: "{")]
        let closers: Set<UInt8> = [UInt8(ascii: "]"), UInt8(ascii: "}")]
        var i = 0
        while i < bytes.count, isWhitespace(bytes[i]) { i += 1 }
        guard i < bytes.count, bytes[i] == open else { return nil }
        i += 1
        var members: [[UInt8]] = []
        var start = i, depth = 0, inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if b == backslash { i += 2; continue }
                if b == quote { inString = false }
            } else if b == quote {
                inString = true
            } else if openers.contains(b) {
                depth += 1
            } else if closers.contains(b) {
                if depth == 0 {
                    guard b == close else { return nil }
                    let last = trim(bytes[start..<i])
                    if !last.isEmpty { members.append(last) } else if !members.isEmpty { return nil }
                    return members
                }
                depth -= 1
            } else if b == comma, depth == 0 {
                members.append(trim(bytes[start..<i]))
                start = i + 1
            }
            i += 1
        }
        return nil
    }

    private static func firstColonOutsideString(_ bytes: [UInt8]) -> Int? {
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), colon = UInt8(ascii: ":")
        var i = 0, inString = false
        while i < bytes.count {
            let b = bytes[i]
            if inString {
                if b == backslash { i += 2; continue }
                if b == quote { inString = false }
            } else if b == quote {
                inString = true
            } else if b == colon {
                return i
            }
            i += 1
        }
        return nil
    }

    private static func isWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }

    private static func trim(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var s = slice
        while let f = s.first, isWhitespace(f) { s = s.dropFirst() }
        while let l = s.last, isWhitespace(l) { s = s.dropLast() }
        return Array(s)
    }
}
