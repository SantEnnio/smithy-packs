---
id: serialized-field-rename
kind: correction
triggers: ["[SerializeField]", "rename serialized", "FormerlySerializedAs", "field hidden in Inspector"]
token_budget: 500
---

# Serialized field — add, rename, or expose

A **`[SerializeField] private <Type> <name>;`** declaration is how a private
field becomes Inspector-editable.  Public fields work too but break Unity
conventions; prefer `[SerializeField] private`.

## When the field is missing

```csharp
[SerializeField] private float speed = 5f;   // sensible default
```

Put the declaration right after other serialized fields, before
`Awake`/`Start`.

## When you must rename a serialized field

Renaming a serialized field WITHOUT `[FormerlySerializedAs]` will silently
**drop the value already saved in scenes/prefabs**.  Always preserve the
old name as an alias:

```csharp
using UnityEngine.Serialization;

[FormerlySerializedAs("oldName")]
[SerializeField] private float newName = 5f;
```

## Repair recipe

1. Read the file with `read_file`.
2. If the field is missing → add `[SerializeField] private <T> <name> = <default>;`.
3. If the field is being renamed → keep the existing serialization by
   wrapping the new declaration with `[FormerlySerializedAs("oldName")]`
   and adding `using UnityEngine.Serialization;` at the top.
4. Patch with `patch`, then recompile.
