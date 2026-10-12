# Windows application design

Use monochrome dark/light surfaces, precise typography and restrained blue/red accents. Icons use the Windows icon font or plain labels; project sources contain no emoji. Segoe UI handles interface text and a monospace font handles endpoints and terminal output.

Hosts is the default screen. Saved rows show the actual username and endpoint, with explicit selection and keyboard focus. The inspector is optional at compact widths. The title-bar search grows within available space, and minimum-width layouts release inspector space instead of clipping the command input.

Host forms keep Save, Save and connect, and Cancel outside the scrollable content. Advanced options start collapsed. Validation is inline, and navigation protects unsaved changes. Empty states distinguish no configured hosts from no filter matches and disconnected file sessions.

Every advertised action must perform a real operation or explain why it is unavailable. Backend version/readiness and terminal states come from the API; guessed OS labels are identified as host-label inference. Technical diagnostics belong in Settings.

Dropdowns, file headers, dialogs and focus/selection states follow both themes. Muted labels retain contrast. Dialog inputs have accessible names and an initial focus target; caption buttons have explicit names. Reduced motion disables page transitions, Windows high-contrast colors take priority, and changes apply to open terminals.

Visual checks render dark/light hosts, the host editor, settings/security, keys, Files, the compact layout and a 150% bitmap. Actual Narrator, OS text scaling and display-DPI interaction remain release checks described in [windows-native.md](windows-native.md).
