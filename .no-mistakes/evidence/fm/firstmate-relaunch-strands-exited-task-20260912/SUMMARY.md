# Live relaunch validation - target 20564d8 (base 5f68d28)

Every run below drove the real `bin/fm-control.sh` or `bin/fm-spawn.sh` against a real tmux 3.7c server on a private `-L` socket, or a real Herdr 0.9.0 server in a private `fm-lab-*` session.
Agents are stand-in processes named `claude`, `codex`, or `cursor-agent`; no real harness ran in the recorded runs.
Drivers: `live-tmux-relaunch-lab.sh` and `live-herdr-relaunch-leader-lab.sh`.

| Scenario | Target 20564d8 | Old code |
| --- | --- | --- |
| tmux: live agent with a same-group child on another PATH | relaunched; codex from the leader PATH (`live-tmux-group-leader.txt`) | base refused "could not read the pane PATH" |
| Herdr: live agent with a same-group child on another PATH | relaunched; same endpoint reused (`live-herdr-group-leader.txt`) | base refused "could not read the pane PATH" |
| tmux: exited agent, shell unwound to parent dir | relaunched into the recorded worktree (`live-tmux-exited-shell.txt`) | - |
| tmux: exited shell with `set -o noclobber` | relaunched (`live-tmux-exited-noclobber.txt`) | base refused: "cannot overwrite existing file" |
| tmux: raw `~/lab-bin/codex --lab-flag` via fm-spawn | tilde expanded with the pane HOME, launched (`live-tmux-raw-tilde.txt`) | base refused the tilde token |
| tmux: Cursor only in `~/.local/bin`, unrelated `agent` on PATH | launched `~/.local/bin/cursor-agent` (`live-tmux-cursor-fallback.txt`) | - |
| tmux: live pool slot owned by task, exit unwinds subshell | lock free during stop; re-entered slot; launched (`live-tmux-pool-mine-live.txt`) | base held the lock through the stop |
| tmux: successor claims the slot while the agent stops | refused post-stop return; no cd, no launch; successor claim kept (`live-tmux-pool-stolen.txt`) | dc4fd46 launched into the stolen slot |
| tmux: project lock held by another process, pool slot | refused before stop; old agent still running (`live-tmux-pool-locked.txt`) | - |
| tmux: project lock held by another process, ordinary worktree | relaunched; other holder's lock untouched (`live-tmux-nonpool-locked.txt`) | base refused "another Treehouse slot allocation" |

Also run: `FM_TEST_EVIDENCE=1 tests/fm-control-herdr-smoke.test.sh` (real Herdr lab, all 10 ok, `herdr-smoke.log`), and `tests/fm-control-relaunch.test.sh` (hermetic, all ok).
