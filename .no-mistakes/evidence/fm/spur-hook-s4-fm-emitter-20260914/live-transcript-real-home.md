# S10 - real firstmate home layout, no FM_* test overrides, real Pacific clock

```console
$ git check-ignore -v config/packet-router-inbox   # in a fresh home extracted from a373d16
.gitignore:13:config/	config/packet-router-inbox
$ env | grep -c '^FM_'
0
$ date -u; TZ=America/Los_Angeles date
Tue Sep 15 04:44:55 UTC 2026
Mon Sep 14 21:44:55 PDT 2026
$ bin/fm-captain-hold.sh hold prod-login --title "Rotate the prod database password" --reason "Halted: only the captain can pass the 2FA prompt" --repo sample --urgent-alert
prod-login
exit=0
$ ls -A <inbox>/new
pkt-urgent-prod-login.md
$ cat <inbox>/new/pkt-urgent-prod-login.md
---
type: continuum-packet
schema: packet-router/v1
kind: urgent-alert
id: pkt-urgent-prod-login
from: firstmate
role_target: spur
priority: high
ask_of: spur
created_at_pt: "2026-09-14T21:44:56"
ttl_hours: 6
dedupe_key: "fm:prod-login"
source_class: H
---

URGENT-ALERT v1
dedupe_key: fm:prod-login
source: firstmate / prod-login
class: H
why: Halted: only the captain can pass the 2FA prompt
blocked: Rotate the prod database password
ask: Halted: only the captain can pass the 2FA prompt
action_hint: Answer the captain hold
link:
```
