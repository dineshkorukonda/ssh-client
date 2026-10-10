# Windows application design

The Windows redesign follows the [frontend-design skill](https://github.com/anthropics/claude-code/blob/main/plugins/frontend-design/skills/frontend-design/SKILL.md) and uses Termius as a workflow reference: a compact sidebar, a searchable host library, selected-host details and persistent terminal tabs.

## Visual system

Use charcoal surfaces (`#181A20`), a darker sidebar (`#121419`), raised cards (`#22252E`), clear text (`#F1F3F8`), secondary text (`#A3AAB9`) and restrained blue focus and selection (`#5688EB`). Segoe UI Variable supplies control typography; Cascadia Code remains the terminal typeface. Borders and spacing define hierarchy without large empty frames.

The library presents saved hosts as cards and keeps connection actions in a detail pane. Favorites and search filter the same library. Open sessions appear in both the sidebar and tab strip. Switching between the library, sessions and SFTP keeps connections running. An empty library offers a direct add-host action.

## Dialogs and verification

Derived WPF windows explicitly use the application window style. This prevents the white dialog background that made the previous connection form unreadable. Inputs, dropdowns, scrolling, primary actions and keyboard focus use the same theme. Credentials are requested for the current session only.

`ssh-client.exe --design-smoke <directory>` renders the actual WPF host library at 1280 by 820 and 960 by 620, the connection form and host editor. It also asserts the derived connection dialog's dark background. The native verification script checks these images alongside real SSH terminal input/output, SFTP transfers and backend cleanup.
