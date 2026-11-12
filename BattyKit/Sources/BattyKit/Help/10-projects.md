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

## Background

A Project can carry a terminal background. The **Background** row in the editor shows **Follows Settings** or what the Project sets, and **Edit…** opens a sheet with **Follow Settings**, **Custom for This Project** and the controls described in [Backgrounds and See-Through](11-backgrounds.md). A custom background with no image hides any image set in Settings.

Opening a Project gives its new session that background, as if you had chosen **Set Session Background…**. Saving the Project doesn't change a session that is already open. **Clear Session Background** then follows Settings, not the Project.

Each Tab card in the editor has its own **Background** row: **Follows Project** until you choose **Custom for This Tab** in its sheet. Opening the Project gives that Tab its own background, and the other Tabs follow the Project's.

If the image can't be used, the Project still opens, without the picture but with its other settings. An orange warning triangle shows on the session's row, and the editor says to choose the image again.

**Save Session as Project…** keeps the session's background and copies its image into the Project. Each Tab keeps its own background, or else its Pane's, so a Pane's background becomes the background of every Tab in it. **Update "Name"…** replaces a stored background, the Project's or a Tab's, only if it changed since the session opened. **Copy from current Session** leaves the Project's background alone and drops the Tabs' backgrounds with the Tabs it replaces.

On a Shared Project, a Tab's choice of image syncs, but not the file. Another Mac uses its own copy if it has one, or downloads the image when you open the Project or show it in the editor, and shows the Tab without the picture until it arrives. Downloaded images are kept in a cache of at most 20 images and 500 MB; the least recently used go first, but never one in use. A Background Sets image downloads in every build. Any other image needs iCloud Drive image sharing, which is in Batty Beta only for now.

## Theme

The **Theme** row in the Project Editor, above Background, shows "Follows Settings" until you choose one. **Edit…** opens a sheet with a **Dark | Light** switch: pick a theme card, or **Follow Settings**, for each appearance separately. An appearance left on Follow Settings uses the theme from Settings.

Opening the Project gives its Session that theme. **Set Session Theme…** and **Clear Session Theme** still work on that Session afterward. **Update Project** saves the Session's theme only if you changed it after opening, and **Save as Project** saves a Session's theme. **Copy from Current Session** leaves the Project's theme alone.

If the Project names a theme this version of Batty doesn't have, the editor marks it "not available" with a warning. The Session uses the Settings theme instead, and saving keeps the name.

## Shared

The **Shared** checkbox syncs a Project through iCloud to your other Macs signed into the same Apple ID. Its name, folder, color, symbol, layout, startup commands, theme and background settings sync; which Projects you opened last, which startup commands you approved and the background's image stay on each Mac, so choose the image on each Mac. The folder path must exist on each Mac, or the Project is listed with a "Folder not found" note until it does. If iCloud cannot take the Project (for example it is over iCloud's size limit), Batty says why and leaves the Project unshared.

In Batty Beta, a Shared Project's image also travels to your other Macs, through a **Batty Beta** folder in iCloud Drive. Batty copies only the image of a Project set to Shared, when you choose it or share the Project. If you turn off **Shared** or delete the Project, the other Macs keep what they have, and the copy in iCloud Drive is removed after 30 days once no Shared Project names it.

On a Mac still waiting for the image, the Project opens without the picture and the terminal is usable straight away. The Project Editor says "Waiting for" the image, with **Don't Use This Image** beside it. The picture appears when it arrives. If iCloud Drive is off, full, or not allowed in System Settings, Batty says so, and the rest of the Project still syncs.

## From the command line

`batty project list` prints your Projects, and `batty project open <name> [--new]` opens one, or focuses its session if it is open. `--new` always opens another copy. If the Project has startup commands that need your approval, the prompt appears in Batty and the command waits for your answer. See the command-line docs for the full list of verbs and exit codes.
