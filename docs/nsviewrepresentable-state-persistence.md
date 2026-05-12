# Preserving NSView State in SwiftUI with `NSViewRepresentable`

A practical guide to bridging `NSView` into SwiftUI without losing the view's
internal state across SwiftUI re-renders, tab switches, or window/sidebar
visibility changes.

---

## The Core Problem

SwiftUI views are value types. The system creates and discards them constantly
in response to state changes. `NSViewRepresentable` is itself a struct, so a
naive implementation like this will work *most* of the time but breaks in subtle
ways:

```swift
struct WebContainer: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.load(URLRequest(url: URL(string: "https://example.com")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
```

Two failure modes show up:

1. **SwiftUI tears down and recreates the host.** If the `NSViewRepresentable`
   ever gets removed from the view hierarchy (a parent's `if`/`switch`, a tab
   that lazily loads, a `NavigationStack` that pops), `makeNSView` runs again on
   re-appearance. You get a brand-new `WKWebView`, and its history, scroll
   position, JavaScript state, and form contents are gone.

2. **A SwiftUI parent rebuilds the representable struct frequently** in
   response to unrelated `@State` changes. `makeNSView` is supposed to run only
   once per host lifetime, but the *struct* is recreated every render. Anything
   you stash in a struct property is recomputed; only what's behind a
   `Coordinator` (or an external reference type) survives.

The fix in both cases is the same: own the `NSView` from a **reference type
that outlives the representable struct**, and have the representable hand that
existing instance back instead of constructing a new one.

---

## Lifecycle Recap

`NSViewRepresentable` has three relevant hooks:

| Method | When it runs | What to do |
|---|---|---|
| `makeNSView(context:)` | Once per host lifetime (a single mount cycle in SwiftUI's host). | Build or *retrieve* the `NSView`. |
| `updateNSView(_:context:)` | Every time SwiftUI thinks the representable's inputs have changed. | Push SwiftUI state *into* the `NSView`. Never recreate the view here. |
| `dismantleNSView(_:coordinator:)` (static) | When SwiftUI tears down the host. | Detach delegates, save state, etc. Avoid releasing resources you want to survive. |

Plus `makeCoordinator() -> Coordinator` for a long-lived companion object
(usually a delegate target).

The key insight: **the host's lifetime is not the same as your app's lifetime,
and not necessarily the same as your data model's lifetime.** If you want the
`NSView` to outlive the host, it has to be owned by something with a longer
lifetime than the host.

---

## Pattern 1: Own the `NSView` from an `ObservableObject`

This is the most general and most reliable pattern. The `NSView` lives inside
a model object owned by SwiftUI through `@StateObject`, and the representable
is just a thin shim.

```swift
import SwiftUI
import AppKit

final class TerminalModel: ObservableObject {
    // The NSView lives here, for the lifetime of this model object.
    let view: NSTextView

    init() {
        let scrollView = NSTextView.scrollableTextView()
        guard let tv = scrollView.documentView as? NSTextView else {
            fatalError("scrollableTextView() should yield NSTextView")
        }
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        self.view = tv
    }

    func append(_ text: String) {
        view.textStorage?.append(NSAttributedString(string: text))
    }
}

struct TerminalView: NSViewRepresentable {
    @ObservedObject var model: TerminalModel

    func makeNSView(context: Context) -> NSScrollView {
        // Return the NSScrollView that *already contains* the model's NSTextView.
        // We do NOT construct a new NSTextView here.
        return model.view.enclosingScrollView ?? NSScrollView()
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Intentionally empty. The model mutates the view directly.
        // If SwiftUI state needs to flow into the view, do it here —
        // but never replace the document view.
    }
}
```

Usage:

```swift
struct ContentView: View {
    // @StateObject — owned by this View, survives re-renders of ContentView.
    @StateObject private var terminal = TerminalModel()

    var body: some View {
        TabView {
            TerminalView(model: terminal)
                .tabItem { Label("Terminal", systemImage: "terminal") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
```

### Why this works

- The `NSTextView` is created exactly once, inside `TerminalModel.init()`.
- `TerminalModel` is held by `@StateObject`, so SwiftUI keeps it alive for the
  whole lifetime of `ContentView`'s host — even if `ContentView`'s `body` is
  re-evaluated a thousand times.
- `makeNSView` returns the *existing* view's scroll container. If the host is
  torn down and rebuilt later, the next `makeNSView` call returns the same
  instance, with its `textStorage`, selection, and scroll position intact.
- `updateNSView` doesn't destroy or replace anything.

### Important: `@StateObject` vs `@ObservedObject` at the ownership site

The model must be created with `@StateObject` at the *owning* view, not
`@ObservedObject`. `@ObservedObject` does not own the object's lifetime — if
the parent view rebuilds the child and passes a new instance, the state is
gone. The child views that consume the model can use `@ObservedObject` or
`@EnvironmentObject`.

---

## Pattern 2: Use the `Coordinator` to Cache the `NSView`

If you don't want a separate model object, you can put the `NSView` on the
`Coordinator`. SwiftUI keeps the coordinator alive for as long as the host
exists, which is shorter than `@StateObject` but longer than the representable
struct.

```swift
struct MapContainer: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        if let cached = context.coordinator.mapView {
            return cached
        }
        let map = MKMapView()
        map.delegate = context.coordinator
        context.coordinator.mapView = map
        return map
    }

    func updateNSView(_ nsView: MKMapView, context: Context) {
        // Only push values in; don't rebuild.
        if nsView.region.center.latitude  != region.center.latitude ||
           nsView.region.center.longitude != region.center.longitude {
            nsView.setRegion(region, animated: true)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var mapView: MKMapView?
    }
}
```

### When Pattern 2 is enough

The coordinator-cached `NSView` survives `body` re-evaluations and parameter
changes, but it does **not** survive the host being removed from the hierarchy
and re-added — at that point SwiftUI builds a new coordinator. If your view
is only ever shown in one place and only its inputs change, this is fine. If
it can disappear and come back, use Pattern 1.

---

## Pattern 3: External Singleton / Injected Reference

For views that are conceptually app-singletons (a long-running background
console, a single shared `WKWebView` used as a renderer, etc.), hold the
`NSView` in something even longer-lived — an `@Environment` value, a
dependency-injected service, or, last resort, a static.

```swift
final class SharedRendererStore {
    static let shared = SharedRendererStore()
    let webView: WKWebView = {
        let wv = WKWebView()
        wv.load(URLRequest(url: URL(string: "about:blank")!))
        return wv
    }()
    private init() {}
}

struct SharedRendererView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        SharedRendererStore.shared.webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { }
}
```

Singletons are a sharp tool. Use them only when there's genuinely one instance
for the whole app; otherwise prefer Pattern 1 with the model injected via
`.environmentObject(...)`.

---

## TabView, NavigationStack, and Conditional Containers

This is where most people get burned. SwiftUI's container views have different
policies about whether they keep offscreen children's hosts alive:

- **`TabView` (macOS):** typically keeps the hosts of all tabs alive once
  they've been shown, so an `@StateObject` on a tab survives switching away
  and back. But this is an implementation detail and has changed across
  releases — relying on container behavior alone is fragile.
- **`NavigationStack` / `NavigationSplitView`:** popping a destination
  destroys its host. The next push builds a new one.
- **`if`/`switch` in a parent's body:** the false branch's host is destroyed.
  When the condition becomes true again, you get a fresh host and a fresh
  `@StateObject`.

The robust fix is to **hoist ownership of the model above the container that
might destroy the host.** Put the `@StateObject` on a parent that stays in the
hierarchy, and pass it down as `@ObservedObject` or via the environment:

```swift
struct AppRoot: View {
    // Owned at the root — survives navigation, tab switching, conditional rendering.
    @StateObject private var terminal = TerminalModel()

    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            TerminalTab(model: terminal)
                .tabItem { Label("Terminal", systemImage: "terminal") }
                .tag(0)

            OtherTab()
                .tabItem { Label("Other", systemImage: "circle") }
                .tag(1)
        }
    }
}

struct TerminalTab: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        TerminalView(model: model)
    }
}
```

Now even if the tab's host is rebuilt — by SwiftUI internals, by toggling
`.id(...)`, by collapsing/expanding a sidebar that wraps the tab — the
`NSTextView` is unaffected because it's owned by `AppRoot`'s `@StateObject`.

If the model needs to be visible to many places, put it in
`.environmentObject(terminal)` on `AppRoot` and read it via
`@EnvironmentObject` deeper down.

---

## `updateNSView` Discipline

A few rules that catch most state-reset bugs:

1. **Never call `removeFromSuperview()`, replace `subviews`, or assign a new
   `documentView` in `updateNSView`.** Mutate properties in place.
2. **Guard against redundant updates.** If `updateNSView` writes back into the
   `NSView` on every SwiftUI render, you can clobber in-progress user input
   (selection, partial typing). Compare before assigning:
   ```swift
   if nsView.stringValue != text { nsView.stringValue = text }
   ```
3. **Don't reset first-responder status unconditionally.** Calling
   `window?.makeFirstResponder(nsView)` from `updateNSView` will yank focus
   away from wherever the user actually clicked.
4. **Use the `Coordinator` for delegate callbacks**, and route them back into
   SwiftUI state via the binding. Don't capture `self` from the struct in
   delegate closures — the struct is ephemeral.

---

## A Complete Example: Persisting Scroll, Selection, and Content

```swift
import SwiftUI
import AppKit

final class EditorModel: ObservableObject {
    let scrollView: NSScrollView
    let textView: NSTextView

    init(initialText: String = "") {
        let sv = NSTextView.scrollableTextView()
        let tv = sv.documentView as! NSTextView
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.string = initialText
        self.scrollView = sv
        self.textView = tv
    }
}

struct EditorView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        model.textView.delegate = context.coordinator
        return model.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // No-op: model owns content. If you needed to push external state in,
        // diff against current and assign only on change.
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let model: EditorModel
        init(model: EditorModel) { self.model = model }
        // Delegate callbacks here, updating model or notifying SwiftUI as needed.
    }
}

struct AppRoot: View {
    @StateObject private var editor = EditorModel(initialText: "Hello.\n")
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            EditorView(model: editor)
                .tabItem { Label("Editor", systemImage: "doc.text") }
                .tag(0)
            Text("Other tab")
                .tabItem { Label("Other", systemImage: "circle") }
                .tag(1)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
```

Switch tabs, type, switch away for an hour, come back — the cursor, selection,
scroll position, undo stack, and text are all where you left them, because
none of that lives in SwiftUI. SwiftUI is just renting a window into an
`NSTextView` that `AppRoot`'s `@StateObject` has been holding onto the whole
time.

---

## Quick Checklist

When state in an `NSView` is being unexpectedly reset, walk this list:

- [ ] Is `makeNSView` constructing a *new* `NSView`, or returning an existing
      one from a long-lived owner?
- [ ] Is the owner a `@StateObject` (or equivalent), not `@State` or a struct
      property?
- [ ] Is the `@StateObject` declared on a view that is itself stable in the
      hierarchy — i.e., not inside an `if` branch, lazy `NavigationStack`
      destination, or conditional tab?
- [ ] Is `updateNSView` mutating in place rather than replacing/rebuilding?
- [ ] Are delegate callbacks routed through the `Coordinator`, not closures
      capturing the struct?
- [ ] Does `dismantleNSView` avoid releasing anything you want to survive?

If all six are green, the `NSView` will persist across re-renders, parameter
changes, tab switches, navigation, and any other shuffling SwiftUI does.
