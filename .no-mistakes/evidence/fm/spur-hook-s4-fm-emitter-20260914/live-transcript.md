# Live transcript: hold --urgent-alert

- worktree: /home/jason/.no-mistakes/worktrees/e95238b70e4e/01M2HMG18ZPSRRN9ESG29YWT7Y (target a373d16)
- base tree: /tmp/fm-ua-base.tiFH0I (base 5a4944e)
- tasks-axi: 0.2.5
- inbox filesystem for S1/S5: DrvFs (Windows C:) under /mnt/c/Users/Jason/AppData/Local/Temp, same filesystem type as the live C:\Continuum\_PacketRouter\inbox\new

## S1 - configured home: hold --urgent-alert on a live halt writes one URGENT-ALERT packet

config/packet-router-inbox:
```text
# Packet Router inbox
/mnt/c/Users/Jason/AppData/Local/Temp/fm-ua-inbox.Rzd5AW/inbox/new
```
```console
$ [target] bin/fm-captain-hold.sh hold rollout-window --title Ship the billing rollout --reason Work is stopped until the captain picks the rollout window --repo sample --urgent-alert
exit=0
stdout:
  rollout-window
stderr:
```
- PASS: hold exits 0
- PASS: stdout is only the task id
- PASS: stderr is empty
```console
$ tasks-axi show rollout-window
    id: rollout-window
    title: Ship the billing rollout
    state: queued
    held: yes
    hold_reason: Work is stopped until the captain picks the rollout window
    hold_kind: captain
    hold_until: "-"
```
```console
$ ls -A /mnt/c/Users/Jason/AppData/Local/Temp/fm-ua-inbox.Rzd5AW/inbox/new
  pkt-urgent-rollout-window.md
```
- PASS: exactly one packet in inbox/new
- PASS: no leftover temp file in inbox/new
```text
---
type: continuum-packet
schema: packet-router/v1
kind: urgent-alert
id: pkt-urgent-rollout-window
from: firstmate
role_target: spur
priority: high
ask_of: spur
created_at_pt: "2026-09-14T13:00:00"
ttl_hours: 6
dedupe_key: "fm:rollout-window"
source_class: H
---

URGENT-ALERT v1
dedupe_key: fm:rollout-window
source: firstmate / rollout-window
class: H
why: Work is stopped until the captain picks the rollout window
blocked: Ship the billing rollout
ask: Work is stopped until the captain picks the rollout window
action_hint: Answer the captain hold
link:
```
Semantic parse of the packet against the Packet Router HOWTO URGENT-ALERT v1 contract:
```console
front matter (parsed): {"type":"continuum-packet","schema":"packet-router/v1","kind":"urgent-alert","id":"pkt-urgent-rollout-window","from":"firstmate","role_target":"spur","priority":"high","ask_of":"spur","created_at_pt":"2026-09-14T13:00:00","ttl_hours":6,"dedupe_key":"fm:rollout-window","source_class":"H"}
body (parsed): {"dedupe_key":"fm:rollout-window","source":"firstmate / rollout-window","class":"H","why":"Work is stopped until the captain picks the rollout window","blocked":"Ship the billing rollout","ask":"Work is stopped until the captain picks the rollout window","action_hint":"Answer the captain hold","link":""}
PARSE OK: packet matches the URGENT-ALERT v1 envelope contract
```
- PASS: S1 packet parses and matches the contract

## S1b - preferred path: hold an existing work item without --title; blocked names that item

```console
$ tasks-axi add deploy-gate "Deploy the payments service" --repo sample
exit=0
```
```console
$ [target] bin/fm-captain-hold.sh hold deploy-gate --reason Deploy halted: only the captain holds the prod credential --urgent-alert
exit=0
stdout:
  deploy-gate
stderr:
```
- PASS: hold exits 0
```text
---
type: continuum-packet
schema: packet-router/v1
kind: urgent-alert
id: pkt-urgent-deploy-gate
from: firstmate
role_target: spur
priority: high
ask_of: spur
created_at_pt: "2026-09-14T13:00:00"
ttl_hours: 6
dedupe_key: "fm:deploy-gate"
source_class: H
---

URGENT-ALERT v1
dedupe_key: fm:deploy-gate
source: firstmate / deploy-gate
class: H
why: Deploy halted: only the captain holds the prod credential
blocked: Deploy the payments service
ask: Deploy halted: only the captain holds the prod credential
action_hint: Answer the captain hold
link:
```
- PASS: blocked is the task title, not the reason

