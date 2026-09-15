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
