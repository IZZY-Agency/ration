import Foundation

/// The rules `Localizable.xcstrings` must satisfy, as pure functions over the
/// decoded catalog so each rule can be tested against small inline catalogs
/// (`CatalogChecksTests`) as well as run on the real one
/// (`CatalogCompletenessTests`). Each returns the offending keys, empty when
/// the catalog complies.
enum CatalogChecks {
    static let translations = ["fr", "uk"]
    /// CLDR cardinal categories the catalog must spell out per language.
    /// French has `many` (1 000 000 de …, the compact-exponent forms) as
    /// well as `one` and `other`; its text is the `other` text here.
    static let pluralCategories: [String: Set<String>] = [
        "fr": ["one", "many", "other"],
        "uk": ["one", "few", "many", "other"],
    ]

    typealias Node = [String: Any]

    static func decode(_ data: Data) throws -> Node {
        guard let root = try JSONSerialization.jsonObject(with: data) as? Node else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return root
    }

    /// Every key except the ones Xcode marked stale, sorted.
    static func liveEntries(_ root: Node) -> [(key: String, entry: Node)] {
        let strings = root["strings"] as? [String: Node] ?? [:]
        return strings
            .filter { ($0.value["extractionState"] as? String) != "stale" }
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, entry: $0.value) }
    }

    static func missingComments(in root: Node) -> [String] {
        liveEntries(root)
            .filter { (($0.entry["comment"] as? String) ?? "").isEmpty }
            .map(\.key)
    }

    /// fr and uk exist, hold at least one string unit, and every unit is
    /// `translated` with a non-empty value. An English unit, when present, must
    /// also have a value.
    static func untranslated(in root: Node) -> [String] {
        var offending: [String] = []
        for (key, entry) in liveEntries(root) {
            let localizations = entry["localizations"] as? Node ?? [:]
            if let english = localizations["en"] as? Node {
                for (path, unit) in stringUnits(english) where ((unit["value"] as? String) ?? "").isEmpty {
                    offending.append("\(key) [en\(path) empty value]")
                }
            }
            for language in translations {
                guard let localization = localizations[language] as? Node else {
                    offending.append("\(key) [\(language) missing]")
                    continue
                }
                let units = stringUnits(localization)
                if units.isEmpty {
                    offending.append("\(key) [\(language) has no string unit]")
                }
                for (path, unit) in units {
                    if unit["state"] as? String != "translated" {
                        offending.append("\(key) [\(language)\(path) state=\(unit["state"] ?? "nil")]")
                    }
                    if ((unit["value"] as? String) ?? "").isEmpty {
                        offending.append("\(key) [\(language)\(path) empty value]")
                    }
                }
            }
        }
        return offending
    }

    /// Where English varies by plural, each translation varies by plural too
    /// and spells out every category its language needs.
    static func pluralGaps(in root: Node) -> [String] {
        var offending: [String] = []
        for (key, entry) in liveEntries(root) {
            let localizations = entry["localizations"] as? Node ?? [:]
            guard !plurals(localizations["en"]).isEmpty else { continue }
            for language in translations {
                let required = pluralCategories[language, default: []]
                let found = plurals(localizations[language])
                if found.isEmpty {
                    offending.append("\(key) [\(language) has no plural variation]")
                }
                for plural in found {
                    let missing = required.subtracting(plural.keys)
                    if !missing.isEmpty {
                        offending.append("\(key) [\(language) missing \(missing.sorted())]")
                    }
                }
            }
        }
        return offending
    }

    /// Each translated value carries the same multiset of format specifiers as
    /// the English value at the same variation path. A plural category English
    /// does not have (uk `few`) is compared with English `other`; a path
    /// English lacks entirely is compared with its nearest English ancestor.
    /// Keys without an English unit use the key itself as the English value.
    static func placeholderMismatches(in root: Node) -> [String] {
        var offending: [String] = []
        for (key, entry) in liveEntries(root) {
            let localizations = entry["localizations"] as? Node ?? [:]
            var english: [String: String] = ["": key]
            if let node = localizations["en"] as? Node {
                english = [:]
                for (path, unit) in stringUnits(node) {
                    english[path] = unit["value"] as? String ?? ""
                }
            }
            for language in translations {
                guard let localization = localizations[language] as? Node else { continue }
                for (path, unit) in stringUnits(localization) {
                    let value = unit["value"] as? String ?? ""
                    guard let reference = englishCounterpart(of: path, in: english) else {
                        offending.append("\(key) [\(language)\(path)] has no English counterpart")
                        continue
                    }
                    let expected = placeholders(reference)
                    let found = placeholders(value)
                    if found != expected {
                        offending.append("\(key) [\(language)\(path)] \(found.sorted { $0.key < $1.key }) != en \(expected.sorted { $0.key < $1.key })")
                    }
                }
            }
        }
        return offending
    }

    static func englishCounterpart(of path: String, in english: [String: String]) -> String? {
        var components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while true {
            let candidate = components.joined(separator: ".")
            if let value = english[candidate] { return value }
            if components.count >= 2, components[components.count - 2] == "plural", components.last != "other" {
                components[components.count - 1] = "other"
                if let value = english[components.joined(separator: ".")] { return value }
            }
            guard components.count > 1 else { return nil }
            components.removeLast(2)
            if components.isEmpty { components = [""] }
        }
    }

    // MARK: - Catalog walking

    /// Every `stringUnit` beneath a localization, keyed by its variation path
    /// (`""`, `.plural.few`, `.sub.count.plural.one`, `.device.mac`).
    static func stringUnits(_ node: Node, path: String = "") -> [(String, Node)] {
        var units: [(String, Node)] = []
        if let unit = node["stringUnit"] as? Node { units.append((path, unit)) }
        if let variations = node["variations"] as? [String: Node] {
            for (kind, cases) in variations {
                for (name, child) in cases {
                    if let child = child as? Node {
                        units += stringUnits(child, path: "\(path).\(kind).\(name)")
                    }
                }
            }
        }
        if let substitutions = node["substitutions"] as? [String: Node] {
            for (name, child) in substitutions {
                units += stringUnits(child, path: "\(path).sub.\(name)")
            }
        }
        return units.sorted { $0.0 < $1.0 }
    }

    /// `plural` variation dictionaries anywhere under a localization.
    static func plurals(_ node: Any?) -> [Node] {
        guard let node = node as? Node else { return [] }
        var found: [Node] = []
        if let variations = node["variations"] as? [String: Node] {
            if let plural = variations["plural"] { found.append(plural) }
            for cases in variations.values {
                for child in cases.values { found += plurals(child) }
            }
        }
        if let substitutions = node["substitutions"] as? Node {
            for child in substitutions.values { found += plurals(child) }
        }
        return found
    }

    /// Multiset of format specifiers (`%@`, `%lld`, `%1$@`, `%#@name@`, and
    /// `%arg` inside a substitution); `%%` is not one.
    static func placeholders(_ value: String) -> [String: Int] {
        let pattern = /%(?:%|(?:\d+\$)?(?:#@[A-Za-z0-9_]+@|arg|[-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfeEgGcCsSaAp]))/
        var counts: [String: Int] = [:]
        for match in value.matches(of: pattern) where match.output != "%%" {
            counts[String(match.output), default: 0] += 1
        }
        return counts
    }
}
