---
name: fresh-review
description: Lightweight fresh-context defect review of the working-tree diff, focused on concurrency, lifetime, and teardown. One agent, findings only.
argument-hint: "[files or a focus, e.g. lib/src/flutter_ffi_uvc_impl.dart concurrency]"
---

Review the current working-tree diff for defects with one fresh-context
agent. Cheap alternative to `/code-review` for changes that touch
concurrency, lifetime, or teardown. Findings only, no cleanups or style.

## Steps

1. Spawn one `general-purpose` agent with the prompt below. Pass
   `$ARGUMENTS` as the focus. Do not review in this context yourself.

2. Relay the agent's findings to the user unchanged, ranked most severe
   first. If it reports none, say so.

## Agent prompt

```
Repo: <cwd>. Read-only. Review `git diff HEAD` (fall back to the last
commit when the tree is clean) plus the full current text of every changed
source file. Focus: <arguments, or "the whole diff">.

Report defects only. Skip style, naming, duplication, and docs unless a doc
now contradicts the code.

For every async function in the diff, list each await and, for each, the
calls that can run before it resumes: the same call again, stop, close,
dispose, a later start or open, and resource destruction. Check each state
assumption after the await against that list.

For every guard or rule added in the diff, ask what bypasses it: other
public entry points (including ones the diff did not touch), callers of the
changed function, synchronous paths, and error paths. Check that every
exception path restores state.

For every native or platform call, check which thread it may run on and
whether the callee tolerates that.

Output: at most 10 findings, most severe first. Each: file, line, one
sentence, and a concrete failure scenario (inputs and calls, then the wrong
outcome). Say "no defects found" if none survive.
```