## S2 - home with NO Packet Router inbox: hold --urgent-alert is unaffected (same output and backlog as base commit)

```console
$ [target, flag] bin/fm-captain-hold.sh hold sample-halt --title Halt progress call --reason captain must pick the window --repo sample --urgent-alert
exit=0
stdout:
  sample-halt
stderr:
```
```console
$ [target, no flag] bin/fm-captain-hold.sh hold sample-halt --title Halt progress call --reason captain must pick the window --repo sample
exit=0
stdout:
  sample-halt
stderr:
```
```console
$ [BASE 5a4944e, no flag] bin/fm-captain-hold.sh hold sample-halt --title Halt progress call --reason captain must pick the window --repo sample
exit=0
stdout:
  sample-halt
stderr:
```
- PASS: all three exit 0
- PASS: stdout identical to base
- PASS: stderr identical to base (empty)
- PASS: backlog.md identical: target+flag vs base
- PASS: backlog.md identical: target no flag vs base
- PASS: no pkt-urgent file anywhere under the three S2 homes
backlog.md after target hold --urgent-alert (unconfigured home):
```text
## In flight

## Queued
- [ ] sample-halt - Halt progress call (repo: sample) (kind: captain) (since 2026-09-14) (hold: captain must pick the window) (hold-kind: captain)
  Captain hold set: 2026-09-14T20:00:00Z
## Done
```

## S3 - routine hold without the flag, and resolving the call, never write a packet

```console
$ [target] bin/fm-captain-hold.sh hold merge-ready --title PR 42 is merge-ready --reason Merge-ready: captain may merge when convenient --repo sample
exit=0
stdout:
  merge-ready
stderr:
```
- PASS: routine hold exits 0
```console
$ [target] bin/fm-captain-hold.sh answer merge-ready --decision-file /tmp/fm-ua-live.h7ng89/s3/decision.txt --release
exit=0
stdout:
  released: merge-ready
stderr:
```
- PASS: answer --release exits 0
```console
$ ls -A /tmp/fm-ua-live.h7ng89/s3/router/inbox/new
```
- PASS: zero packets after routine hold + answer

## S4 - --until deferral with --urgent-alert does not write a packet

```console
$ [target] bin/fm-captain-hold.sh hold revisit-later --title Revisit vendor choice --reason Captain deferred: revisit next month --repo sample --until 2026-10-01 --urgent-alert
exit=0
stdout:
  revisit-later
stderr:
```
- PASS: deferral hold exits 0
```console
$ tasks-axi show revisit-later
    id: revisit-later
    title: Revisit vendor choice
    state: queued
    held: yes
    hold_reason: "Captain deferred: revisit next month"
    hold_kind: captain
    hold_until: 2026-10-01
```
```console
$ ls -A /tmp/fm-ua-live.h7ng89/s4/router/inbox/new
```
- PASS: zero packets for --until

## S5 - escalate an already-active routine hold, then retry: emits each time, same dedupe_key, one file

```console
$ [target] bin/fm-captain-hold.sh hold schema-call --title Pick the schema migration path --reason Captain to choose A or B --repo sample
exit=0
stdout:
  schema-call
stderr:
```
- PASS: routine hold wrote nothing
```console
$ [target] bin/fm-captain-hold.sh hold schema-call --reason Work stopped: migration cannot start until the captain picks A or B --urgent-alert
exit=0
stdout:
  schema-call
stderr:
```
- PASS: escalation exits 0
- PASS: escalation wrote one packet
```text
---
type: continuum-packet
schema: packet-router/v1
kind: urgent-alert
id: pkt-urgent-schema-call
from: firstmate
role_target: spur
priority: high
ask_of: spur
created_at_pt: "2026-09-14T13:00:00"
ttl_hours: 6
dedupe_key: "fm:schema-call"
source_class: H
---

URGENT-ALERT v1
dedupe_key: fm:schema-call
source: firstmate / schema-call
class: H
why: Work stopped: migration cannot start until the captain picks A or B
blocked: Pick the schema migration path
ask: Work stopped: migration cannot start until the captain picks A or B
action_hint: Answer the captain hold
link:
```
Simulate the Packet Router watcher claiming the first packet (move it out of inbox/new), then retry the same hold:
```console
$ [target] bin/fm-captain-hold.sh hold schema-call --reason Work stopped: migration cannot start until the captain picks A or B --urgent-alert
exit=0
stdout:
  schema-call
stderr:
```
- PASS: retry exits 0
- PASS: retry wrote one new packet
- PASS: retry keeps dedupe_key fm:schema-call
Retry again without the watcher claiming (file still in inbox/new):
```console
$ [target] bin/fm-captain-hold.sh hold schema-call --reason Work stopped: migration cannot start until the captain picks A or B --urgent-alert
exit=0
stdout:
  schema-call
stderr:
```
- PASS: second retry exits 0
```console
$ ls -A /mnt/c/Users/Jason/AppData/Local/Temp/fm-ua-inbox.KX02iG/inbox/new
  pkt-urgent-schema-call.md
```
- PASS: still exactly one file in inbox/new (atomic replace, no temp leftovers)

