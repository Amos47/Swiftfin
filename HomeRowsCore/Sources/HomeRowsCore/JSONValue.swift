//
// Swiftfin is subject to the terms of the Mozilla Public
// License, v2.0. If a copy of the MPL was not distributed with this
// file, you can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright (c) 2026 Jellyfin & Jellyfin Contributors
//

import Foundation

/// Any JSON value. Objects keep the server's key order (`JSONDecoder` doesn't), which matters for provider schemas,
/// whose properties are shown in that order.
public enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var object: JSONObject? {
        if case let .object(value) = self {
            value
        } else {
            nil
        }
    }

    public var array: [JSONValue]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    public var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }

    public var number: Double? {
        if case let .number(value) = self {
            value
        } else {
            nil
        }
    }

    public var bool: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }

    /// The number as an integer, when it is one.
    public var int: Int? {
        guard let number, number.rounded() == number, abs(number) < 9.0e15 else { return nil }
        return Int(number)
    }
}

/// A JSON object that keeps key order. Equality ignores order.
public struct JSONObject: Hashable, Sendable {

    public private(set) var keys: [String]
    private var values: [String: JSONValue]

    public init(_ entries: [(String, JSONValue)] = []) {
        keys = []
        values = [:]
        for (key, value) in entries {
            self[key] = value
        }
    }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var entries: [(key: String, value: JSONValue)] {
        keys.map { ($0, values[$0]!) }
    }

    public var dictionary: [String: JSONValue] {
        values
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.values == rhs.values
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(values)
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, Equatable {
    public let offset: Int
}

public extension JSONValue {

    /// Parses JSON text, keeping object key order.
    static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw JSONParseError(offset: parser.index) }
        return value
    }
}

private struct Parser {

    let bytes: [UInt8]
    var index = 0

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private func fail() -> JSONParseError {
        JSONParseError(offset: index)
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw fail() }
            index += 1
        }
    }

    mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw fail() }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try .object(parseObject())
        case UInt8(ascii: "["): return try .array(parseArray())
        case UInt8(ascii: "\""): return try .string(parseString())
        case UInt8(ascii: "t"): try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"): try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"): try expect("null")
            return .null
        default: return try .number(parseNumber())
        }
    }

    private mutating func parseObject() throws -> JSONObject {
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return object
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail() }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return object
            } else {
                throw fail()
            }
        }
    }

    private mutating func parseArray() throws -> [JSONValue] {
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return array
        }
        while true {
            skipWhitespace()
            try array.append(parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw fail() }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return array
            } else {
                throw fail()
            }
        }
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count,
              let value = UInt16(String(decoding: bytes[index ..< index + 4], as: UTF8.self), radix: 16)
        else { throw fail() }
        index += 4
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []

        func flushRun() {
            if !run.isEmpty {
                scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
                run.removeAll()
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                flushRun()
                return String(scalars)
            case UInt8(ascii: "\\"):
                flushRun()
                guard index < bytes.count else { throw fail() }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let unit = try parseHex4()
                    if (0xD800 ... 0xDBFF).contains(unit) {
                        try expect("\\u")
                        let low = try parseHex4()
                        let value = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low &- 0xDC00)
                        guard (0xDC00 ... 0xDFFF).contains(low), let scalar = Unicode.Scalar(value) else { throw fail() }
                        scalars.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(unit) else { throw fail() }
                        scalars.append(scalar)
                    }
                default:
                    throw fail()
                }
            default:
                run.append(byte)
            }
        }
        throw fail()
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) {
            index += 1
        }
        guard index > start, let number = Double(String(decoding: bytes[start ..< index], as: UTF8.self)) else { throw fail() }
        return number
    }
}

// MARK: - Serializing

public extension JSONValue {

    /// JSON text, with object keys in order. Whole numbers are written without a fraction.
    func serialized() -> Data {
        var output = ""
        write(to: &output)
        return Data(output.utf8)
    }

    private func write(to output: inout String) {
        switch self {
        case .null:
            output += "null"
        case let .bool(value):
            output += value ? "true" : "false"
        case let .number(value):
            if let int {
                output += String(int)
            } else {
                output += value.isFinite ? String(value) : "null"
            }
        case let .string(value):
            Self.writeString(value, to: &output)
        case let .array(values):
            output += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 {
                    output += ","
                }
                value.write(to: &output)
            }
            output += "]"
        case let .object(object):
            output += "{"
            for (offset, entry) in object.entries.enumerated() {
                if offset > 0 {
                    output += ","
                }
                Self.writeString(entry.key, to: &output)
                output += ":"
                entry.value.write(to: &output)
            }
            output += "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case let scalar where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

// MARK: - Codable

/// Codable support, for embedding in Codable DTOs. Decoding through `JSONDecoder` loses object key order; use
/// `JSONValue.parse` where order matters.
extension JSONValue: Codable {

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            nil
        }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: Key.self) {
            self = try .object(JSONObject(container.allKeys.map { try ($0.stringValue, container.decode(JSONValue.self, forKey: $0)) }))
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd {
                try values.append(container.decode(JSONValue.self))
            }
            self = .array(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = try .string(container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            var container = encoder.singleValueContainer()
            if let int {
                try container.encode(int)
            } else {
                try container.encode(value)
            }
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case let .object(object):
            var container = encoder.container(keyedBy: Key.self)
            for entry in object.entries {
                try container.encode(entry.value, forKey: Key(stringValue: entry.key))
            }
        }
    }
}
