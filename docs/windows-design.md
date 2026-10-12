# Windows application design

The Windows native client interface follows the [frontend-design skill](https://github.com/anthropics/claude-code/blob/main/plugins/frontend-design/skills/frontend-design/SKILL.md) and adopts a minimalist **shadcn / DaisyUI** aesthetic: a pure black theme (`#000000` / `#09090B`), crisp zinc borders (`#27272A`), high-contrast typography, a full-page Add/Edit Host flow, and integrated SFTP with terminal split panes.

## Visual system and desktop chrome

- **Shadcn neutral dark theme**: Pure black background (`#000000`), dark zinc card surfaces (`#09090B`), subtle zinc-800 borders (`#27272A`), crisp white headers (`#FAFAFA`), and muted text (`#A1A1AA`).
- **Clean typography**: Strict Segoe UI Variable hierarchy for UI controls; Cascadia Code for terminal output and connection hostnames. All legacy `>_` logo boxes and glyph emblems have been removed for an uncluttered, modern look.
- **Titlebar command bar (`Ctrl+K`)**: Centered Omnibar with keyboard shortcut badge (`Ctrl K`) supporting instant ad-hoc connections (`user@host:port`) and dynamic host filtering. Caption controls use native Segoe Fluent Icons (`\uE921`, `\uE922` / `\uE923`, `\uE8BB`) with Windows red hover state on Close.
- **Focused sidebar**: Streamlined to essentials (`Hosts`, `Favorites`, `Open sessions`, and `Settings`). Unnecessary workspace and vault cards have been eliminated.
- **Dedicated Add / Edit Host page**: Replaced modal popup dialogs with a full-page, sectioned form (Server Details, Authentication, and Advanced Organization) with one-click navigation back to the host library.
- **Integrated SFTP & split panes**: Embedded side-by-side SFTP file browser with Windows Explorer drag-and-drop file upload, plus multi-terminal split views (`◫ Split Right`).

## Verification and Smoke Testing

`ssh-client.exe --design-smoke <directory>` renders and asserts the actual WPF interface:
- `hosts.png`: 1280 × 820 main library in shadcn theme
- `hosts-compact.png`: 960 × 620 compact responsive layout
- `add-host-page.png`: Full-page Add/Edit host editor
- `connection.png` & `host-editor.png`: Dark-surface dialog forms
