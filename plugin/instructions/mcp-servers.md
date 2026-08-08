# MCP servers

How to decide whether a capability belongs in an MCP server at all, and what has to be
written down when you add one.

This is the decision framework. The inventory of servers goes underneath it, one entry per
server, added as servers are added.

---

## Every integration declares a preference order

For any capability reachable more than one way, record the order and the reason for it.
The default order, and why each position sits where it does:

1. **A dedicated CLI.** Fastest, because it is one process and no protocol round trip.
   Most reliable, because it fails with an exit code and a message on stderr rather than a
   schema error several layers down. And it composes — output pipes into a filter or a
   loop, so one invocation answers a question that would otherwise take five calls.
2. **A built-in tool.** No install, no authentication, no version skew with something that
   upgraded underneath you. It loses to a CLI on expressiveness: it does the one thing it
   does, exactly that way.
3. **An MCP server.** Wins where the operation is genuinely structured — typed arguments,
   typed results, paginated resources, an API that would need a hundred lines of shell to
   call correctly. Pays for it with a round trip per call, a schema to load first, and an
   auth state that can be absent.

The order is a default, not a law. Invert it wherever the reasons invert: a server
returning a typed result beats a CLI whose output you would have to parse with a regex.
State the inversion and its reason next to the integration, so the next reader does not
"correct" it back.

---

## Every server documents its non-use cases

For each server, write **both** lists:

- **Use it when** — the operations it is the right tool for.
- **Do not use it when** — the operations that look like its job but belong elsewhere,
  each naming what to use instead.

**The negative list is the one that changes behaviour.** "You may use this server" gives no
guidance at the moment of choosing, because at that moment every available tool is
permitted and the only open question is which one. "Not for bulk reads — use the CLI, one
call instead of forty" resolves that; "reads and writes supported" does not.

---

## Calling them

- **Load the schema before calling a deferred tool.** A deferred tool is a name with no
  parameters attached. Calling it before fetching its schema fails validation, and the
  failure looks like a broken tool rather than an unloaded one, which sends you debugging
  the wrong thing.
- **Batch related queries.** One call asking for five things beats five calls asking for
  one, and the gap widens with latency. Where the server exposes a bulk or filter
  argument, use it — a loop of single-item calls is the most common way a server that was
  fast becomes slow.
- **Keep "empty result" and "call failed" apart.** They are different conditions and must
  not collapse into one branch. See [error-handling.md](error-handling.md).

---

## Adding a server

1. **Establish the need.** Name the operations you cannot do with a CLI or a built-in
   tool, or can only do badly. If that list is short, stop here.
2. **Check what it can reach.** Scope, credentials, blast radius. A server holding write
   access to something irreversible deserves the scrutiny of a deploy credential, and its
   secrets follow [secret-hygiene.md](secret-hygiene.md).
3. **Configure it, and pin what can be pinned.** Record the version, so a behaviour change
   upstream is diagnosable rather than mysterious.
4. **Exercise it end to end** — a real call, a real result, and one deliberate failure, so
   you know what its failure looks like before meeting it under pressure.
5. **Document it here with its use cases and its non-use cases**, and **consider a thin
   CLI wrapper** for the two or three operations you reach for most. A wrapper in `bin/`
   collapses a multi-call sequence into one command, composes with the shell, and keeps
   the sequence in one place when the calls change.

---

## Availability is not guaranteed

A server authenticated interactively may simply be absent in a headless or scheduled run:
no browser, no session, no way to complete the flow. Anything automated must **degrade
gracefully** — detect the absence, report it, and either fall back to a CLI path or exit
non-zero with a reason.

The failure to design against is a scheduled job that quietly produces an empty result
because the server it depends on was never reachable, and then reports success.
