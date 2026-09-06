Mode: Unknown harness fallback.

This primary harness does not have a verified watcher wake adapter.
When this session holds the fleet lock and away mode is inactive, use the bounded foreground fallback:

1. Run `bin/fm-wake-drain.sh`, handle all emitted wakes, reconcile open decisions and unread status lines, then run the exact command printed as `WAKE_ACK_REQUIRED`, including its recovery generation.
   An empty queue can still require that acknowledgement; before it completes, interruption leaves the recovery episode open.
2. From this session's code root, run this export-prefixed command as one standalone foreground tool call:

   ```sh
   export FM_HOME=__FM_HOME_SH__; [ -f __FM_X_MODE_ENV_SH__ ] && . __FM_X_MODE_ENV_SH__; bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"
   ```

   The rendered paths select this session's home and source its Relay cadence when present.
   Keep setup, drain, and acknowledgement work in separate calls; [`arm-pretool-check.md`](../arm-pretool-check.md#blessed-syntax-tree) owns the accepted command shape.
3. After every return, including `check: rearm-resurface` and a quiet exit 124, repeat the drain, handling, and acknowledgement step.
   Inspect other failures before trying a fresh checkpoint.
4. The owning model must start the next checkpoint while supervision remains required.
   Return the foreground tool result to that same model; a process that survives a tool call is not evidence of notification delivery.

This fallback provides no callback continuity after the model stops issuing tool calls.
[`watcher-continuity.md`](../watcher-continuity.md#foreground-checkpoint-boundary) owns the checkpoint lifetime, warning interpretation, and verification limit.
Use `bin/fm-watch-arm.sh` only after verifying a harness-owned tracked background mechanism that survives the call and notifies the owning model on exit.
Never use shell `&` for watcher supervision or treat a successful arm as proof of that callback.

Record new verification evidence before promoting an unknown harness to a named snippet.
