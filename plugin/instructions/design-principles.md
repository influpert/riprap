# Design principles

Choosing between two shapes for the same change: how much structure to build, and when.

Naming, function length and comments are next door in [code-style.md](code-style.md). This
file is the level above that — how many pieces there are, and what depends on what.

---

## Build the smallest thing that solves the whole problem

**When two designs both work, ship the one with less code in it.** Fewer files, fewer
layers, fewer branches, fewer concepts the reader has to hold at once. The bar the larger
design has to clear is not "this is nicer" — it is a concrete requirement the smaller one
fails to meet, stated out loud.

The questions, in the order they are worth asking:

1. **Does this need to exist at all?** The cheapest code is the code not written. A
   requirement that turns out to be somebody's guess about a future need is the most
   expensive thing in any design.
2. **Can something here already do it?** A parameter on a function that exists beats a
   second function beside it — until the parameter is really a second function wearing a
   disguise, which [code-style.md](code-style.md) tells you how to spot.
3. **How many concepts does the reader have to learn?** A factory, an interface and a
   registry to produce one object is three concepts for one outcome.
4. **What happens at deletion time?** If this is dropped in a year, how many files are
   touched? A design that is hard to delete was hard to add, for the same reason.

**Why:** every line is carried forever — read on each visit to the file, reasoned about on
each change nearby, and migrated on every upgrade. Code that is not there cannot have a
bug, cannot go stale, and cannot be misread at 5pm by somebody who has never seen it.
Speculative structure is the worst version of this: it is paid for immediately, and the
requirement it was built for arrives in a different shape or never arrives at all.

**The two ways this gets misread**, both common enough to be worth naming:

- **Simple is not short.** A dense one-liner that takes three reads is not simpler; it is
  the same complexity with the whitespace removed. Simple means a tired reader gets it
  right on the first pass.
- **Simple is not "solves less of the problem".** Skipping the error path, ignoring the
  empty case, handling one of three inputs — that is not simplicity, it is an unfinished
  implementation, and it gets finished later by whoever hits the missing case with none of
  your context.

Deleting counts as building. The smallest change that solves a problem is sometimes a
negative diff, and removing a concept is usually worth more than adding a better one
beside it.

---

## SOLID, and what each letter is actually for

Five principles, each worth far more as a **symptom detector** than as a construction rule.

| Principle | The rule | The symptom it detects |
|---|---|---|
| Single responsibility | One reason to change per unit | You cannot name it without "and"; two unrelated tickets keep editing the same file |
| Open/closed | Extend without editing | Every new case adds an arm to the same `switch`, in three files |
| Liskov substitution | A subtype works wherever its parent does | A subclass overrides a method to raise, or a caller checks the concrete type first |
| Interface segregation | No client depends on methods it does not call | Implementers write empty methods to satisfy the interface |
| Dependency inversion | Depend on the abstraction, not the concrete | The test cannot run without a network, a clock, or a real database |

**Why the symptom column is the useful one:** every symptom there is observable in code
that already exists. The principles stated as construction rules are not. "One reason to
change" is a judgement about a future nobody has seen, and a judgement about the future is
exactly how five interfaces get written for one implementation. Wait for the symptom. It
arrives loudly, and it arrives with the evidence attached.

Single responsibility is the one with a concrete test already written down: if you cannot
name a function without using "and", it is doing two things. See
[code-style.md](code-style.md) on function size — length is the symptom, not the problem.

---

## When they pull in opposite directions

They will, and the resolution is not a compromise between them. It is a rule about *when*.

**Start with the simplest thing. Add structure at the second occurrence, not the first.**
One implementation gets no interface. Two implementations that genuinely differ get an
interface, and the second one pays for it. Three call sites doing the same thing get a
helper.

**Why the second and not the first:** an abstraction built from one example is an
abstraction shaped by an accident. Its seams land wherever that one case happened to have
seams, and the second case then either does not fit or gets bent until it does — which is
strictly worse than no abstraction at all, because now there is a wrong one and everything
depends on it. The second occurrence is the first moment the shared shape is observable
rather than guessed.

**The exception, and it is real: a boundary you cannot move later.** A published API, an
on-disk format, a database schema, a message envelope — anything with a consumer you do
not control. Getting those wrong is a migration rather than a refactor, so they earn their
design up front, on the first occurrence. Everything inside the process does not.

**What each failure costs.** Over-applied SOLID costs a reader five files to follow one
call, and taxes every future change with a seam in the wrong place. Under-applied SOLID
costs a 400-line function nobody can test in isolation, so it gets changed by copy-paste
and the bug gets fixed in two of the four copies. Both are expensive. Only one of them
looks like good engineering while you are doing it, which is why SOLID-by-rote is the
harder of the two to stop.

---

## Hard to test is a design finding

**When a change is hard to write a test for, the usual cause is the design, not the test
framework.** A function that needs a network, a clock, a real database or a live filesystem
in order to run is a function with its dependencies welded in — the symptom in the
dependency inversion row above.

The fix is in the code: take the dependency as an argument rather than reaching for it
inside. It is not a carve-out from [testing.md](testing.md)'s test-first rule, and it is
certainly not a stub for a method that does not exist — [testing.md](testing.md) records
what that one costs.
