---
id: generic-roslyn-error
kind: correction
triggers: []
token_budget: 300
---

# Generic Roslyn error fallback

When the specific diagnostic code is not catalogued:

1. Read ±15 lines around the diagnostic line with `read_file`.
2. Re-read the message — Roslyn's wording usually points straight at the fix.
3. Propose the smallest possible `patch`.
4. Recompile.

Do NOT rewrite whole files.  Do NOT invent APIs.  Stop and report if
you cannot identify a minimal change.
