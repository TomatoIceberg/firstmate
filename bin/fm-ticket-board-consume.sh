#!/usr/bin/env bash
# fm-ticket-board-consume.sh - turn a captured ticket-board poll result into
# durable ticket records, then rebuild and rearm the board.
#
# Usage:
#   fm-ticket-board-consume.sh <result-file> [<store.json>]
#
# <result-file> is the durable captured result named by a
# `procevent lavish <source-id> <sequence>` wake for the ticket board's
# source (state/procevent-inbox/<source-id>.<sequence>.result; see the
# process-event-sources skill). This is the receiving side of ticket
# creation: the captain types a plain-language ticket description into the
# board's own Lavish conversation panel and sends it, and Lavish captures
# that as an ordinary freeform message (tag=message) inside the result's
# `prompts[N]` block - there is no custom form on the board page itself. This
# script reads every such row's full sent text, turns each into one ticket
# record (a slug id, a title taken from the first line, and the full text as
# the body), appends it to the durable store (default: the path
# `bin/fm-ticket-board.sh store` prints) in the "backlog" status, then
# rebuilds and rearms the board through `bin/fm-ticket-board.sh build` so the
# new ticket is visible immediately.
#
# Any row not tagged `message` is ignored: this board carries no decision
# forms, so a `choice` row (if one ever appeared) is not ticket-board input.
# A result with no message rows prints `captured: 0` and exits 0 without
# touching the store or rebuilding - firstmate need not treat "captain closed
# the board without typing anything" as an error.
#
# Fail-closed: a missing or unreadable result file, or an updated store that
# would not satisfy fm-ticket-board.v1, refuses before the existing durable
# store is touched - the new content is built and validated in a private
# staged copy first, and only replaces the store after that build succeeds.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() {
  printf 'fm-ticket-board-consume: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

RESULT=${1-}
[ -n "$RESULT" ] || { usage >&2; exit 2; }
[ "$#" -le 2 ] || { usage >&2; exit 2; }
[ -f "$RESULT" ] && [ ! -L "$RESULT" ] || fail "result file does not exist: $RESULT"
command -v jq >/dev/null 2>&1 || fail "jq is required"

STORE=${2:-$("$SCRIPT_DIR/fm-ticket-board.sh" store)}

# Extract every freeform message row as one "title<TAB>body" output line.
# Reads the declared field order rather than assuming a fixed column, exactly
# like fm-procevent-lavish.sh's own cmd_answers. The `prompt` field carries
# the full text the captain sent; `text` is Lavish's generic "Freeform
# message" label and is used only if `prompt` is somehow absent. Title is the
# first line (falling back to the full text when the first line is blank),
# capped at 200 bytes; body is the full text with embedded control
# characters (including newlines) flattened to spaces, capped at 4000 bytes.
messages() {
  perl -e '
    use strict; use warnings;
    my ($path) = @ARGV;
    open my $fh, "<", $path or exit 1;
    my (@fields, $want, @rows);
    while (my $line = <$fh>) {
      if (!@fields) {
        next unless $line =~ /^prompts\[(\d+)\]\{([^}]*)\}:\s*$/;
        ($want, @fields) = ($1, split /,/, $2);
        next;
      }
      last unless $line =~ /^\s/;
      last if @rows >= $want;
      chomp $line;
      push @rows, $line;
    }
    close $fh;
    for my $row (@rows) {
      $row =~ s/^\s+//;
      my @vals;
      while (length $row) {
        if ($row =~ s/^"((?:[^"\\]|\\.)*)"//) {
          my $v = $1;
          $v =~ s/\\(.)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : $1 eq "r" ? "\r" : $1/ge;
          push @vals, $v;
        } else {
          $row =~ s/^([^,]*)//;
          push @vals, $1;
        }
        last unless $row =~ s/^,//;
      }
      my %f;
      $f{$fields[$_]} = $vals[$_] for 0 .. $#fields;
      next unless defined $f{tag} && $f{tag} eq "message";
      my $raw = (defined $f{prompt} && length $f{prompt}) ? $f{prompt} : $f{text};
      next unless defined $raw;
      $raw =~ s/^\s+|\s+$//g;
      next unless length $raw;
      my ($title) = split /\n/, $raw, 2;
      $title =~ s/[\x00-\x1f\x7f]/ /g;
      $title =~ s/^\s+|\s+$//g;
      $title = $raw unless length $title;
      $title = substr($title, 0, 200);
      my $body = $raw;
      $body =~ s/[\x00-\x1f\x7f]+/ /g;
      $body =~ s/^\s+|\s+$//g;
      next unless length $body;
      $body = substr($body, 0, 4000);
      print "$title\t$body\n";
    }
  ' "$1"
}

new_id() {
  # tkt-<UTC compact timestamp>-<4 hex>: unique enough for a captain-paced
  # single-operator feed; a collision is refused rather than silently merged.
  printf 'tkt-%s-%04x\n' "$(date -u +%Y%m%dT%H%M%S)" "$((RANDOM % 65536))"
}

CAPTURED=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-ticket-consume.XXXXXX") || fail "cannot stage captured messages"
trap 'rm -f -- "$CAPTURED"' EXIT
messages "$RESULT" > "$CAPTURED"
COUNT=$(wc -l < "$CAPTURED" | tr -d ' ')
printf 'captured: %s\n' "$COUNT"
[ "$COUNT" -gt 0 ] || exit 0

[ -f "$STORE" ] || "$SCRIPT_DIR/fm-ticket-board.sh" init "$STORE" >/dev/null
jq empty "$STORE" 2>/dev/null || fail "ticket store is not valid JSON: $STORE"

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STAGED=$(umask 077; mktemp "${STORE%/*}/.tickets.XXXXXX") || fail "cannot stage the store"
trap 'rm -f -- "$CAPTURED" "$STAGED" "$STAGED.next"' EXIT
cp -p "$STORE" "$STAGED" || fail "cannot stage the store"

while IFS=$'\t' read -r title body; do
  id=$(new_id)
  jq -e --arg id "$id" 'any(.tickets[]; .id == $id) | not' "$STAGED" >/dev/null \
    || fail "generated a colliding ticket id: $id"
  jq --arg id "$id" --arg title "$title" --arg created "$NOW" --arg body "$body" \
    '.tickets += [{id: $id, title: $title, status: "backlog", created: $created, body: $body}]' \
    "$STAGED" > "$STAGED.next" || fail "cannot append ticket: $id"
  mv -f -- "$STAGED.next" "$STAGED"
  printf 'ticket: %s %s\n' "$id" "$title"
done < "$CAPTURED"

"$SCRIPT_DIR/fm-ticket-board.sh" build "$STAGED" \
  || fail "the updated store does not satisfy fm-ticket-board.v1"
if ! { chmod 0600 "$STAGED" && mv -f -- "$STAGED" "$STORE"; }; then
  fail "cannot publish the updated store"
fi
