# Projects

A **Project** is a saved recipe for a session: a name, a root folder, a session color and symbol, the pane layout and what each pane shows, and for every tab its directory and an optional startup command. Opening a Project builds that session for you in one step. Batty never captures a session into a Project on its own; you save one explicitly.

## Creating a Project

- **File ▸ Open Project ▸ New Project…** opens the Project Editor on a blank Project.
- **File ▸ Save Session as Project…** starts from the session you are looking at, capturing its layout, panes and tabs. Right-click a session in the sidebar and choose **Save as Project…** for the same thing.
- If the session was opened from a Project, the File menu and the sidebar menu also offer **Update "Name"…** to replace that Project's layout and tabs. To keep it as a separate Project instead, use **File ▸ Save Session as New Project…** or, in the sidebar menu, **Save as New Project…**.
- **File ▸ Edit Projects…** opens the Project Editor to change, reorder, or delete the Projects you have.

In the editor, set the name, the **Root folder**, the **Session color** and **Symbol**, then click panes in the layout to choose what each one shows and to add **Tabs**. **Copy from current Session** fills the layout from the session you have selected. Click **Save**, or **Save & Open** to save and open it right away.

## Opening a Project

- **File ▸ Open Project ▸ *name*** opens that Project. **Choose Project…**, below your Projects in the submenu, shows the Open a Project picker.
- The briefcase button at the bottom of the sidebar, next to `+`, opens the same picker.
- The Command Palette lists **Open Project…** and one **Open Project: *name*** row per Project.
- [Open Quickly](05-shortcuts.md) lists your Projects too (see below).

Return opens the Project as a new session, or switches to its session if one is already open. `Option-Return` opens another copy instead. In the picker, `Cmd-E` edits the highlighted Project and `Cmd-N` starts a new one.

## Open Quickly

If you have saved Projects, Open Quickly also lists them: type a Project's name and press Return to open it as a Session (or switch to it if it is already open); Option-Return opens another copy, or press Option-Return on one of its Session's Tabs.

## Startup commands

Each tab can have a **Startup command**, typed into that tab's shell once the shell is ready. When the command exits, the tab stays open at the prompt. The **Run startup commands when the Project opens** switch in the editor turns them on or off for the whole Project.

Commands run like typed input, so Batty asks first. The confirmation sheet lists every command and appears the first time you open the Project and again whenever a command changes. Choose **Run Commands** or **Open Without Running**. **Don't ask again until the commands change** is on by default, so the sheet stays away until you edit a command; turn it off to be asked every time.

If a tab's shell never reports its directory, Batty can't tell it is ready and shows an orange warning triangle on that tab instead of typing the command. Click it to **Run Now** or **Dismiss**.

## Shared

The **Shared** checkbox syncs a Project through iCloud to your other Macs signed into the same Apple ID. Its name, folder, color, symbol, layout and startup commands sync; which Projects you opened last and which startup commands you approved stay on each Mac. The folder path must exist on each Mac, or the Project is listed with a "Folder not found" note until it does. If iCloud cannot take the Project (for example it is over iCloud's size limit), Batty says why and leaves the Project unshared.

## From the command line

`batty project list` prints your Projects, and `batty project open <name> [--new]` opens one, or focuses its session if it is open. `--new` always opens another copy. If the Project has startup commands that need your approval, the prompt appears in Batty and the command waits for your answer. See the command-line docs for the full list of verbs and exit codes.
