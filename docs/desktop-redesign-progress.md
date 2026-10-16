# Desktop redesign

## Direction and architecture

The native Windows application remains WPF on .NET 10. WebView2 hosts the bundled
xterm.js renderer; DesktopClient calls the existing authenticated loopback API.
OTP owns SSH, authentication, sessions, SFTP and persistence. No new UI runtime or
package dependency is needed.

Palette: canvas `#0B0D11`, navigation `#101217`, surface `#171A21`, hover
`#20242C`, rule `#2B3039`, action `#4DA3FF`. Segoe UI Variable is the interface
face; Cascadia Code/Consolas is reserved for terminal content and endpoints.
Spacing follows 4/8/12/16/24; controls use 4–6 pixel corners. Selection, status
and keyboard focus carry color; large cards and decorative badges are removed.

Layout concept:

```text
identity          search / quick connect                 window controls
navigation        session tabs / page title and actions
                  compact toolbar
open sessions     terminal canvas / host collection / preferences
status            operation feedback
```

The brief review removed the old four-card dashboard hierarchy and repeated
uppercase technical badges. Connection actions and real saved state lead the
Overview. Native caption behavior, access keys, focus rings, light theme and high
contrast remain part of the design system. The collapsible session rail and
terminal tab selection are the defining interaction, with quiet surrounding UI.

## Baseline

- Branch: feature/premium-desktop-redesign, from origin/main f8c4c3b.
- frontend-design installed using the requested npx command and read completely.
- python scripts/check.py: PASS, including 406 Elixir tests, 21 excluded,
  formatting, 12 release script tests, 13 workflow tests, 6 UI contracts.
- .NET SDK was absent from PATH. Installed official SDK 10.0.402 under the user tooling directory; no application dependencies were added.
- No supplied screenshot attachments are present in this checkout. The existing native design-smoke harness was used to inspect the redesigned UI.

## Phases

- [x] Repository and integration audit; baseline checks.
- [x] Shared resources and controls.
- [x] Shell, caption and session rail.
- [x] Terminal workspace.
- [x] Overview and Hosts.
- [x] Files, keys and preferences.
- [x] Adaptive layout and interaction verification.
- [x] Package, native journeys and screenshots.

Release Bot advances synchronized version references after merge. This feature PR
keeps the current release version and follows the existing publication pipeline.

## Verification and limits

- `python scripts/check.py`: PASS. 407 tests passed, 21 excluded. Formatting,
  release synchronization, emoji audit, 12 release tests, 13 workflow tests and
  6 WPF resource contracts passed. The baseline was 406 passed; the added test
  validates typography persistence, rejection of invalid values and old settings.
- `mix test test/integration/local_ssh_integration_test.exs --include integration`:
  PASS, 8 tests using the local SSH daemon.
- `dotnet run --project windows/tests/HostContract -c Release`: PASS. Includes
  transient host-status notification and serialization checks.
- `scripts/build_windows.ps1`: PASS. Self-contained Windows package assembled with
  its OTP runtime and signed offline WebView2 installer.
- Final native publish: PASS with warnings as errors, no build warnings/errors.
- `scripts/test_native_windows.ps1`: PASS. Real OTP fixture, WebView2 terminal
  input/output, password authentication/cancellation, host-trust rejection, key
  selection, host editing, SFTP roundtrip/queued transfers, breadcrumbs, update
  controls, preference persistence, palette and process cleanup.
- Added workbench journey: independent split output, reconnect of both panes,
  active-pane retention across navigation, sidebar collapse without session loss,
  compact details overlay, invalid line-height recovery, four-size page captures
  and scroll access to compact Files/transfer queue.
- Reviewed WPF page renders at 1536 x 960, 1280 x 800, 1024 x 768 and 720 x 540.
  Existing 125%, 150% and 200% bitmap renders pass. Terminal images use real
  WebView2 captures, not replacement terminal content.

Manual checks remain: interactive Windows snap/maximize and cross-display DPI
changes, OS text scaling/high contrast, Narrator and long-running real-world
interactive terminal applications. Automated renders do not replace these.
No production host or server configuration was used or changed. Linux/browser
presentation is outside this native Windows redesign.

## Screenshots

Overview and Hosts use explicitly labelled preview fixtures. Terminal, Files,
keys and Settings use the local SSH integration fixture; no private-key contents
are shown. All images are native WPF renders, with the terminal's real WebView2
surface composited into its frame.

- [Overview](screenshots/desktop-redesign/overview.png)
- [Hosts](screenshots/desktop-redesign/hosts.png) and [light theme](screenshots/desktop-redesign/hosts-light.png)
- [Split terminal](screenshots/desktop-redesign/session.png)
- [Files](screenshots/desktop-redesign/sftp.png)
- [SSH identities](screenshots/desktop-redesign/keys.png)
- [Settings](screenshots/desktop-redesign/settings.png)
- [Minimum terminal](screenshots/desktop-redesign/terminal-minimum.png)
- [Minimum Files, scrolled to remote/queue](screenshots/desktop-redesign/files-minimum-scrolled.png)

## Changed implementation files

- Shared resources: `windows/native/App.xaml`, `ThemeManager.cs`.
- Shell, pages and commands: `MainWindow.xaml`, `MainWindow.xaml.cs`,
  `MainWindow.Design.cs`, `MainWindow.Accessibility.cs`, `MainWindow.Productivity.cs`.
- Terminal and sessions: `TerminalView.cs`, `TerminalTabItem.cs`,
  `terminal/terminal.js`, `terminal/terminal.css`.
- Host/file presentation: `Host.cs`, `FileEntry.cs`, `SftpPane.cs`.
- Preferences API: `lib/ssh_client/desktop.ex`,
  `lib/ssh_client_web/desktop_api.ex`.
- Verification: `windows/native/App.xaml.cs`, `MainWindow.VisualSmoke.cs`,
  `windows/tests/HostContract/Program.cs`, `scripts/test_native_windows.ps1`,
  `test/ssh_client_web/desktop_api_test.exs`.
- Documentation: this report, `docs/windows-design.md`, `docs/windows-native.md`,
  and the screenshot directory.
- Installed skill: `.agents/skills/frontend-design/SKILL.md`, its license,
  and `skills-lock.json`.
