#!/bin/bash
# PreToolUse guard for the `tests` subagent (.claude/agents/tests.md).
#
# Lets through only the approved test commands, one per call; blocks everything else with
# exit 2. A pass (exit 0) still goes through the normal permission rules.
#
# Approved:
#   swift test [list] --scratch-path ~/Library/Caches/FluenceBuild/tests [--filter <Name>]
# The scratch path keeps `.build/` out of the iCloud-synced repository (AGENTS.md).

set -u

command=$(/usr/bin/jq -r '.tool_input.command // empty')

approved='^swift test( list)? --scratch-path (~|\$HOME)/Library/Caches/FluenceBuild/tests( --filter [A-Za-z0-9_./]+)?$'

if [[ "$command" =~ $approved ]]; then
  exit 0
fi

echo "Blocked: the tests agent may only run 'swift test [list] --scratch-path ~/Library/Caches/FluenceBuild/tests [--filter <Name>]', one command, no pipes, chaining or redirections." >&2
exit 2
