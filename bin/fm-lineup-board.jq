# Schema only. Recommendations, provider relations, and benchmark research
# belong to the invoking agent, never to this validator.
def text: type == "string";
def nonempty: text and length > 0;
def token: nonempty and test("^[A-Za-z0-9_./:@+-]+$");
def profile:
  type == "object" and (keys - ["harness","model","effort"] | length == 0)
  and (.harness | IN("claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","gemini","muse","rovo","omp","agy"))
  and ((has("model") | not) or (.model | token))
  and ((has("effort") | not) or (.effort | IN("low","medium","high","xhigh","max","ultra")));
def profiles: type == "array" and length > 0 and all(.[]; profile);
def profile_set: profile or profiles;
def optional_bool($k): (has($k) | not) or (.[$k] | type == "boolean");
def dispatch:
  type == "object" and (.rules | type == "array")
  and all(.rules[]; type == "object" and (.when | nonempty) and (.use | profile_set)
    and ((has("why") | not) or (.why | text)))
  and (.default | profile_set);
def row:
  type == "object" and (.id | token) and (.label | nonempty)
  and (.kind | IN("helm","backup_helm","secondmates","rule","default"))
  and (.current | type == "array" and all(.[]; profile))
  and (.options | profiles) and (.suggested | profiles) and (.reason | nonempty)
  and (. as $row | all(.suggested[]; . as $p | any($row.options[]; . == $p)))
  and (if .kind == "rule" then (.rule_index | type == "number" and . >= 0 and floor == .) and (.when | nonempty) else true end);
def cache:
  type == "object" and (.entries | type == "array")
  and all(.entries[]; type == "object" and (.harness | token) and (.model | token)
    and (.task | nonempty) and (.benchmark | nonempty) and (.score | type == "number")
    and (.source | text and test("^https://[^[:space:]<>]+$"))
    and (.as_of | text and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")));
if $mode == "board" then
  type == "object" and .schema == "fm-lineup-board.v1" and (.generated | nonempty)
  and (.quotas | type == "array" and all(.[];
    type == "object" and (.provider | nonempty) and (.headroom | text)
    and (.reset | text) and (.runway | text) and (.spend_priority | text) and (.attention | text)))
  and (.rows | type == "array" and all(.[]; row))
  and ([.rows[].id] | length == (unique | length))
  and (. as $p | all(["helm","backup_helm","secondmates","default"][];
    . as $kind | [$p.rows[] | select(.kind == $kind)] | length == 1))
  and ([.rows[] | select(.kind == "rule") | .rule_index] | sort == [range(0;length)])
elif $mode == "apply" then
  type == "object" and .schema == "fm-lineup-apply.v1" and (.dispatch | dispatch)
  and (.roles | type == "object" and (keys | sort) == ["backup_helm","helm","secondmates"] and all(.[]; profile))
  and (.instructions | text)
  and (if (.instructions | test("\\S")) then (.resolution | nonempty) else true end)
  and optional_bool("fallback_arrays") and optional_bool("restart_secondmates")
  and (if .fallback_arrays == true then true else
    all((.dispatch.rules[].use,.dispatch.default); type != "array" or length == 1) end)
  and (if .restart_secondmates == true then
    (.restart_ids | type == "array" and length > 0 and all(.[]; text and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")))
    else (has("restart_ids") | not) or (.restart_ids == []) end)
elif $mode == "cache" then cache
else false end
