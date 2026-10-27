# Skipper

The file manager for macOS that Apple never built. It works like Windows Explorer and adds two
independent panes, full-text search, folder sizes and a folder overview. Everything can be driven
from the keyboard.

Skipper is a single-file AppKit app (`Sources/main.swift`) with no dependencies. Its user interface
is available in English and German and follows the macOS language setting.

## Setup and build

```bash
git clone https://github.com/applirado/skipper.git && cd skipper
xcode-select --install     # only if the Command Line Tools are not installed yet
./setup.sh                 # once: pick a stable signing identity, build, install to /Applications
./build.sh --install       # afterwards: rebuild and install
```

`setup.sh` picks a stable code-signing identity and stores it in `.signing-identity`. It prefers an
existing Apple developer certificate. If there is none, it creates a self-signed "Skipper Local
Signing" certificate in the login keychain. With a stable identity, macOS remembers privacy
permissions such as access to Desktop, Documents or Downloads across builds. Without the setup,
`build.sh` signs ad hoc and macOS asks again after every build.

The app icon is drawn in `Design/AppIcon.svg`. After changing it, run `./make-icon.sh` (needs
`rsvg-convert`, `brew install librsvg`) to regenerate `Resources/AppIcon.icns`.

`build.sh --install` quits a running Skipper, replaces the copy in `/Applications` and starts it.

## Keyboard shortcuts

Ctrl and ⌘ both work for the Windows-style shortcuts.

| Action | Shortcut |
|---|---|
| Copy / cut / paste | Ctrl+C / Ctrl+X / Ctrl+V |
| Select all | Ctrl+A |
| **Copy path** | **Ctrl+Shift+C** (or ⌥⌘C) |
| Open | Enter / double-click |
| Back / forward / up | Backspace, Alt+← / Alt+→ / Alt+↑ |
| Rename | F2 |
| Move to Trash / delete permanently | Del (fn+⌫) or ⌘⌫ / Shift+Del |
| New folder (in the active pane) | ⌥⌘N or Ctrl+Shift+N |
| New window / new tab / close | Ctrl+N / Ctrl+T / Ctrl+W |
| Address bar / search | Ctrl+L or Alt+D / Ctrl+F |
| Full-text search (subfolders and contents) | Type a term, press Enter; Esc ends it |
| Refresh | F5 / Ctrl+R |
| Hidden files | Ctrl+H |
| Quick Look | Space |
| **New Skipper window from anywhere (global)** | **⌥⌘E** |
| Add selected folder to favorites | ⌃⌘T |
| Add current folder to favorites | ⌥⌘F |
| Settings (startup layout, colors) | ⌘, |
| Zoom in / out / reset (50–300 %) | ⌘+ / ⌘− / ⌘0 |
| Toggle sidebar (active pane) | ⌃⌘S |
| Toggle folder overview in the status bar (active pane) | ⌃⌘I |
| Toggle full screen | ⌥⌘↩ (also ⌥↩) |
| Left pane only / right pane only | ⌥⌘← / ⌥⌘→ |
| Both panes | ⌥⌘← and → together, or ⌥⌘S |
| Switch to the other pane | Tab |
| Focus left / right pane | ⌃⌥⌘← / ⌃⌥⌘→ |

## Features

**Two panes**
- Show one or two independent panes side by side, each with its own folder, history and search.
- Toggle with the button at the right end of the toolbar, ⌥⌘S, or the View menu.
- Hidden panes keep their folder. The split ratio is kept when the window is resized; drag the divider to change it.
- Tab or ⌃⌥⌘←/→ moves the focus between panes. After switching layouts, the file list has focus and the first entry is selected, so you never need the mouse.
- Each pane can have its own background color, set in Settings (⌘,).
- Files can be dragged between the panes.

**Navigation**
- Address bar: type or paste a path (quotes, `~` and `file://` are accepted) and press Enter. Typing `cmd` or `terminal` opens a terminal there.
- Toolbar buttons copy the current folder path and open a terminal in the current folder (also ⌥⌘T).
- Choose the terminal app by right-clicking the terminal button, or via Skipper › Terminal App. Supported: Terminal, iTerm2, Warp, Ghostty, Alacritty, kitty, WezTerm, Hyper, Tabby, and any other app via "Choose Other App…".
- Folders first, natural sorting, sortable columns, automatic refresh when the folder changes.

**Sidebar and favorites**
- Favorites appear as their own group at the top of the sidebar, above the standard locations and drives.
- Add with ⌃⌘T, ⌥⌘F, the context menu, or by dragging folders into the sidebar. Reorder by drag and drop, remove via the context menu.
- Stored in `~/Library/Application Support/Skipper/favorites.json`. The file is human-readable and can be edited by hand; changes are picked up immediately. Renamed or moved folders are found again automatically.
- The sidebar can be collapsed per pane (⌃⌘S or the button at the left end of the toolbar).

**Files**
- Context menu: copy path, copy as quoted path, copy name, open with, open in new tab, open in terminal, add to favorites.
- Cut files are dimmed. Conflicts ask to replace, keep both or skip. Pasting into the same folder creates "Name - Copy".
- Copy and paste works with Finder in both directions.
- Drag and drop: same volume moves, another volume copies, ⌥ always copies.

**Search**
- Typing filters the current folder by name.
- Enter starts a Spotlight full-text search in the current folder and all subfolders, matching file names and contents. Results show a Folder column; the context menu item "Open Enclosing Folder" jumps there. Esc or Back ends the search.
- Only files indexed by Spotlight are found.

**Folder sizes and overview**
- The Size and Files columns show the size and file count of folders, including all subfolders. They are calculated in the background and show "…" until ready. "≥" means some subfolders could not be read. F5 recalculates. Other volumes mounted below a folder are not counted.
- The folder overview at the right end of the status bar shows a colored bar with the largest file categories by size (audio, video, images, documents, code, archives, apps, other) and the total size. The tooltip lists all categories. With two or more entries selected, it summarizes the selection.

**Appearance**
- Zoom the content with ⌘+ / ⌘− / ⌘0, as in VS Code. The setting applies to all windows and is remembered.
- Date, type, size, files and folder columns size themselves to their longest entry; the name column gets the remaining space.
- Settings (⌘,) define how the first window appears: normal, maximized or full screen, with one or both panes.

## Translations

The source strings in `Sources/main.swift` are English and wrapped in `L("…")`. Translations live
in `Resources/<language>.lproj/`:

- `Localizable.strings`: one line per text, `"English text" = "Translation";`
- `Localizable.stringsdict`: plural forms for texts with a count, such as `%ld items`
- `InfoPlist.strings`: the privacy prompts from `Info.plist`

To add a language, copy `Resources/de.lproj` to `Resources/<code>.lproj`, translate the right-hand
sides and add the language code to `CFBundleLocalizations` in `Info.plist`. Keep placeholders such
as `%@` and `%ld` intact. A single app can be switched to another language under System Settings ›
General › Language & Region › Applications.
