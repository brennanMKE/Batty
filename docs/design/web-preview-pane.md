# Web Preview Pane — design (#0649)

**Status: drafted for user approval** (#0301 design-first gate). Implementation proceeds against this draft, as the Server Pane did; visual sign-off happens when the user checks the `resolved` issue. The mock-up is [`web-preview-pane.html`](web-preview-pane.html).

Read `docs/pane-kinds.md`, `docs/pane-view-lifecycle.md` and `docs/design/server-pane-view.md` first.

## 1. What it is

A non-terminal Pane of kind `web-preview` that shows one page from a local dev server in a `WKWebView`. It is a viewer: there are no CLI verbs to click, type into or script the page (`docs/batty-cli-design.md`, "Deliberately skip: in-app browser automation").

It is created by:

- `batty server preview --url U` or `--port N` (`http://127.0.0.1:N/`), next to the calling Pane per `--split`, else the Server Pane placement setting;
- `batty server serve <dir> --open`, below that Server Pane, when Settings › General › Server Panes › "Open served sites in" is Batty (the default);
- a Server Pane's **Open in Batty** button (any backend, while listening on an allowed URL), below that Server Pane.

The calling Pane keeps keyboard focus in every case. There is one preview per (Session, URL origin): opening the same origin again navigates the existing Pane to the new URL and shows it if hidden. It is excluded from `pane split --view` and Project slots (it needs a URL, and it is behind the `serverPane` flag, which the static `pane split` schema can't express). Save Session as Project captures it as an empty terminal slot with a note. There is no menu or Command Palette entry.

## 2. Layout

```
┌──────────────────────────────────────────────────────────┐
│ [‹] [›] [↻]  http://127.0.0.1:52144/index.html  [Browser] │  toolbar
├──────────────────────────────────────────────────────────┤
│                                                          │
│                 (the page, WKWebView)                    │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

- **Toolbar:** Back, Forward, Reload (disabled states follow the web view), the current URL (monospaced, middle-truncated, selectable) and Open in Browser.
- **Error state:** when a load fails, the page area shows the error text and a Reload button in place of the page.

## 3. Decisions and reasons

1. **A separate Pane from the Server Pane** so it can show any dev server, including terminal-backed #0648 servers, while the Server Pane's facts stay visible next to the page.
2. **Top-level navigation** is limited to `http`/`https` on `localhost`, `127.0.0.1` or `[::1]` (exact hosts) plus `about:blank`. A link the user clicks to any other `http(s)` host opens in the default browser; a script-driven top-level navigation elsewhere is cancelled and logged. `file:` is refused everywhere. `target=_blank` and `window.open` follow the same rules.
3. **Subresources and subframes** may load from any `http(s)`, `data:` or `blob:` source, so Artifact pages that load scripts from CDNs render.
4. **Data:** a non-persistent `WKWebsiteDataStore` per Pane; nothing reaches disk or is shared between Panes. Downloads are cancelled.
5. **Web Inspector** is available (`isInspectable`), as a developer viewer.
6. **Reload on change:** a preview of Batty's in-app static server subscribes to that server's change broadcaster and reloads in-process. The server never injects its reload script for the preview's `BattyPreview/1` user agent, so the preview shows the bytes as they ship and never reloads twice.
7. **Lifecycle** (`docs/pane-view-lifecycle.md`): the web view is created on the first show, so a Pane created hidden makes none. Hiding unmounts it and suspends media. Showing again reloads only when a change arrived while hidden; a Session switch otherwise keeps the page and its scroll position. Closing the Pane stops loading and releases the web view synchronously.

## 4. Focus, drops and keys

- `TerminalHostView` returns `nil` from `hitTest` where no terminal is, so clicks, scrolls and text drags reach the web view.
- Clicking into the page focuses the Pane (the web view reports `mouseDown`); clicking a terminal afterwards focuses it through `TerminalClickFocusMonitor` as before.
- A Finder file dropped on the preview is consumed by the terminal host's file-drag registration and does nothing; neighbouring terminals' drops are unchanged.
- The web view is mounted only while the Pane is active, so a hidden preview never takes clicks.
- No `.onDrop` and no gestures over the web view; decorative overlays are `.allowsHitTesting(false)`.

## 5. Accessibility identifiers

`web-preview.<paneID>`, `web-preview-url`, `web-preview-back`, `web-preview-forward`, `web-preview-reload`, `web-preview-open-browser`, `web-preview-error`, `web-preview-page`.
