// BattyXPCCoreReexport.swift

// The shared XPC contract lives in the dependency-free BattyXPCCore target
// so the broker agent (#0270) can link it without pulling in Sparkle.
// Re-export it here so existing `import BattyKit` consumers (the app,
// BattyKitTests) see the same public API.
@_exported import BattyXPCCore