## S6 - adversarial: a refused hold with --urgent-alert never pages

```console
$ [target] bin/fm-captain-hold.sh hold paren-call --title Paren call --reason Pick (A) or (B) --repo sample --urgent-alert
exit=1
stdout:
stderr:
  fm-captain-hold: reason must not contain parentheses (tasks-axi hold contract)
```
- PASS: parenthesised reason refused (nonzero)
```console
$ [target] bin/fm-captain-hold.sh hold no-title-call --reason Work stopped --urgent-alert
exit=1
stdout:
stderr:
  fm-captain-hold: --title is required to create task no-title-call
```
- PASS: new task without --title refused (nonzero)
```console
$ [target] bin/fm-captain-hold.sh hold closed-call --title Closed call --reason Captain to pick --repo sample
exit=0
stdout:
  closed-call
stderr:
```
```console
$ [target] bin/fm-captain-hold.sh answer closed-call --decision-file /tmp/fm-ua-live.h7ng89/s6/decision.txt
exit=0
stdout:
  answered: closed-call
stderr:
```
```console
$ [target] bin/fm-captain-hold.sh hold closed-call --reason Work stopped again --urgent-alert
exit=1
stdout:
stderr:
  fm-captain-hold: task closed-call is already closed; a new captain call needs its own task
```
- PASS: hold on a closed task refused (nonzero)
```console
$ [target] bin/fm-captain-hold.sh hold bad/id --title x --reason Work stopped --repo sample --urgent-alert
exit=1
stdout:
stderr:
  fm-captain-hold: task-id must be a non-empty privacy-safe slug: bad/id
```
- PASS: unsafe task id refused (nonzero)
```console
$ ls -A /tmp/fm-ua-live.h7ng89/s6/router/inbox/new
```
- PASS: zero packets after every refused hold

## S7 - configured but broken inbox: hold still succeeds and prints one actionable: line

Inbox condition: missing-dir
```console
$ [target] bin/fm-captain-hold.sh hold halt-missing-dir --title Halt missing-dir --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-missing-dir
stderr:
  actionable: URGENT-ALERT for task halt-missing-dir was not written to Packet Router inbox /tmp/fm-ua-live.h7ng89/s7-missing-dir/router/inbox/new (inbox directory is missing)
```
- PASS: missing-dir: hold exits 0
- PASS: missing-dir: stdout is only the task id
- PASS: missing-dir: stderr is exactly one actionable: line
- PASS: missing-dir: that line starts with actionable: URGENT-ALERT
- PASS: missing-dir: task is still captain-held
- PASS: missing-dir: no packet written
Inbox condition: is-a-file
```console
$ [target] bin/fm-captain-hold.sh hold halt-is-a-file --title Halt is-a-file --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-is-a-file
stderr:
  actionable: URGENT-ALERT for task halt-is-a-file was not written to Packet Router inbox /tmp/fm-ua-live.h7ng89/s7-is-a-file/router/inbox/new (inbox directory is missing)
```
- PASS: is-a-file: hold exits 0
- PASS: is-a-file: stdout is only the task id
- PASS: is-a-file: stderr is exactly one actionable: line
- PASS: is-a-file: that line starts with actionable: URGENT-ALERT
- PASS: is-a-file: task is still captain-held
- PASS: is-a-file: no packet written
Inbox condition: read-only
```console
$ [target] bin/fm-captain-hold.sh hold halt-read-only --title Halt read-only --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-read-only
stderr:
  actionable: URGENT-ALERT for task halt-read-only was not written to Packet Router inbox /tmp/fm-ua-live.h7ng89/s7-read-only/router/inbox/new (could not create a temp file)
```
- PASS: read-only: hold exits 0
- PASS: read-only: stdout is only the task id
- PASS: read-only: stderr is exactly one actionable: line
- PASS: read-only: that line starts with actionable: URGENT-ALERT
- PASS: read-only: task is still captain-held
- PASS: read-only: no packet written

