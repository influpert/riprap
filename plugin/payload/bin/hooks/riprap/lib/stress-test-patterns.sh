#!/usr/bin/env bash
# Shared constants for the plan stress-test gate.
# Sourced by bin/hooks/riprap/claude/require-plan-stress-test.sh.
# See interaction-preferences.md's "Always stress-test a plan before presenting it" for
# the rule, and its "## Enforcement" subsection for what this mechanism does and does not
# verify.
#
# QUALIFYING_TOOL_NAMES does not live here. It names the subagent-dispatch tool for this
# harness — a fact about the runtime the hook is running under, not a project preference —
# and this file's .local.sh extension point below is exactly the mechanism that would let
# a mismatched name go silently unnoticed rather than surfaced and fixed upstream. It is a
# plain constant in the hook script itself instead.

# The first-plan floor: this many qualifying dispatches before the first ExitPlanMode of a
# session is allowed. Two distinct-angle critics plus the mandatory devil's advocate, per
# interaction-preferences.md. The rule recommends five (four critics plus the advocate);
# this is the floor below which the hook blocks, not the recommendation.
# shellcheck disable=SC2034  # consumed by require-plan-stress-test.sh
STRESS_TEST_MIN_DISPATCHES=3

# The revision floor: this many qualifying dispatches, since the last PASSING check, before
# any later ExitPlanMode in the same session is allowed — the devil's advocate alone, per
# interaction-preferences.md's "A changed plan is a new plan". A critic for each angle the
# revision touched is recommended, not enforced. The hook reads "a pass is already recorded
# for this transcript" as "this is a revision", because it cannot see whether a later plan
# revises the earlier one or is unrelated to it; the hook script's header states what that
# proxy lets through.
# shellcheck disable=SC2034  # consumed by require-plan-stress-test.sh
STRESS_TEST_REVISION_MIN_DISPATCHES=1

# --- project extension point ------------------------------------------------
# riprap owns this file and overwrites it on every update, so a value changed here is
# gone the next time. To raise or lower STRESS_TEST_MIN_DISPATCHES or
# STRESS_TEST_REVISION_MIN_DISPATCHES for this project, set it in
# bin/hooks/lib/stress-test-patterns.local.sh instead; riprap sources it if present and
# never overwrites it. The two are independent: raising one leaves the other as it is.
_riprap_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/stress-test-patterns.local.sh"
if [ -r "$_riprap_local" ]; then
  # shellcheck source=/dev/null
  . "$_riprap_local"
fi
unset _riprap_local
