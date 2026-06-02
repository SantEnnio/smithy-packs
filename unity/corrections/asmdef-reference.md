---
id: asmdef-reference
kind: correction
triggers: ["asmdef", "assembly reference", "the type or namespace name 'UI'", "UnityEngine.UI", "missing assembly"]
token_budget: 500
---

# Assembly reference missing in .asmdef

When a script uses a type from another Unity module (e.g. `UnityEngine.UI`,
`Unity.InputSystem`, `UnityEngine.AI`) but the assembly that owns the
script doesn't reference it, the compiler emits **CS0246** (type/namespace
not found).  The fix lives in the `.asmdef`, not in the script.

## Diagnose first

1. Find the `.asmdef` that owns the failing script (walk up from the
   script's folder; the nearest `.asmdef` wins).
2. Open the `.asmdef` — it is JSON.

## Add the missing reference

If the script uses `using UnityEngine.UI;`, the `.asmdef` needs:

```json
{
  "references": [
    "UnityEngine.UI"
  ]
}
```

Common namespaces → assembly references:

| using | reference |
| --- | --- |
| `UnityEngine.UI` | `UnityEngine.UI` |
| `UnityEngine.UIElements` | `UnityEngine.UIElementsModule` |
| `UnityEngine.AI` | `UnityEngine.AIModule` |
| `Unity.InputSystem` | `Unity.InputSystem` |
| `UnityEngine.Animations.Rigging` | `Unity.Animation.Rigging` |
| `Unity.RenderPipelines.Universal.Runtime` | `Unity.RenderPipelines.Universal.Runtime` |

## Repair recipe

1. `read_file` the failing script — confirm which `using` is unresolved.
2. `read_file` the `.asmdef` that owns the script.
3. `patch` the `.asmdef` to add the missing entry to `"references"`.
4. `unity_compile` — confirm green.

If adding the reference would create a dependency cycle, the alternative is
to remove the dependency on the foreign assembly (e.g. replace `Image`
with a plain `SpriteRenderer`).
