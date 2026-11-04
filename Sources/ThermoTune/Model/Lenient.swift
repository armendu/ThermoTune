import Foundation

/// Decodes to `nil` instead of failing the whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    static func array(from data: Data) -> (values: [Value], isComplete: Bool) {
        guard let entries = try? JSONDecoder().decode([Lenient].self, from: data) else { return ([], false) }
        let values = entries.compactMap(\.value)
        return (values, values.count == entries.count)
    }

    static func dictionary(from data: Data) -> (values: [String: Value], isComplete: Bool) {
        guard let entries = try? JSONDecoder().decode([String: Lenient].self, from: data) else { return ([:], false) }
        let values = entries.compactMapValues(\.value)
        return (values, values.count == entries.count)
    }
}

extension UserDefaults {
    // One unreadable entry must not cost the rest, and since the next save writes
    // only what was read, the raw data is first copied to `<key>Backup`.

    /// `nil` when nothing is saved.
    func lenientArray<Value: Decodable>(of type: Value.Type, forKey key: String) -> [Value]? {
        guard let data = data(forKey: key) else { return nil }
        let (values, isComplete) = Lenient<Value>.array(from: data)
        if !isComplete { set(data, forKey: key + "Backup") }
        return values
    }

    func setEncoded<Value: Encodable>(_ value: Value, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) { set(data, forKey: key) }
    }

    /// `nil` when nothing is saved.
    func lenientDictionary<Value: Decodable>(of type: Value.Type, forKey key: String) -> [String: Value]? {
        guard let data = data(forKey: key) else { return nil }
        let (values, isComplete) = Lenient<Value>.dictionary(from: data)
        if !isComplete { set(data, forKey: key + "Backup") }
        return values
    }
}
