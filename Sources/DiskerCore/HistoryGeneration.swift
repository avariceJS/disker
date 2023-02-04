import Foundation

/// Invalidates asynchronous work that began before local history was cleared.
public struct HistoryGeneration: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let value: UInt64
    }

    private var value: UInt64 = 0

    public init() {}

    public func token() -> Token {
        Token(value: value)
    }

    public func accepts(_ token: Token) -> Bool {
        token.value == value
    }

    public mutating func advance() {
        value &+= 1
    }
}
