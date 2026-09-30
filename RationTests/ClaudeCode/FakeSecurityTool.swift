import Foundation
@testable import Ration

/// Stands in for `/usr/bin/security` holding Claude Code's entry, so no test
/// touches the real Keychain. Understands the three commands Ration uses.
/// Hooks let a test play Claude Code writing between Ration's steps.
final class FakeSecurityTool: SecurityTool, @unchecked Sendable {
    struct Call: Equatable {
        let arguments: [String]
        let usedStdin: Bool
    }

    private let lock = NSLock()
    private var storedItem: Data?
    private var readCount = 0
    private(set) var calls: [Call] = []
    private(set) var writes = 0
    /// After serving read number n (1-based), may change the item.
    var afterRead: ((Int, inout Data?) -> Void)?
    /// After storing a write, may change the item.
    var afterWrite: ((inout Data?) -> Void)?
    var failWriteStatus: Int32?

    init(item: [String: Any]? = nil) {
        storedItem = item.map { try! JSONSerialization.data(withJSONObject: $0) }
    }

    var item: [String: Any]? {
        lock.withLock { storedItem.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    func setItem(_ object: [String: Any]?) {
        lock.withLock { storedItem = object.map { try! JSONSerialization.data(withJSONObject: $0) } }
    }

    func run(_ arguments: [String], stdin: Data?) throws -> (status: Int32, output: Data) {
        try lock.withLock {
            calls.append(Call(arguments: arguments, usedStdin: stdin != nil))
            if arguments.first == "find-generic-password" {
                guard var item = storedItem else { return (44, Data()) }
                readCount += 1
                let served = item + Data("\n".utf8)
                afterRead?(readCount, &storedItem)
                item = storedItem ?? item
                return (0, served)
            }
            let hex: String
            if arguments == ["-i"], let stdin {
                let line = String(decoding: stdin, as: UTF8.self)
                guard let start = line.range(of: "-X \""), let end = line[start.upperBound...].firstIndex(of: "\"") else { return (1, Data()) }
                hex = String(line[start.upperBound..<end])
            } else if arguments.first == "add-generic-password", let index = arguments.firstIndex(of: "-X"), index + 1 < arguments.count {
                hex = arguments[index + 1]
            } else {
                return (1, Data())
            }
            if let failWriteStatus { return (failWriteStatus, Data()) }
            var bytes = Data()
            var iterator = hex.makeIterator()
            while let high = iterator.next(), let low = iterator.next() {
                bytes.append(UInt8(String([high, low]), radix: 16)!)
            }
            storedItem = bytes
            writes += 1
            afterWrite?(&storedItem)
            return (0, Data())
        }
    }
}
