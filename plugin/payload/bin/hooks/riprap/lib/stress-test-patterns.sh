#!/usr/bin/env bash
# Shared constants for the plan stress-test gate.
# Sourced by bin/hooks/riprap/claude/require-plan-stress-test.sh.
# See interaction-preferences.md's "Always stress-test a plan before presenting it" for
# the rule, and its "## Enforcement" subsection for what this mechanism does and does not
# verify.

# The tool name a subagent dispatch is recorded under in the session transcript.
#
# Confirmed "Agent" by inspecting a real transcript in one harness. "Task" is included
# defensively for CLI-family harnesses, where this tool has historically carried that
# name. This is riprap's own unresolved fact about the runtime it is running under, not a
# per-repository preference — unlike every other array in this family of files, it does
# NOT belong in the .local.sh extension point below. An adopter whose harness uses a third
# name has found a gap in this list, not a reason to configure around it; widen this array
# itself (upstream, or locally as a stopgap) rather than treating it as a customization
# knob. The mandatory pre-merge verification step in this feature's plan exists precisely
# to catch this before it ships wrong.
QUALIFYING_TOOL_NAMES=(Agent Task)

# The floor: this many qualifying dispatches, since the last PASSING check, before
# ExitPlanMode is allowed. Five distinct-angle critics plus the mandatory devil's
# advocate, per interaction-preferences.md.
# shellcheck disable=SC2034  # consumed by require-plan-stress-test.sh
STRESS_TEST_MIN_DISPATCHES=6

# QUALIFYING_TOOL_NAMES as a JSON array, for the jq --argjson step in the hook. A function
# rather than a top-level assignment: jq isn't guaranteed available yet when this file is
# sourced (the hook checks for it afterward), so building the JSON eagerly here could fail
# before the hook gets a chance to give its own, more specific "install jq" message.
stress_test_names_json() {
  printf '%s\n' "${QUALIFYING_TOOL_NAMES[@]}" | jq -R . | jq -s .
}

# Does a qualifying dispatch's concatenated description+prompt text name the devil's
# advocate? Matches a straight apostrophe, a curly one, or none at all ("devils advocate")
# — a documented text proxy for the mandatory angle, not a semantic guarantee that the
# dispatch actually argued the plan should not happen. See this rule's own "## Enforcement"
# section in interaction-preferences.md for what this hook can and cannot verify.
stress_test_is_devils_advocate() {  # $1 = text, one qualifying dispatch per line
  printf '%s' "$1" | grep -qiE "devil.?s.?advocate"
}

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a value changed here is
# gone the next time. To raise or lower STRESS_TEST_MIN_DISPATCHES for this project, set
# it in bin/hooks/lib/stress-test-patterns.local.sh instead; riprap sources it if present
# and never overwrites it. QUALIFYING_TOOL_NAMES is deliberately not meant to be
# overridden here — see the comment above.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/stress-test-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
