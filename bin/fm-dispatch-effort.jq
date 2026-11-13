def effort_ok($h; $m; $e):
  if $e == null then true
  elif ($e | type) != "string" then false
  elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
  elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
  elif $h == "grok" then (["low","medium","high"] | index($e))
  elif $h == "pi" or $h == "pi-signed" or $h == "omp" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "rovo" then (["low","medium","high","max"] | index($e))
  elif $h == "agy" then (["low","medium","high","xhigh","max"] | index($e))
  elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
  else true
  end;
