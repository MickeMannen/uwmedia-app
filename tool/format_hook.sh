#!/bin/sh
# Claude Code PostToolUse hook (.claude/settings.json): formats a Dart file
# right after Claude edits or writes it, so `dart format --set-exit-if-changed`
# in the default suite and CI never fails on an agent's edit. Reads the
# tool call as JSON on stdin; does nothing for non-Dart files.
f=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
case "$f" in
  *.dart)
    [ -f "$f" ] && dart format "$f" >/dev/null 2>&1
    ;;
esac
exit 0
