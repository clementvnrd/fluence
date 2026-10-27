#!/bin/bash
# PreToolUse guard for the `tests` subagent (.claude/agents/tests.md).
#
# Registered in .claude/settings.json, not in the agent's frontmatter: Claude Code skips
# frontmatter hooks in `claude -p` and SDK runs, while settings-file hooks always run.
# It fires on every Bash call and acts only inside the `tests` subagent.
#
# There it lets through only the approved test commands, one per call, and blocks
# everything else with exit 2. A pass (exit 0) still goes through the normal permission rules.
#
# Approved:
#   swift test [list] --scratch-path ~/Library/Caches/FluenceBuild/tests [--filter <Name>]
# The scratch path keeps `.build/` out of the iCloud-synced repository (AGENTS.md).

set -u

input=$(cat)

if [[ "$(/usr/bin/jq -r '.agent_type // empty' <<<"$input")" != "tests" ]]; then
  exit 0
fi

command=$(/usr/bin/jq -r '.tool_input.command // empty' <<<"$input")

approved='^swift test( list)? --scratch-path (~|\$HOME)/Library/Caches/FluenceBuild/tests( --filter [A-Za-z0-9_./]+)?$'

if [[ "$command" =~ $approved ]]; then
  exit 0
fi

echo "Blocked: the tests agent may only run 'swift test [list] --scratch-path ~/Library/Caches/FluenceBuild/tests [--filter <Name>]', one command, no pipes, chaining or redirections." >&2
exit 2
