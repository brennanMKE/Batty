// GhosttySmoke.swift

import BattyKit

@MainActor
enum GhosttySmoke {
    static let configNew: @convention(c) () -> ghostty_config_t? = ghostty_config_new
}
