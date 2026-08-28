#!/usr/bin/env bash
# Behavior tests for bin/fm-ticket-board-consume.sh: extracting freeform
# `message` rows from a captured Lavish result, ignoring everything else,
# appending tickets to the durable store, and fail-closed rebuild-before-publish.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONSUME="$ROOT/bin/fm-ticket-board-consume.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-board-consume)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/state" "$home/data"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" lavish-axi
  printf '%s\n' "$home"
}

run_consume() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$CONSUME" "$@"
}

# A realistic captured result: the exact wire shape lavish-axi poll produces
# for a plain typed message, verified live against lavish-axi 0.1.x - field
# order uid,prompt,selector,tag,text, with `prompt` carrying the full sent
# text and `text` carrying only the generic "Freeform message" label.
write_message_result() {  # <path> <text-with-wire-escapes-already-applied>
  local escaped=$2
  escaped=${escaped//\"/\\\"}
  cat > "$1" <<EOF
[lavish-axi] Long-polling for user feedback.
session:
  file: /board.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","$escaped","",message,Freeform message
next_step: "Apply the requested changes."
EOF
}

test_consume_extracts_a_message_and_appends_a_ticket() {
  local home result out store
  home=$(make_home basic)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "Fix the login button color on Safari"

  out=$(run_consume "$home" "$result") || fail "consume failed on a well-formed message result"
  assert_contains "$out" "captured: 1" "consume did not report one captured message: $out"
  assert_contains "$out" "ticket: tkt-" "consume did not print the new ticket id: $out"
  assert_contains "$out" "Fix the login button color on Safari" "consume did not print the ticket title: $out"

  jq -e '.tickets | length == 1' "$store" >/dev/null || fail "the store does not have exactly one ticket"
  jq -e '.tickets[0].status == "backlog"' "$store" >/dev/null || fail "the new ticket is not in backlog"
  jq -e '.tickets[0].title == "Fix the login button color on Safari"' "$store" >/dev/null \
    || fail "the new ticket title does not match the sent text"
  jq -e '.tickets[0].body == "Fix the login button color on Safari"' "$store" >/dev/null \
    || fail "the new ticket body does not match the sent text"
  jq -e '.tickets[0].id | test("^tkt-[A-Za-z0-9._-]+$")' "$store" >/dev/null \
    || fail "the new ticket id is not a slug"
  assert_present "$home/.lavish/ticket-board.html" "consume did not rebuild the board"
  pass "consume extracts a freeform message and appends one backlog ticket"
}

test_consume_creates_the_store_when_absent() {
  local home result store
  home=$(make_home create-store)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "First ticket ever"
  rm -f "$store"

  run_consume "$home" "$result" >/dev/null || fail "consume failed when the store did not exist yet"
  jq -e '.schema == "fm-ticket-board.v1" and (.tickets | length) == 1' "$store" >/dev/null \
    || fail "consume did not create a valid store carrying the new ticket"
  pass "consume creates the store on first use"
}

test_consume_splits_title_from_a_multiline_body() {
  local home result store
  home=$(make_home multiline)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" 'Login is broken\nSteps: open Safari, click login\nExpected: it works'

  run_consume "$home" "$result" >/dev/null || fail "consume failed on a multiline message"
  jq -e '.tickets[0].title == "Login is broken"' "$store" >/dev/null \
    || fail "title is not the first line: $(jq -c '.tickets[0]' "$store")"
  jq -e '.tickets[0].body | contains("Expected: it works")' "$store" >/dev/null \
    || fail "body dropped the later lines of a multiline message"
  jq -e '.tickets[0].body | contains("\n") | not' "$store" >/dev/null \
    || fail "body still carries a raw newline instead of being flattened"
  pass "consume derives the title from the first line and flattens the full body"
}

test_consume_ignores_non_message_rows() {
  local home result store
  home=$(make_home ignore-choice)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  cat > "$result" <<'EOF'
session:
  file: /board.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","Captain's Call answer","",choice,"Option A"
EOF
  out=$(run_consume "$home" "$result") || fail "consume failed on a choice-only result"
  assert_contains "$out" "captured: 0" "a choice-tagged row was mistaken for a ticket: $out"
  assert_absent "$store" "consume created a store for a result with no ticket content"
  pass "consume ignores rows not tagged message and never mutates the store"
}

test_consume_refuses_a_missing_result_file() {
  local home rc out
  home=$(make_home missing-result)
  set +e; out=$(run_consume "$home" "$home/does-not-exist.txt" 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume accepted a missing result file"
  assert_contains "$out" "does not exist" "the missing-result refusal did not say why: $out"
  pass "consume refuses a missing result file"
}

test_consume_does_not_publish_when_rebuild_fails() {
  local home result store before
  home=$(make_home rebuild-failure)
  result="$home/result.txt"
  store="$home/data/tickets.json"
  write_message_result "$result" "First ticket"
  run_consume "$home" "$result" >/dev/null || fail "the first consume failed"
  before=$(cat "$store")

  write_message_result "$result" "Second ticket, but the board session will fail"
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lavish-axi"

  set +e; run_consume "$home" "$result" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail "consume reported success despite a failed rebuild"
  [ "$(cat "$store")" = "$before" ] || fail "consume published a new ticket despite a failed rebuild"
  pass "consume never publishes a new ticket when the board rebuild fails"
}

test_consume_extracts_a_message_and_appends_a_ticket
test_consume_creates_the_store_when_absent
test_consume_splits_title_from_a_multiline_body
test_consume_ignores_non_message_rows
test_consume_refuses_a_missing_result_file
test_consume_does_not_publish_when_rebuild_fails