## S8 - adversarial config values that are not an absolute path are a silent no-op

config/packet-router-inbox = `router/inbox/new`
```console
$ [target] bin/fm-captain-hold.sh hold halt-1 --title Halt 1 --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-1
stderr:
```
- PASS: value 1: exit 0, stdout id, empty stderr
- PASS: value 1: no packet anywhere
config/packet-router-inbox = `~/router/inbox/new`
```console
$ [target] bin/fm-captain-hold.sh hold halt-2 --title Halt 2 --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-2
stderr:
```
- PASS: value 2: exit 0, stdout id, empty stderr
- PASS: value 2: no packet anywhere
config/packet-router-inbox = `C:\Continuum\_PacketRouter\inbox\new`
```console
$ [target] bin/fm-captain-hold.sh hold halt-3 --title Halt 3 --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-3
stderr:
```
- PASS: value 3: exit 0, stdout id, empty stderr
- PASS: value 3: no packet anywhere
config/packet-router-inbox = `   # only a comment`
```console
$ [target] bin/fm-captain-hold.sh hold halt-4 --title Halt 4 --reason Work stopped on a captain call --repo sample --urgent-alert
exit=0
stdout:
  halt-4
stderr:
```
- PASS: value 4: exit 0, stdout id, empty stderr
- PASS: value 4: no packet anywhere

## S9 - adversarial text: YAML-hostile reason and title do not break the packet envelope

```console
$ [target] bin/fm-captain-hold.sh hold hostile.text_1 --title Fix "prod" at C:\data\new: tabs #hash --- Café ✓ --reason Halted: key: value "quoted" \back\slash #not-a-comment --- & *star --repo sample --urgent-alert
exit=0
stdout:
  hostile.text_1
stderr:
```
- PASS: hold exits 0
```text
---
type: continuum-packet
schema: packet-router/v1
kind: urgent-alert
id: pkt-urgent-hostile.text_1
from: firstmate
role_target: spur
priority: high
ask_of: spur
created_at_pt: "2026-09-14T13:00:00"
ttl_hours: 6
dedupe_key: "fm:hostile.text_1"
source_class: H
---

URGENT-ALERT v1
dedupe_key: fm:hostile.text_1
source: firstmate / hostile.text_1
class: H
why: Halted: key: value "quoted" \back\slash #not-a-comment --- & *star
blocked: Fix "prod" at C:\data\new: tabs #hash --- Café ✓
ask: Halted: key: value "quoted" \back\slash #not-a-comment --- & *star
action_hint: Answer the captain hold
link:
```
```console
front matter (parsed): {"type":"continuum-packet","schema":"packet-router/v1","kind":"urgent-alert","id":"pkt-urgent-hostile.text_1","from":"firstmate","role_target":"spur","priority":"high","ask_of":"spur","created_at_pt":"2026-09-14T13:00:00","ttl_hours":6,"dedupe_key":"fm:hostile.text_1","source_class":"H"}
body (parsed): {"dedupe_key":"fm:hostile.text_1","source":"firstmate / hostile.text_1","class":"H","why":"Halted: key: value \"quoted\" \\back\\slash #not-a-comment --- & *star","blocked":"Fix \"prod\" at C:\\data\\new: tabs #hash --- Café ✓","ask":"Halted: key: value \"quoted\" \\back\\slash #not-a-comment --- & *star","action_hint":"Answer the captain hold","link":""}
PARSE OK: packet matches the URGENT-ALERT v1 envelope contract
```
- PASS: hostile text carried verbatim and envelope still parses

## Result

FAILS=0
