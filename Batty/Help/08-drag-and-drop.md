# Drag and Drop

Drag a file from Finder onto a terminal in Batty and its path gets typed in for you. Useful when a command wants a path you'd rather not retype.

## What you can drop

Files and folders. Anything that produces a file URL works — Finder, the Open dialog, the path bar at the top of a Finder window, recent items, search results.

## What happens when you drop

A single file: the path is inserted at the cursor, wrapped in single quotes so spaces and special characters survive the shell. The cursor lands after the closing quote with a trailing space, ready for whatever you type next.

Multiple files at once: each path is quoted the same way and they're joined with spaces into a single inserted string. Batty quotes the paths automatically so you don't have to escape anything.

## The visual cue

As you drag over a pane, an accent-colored border lights up around the terminal area. That border is your confirmation: let go and the drop takes. No border, no drop.

The target is always the **active tab in the focused pane**. Inactive tabs and other panes ignore the drag. Switch tabs or click into the pane you want before dragging.

## In practice

Drag `/Users/you/Pictures/My Photo.png` and you'll see:

```
'/Users/you/Pictures/My Photo.png' 
```

Drop three files at once:

```
'/Users/you/one.txt' '/Users/you/two.txt' '/Users/you/three.txt' 
```

Now type `cp `, `mv `, or `ls -l ` in front of the inserted paths, press Return, and you're done.

## What v1 doesn't do

- Dropping on a non-active tab's area to bring it forward — switch tabs first.
- Dropping plain text or other non-file content — only file URLs are accepted.
- Dropping a folder onto a "cd here" affordance to start a new tab or pane in that directory.
- Dragging a tab chip between panes or sessions.

These may show up later. For now: drop a file URL onto the focused pane's active tab and Batty types the quoted path.

See [Tabs](04-tabs.md) and [Panes and Splits](03-panes.md) for how focus works.
