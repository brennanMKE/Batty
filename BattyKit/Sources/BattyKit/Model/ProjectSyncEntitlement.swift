// ProjectSyncEntitlement.swift

import Foundation
import Security

/// Whether the running binary was signed with the iCloud key-value-storage
/// entitlement. Builds without a provisioning profile omit it, and a store
/// built without it would only log errors.
public enum ProjectSyncEntitlement {
    nonisolated public static let key = "com.apple.developer.ubiquity-kvstore-identifier"

    /// True in a process running tests: the environment names a test
    /// configuration, or the XCTest framework is loaded. Either signal is enough.
    nonisolated public static func isTestProcess() -> Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    nonisolated public static func isPresent() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) else { return false }
        return (value as? String).map { !$0.isEmpty } ?? false
    }
}
