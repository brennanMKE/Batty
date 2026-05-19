# Terminal pane requirements

Non-negotiable behaviors that every pane must preserve, regardless of what
other features are added on top. These exist because the terminal inside each
pane is a live `ghostty_surface_t` (a real PTY + GPU-rendered AppKit NSView)
with rich input/output capabilities that go well beyond what a plain SwiftUI
view supports. Any work that adds new gestures, overlays, or event handlers to
the pane area **must** be verified against every item in this list.

Read `view-hierarchy.md` first. The hybrid SwiftUI / AppKit architecture is
the reason these requirements are non-trivial to satisfy simultaneously.

---

## 1. Pointer input

| Requirement | Why |
|---|---|
| **Left-click focuses the pane and routes the click to the terminal** | Ghostty uses the click to position the cursor, set focus for keyboard input, and fire xterm mouse-reporting sequences if the running program requests them. |
| **Right-click inside the terminal opens the system context menu** (or routes to Ghostty's context handler) | Some programs (e.g. vim) intercept right-click for their own menus via mouse-reporting. |
| **Mouse drag inside the terminal selects text** | Ghostty handles selection natively; the NSView's drag handling must not be preempted. |
| **Scroll wheel scrolls the terminal buffer** | Ghostty owns scrollback; SwiftUI scroll containers must not sit between the wheel event and the NSView. |

**Regression pattern:** Any transparent SwiftUI view with `.contentShape` placed above the terminal NSView will absorb pointer events before Ghostty sees them. See issues #0143 and the two failed fix attempts documented there.

---

## 2. Keyboard input

| Requirement | Why |
|---|---|
| **All keystrokes are forwarded to the focused terminal** | Ghostty handles every key event — including modifier-only keys, dead keys, IME composition, and control sequences — through `keyDown` on the NSView. Intercepting or swallowing key events breaks running programs. |
| **Cmd-C / Cmd-V use Ghostty's copy-paste implementation** | Ghostty integrates with the system pasteboard for both plain text and rich terminal content. These should not be intercepted by SwiftUI gesture recognizers. |
| **IME (CJK input methods) work correctly** | Ghostty implements `NSTextInputClient` on the terminal NSView. The view must remain the first responder for text input; SwiftUI focus must not redirect the first responder away during composition. |

---

## 3. Drag and drop onto the terminal

The terminal NSView registers as an AppKit `NSDraggingDestination`. Ghostty handles drops natively. **These must not be blocked by any Batty overlay.**

| Drag type | Behavior |
|---|---|
| **Files / folders from Finder** | Ghostty converts the file paths to shell-escaped strings and sends them to the PTY as if typed. The user drops a file, its path appears at the prompt. |
| **Text from any app** | Pasted into the terminal as if typed. |
| **Images** | Ghostty may render them inline (sixel / iTerm2 protocol) or forward as path, depending on the program. |

**Regression pattern:** Any SwiftUI `.onDrop` or AppKit `NSDraggingDestination` registered on a view that sits **above** the terminal NSView in AppKit's z-order will claim the drag session before Ghostty's NSView sees it — even if the registered UTTypes don't include the dragged type. SwiftUI's `.onDrop` in particular registers its backing NSView broadly at the AppKit level; the declared Swift UTType filter is applied after the drag session is claimed. This is the mechanism that broke file drops in issues #0143 attempts 1 and 2.

---

## 4. Pane chrome overlays

Batty adds its own overlays on top of the terminal:

| Overlay | What it must NOT do |
|---|---|
| Focus border (accent stroke) | Must use `.allowsHitTesting(false)` — already correct. |
| Bell flash border | Must use `.allowsHitTesting(false)` — already correct. |
| File-drop highlight (`isDragHovering` stroke) | Must use `.allowsHitTesting(false)` — already correct. |
| **Pane-swap drop target (#0127)** | Must not claim drags of types other than its own UUID string; must not absorb pointer events; see #0143 for the unsolved problem. |

**Rule:** Every overlay added to the pane body must carry `.allowsHitTesting(false)` unless it has an explicit, tested reason to receive input. A view that receives input must be proven not to intercept any of the events in sections 1–3 above.

---

## 5. The AppKit z-order constraint

The terminal NSView is placed by `TerminalHostStore` directly into the window's AppKit layer — it is **not** a child of any SwiftUI `NSViewRepresentable`. This means:

- SwiftUI rendering order (ZStack, `.overlay`, `.background`) does **not** determine which AppKit view is on top.
- The terminal NSView's position in the AppKit z-order is set by when `TerminalHostStore` adds it relative to SwiftUI's container NSViews.
- A SwiftUI `.overlay` is rendered by SwiftUI's own NSView container, which may be **below** the terminal NSView in AppKit's z-order even though it renders on top visually.

**Consequence for drag and drop:** AppKit's drag routing (`NSDraggingDestination` dispatch) follows AppKit's z-order, not SwiftUI's visual z-order. A SwiftUI overlay that appears visually on top of the terminal may still receive drags **before** the terminal NSView only if its backing NSView is actually above the terminal NSView in AppKit's subview list — which is not guaranteed and depends on insertion order.

Any feature that needs to intercept drag events above the terminal NSView must do so at the AppKit level (a custom `NSView` subclass registered as `NSDraggingDestination`) with explicit type filtering at the AppKit level (not in a Swift closure) so that non-matching drag types fall through cleanly.

---

## 6. Checklist for pane-area feature work

Before marking a pane-area feature complete, manually verify:

- [ ] Clicking inside the terminal focuses it and routes the click (text cursor moves, mouse-reporting programs respond).
- [ ] Dragging text inside the terminal selects it.
- [ ] Scroll wheel scrolls the buffer.
- [ ] Dropping a file from Finder onto the terminal inserts its path at the prompt.
- [ ] Dropping text onto the terminal pastes it.
- [ ] The keyboard types characters into the focused terminal.
- [ ] IME input (e.g. Japanese kana) composes correctly.
- [ ] The new feature's own behavior (highlight, gesture, etc.) still works.
