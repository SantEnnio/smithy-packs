# smithy-packs

Domain packs for [Smithy](https://github.com/SantEnnio/smithy) — curated context,
conventions, canonical examples, correction indexes and script-backed tools that
teach the agent a specific domain.

Each top-level directory is one pack, with a `pack.toml` manifest at its root:

- `unity/` — Unity / C# game-dev pack
- `web/` — web pack

## How Smithy uses this repo

The Smithy app keeps a clone of this repo at `~/.smithy/packs` and refreshes it
on launch (clone on first run, fast-forward pull afterwards). It then auto-selects
the pack whose `[detect]` rules match the opened project.

Overrides (mainly for development):

- `SMITHY_PACKS_DIR=/path/to/smithy-packs` — use a local checkout instead of
  `~/.smithy/packs` (and skip the startup sync).
- `SMITHY_PACK_DIR=/path/to/smithy-packs/unity` — force a single pack.

## Adding or editing a pack

Edit the files here and push. Installed apps pick up the change on their next
launch via the fast-forward pull. Keep `pack.toml` schema-compatible with the
Smithy version that consumes it.
