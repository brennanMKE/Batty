# Servers list — design (#0691)

**Status: implemented for user sign-off.** Replaces the Server Pane
(`server-pane-view.md`, #0648, superseded).

## Purpose

One place to see which dev servers Batty is tracking and copy their URLs,
without giving each server a Pane. Servers come from `batty server start`
(command in a terminal Pane), `batty server share` (a server started
elsewhere, #0692; Batty never signals it) and `batty server serve` (Batty's in-app static server, #0649).

## When the icon shows

A toolbar button (SF Symbol `server.rack`) sits after the split buttons and
before Reminders and the Bell Feed. It shows only when
`ServersToolbarVisibility.isVisible(flagOn:activeCount:alwaysShow:)` is true:
the `servers` flag is on **and** at least one server is running, or the user
turned on Settings › General › Servers › "Always show Servers in the toolbar"
(default off). A fresh install shows nothing new.

## Model

`AppStateStore.servers` is one app-wide `ServerRegistry` (not per Window).
Each `ServerEntry` keeps the #0648/#0658 machinery unchanged: listener scan,
HTTP probe, ownership checks, Stop/Restart through its `ServerBackend`. One
entry per port. An entry ticks from registration until it reaches Stopped or
Exited/Crashed with no Stop or Restart in flight; then it leaves
the registry and is torn down (`ServerEntry.onFinished`). A Restart's
intermediate Stopped step never removes it. No entries means no ticks and no
scans.

## Row anatomy

- Name: the served folder's name, else the command's program
  (`npm run dev` → `npm`), else the shared process's program, with `--name` overriding all of them, else
  "Port N".
- `127.0.0.1:<port>`, monospaced.
- State text with a tone color (Starting, Listening, Serving, Not responding,
  Stopping).
- Copy URL (`doc.on.doc`): `http://127.0.0.1:<port>/`, or the `--url` the CLI
  passed. A server bound only to `::1` answers the listener scan but not the
  probe or the copied URL.
- Copy Tailnet URL, only once #0694 sets `ServerEntry.tailnetURL`.
- A "…" menu: Open in Browser; Show Terminal (a `start` server whose Tab
  still exists); Restart and Stop only for servers Batty started (terminal
  and in-app kinds), disabled with the refusal reason as help when the
  ownership check refuses. Shared servers never offer Stop or Restart in
  the list; instead they offer Remove from List (`servers.row.unshare`,
  #0692), the GUI form of `batty server unshare`. A shared server never
  leaves the list on its own, since its process may re-bind under a file
  watcher. The issue text asked for Copy only; the menu is the orchestrator's
  addition, kept in `ServersListView` so removing it is a one-file change.
- No metrics, no expvar block: those were the Server Pane's, and the list is
  meant to stay minimal. `ServerStatsFetching` stays for #0693.

## Accessibility identifiers

`toolbar.servers`, `servers.row.<id>`, `servers.port`, `servers.state`,
`servers.copy-url`, `servers.copy-tailnet-url`, `servers.row-menu`,
`servers.row.unshare`,
`servers.empty`, `settings-always-show-servers`.

## Seams

- #0692: `server list`/`share`/`unshare` read and write `ServerRegistry`.
  `share` and `start` open a Process Status Pane (`ServerEntry.processStatusPaneID`);
  `ServerEntry.onListenerChange` retargets it when the listener's pid
  changes, and opens it for `start` on the first listener. A Pane the user
  closed is never reopened by a tick.
- `ServerRegistry.remove(id:)` is the single exit point for entries (finish,
  `unshare`, teardown); #0694 hooks its tailnet mapping removal there.
- #0693: `ServerStatsFetching` for `GET /_batty/status`; `servingFacts` for
  static entries. The row is a `VStack`, so a status line can be added below.
- #0694: `ServerEntry.tailnetURL`.
