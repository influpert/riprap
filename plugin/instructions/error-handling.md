# Error handling

Let errors surface, and keep secrets and personal data out of the logs.

These rules are cross-language. They apply to shell scripts, application code, build
tooling, and one-off maintenance scripts equally.

---

## Let errors bubble up

**Default: do not catch, do not suppress, do not swallow.** An unhandled error is loud,
traceable, and fixable. A suppressed one is a silent failure that hides the real problem
until it surfaces somewhere far away from its cause.

The specific danger is the script that exits 0 on failure. It looks fine in the terminal,
it looks fine in CI, it looks fine on the dashboard — and it is quietly doing nothing.
Every run after that reinforces a false belief that the step works. The bug is not
discovered by the person who introduced it; it is discovered weeks later by whoever
depended on the output that was never produced.

Catch an error only when you can do something useful with it: retry with backoff, fall
back to a defined alternative, add context and re-raise, or convert it into a meaningful
message for a user. "Continue as if nothing happened" is not one of those.

---

## Anti-patterns

Same mistake, six shapes. None of these is acceptable as a reflex.

| Ecosystem | Do not | Why it hurts |
|---|---|---|
| Shell | `cmd 2>/dev/null` blanket-applied; `cmd \|\| true`; trailing `exit 0` | Discards the message that identifies the failure and reports success to the caller |
| JavaScript / TypeScript | `catch {}`, `catch (e) {}` with an empty body; a `.catch(() => {})` tacked onto a promise | The rejection is consumed, the awaiting code proceeds on undefined data |
| Python | `except: pass`, or a bare `except:` that also swallows interrupts | Hides everything including typos and interrupt signals; the traceback is destroyed |
| Ruby | `rescue` with no exception class and no body; `rescue => e` that only logs and continues | A bare rescue catches far more than intended and returns nil to the caller |
| Go | `_ = doWork()`, or an `if err != nil` block with nothing in it | The error value was produced specifically so you would read it |
| Rust | `let _ = fallible();`, reflexive `.unwrap_or_default()` on a real failure | Substitutes a plausible-looking zero value for a failure that needed handling |

Two shell notes worth calling out, because they are the most common:

- `2>/dev/null` is acceptable when you are probing for something whose absence is
  expected and handled — checking whether an optional file or binary exists. It is not
  acceptable on a command whose failure means the script cannot do its job.
- `|| true` at the end of a pipeline is almost always a bug in disguise. It says "this
  step may fail and I have decided not to know."

---

## When suppression is allowed

Suppress an error only when you have been explicitly told to, or when the failure is a
known, expected, benign case. Even then:

- **Scope the suppression to the specific expected failure.** Catch the one error type,
  the one exit code, the one condition — never a catch-all.
- **Comment why.** One line saying which failure is expected and why it is safe.
- **Never widen the scope to make it convenient.** A narrow catch that stops working is a
  signal; a catch-all that never stops working is a blindfold.

---

## Logging

- **Never log credentials, tokens, API keys, session identifiers, password reset links,
  or one-time codes.** Logs get shipped, aggregated, mirrored into third-party tools, and
  read by people who were never meant to see any of that. A leaked one-time code in a log
  line is a leaked account.
- **Never dump a whole model or record object into a log.** It is enormously verbose and
  routinely carries personal data — emails, phone numbers, addresses, free-text notes —
  into a system with different retention and access rules than your database.
- **Log identifiers, not objects.** `[WidgetSync] failed for widget_id=4821 status=timeout`
  tells you everything you need and nothing you should not have.
- **Prefix with a structured `[Component]` tag** so logs are greppable. Without it,
  finding one subsystem's output in an interleaved stream is guesswork.
- Log at the point where you have the most context. A message that says only "request
  failed" costs the next reader an hour.
