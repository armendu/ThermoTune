import Foundation

/// One element of a saved list that decodes to `nil` instead of failing the
/// whole list.
struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }

    /// The elements of a JSON array that can be read, and whether all of them could.
    static func array(from data: Data) -> (values: [Value], isComplete: Bool) {
        guard let entries = try? JSONDecoder().decode([Lenient].self, from: data) else { return ([], false) }
        let values = entries.compactMap(\.value)
        return (values, values.count == entries.count)
    }

    /// The entries of a JSON object that can be read, and whether all of them could.
    static func dictionary(from data: Data) -> (values: [String: Value], isComplete: Bool) {
        guard let entries = try? JSONDecoder().decode([String: Lenient].self, from: data) else { return ([:], false) }
        let values = entries.compactMapValues(\.value)
        return (values, values.count == entries.count)
    }
}

extension UserDefaults {
    // Saved lists are read leniently: one entry a newer ThermoTune wrote, or a
    // damaged one, must not cost the rest. And since the next save writes only
    // what was read, whatever couldn't be is first copied to `<key>Backup`.

    /// The readable part of the array saved under `key`, or `nil` when nothing is saved.
    func lenientArray<Value: Decodable>(of type: Value.Type, forKey key: String) -> [Value]? {
        guard let data = data(forKey: key) else { return nil }
        let (values, isComplete) = Lenient<Value>.array(from: data)
        if !isComplete { set(data, forKey: key + "Backup") }
        return values
    }

    /// The readable part of the dictionary saved under `key`, or `nil` when nothing is saved.
    func lenientDictionary<Value: Decodable>(of type: Value.Type, forKey key: String) -> [String: Value]? {
        guard let data = data(forKey: key) else { return nil }
        let (values, isComplete) = Lenient<Value>.dictionary(from: data)
        if !isComplete { set(data, forKey: key + "Backup") }
        return values
    }
}
