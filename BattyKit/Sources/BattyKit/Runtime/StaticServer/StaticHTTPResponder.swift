// StaticHTTPResponder.swift

import Foundation

public nonisolated struct StaticResponderOptions: Sendable {
    public var port: UInt16
    public var injectsReloadScript: Bool

    public init(port: UInt16, injectsReloadScript: Bool) {
        self.port = port
        self.injectsReloadScript = injectsReloadScript
    }
}

public nonisolated struct StaticResponse: Sendable {
    public enum Kind: Sendable { case complete, eventStream }

    public var status: Int
    public var headers: [(String, String)]
    public var body: Data
    public var kind: Kind = .complete

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public var serializedHead: Data {
        var text = "HTTP/1.1 \(status) \(StaticHTTPResponder.reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Turns one parsed request into a response. Pure apart from reading the
/// resolved file.
public nonisolated enum StaticHTTPResponder {
    public static func respond(to head: HTTPRequestHead, resolver: StaticFilePathResolver, options: StaticResponderOptions) -> StaticResponse {
        guard head.method == "GET" || head.method == "HEAD" else {
            var response = simple(405)
            response.headers.append(("Allow", "GET, HEAD"))
            return response
        }
        guard isAllowedHost(head.header("host"), port: options.port) else { return simple(403) }
        let isHead = head.method == "HEAD"

        if StaticFilePathResolver.rawPath(of: head.target) == ReloadScriptInjector.endpoint {
            guard !isHead else { return simple(200) }
            return StaticResponse(
                status: 200,
                headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff")],
                body: Data(": connected\n\n".utf8),
                kind: .eventStream)
        }

        let injects = options.injectsReloadScript
        var response: StaticResponse
        switch resolver.resolve(target: head.target) {
        case .forbidden:
            response = simple(403)
        case .notFound, .reserved:
            response = simple(404)
        case .redirect(let location):
            response = simple(301)
            response.headers.append(("Location", location))
        case .listing(let directory, let relativePath):
            var body = StaticDirectoryListing.html(for: directory, relativePath: relativePath)
            if injects { body = ReloadScriptInjector.inject(into: body) }
            response = make(200, type: "text/html; charset=utf-8", body: body)
        case .file(let url):
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return simple(404) }
            let type = StaticFileMIMEType.mimeType(forPathExtension: url.pathExtension)
            if injects, StaticFileMIMEType.isHTML(type) {
                response = make(200, type: type, body: ReloadScriptInjector.inject(into: data))
            } else {
                switch ByteRange.parse(header: head.header("range"), size: data.count) {
                case .full:
                    response = make(200, type: type, body: data)
                case .partial(let range):
                    response = make(206, type: type, body: data.subdata(in: range.lowerBound..<(range.upperBound + 1)))
                    response.headers.append(("Content-Range", "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)"))
                case .unsatisfiable:
                    response = simple(416)
                    response.headers.append(("Content-Range", "bytes */\(data.count)"))
                }
                response.headers.append(("Accept-Ranges", "bytes"))
            }
        }
        if isHead { response.body = Data() }
        return response
    }

    public static func isAllowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"].contains(host)
    }

    public static func simple(_ status: Int) -> StaticResponse {
        make(status, type: "text/plain; charset=utf-8", body: Data("\(status) \(reason(status))\n".utf8))
    }

    static func make(_ status: Int, type: String, body: Data) -> StaticResponse {
        StaticResponse(status: status, headers: [
            ("Content-Type", type),
            ("Content-Length", String(body.count)),
            ("Cache-Control", "no-store"),
            ("X-Content-Type-Options", "nosniff"),
            ("Connection", "close"),
        ], body: body)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 301: "Moved Permanently"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 416: "Range Not Satisfiable"
        case 431: "Request Header Fields Too Large"
        default: "Error"
        }
    }
}
