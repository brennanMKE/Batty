// HTTPRequestHead.swift

import Foundation

public nonisolated enum HTTPParseError: Error, Equatable, Sendable {
    case incomplete
    case malformed
    case tooLarge
}

/// The request line and headers of one HTTP/1.x request. Header names are
/// stored lowercased.
public nonisolated struct HTTPRequestHead: Equatable, Sendable {
    public static let maximumSize = 16 * 1024

    public let method: String
    public let target: String
    public let version: String
    public let headers: [String: String]

    public func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    public static func parse(_ data: Data) -> Result<HTTPRequestHead, HTTPParseError> {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: terminator) else {
            return .failure(data.count > maximumSize ? .tooLarge : .incomplete)
        }
        let headData = data[data.startIndex..<end.lowerBound]
        if headData.count + terminator.count > maximumSize { return .failure(.tooLarge) }
        if headData.contains(0) { return .failure(.malformed) }
        guard let text = String(data: headData, encoding: .utf8) else { return .failure(.malformed) }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3,
              !requestLine[0].isEmpty, !requestLine[1].isEmpty,
              requestLine[2].hasPrefix("HTTP/1.") else { return .failure(.malformed) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .failure(.malformed) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .failure(.malformed) }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return .success(HTTPRequestHead(
            method: String(requestLine[0]), target: String(requestLine[1]), version: String(requestLine[2]), headers: headers))
    }
}
