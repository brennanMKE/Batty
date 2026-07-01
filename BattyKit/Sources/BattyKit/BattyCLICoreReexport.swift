// BattyCLICoreReexport.swift

// SessionURLBuilder moved to the dependency-free BattyCLICore target so the
// CLI can link it without pulling in Sparkle. Re-export it here so existing
// `import BattyKit` consumers keep seeing the same public API.
@_exported import BattyCLICore
