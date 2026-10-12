# Windows UX audit merge order

All PRs remain unmerged for the repository owner. The release infrastructure is independent; the Windows fixes form a dependency stack.

| Order | PR | Scope | Issues |
| --- | --- | --- | --- |
| 1 | [231](https://github.com/dineshkorukonda/ssh-client/pull/231) | Complete multi-platform release pipeline | 223 |
| 2 | [225](https://github.com/dineshkorukonda/ssh-client/pull/225) | Host address contract and stack CI | 202 |
| 3 | [226](https://github.com/dineshkorukonda/ssh-client/pull/226) | Real identities and authentication | 203, 204, 207, 208 |
| 4 | [227](https://github.com/dineshkorukonda/ssh-client/pull/227) | Terminal actions and session lifetime | 205, 211 |
| 5 | [228](https://github.com/dineshkorukonda/ssh-client/pull/228) | Integrated Files and transfer queue | 206, 220 |
| 6 | [229](https://github.com/dineshkorukonda/ssh-client/pull/229) | Forms, search, preferences, recovery and workspaces | 209, 210, 212, 213, 218, 221 |
| 7 | [230](https://github.com/dineshkorukonda/ssh-client/pull/230) | Compact layout, themes, accessibility and truthful status | 214, 215, 216, 217, 222 |
| 8 | [232](https://github.com/dineshkorukonda/ssh-client/pull/232) | User journeys, source checks and docs | 219, 223 |

After each parent is merged, retarget the next Windows PR to `main` and rebase its branch on the latest `origin/main`. The Release Bot changes version references after merges, so do not replay an older release bump. Re-run checks, resolve conflicts and wait for the post-merge CI/Release Bot before advancing. Do not delete branches until their release workflows succeed. No PR in this batch authorizes an agent to merge on the owner's behalf.

The final validation PR documents manual release checks that automation does not prove, including Narrator, live Windows DPI, clean-machine installation, sleep/resume and signing.
