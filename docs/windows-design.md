# Windows application design

Use monochrome dark/light surfaces, precise typography and restrained blue/red accents. Icons use the Windows icon font or plain labels; project sources contain no emoji. Segoe UI handles interface text and a monospace font handles endpoints and terminal output.

Overview is the default screen. Quick connect leads, followed by real connection history, favorite hosts and open sessions. Infrastructure counts stay below connection actions. The title-bar search grows within available space.

The shared workbench tokens live in App.xaml and ThemeManager. Slate surfaces separate the navigation, canvas and elevated controls. Segoe UI Variable Text handles interface text; terminal font family, font size, line height and scrollback are persisted preferences. There are no page entrance animations or button scale animations.

The sidebar automatically collapses at compact widths and can be toggled with Ctrl+Shift+B. Its session list scrolls, truncates long titles and offers reconnect, disconnect, Files and close actions. Session state comes from the backend. Host cards and rows show transient connection status without persisting it in host metadata. The details inspector opens over the collection at compact widths and has its own close action.

Terminal tabs stay in one horizontally scrolling strip. Each workspace has one action toolbar; pane headers appear for splits. Focus outlines identify the active terminal, and separators remain resizable. xterm.js still owns rendering, input, Unicode, colors and scrollback. Resize work is coalesced per animation frame and skipped while the canvas is hidden.

Files uses two browsers at wide widths and stacks them at narrow widths. A scrolling viewport keeps both browsers and the transfer queue accessible near the minimum window size. File rows, column headers, empty folders, loading feedback, drag feedback and transfer progress share theme resources. Settings uses section anchors, a scrolling form and a pinned save action.

Host forms keep Save, Save and connect, and Cancel outside the scrollable content. Advanced options start collapsed. Validation is inline, and navigation protects unsaved changes. Empty states distinguish no configured hosts from no filter matches and disconnected file sessions.

Every advertised action must perform a real operation or explain why it is unavailable. Backend version/readiness and terminal states come from the API; guessed OS labels are identified as host-label inference. Technical diagnostics belong in Settings.

Dropdowns, file headers, dialogs and focus/selection states follow both themes. Muted labels retain contrast. Dialog inputs have accessible names and an initial focus target; caption buttons have explicit names. Reduced motion disables page transitions, Windows high-contrast colors take priority, and changes apply to open terminals.

Visual checks render dark/light hosts, the host editor and dialogs, plus every main page at 1536 x 960, 1280 x 800, 1024 x 768 and 720 x 540. Connected terminal captures use real WebView2 snapshots composited into the WPF render. The native journey verifies split input/output, reconnect, sidebar state and typography persistence. Scaled bitmap captures cover 125%, 150% and 200%. Actual Narrator, OS text scaling and display-DPI interaction remain release checks described in [windows-native.md](windows-native.md).
