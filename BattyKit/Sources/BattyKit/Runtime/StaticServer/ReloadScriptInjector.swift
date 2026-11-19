// ReloadScriptInjector.swift

import Foundation

public nonisolated enum ReloadScriptInjector {
    public static let endpoint = "/__batty/reload"
    public static let script = "<script>new EventSource(\"/__batty/reload\").onmessage=function(){location.reload()}</script>"

    /// Inserts the script before the last `</body>` (any case), or appends
    /// it when there is none.
    public static func inject(into data: Data) -> Data {
        let bytes = [UInt8](data)
        let needle = Array("</body>".utf8)
        var insertAt = bytes.count
        if bytes.count >= needle.count {
            var index = bytes.count - needle.count
            while index >= 0 {
                var matches = true
                for offset in 0..<needle.count where lowercase(bytes[index + offset]) != needle[offset] {
                    matches = false
                    break
                }
                if matches {
                    insertAt = index
                    break
                }
                index -= 1
            }
        }
        var result = Data(bytes[0..<insertAt])
        result.append(Data(script.utf8))
        result.append(Data(bytes[insertAt...]))
        return result
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }
}
