# Code style

Naming, structure, and comments — the parts of style a formatter cannot decide for you.

Run `bin/format` before you commit and `bin/lint` before you open a PR. Everything below
is about the decisions those tools do not make.

---

## Naming

Casing conventions differ between ecosystems. Match the host language and stay consistent
within the file. What does not vary is the shape of the name.

| Entity | Convention | Example |
|---|---|---|
| Files | Match the language's file convention; name after the primary export | `widget_processor`, `WidgetProcessor` |
| Classes / types | Noun phrase, singular, no prefixes or suffixes for their own sake | `Widget`, `WidgetProcessor`, `RecordStore` |
| Functions / methods | Verb phrase — say what it does | `build_widget`, `fetch_record`, `retry_item` |
| Constants | Upper case with separators, scoped to where they are used | `MAX_WIDGET_RETRIES`, `DEFAULT_ITEM_LIMIT` |
| Booleans | Follow the ecosystem's convention, always positive | `is_active` / `hasRecords` (JS, Python, Go); `active?` (Ruby); `IsActive` (C#) |
| Event handlers | `handle_` prefix plus the event | `handle_widget_click`, `handle_item_submit` |

On booleans specifically: an `is_`/`has_`/`can_` prefix is the right answer in most
languages and the wrong one in Ruby, where the `?` suffix is the convention and
`is_active` reads as foreign. Match the language you are in — a naming rule imported from
another ecosystem is noticed by every reviewer and followed by none.

Two rules that matter more than the table:

- **Descriptive over short.** `google_calendar_event` is a better name than `gce` in every
  context. The name is written once and read hundreds of times; the reader should never
  have to scroll up to find out what an identifier means. Loop counters and single-line
  lambdas are the only place a one-letter name earns its keep.
- **Booleans are positive.** `is_enabled` reads cleanly everywhere. `is_not_disabled`
  forces the reader to resolve a double negative at every call site, and the negation
  gets dropped in a refactor sooner or later.

---

## Function size

Keep functions focused on one job. Under about 20 lines is the target, not a hard limit.

Length is a symptom, not the problem. A long function is usually several functions that
have not been separated yet, which is why it is hard to name, hard to test in isolation,
and hard to change without reading all of it. If you cannot name a function without using
"and", it is doing two things. Break the rule when splitting would be worse: a sequential
setup block is clearer whole than scattered across four helpers each called once.

How many pieces there should be in the first place, and when an abstraction earns its
keep, is one level up in [design-principles.md](design-principles.md).

---

## Comments: document WHY, not WHAT

The code already says what it does. A comment that restates the next line is noise that
still has to be maintained, and it goes stale the first time someone edits the line
without editing the comment above it.

Worth writing:

- A non-obvious constraint. *"Batch size is capped at 50 because the upstream API rejects
  larger payloads without a documented error."*
- The reason an obvious approach was rejected. *"Sorted before grouping because the
  grouping step assumes contiguous keys."*
- A workaround and its trigger condition, so the next reader knows when it can go.

Not worth writing: a comment reading "increment the counter" above `counter += 1`, a
comment restating the function name directly below it, or commented-out code — version
control already remembers that.

---

## Member order within a file

Use one consistent ordering for every class or module:

1. Constants
2. Type declarations, fields, attributes, associations
3. Lifecycle hooks (initialize, connect, mount, setup)
4. Public API
5. Private helpers

**The value is the consistency, not this particular order.** A reader who has learned the
layout once can find the public surface of any file in the codebase without scanning it
top to bottom. If your ecosystem has a strong existing convention, follow that one — just
follow it everywhere.

---

## Symmetric lifecycle teardown

**Whatever you set up in a setup/connect/mount step, tear down in the matching
teardown/disconnect/unmount step.** Every listener gets removed, every timer gets
cleared, every subscription gets cancelled, every handle gets closed.

Unbalanced setup is the single most common source of leaks in long-lived processes and
in UI components that mount and unmount repeatedly. The symptom is never the cause: it
shows up as memory that climbs over hours, a handler that fires three times because it
was attached three times, or a timer firing against a component that no longer exists.
None of that points back to the missing line.

When you add a line to a setup method, add its counterpart to the teardown method in the
same edit. Later never happens.

---

## Formatting is not a review topic

Indentation, quote style, line width, trailing commas, import order — `bin/format`
settles all of it. Never spend review cycles on something a formatter decides
automatically. If a formatting argument keeps recurring, change the formatter config
once and reformat the repo; do not relitigate it per pull request.
