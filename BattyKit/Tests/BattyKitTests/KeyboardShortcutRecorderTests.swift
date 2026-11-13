// KeyboardShortcutRecorderTests.swift

import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import BattyKit

@MainActor
private final class Box {
    var value: ShortcutBinding
    init(_ value: ShortcutBinding) { self.value = value }
    var binding: Binding<ShortcutBinding> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

@MainActor
struct KeyboardShortcutRecorderTests {
    private static let start = ShortcutBinding(key: "k", modifiers: EventModifiers.command.rawValue)
    private static let rightArrow = ShortcutBinding(
        key: ShortcutBinding.SpecialKey.rightArrow.rawValue,
        modifiers: EventModifiers.command.rawValue
    )

    private func host(_ box: Box) -> (NSWindow, NSHostingView<KeyboardShortcutRecorder>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let hosting = NSHostingView(rootView: KeyboardShortcutRecorder(binding: box.binding))
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func recorder(in view: NSView) -> RecorderView? {
        if let found = view as? RecorderView { return found }
        for sub in view.subviews { if let found = recorder(in: sub) { return found } }
        return nil
    }

    private func commitRightArrow(in window: NSWindow, hosting: NSView) throws {
        let recorder = try #require(recorder(in: hosting))
        window.makeFirstResponder(recorder)
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_RightArrow)
        ))
        recorder.keyDown(with: event)
    }

    @Test func committingAShortcutWritesTheBindingSynchronously() throws {
        let box = Box(Self.start)
        let (window, hosting) = host(box)
        try commitRightArrow(in: window, hosting: hosting)
        #expect(box.value == Self.rightArrow)
    }

    @Test func aRebindingAfterUpdateCommitsToTheNewBinding() throws {
        let a = Box(Self.start), b = Box(Self.start)
        let (window, hosting) = host(a)
        hosting.rootView = KeyboardShortcutRecorder(binding: b.binding)
        hosting.layoutSubtreeIfNeeded()
        try commitRightArrow(in: window, hosting: hosting)
        #expect(b.value == Self.rightArrow)
        #expect(a.value == Self.start)
    }
}
