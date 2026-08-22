# Writing style

**This governs everything riprap writes**: answers in a session, plans, task descriptions,
commit messages, pull request bodies, code comments, and documentation. Not only the artifacts
with a filename. A plan written in a house style nobody applies to the conversation around it
is two standards, and the reader has to guess which one is real.

It is riprap's distillation of the [Google developer documentation style
guide](https://developers.google.com/style), used under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). Google is not affiliated with riprap
and does not endorse it. **What is here is the part that applies to every sentence.** The full
guide — the word list, punctuation, tables, code samples, UI elements, images, accessibility —
is extracted into `/riprap:write`, which is also what reviews a finished document against it.

That split is deliberate. This file is read every session; the reference is read when a specific
question comes up. Putting all seventy upstream pages here would charge every session for a
word-list lookup it will almost never make.

---

## The rules that apply to every sentence

**Second person.** Address the reader as *you*. Reserve *we* for the project speaking as
itself, and only where the antecedent is unmistakable. *User* means the user of the software
the reader is building — never the reader.

**Active voice.** Make clear who performs the action. Passive is fine when the object is what
matters (*the file is saved*), when the actor is genuinely irrelevant, or when naming the actor
would be an accusation (*over 50 conflicts were found*, not *you created over 50 conflicts*).

**Present tense.** *The server sends an acknowledgment*, not *will send*. Future tense is for
something that genuinely happens later — *the file will be archived the next time the backup
runs*. Never for how a product will behave after the next release.

**Conditions before instructions.** *To delete the document, click Delete* — not *click Delete
if you want to delete the document*. The reader who does not want that outcome can stop reading
at the comma instead of at the end.

**Say what you mean by must, can, and might.** *Must* for required. *Can* for optional. *Might*
for possible. **Avoid *should***: it leaves the reader unable to tell whether an action is
required, recommended, or merely one option. When something is recommended, say *we recommend*.
When describing a value, do not write *the value should be true* — write *set the value to
true*, or *the server sets it to true*, or *if it is false, change it*.

**Be timeless.** Document how things work now. *Currently*, *now*, *new*, *latest*, *soon*, *at
present*, *eventually* and *does not yet* either date the text or leak a roadmap. If you must
say *new*, anchor it to a version or a date.

**No excessive claims.** Avoid *best*, *simplest*, *fastest*, *always*, *never*, *ensures*,
*guarantees* unless the thing is genuinely guaranteed. A claim that a system *is secure* is
falsified by the first incident; *helps with security* survives it.

**Never call the work easy.** *Simply*, *just*, *easy*, *quickly*, *obviously* tell a reader who
is stuck that the problem is them. Cut the word; the sentence is almost always better without it.

**Write around jargon.** Prefer the plain term. If a term earns its place, define it in
parentheses on first use or link a definition. Ban list: use *allowlist* and *denylist*, and
prefer plain alternatives to *blast radius*, *ingest*, *off-the-shelf*.

**No anthropomorphism.** *A Delimiter specifies where to split a string*, not *tells the splitter
where a string should be broken*. Software does not see, know, want, or try.

**Sentence case for every heading and title.** Task headings start with a bare infinitive —
*Create an instance*, not *Creating an instance*. Concept headings are noun phrases. No trailing
period, no numbers to imply sequence, no links inside a heading.

**One idea per paragraph, most important thing first.** A paragraph past five or six sentences
is usually two paragraphs. A reader who stops after the first sentence should still have the
point.

**Descriptive link text.** Use the destination's title or a phrase that says what is there.
Never *this document*, *click here*, or a bare URL — a screen reader user jumping link to link
gets nothing from any of them. Introduce a reference with *For more information, see …*.

**Contractions are fine, and negative ones are better.** *Don't* and *isn't* are harder to
misread than *do not* and *is not*, because a scanning reader drops *not*.

**No exclamation marks. No `&` for *and*. Serial commas.**

---

## Writing a task somebody else will pick up

Rule 1 sets the bar for reading work: **below 95% confidence, ask**. This is the same bar
pointed the other way, and it is the half that decides whether anyone downstream ever reaches it.

**Break a plan into tasks each written so that any agent picking one up is already over 95%
without coming back to ask.** The test is concrete: *can someone who has read only this task and
the repository start on it, without inventing a detail you did not supply?* If not, it is not a
task — it is a question you left for somebody else, and they will answer it with a guess you
never see.

A task that clears the bar names:

- **What changes**, in repository-relative paths.
- **What done means** — the check that settles it, and the result to expect.
- **What it depends on**, if the order matters.
- **What you did not check.** Silence reads as *checked*, and the reader budgets accordingly.

The cost of getting this wrong is asymmetric. A vague task does not fail loudly; it gets picked
up, interpreted, and completed — and the interpretation only surfaces at review, when the work
is already written and its author is committed to it.

---

## Applying it

**While drafting** — a plan, a task, a handoff, a pull request body — write to this file. It is
short enough to hold in your head, and it covers what goes wrong most.

**Before publishing something substantial**, run `/riprap:write` over it. That is where the word
list, punctuation, table, code and UI rules live, and it checks the draft rather than making you
carry seventy pages of guidance through the work.

**Where a project disagrees with this file, the project wins** — as with everything riprap ships.
A repository with its own style guide has one for reasons riprap cannot see.
