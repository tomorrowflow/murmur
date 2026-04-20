#!/bin/bash
# Claude Code Stop hook for Murmur.
#
# Pipes the final assistant message to Murmur's Read Aloud overlay and then
# auto-starts STT recording so the user can reply by voice. Right Option
# (single tap) or Cmd+Opt+C stops the follow-up recording; the transcription
# pastes back into the terminal where Claude Code ran.
#
# Install:
#   mkdir -p ~/.claude/hooks
#   cp scripts/claude-code/recap.sh ~/.claude/hooks/recap.sh
#   chmod +x ~/.claude/hooks/recap.sh
#
# Then add to ~/.claude/settings.json:
#   "hooks": {
#     "Stop": [
#       { "hooks": [{ "type": "command", "command": "~/.claude/hooks/recap.sh" }] }
#     ]
#   }
#
# Falls back to macOS `say` if Murmur's local HTTP server is unreachable.

INPUT=$(cat)
MSG=$(printf '%s' "$INPUT" | jq -r '.last_assistant_message // empty')

[ -z "$MSG" ] && exit 0

# Walk up the process tree so Murmur can bind the recap to the terminal
# that actually ran Claude Code — not whatever the user switched to while
# Claude was thinking.
pid=$$
ancestors=""
while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    ancestors="${ancestors}${ancestors:+,}${pid}"
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$pid" ] && break
done

PAYLOAD=$(jq -n --arg text "$MSG" --arg pids "$ancestors" \
    '{text: $text, autoRecordAfter: true, sourcePids: $pids}')

if ! curl -sS -f --connect-timeout 2 -m 120 \
        -X POST http://127.0.0.1:7878/api/v1/read-aloud \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" >/dev/null 2>&1; then
    (printf '%s' "$MSG" | say -r 200) >/dev/null 2>&1 &
    disown
fi

exit 0
