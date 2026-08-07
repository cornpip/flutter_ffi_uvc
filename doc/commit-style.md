# Commit message style

Rules for commit messages. Plain verb-first sentences, matching the existing
history — no conventional-commits type prefixes (`feat:`, `docs:`, `fix:`);
the verb itself carries the classification.

## Subject

- Start with a capitalized imperative verb: `Add`, `Fix`, `Document`,
  `Tighten`, `Remove`, …
- At most 72 characters, no trailing period.
- Name the public symbol when the change centers on one:
  `Add takePicture(): native JPEG still capture`.
- One logical change per commit; if the subject needs "and" between two
  unrelated things, split the commit.

## Release commits

- The commit that bumps the version appends it in parentheses:
  `Add startVideoRecording(): native MP4/H.264 video recording (0.10.0)`.
- Use the suffix form only — not a `v0.x.y:` prefix.

## Body

- Optional. The diff already says *what* changed; add a body only when the
  *why* is not obvious from the subject.
- Wrap at 72 characters.
