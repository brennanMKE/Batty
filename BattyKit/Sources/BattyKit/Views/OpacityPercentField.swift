// OpacityPercentField.swift

import AppKit
import SwiftUI

/// Opacity is stored from 0 to 1 and shown as a whole percent, as Terminal.app
/// does.
nonisolated enum OpacityPercent {
    static func text(for value: Double) -> String {
        String(wholePercent(of: value))
    }

    /// The value after `text` is committed. Stays `current` for text that isn't
    /// a number, and for text naming the percent already shown, so committing
    /// an untouched field can't round a stored value such as 0.355.
    static func value(afterCommitting text: String, current: Double) -> Double {
        guard let typed = typedPercent(in: text), typed != wholePercent(of: current) else { return current }
        return Double(typed) / 100
    }

    private static func wholePercent(of value: Double) -> Int {
        value.isNaN ? 0 : Int((min(max(value, 0), 1) * 100).rounded())
    }

    /// The character check also keeps out `nan`, `inf` and hex, which `Double`
    /// parses.
    private static func typedPercent(in text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard trimmed.allSatisfy({ "0123456789.+-".contains($0) }), let parsed = Double(trimmed) else { return nil }
        return Int(min(max(parsed, 0), 100).rounded())
    }
}

/// An AppKit field because `TextField(value:format:)` writes its binding on
/// every keystroke (measured on macOS 27), so typing 37 would apply 3% and then
/// 37%, each a config push to every Tab. Here a value applies only on Return, at
/// the end of editing, or when the field's window stops being key.
struct OpacityPercentField: NSViewRepresentable {
    let value: Double
    let label: String
    let identifier: String
    let onCommit: (Double) -> Void

    func makeCoordinator() -> OpacityPercentFieldCoordinator {
        OpacityPercentFieldCoordinator(value: value, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = OpacityPercentFieldCoordinator.makeField(delegate: context.coordinator)
        field.setAccessibilityLabel(label)
        field.setAccessibilityIdentifier(identifier)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.render(value, in: field)
        context.coordinator.setEnabled(context.environment.isEnabled, on: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// `updateNSView` can run inside AppKit's layout pass, where dirtying
/// constraints raises an exception, so the field's size never depends on its
/// text.
private final class FixedSizeTextField: NSTextField {
    private static let width: CGFloat = 44

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width, height: cell?.cellSize.height ?? NSView.noIntrinsicMetric)
    }

    override func invalidateIntrinsicContentSize() {}
}

final class OpacityPercentFieldCoordinator: NSObject, NSTextFieldDelegate {
    var onCommit: (Double) -> Void

    private var value: Double
    private var shownText: String
    private var hasDraft = false
    private var wantsEnabled = true
    private(set) weak var observedWindow: NSWindow?
    private weak var editedField: NSTextField?

    init(value: Double, onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.onCommit = onCommit
        self.shownText = OpacityPercent.text(for: value)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    static func makeField(delegate: OpacityPercentFieldCoordinator) -> NSTextField {
        let field = FixedSizeTextField(string: delegate.shownText)
        field.alignment = .right
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.delegate = delegate
        return field
    }

    /// While the field is being edited this writes the field editor's text,
    /// because setting `stringValue` would abort editing, which changes the
    /// responder. A new value, such as a slider drag, replaces a draft: it is
    /// the later intent.
    func render(_ newValue: Double, in field: NSTextField) {
        value = newValue
        let text = OpacityPercent.text(for: newValue)
        guard text != shownText else { return }
        hasDraft = false
        show(text, in: field)
    }

    /// Disabling a field that is being edited aborts the editing, which changes
    /// the responder, so that waits for a fresh turn instead of running inside
    /// a view update.
    func setEnabled(_ enabled: Bool, on field: NSTextField) {
        wantsEnabled = enabled
        guard field.isEnabled != enabled else { return }
        guard field.currentEditor() != nil else {
            field.isEnabled = enabled
            return
        }
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, field.isEnabled != self.wantsEnabled else { return }
            field.isEnabled = self.wantsEnabled
            // Aborted editing sends no end notification.
            self.stopObservingWindow()
            self.hasDraft = false
            self.show(self.shownText, in: field)
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        observeWindow(of: field)
    }

    func controlTextDidChange(_ notification: Notification) {
        hasDraft = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        stopObservingWindow()
        commit(field.stringValue)
        // The field editor is still attached here, but what's written to it
        // no longer reaches the field, so the redisplay goes to the field.
        shownText = OpacityPercent.text(for: value)
        field.stringValue = shownText
    }

    /// Return commits here and stops, so it can't also press a sheet's default
    /// button.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)),
              let field = control as? NSTextField
        else { return false }
        applyDraft(from: textView, in: field)
        return true
    }

    /// Clicking another window or closing this one doesn't end editing, so the
    /// draft would stay on screen, not in effect, until focus next moved. Editing
    /// carries on: no responder changes for the window becoming key to react to.
    @objc private func windowDidResignKey(_ notification: Notification) {
        guard hasDraft, let field = editedField, let editor = field.currentEditor() as? NSTextView else { return }
        applyDraft(from: editor, in: field)
    }

    private func applyDraft(from editor: NSTextView, in field: NSTextField) {
        commit(editor.string)
        show(OpacityPercent.text(for: value), in: field)
        editor.selectAll(nil)
    }

    private func observeWindow(of field: NSTextField) {
        stopObservingWindow()
        guard let window = field.window else { return }
        editedField = field
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResignKey(_:)),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
    }

    private func stopObservingWindow() {
        editedField = nil
        observedWindow = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    /// Every caller redisplays afterwards: typing 150 at 100% changes no stored
    /// value, so no view update would replace the text.
    private func commit(_ text: String) {
        guard hasDraft else { return }
        hasDraft = false
        let next = OpacityPercent.value(afterCommitting: text, current: value)
        guard next != value else { return }
        value = next
        onCommit(next)
    }

    private func show(_ text: String, in field: NSTextField) {
        shownText = text
        if let editor = field.currentEditor() as? NSTextView {
            editor.string = text
        } else {
            field.stringValue = text
        }
    }
}
