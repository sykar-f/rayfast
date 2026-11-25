#!/bin/zsh
# usage: tests/codex-trigger.sh -> checks that conversions and Codex never compete for the same query.
# Multi-word conversions must still produce a result (so ↩ copies it, and Codex stays behind ⌘↩);
# natural-language questions must produce none (so the list offers "Ask Codex" instead).
cd "$(dirname "$0")/.."; B=build/rayfast.app/Contents/MacOS/rayfast; fail=0
calc=("5 km to mi" "3 cups in ml" "100 usd to inr" "20% of 150" "sqrt(2) * pi" "time in nyc" "london time"
      "3pm pst to ist" "noon tokyo to nyc" "1 gib in mb" "2 + 2" "what time is it in paris")
prose=("how do i flush dns" "what is pi" "convert 5 km to miles" "how many km in a mile" "explain the time in nyc"
       "time in the morning" "translate hello in spanish" "e to the power of 2" "how much is 100 usd in eur"
       "write a haiku" "pi to 10 digits" "log in to github" "sin of 30 degrees")
for q in "${calc[@]}"; do $B --eval "$q" | grep -q '(none)' && { echo "FAIL calc lost:      $q"; fail=1; }; done
for q in "${prose[@]}"; do $B --eval "$q" | grep -q '(none)' || { echo "FAIL prose captured: $q"; fail=1; }; done
[ $fail = 0 ] && echo "ok: ${#calc} conversions, ${#prose} questions"; exit $fail
