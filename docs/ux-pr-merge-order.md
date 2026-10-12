# Windows UX audit PR history

The original audit PRs are merged. PRs 225 and 231 reached `main` directly; PRs 226–230 and 232 were merged into feature branches. Their remaining changes are recovered together in a PR targeting `main`.

| Original order | PR | Scope | Issues |
| --- | --- | --- | --- |
| 1 | [231](https://github.com/dineshkorukonda/ssh-client/pull/231) | Complete multi-platform release pipeline | 223 |
| 2 | [225](https://github.com/dineshkorukonda/ssh-client/pull/225) | Host address contract and branch CI | 202 |
| 3 | [226](https://github.com/dineshkorukonda/ssh-client/pull/226) | Real identities and authentication | 203, 204, 207, 208 |
| 4 | [227](https://github.com/dineshkorukonda/ssh-client/pull/227) | Terminal actions and session lifetime | 205, 211 |
| 5 | [228](https://github.com/dineshkorukonda/ssh-client/pull/228) | Integrated Files and transfer queue | 206, 220 |
| 6 | [229](https://github.com/dineshkorukonda/ssh-client/pull/229) | Forms, search, preferences, recovery and workspaces | 209, 210, 212, 213, 218, 221 |
| 7 | [230](https://github.com/dineshkorukonda/ssh-client/pull/230) | Compact layout, themes, accessibility and truthful status | 214, 215, 216, 217, 222 |
| 8 | [232](https://github.com/dineshkorukonda/ssh-client/pull/232) | User journeys, source checks and docs | 219, 223 |

Every future PR must target `main` and start from the latest `origin/main`. Stacked PRs and feature-branch bases are prohibited. Merge prerequisite changes into `main` before opening dependent PRs. The repository owner merges PRs; agents retain branch context until CI and release workflows succeed.

The final validation PR documents manual release checks that automation does not prove, including Narrator, live Windows DPI, clean-machine installation, sleep/resume and signing.
