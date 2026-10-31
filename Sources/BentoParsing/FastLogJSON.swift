import Darwin
import Foundation

/// High-throughput UTF-8 JSON pre-filtering, field extraction, and ISO-8601 timestamp parsing for session log decoders.
public enum FastLogJSON: Sendable {
    /// Classification of a raw line's top-level JSON object framing after stripping ASCII whitespace.
    public enum LineFraming: Sendable, Equatable {
        case empty
        case object(Range<Int>)
        case invalid
    }

    /// Inspects leading/trailing ASCII whitespace and verifies `{ ... }` object framing without heap allocation.
    @inlinable
    public static func inspectObjectFraming(in buf: UnsafeBufferPointer<UInt8>) -> LineFraming {
        let count = buf.count
        if count == 0 {
            return .empty
        }
        guard let base = buf.baseAddress else {
            return .empty
        }
        var start = 0
        while start < count && isASCIIWhitespace(base[start]) {
            start += 1
        }
        if start == count {
            return .empty
        }
        var end = count - 1
        while end > start && isASCIIWhitespace(base[end]) {
            end -= 1
        }
        if base[start] == 0x7B && base[end] == 0x7D {
            return .object(start..<(end + 1))
        }
        return .invalid
    }

    /// Inspects leading/trailing ASCII whitespace and verifies `{ ... }` object framing without heap allocation.
    @inlinable
    public static func inspectObjectFraming(in line: Data) -> LineFraming {
        if line.isEmpty {
            return .empty
        }
        return line.withUnsafeBytes { rawBuffer in
            inspectObjectFraming(in: rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Checks whether `buf` contains the exact ASCII bytes of `needle` using C `memmem`.
    @inlinable
    public static func containsASCII(_ needle: StaticString, in buf: UnsafeBufferPointer<UInt8>) -> Bool {
        let needleLen = needle.utf8CodeUnitCount
        if needleLen == 0 { return true }
        if buf.count < needleLen { return false }
        guard let base = buf.baseAddress else { return false }
        return memmem(base, buf.count, needle.utf8Start, needleLen) != nil
    }

    /// Checks whether `data` contains the exact ASCII bytes of `needle` using C `memmem`.
    @inlinable
    public static func containsASCII(_ needle: StaticString, in data: Data) -> Bool {
        let needleLen = needle.utf8CodeUnitCount
        if needleLen == 0 { return true }
        if data.count < needleLen { return false }
        return data.withUnsafeBytes { rawBuffer in
            containsASCII(needle, in: rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Extracts an unescaped ASCII string value immediately following `keyPattern` inside `buf`.
    public static func extractSimpleString(
        afterKeyPattern keyPattern: StaticString,
        in buf: UnsafeBufferPointer<UInt8>
    ) -> String? {
        let patLen = keyPattern.utf8CodeUnitCount
        let count = buf.count
        guard count > patLen + 2, let base = buf.baseAddress else { return nil }
        let rawBase = UnsafeRawPointer(base)
        guard let foundPtr = memmem(rawBase, count, keyPattern.utf8Start, patLen) else {
            return nil
        }
        let foundOffset = rawBase.distance(to: UnsafeRawPointer(foundPtr))
        var idx = foundOffset + patLen
        while idx < count && isASCIIWhitespace(base[idx]) {
            idx += 1
        }
        guard idx < count, base[idx] == 0x22 else { return nil }  // opening '"'
        idx += 1
        let strStart = idx
        while idx < count {
            let b = base[idx]
            if b == 0x5C || b < 0x20 {  // backslash escape or control char -> fallback
                return nil
            }
            if b == 0x22 {  // closing '"'
                let slice = UnsafeBufferPointer(start: base.advanced(by: strStart), count: idx - strStart)
                return String(decoding: slice, as: UTF8.self)
            }
            idx += 1
        }
        return nil
    }

    /// Extracts an unescaped ASCII string value immediately following `keyPattern` (e.g. `"\"timestamp\":"`)
    /// when present without backslash escapes; returns `nil` if absent or escaped so callers can fall back.
    public static func extractSimpleString(afterKeyPattern keyPattern: StaticString, in data: Data) -> String? {
        let patLen = keyPattern.utf8CodeUnitCount
        guard data.count > patLen + 2 else { return nil }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> String? in
            extractSimpleString(afterKeyPattern: keyPattern, in: rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Parses `"timestamp":"<ISO8601>"` directly from UTF-8 bytes without allocating an intermediate `String`.
    public static func extractTimestamp(
        afterKeyPattern keyPattern: StaticString,
        in buf: UnsafeBufferPointer<UInt8>
    ) -> Date? {
        let patLen = keyPattern.utf8CodeUnitCount
        let count = buf.count
        guard count > patLen + 20, let base = buf.baseAddress else { return nil }
        let rawBase = UnsafeRawPointer(base)
        guard let foundPtr = memmem(rawBase, count, keyPattern.utf8Start, patLen) else {
            return nil
        }
        let foundOffset = rawBase.distance(to: UnsafeRawPointer(foundPtr))
        var idx = foundOffset + patLen
        while idx < count && isASCIIWhitespace(base[idx]) {
            idx += 1
        }
        guard idx < count, base[idx] == 0x22 else { return nil }
        idx += 1
        let strStart = idx
        while idx < count && base[idx] != 0x22 {
            if base[idx] == 0x5C { return nil }
            idx += 1
        }
        guard idx < count else { return nil }
        return parseISO8601UTF8(UnsafeBufferPointer(start: base.advanced(by: strStart), count: idx - strStart))
    }

    /// Parses `"timestamp":"<ISO8601>"` directly from UTF-8 bytes without allocating an intermediate `String`.
    public static func extractTimestamp(afterKeyPattern keyPattern: StaticString, in data: Data) -> Date? {
        let patLen = keyPattern.utf8CodeUnitCount
        guard data.count > patLen + 20 else { return nil }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Date? in
            extractTimestamp(afterKeyPattern: keyPattern, in: rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Extracts a non-negative integer value immediately following `keyPattern` inside `buf[startOffset...]`.
    public static func extractNonNegativeInt(
        afterKeyPattern keyPattern: StaticString,
        in buf: UnsafeBufferPointer<UInt8>,
        from startOffset: Int = 0
    ) -> Int? {
        let patLen = keyPattern.utf8CodeUnitCount
        let count = buf.count
        guard startOffset >= 0, count > startOffset + patLen, let base = buf.baseAddress else { return nil }
        let rawBase = UnsafeRawPointer(base)
        let searchStart = rawBase.advanced(by: startOffset)
        let searchLen = count - startOffset
        guard let foundPtr = memmem(searchStart, searchLen, keyPattern.utf8Start, patLen) else {
            return nil
        }
        var idx = rawBase.distance(to: UnsafeRawPointer(foundPtr)) + patLen
        while idx < count && isASCIIWhitespace(base[idx]) {
            idx += 1
        }
        guard idx < count, base[idx] >= 0x30 && base[idx] <= 0x39 else { return nil }
        var value = 0
        while idx < count && base[idx] >= 0x30 && base[idx] <= 0x39 {
            value = value &* 10 &+ Int(base[idx] - 0x30)
            idx += 1
        }
        return value
    }

    /// Extracts a non-negative integer value immediately following `keyPattern` inside `data[startOffset...]`.
    public static func extractNonNegativeInt(
        afterKeyPattern keyPattern: StaticString,
        in data: Data,
        from startOffset: Int = 0
    ) -> Int? {
        let patLen = keyPattern.utf8CodeUnitCount
        guard startOffset >= 0, data.count > startOffset + patLen else { return nil }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int? in
            extractNonNegativeInt(
                afterKeyPattern: keyPattern,
                in: rawBuffer.bindMemory(to: UInt8.self),
                from: startOffset
            )
        }
    }

    /// Locates the byte offset of `needle` inside `buf`, or `nil` if absent.
    public static func offsetOfASCII(_ needle: StaticString, in buf: UnsafeBufferPointer<UInt8>) -> Int? {
        let needleLen = needle.utf8CodeUnitCount
        guard buf.count >= needleLen, let base = buf.baseAddress else { return nil }
        let rawBase = UnsafeRawPointer(base)
        guard let foundPtr = memmem(rawBase, buf.count, needle.utf8Start, needleLen) else {
            return nil
        }
        return rawBase.distance(to: UnsafeRawPointer(foundPtr))
    }

    /// Locates the byte offset of `needle` inside `data`, or `nil` if absent.
    public static func offsetOfASCII(_ needle: StaticString, in data: Data) -> Int? {
        let needleLen = needle.utf8CodeUnitCount
        guard data.count >= needleLen else { return nil }
        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Int? in
            offsetOfASCII(needle, in: rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    /// Parses a JSON timestamp field (`String` ISO-8601 or numeric Unix epoch seconds/milliseconds).
    public static func parseTimestamp(_ raw: Any?, fallback: Date = Date(timeIntervalSince1970: 0)) -> Date {
        if let str = raw as? String {
            return parseISO8601String(str) ?? fallback
        }
        if let num = raw as? NSNumber {
            let val = num.doubleValue
            if val > 10_000_000_000 {
                return Date(timeIntervalSince1970: val / 1000.0)
            }
            return Date(timeIntervalSince1970: val)
        }
        return fallback
    }

    /// Parses an ISO-8601 timestamp string using pure integer arithmetic on the common profile,
    /// falling back to Foundation's `ISO8601DateFormatter` for unusual variants.
    public static func parseISO8601String(_ raw: String) -> Date? {
        var utf8Str = raw
        if let fast = utf8Str.withUTF8({ parseISO8601UTF8($0) }) {
            return fast
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractional.date(from: raw) {
            return parsed
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Fast pure-integer parser for `YYYY-MM-DD[T ]HH:MM:SS[.sss...][Z|+HH:MM|-HH:MM]`.
    public static func parseISO8601UTF8(_ bytes: UnsafeBufferPointer<UInt8>) -> Date? {
        let n = bytes.count
        // Minimum length: "YYYY-MM-DDTHH:MM:SSZ" = 20 bytes
        guard n >= 20 else { return nil }
        guard
            bytes[4] == 0x2D,  // '-'
            bytes[7] == 0x2D,  // '-'
            bytes[10] == 0x54 || bytes[10] == 0x74 || bytes[10] == 0x20,  // 'T', 't', or ' '
            bytes[13] == 0x3A,  // ':'
            bytes[16] == 0x3A  // ':'
        else {
            return nil
        }

        guard
            let year = parse4Digits(bytes, at: 0),
            let month = parse2Digits(bytes, at: 5), (1...12).contains(month),
            let day = parse2Digits(bytes, at: 8), (1...31).contains(day),
            let hour = parse2Digits(bytes, at: 11), (0...23).contains(hour),
            let minute = parse2Digits(bytes, at: 14), (0...59).contains(minute),
            let second = parse2Digits(bytes, at: 17), (0...60).contains(second)
        else {
            return nil
        }

        var idx = 19
        var fractionalSeconds = 0.0
        if idx < n && (bytes[idx] == 0x2E || bytes[idx] == 0x2C) {  // '.' or ','
            idx += 1
            var scale = 0.1
            var digitCount = 0
            while idx < n && bytes[idx] >= 0x30 && bytes[idx] <= 0x39 {
                if digitCount < 9 {
                    fractionalSeconds += Double(bytes[idx] - 0x30) * scale
                    scale *= 0.1
                }
                digitCount += 1
                idx += 1
            }
            if digitCount == 0 {
                return nil
            }
        }

        var tzOffsetSeconds = 0
        if idx == n - 1 && (bytes[idx] == 0x5A || bytes[idx] == 0x7A) {
            tzOffsetSeconds = 0
        } else if idx < n && (bytes[idx] == 0x2B || bytes[idx] == 0x2D) {
            let sign = (bytes[idx] == 0x2D) ? -1 : 1
            idx += 1
            guard idx + 2 <= n, let tzHour = parse2Digits(bytes, at: idx), (0...23).contains(tzHour) else {
                return nil
            }
            idx += 2
            var tzMin = 0
            if idx < n && bytes[idx] == 0x3A {
                idx += 1
            }
            if idx + 2 == n, let parsedMin = parse2Digits(bytes, at: idx), (0...59).contains(parsedMin) {
                tzMin = parsedMin
                idx += 2
            }
            guard idx == n else { return nil }
            tzOffsetSeconds = sign * (tzHour * 3600 + tzMin * 60)
        } else {
            return nil
        }

        // Howard Hinnant's civil-to-days since 1970-01-01
        var y = year
        y -= (month <= 2) ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719_468

        let epochSeconds =
            Double(days * 86_400 + hour * 3600 + minute * 60 + second - tzOffsetSeconds) + fractionalSeconds
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Parses the cross-agent `mcp__<server>__<tool>` naming convention into `(server, tool)`.
    public static func parseMCPToolName(_ rawName: String) -> (server: String, tool: String)? {
        guard rawName.hasPrefix("mcp__") else { return nil }
        let remainder = rawName.dropFirst(5)
        guard let separatorRange = remainder.range(of: "__") else { return nil }
        let server = String(remainder[..<separatorRange.lowerBound])
        let tool = String(remainder[separatorRange.upperBound...])
        guard !server.isEmpty, !tool.isEmpty else { return nil }
        return (server, tool)
    }

    /// Coerces an untyped JSON dictionary value (`Int`, `NSNumber`, numeric `String`) into an `Int`.
    public static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int {
            return value
        }
        if let number = raw as? NSNumber {
            return number.intValue
        }
        if let str = raw as? String {
            return Int(str.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    /// Parses an embedded JSON object argument (which may already be a `[String: Any]` or a JSON-encoded `String`).
    public static func dictionaryArguments(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            return dict
        }
        if let str = raw as? String,
            str.contains("{"),
            let data = str.data(using: .utf8),
            let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        {
            return dict
        }
        return nil
    }

    @usableFromInline
    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
    }

    @inline(__always)
    private static func parse2Digits(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int? {
        let d0 = bytes[offset]
        let d1 = bytes[offset + 1]
        guard d0 >= 0x30, d0 <= 0x39, d1 >= 0x30, d1 <= 0x39 else { return nil }
        return Int(d0 - 0x30) * 10 + Int(d1 - 0x30)
    }

    @inline(__always)
    private static func parse4Digits(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> Int? {
        guard
            let hi = parse2Digits(bytes, at: offset),
            let lo = parse2Digits(bytes, at: offset + 2)
        else {
            return nil
        }
        return hi * 100 + lo
    }
}
