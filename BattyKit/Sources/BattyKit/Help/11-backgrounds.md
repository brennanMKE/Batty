# Backgrounds and See-Through

A terminal can show a picture behind its text, let the desktop and other windows show through, or both. Turn the image and the terminal down together to tint a picture and still see what is behind it. Both are off until you set them.

## Where to set a background

There are three levels, and the most specific one wins.

1. **Pane:** the gear on a Pane's row in the sidebar, beside the eye. Expand a session's Pane list to see it. The gear is filled in while the Pane has its own background. Only terminal Panes have one.
2. **Session:** right-click a session and choose **Set Session Background…**. **Clear Session Background** removes it.
3. **Everywhere else:** the **Background** section of **Settings → Appearance** (`Cmd-,`). **Restore Defaults** turns it off.

A Pane or Session with no background of its own shows **Follow App Default** selected (**Follow Session** for a Pane whose session has its own background). Choose **Custom for This Pane** or **Custom for This Session** to set values. Changes apply as you make them, so the terminal is your preview. **Cancel** puts back what was there, and **Done** keeps it.

A custom background is complete, so it ignores later changes to the levels above it. A Pane's background covers all its Tabs, including new ones, and a new split starts out following instead of copying it. A Session's background reaches every terminal Pane in the session, including later ones, except a Pane with its own.

Pane and Session backgrounds aren't saved. They end when you quit Batty, and **Duplicate Session** doesn't copy them. The Settings background is saved. To keep one with a session, save the session as a [Project](10-projects.md).

## The controls

- **Image:** **Choose…** opens your images, and **Add from File…** there brings in a PNG or JPEG. **None** removes it. Animation isn't supported. Batty keeps its own copy, scaled down if its longest side is over 4096 pixels, so moving your file changes nothing. The first image you choose starts at 15% **Image Opacity**, as a tint.
- **Image Size:** **Fit** shows the whole image and can leave empty space. **Fill**, the default, covers the Pane, keeps the image's proportions and crops what overflows. **Stretch** covers the Pane and distorts the image to its shape. **Actual Size** draws the image unscaled.
- **Position:** where the image sits.
- **Image Opacity:** relative to **Terminal Opacity**.
- **Terminal Opacity:** below 100%, the desktop and other windows show through.
- **Include programs that paint their own background:** programs such as vim or htop that paint their own colors stay opaque unless you turn this on. It is available below 100%.

Each Pane draws its own copy of the image, so one picture doesn't span a split, and each Tab keeps its own copy in memory.

## Background Images

**File → Background Images…**, or **Manage Images…** in Settings' Background section, opens a window showing every image Batty holds, with a thumbnail, what uses it and its size. **Add from File…** brings in a new one. Images stay until you remove them.

**Remove…** lists what uses the image and asks first. Those uses then have no image, and keep their other settings: terminals lose the picture right away, Settings shows **None**, and a Project opens with no picture. A Shared Project changes on this Mac only. If Batty can't read all your saved Projects, it removes nothing and says why.

If Batty's copy of the image in Settings goes missing or changes, terminals open with no picture and Settings asks you to choose it again.

## Background Sets

**Background Sets**, at the top of the Background Images window and of every **Choose…** sheet, shows sets of pictures from the Batty website, using thumbnails only.

- Nothing is fetched until you first open **Background Sets**.
- Choosing a picture as a background downloads it once. The sheet stays open while it downloads, and your old background stays until it finishes. Click the picture again to stop the download, or click another to download that one instead. After that the picture works offline.
- Pictures from Background Sets stay in their sets and don't appear under **My Images**.
- Offline, Background Sets shows the last copy it saw.
- A picture the website drops keeps working wherever you use it.

## See-through windows

While any terminal Pane in any session of a window is below 100% **Terminal Opacity**, that window lets the desktop and other apps show through those terminals.

- A Pane at 100% stays solid, and so do the sidebar, title bar, tab bars and dividers.
- Native full screen is always opaque.
- Each window decides for itself.
- There is no blur, so what is behind the window stays sharp.

In Batty Beta, the only background image copied to iCloud Drive is the one on a Shared [Project](10-projects.md). Images in the library, on a Pane or Session, in Settings or on a local Project stay on this Mac.
