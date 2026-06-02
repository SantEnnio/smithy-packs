---
id: namespaces-asmdef
kind: knowledge
triggers: ["asmdef", "namespace", "assembly", "rootNamespace", "Assembly-CSharp"]
token_budget: 450
---

# Namespaces & asmdef in Unity

Unity compiles every C# file in `Assets/` into either:

- the **default `Assembly-CSharp.dll`** (when no `.asmdef` lives in or
  above the script's folder), or
- the **assembly defined by the nearest ancestor `.asmdef`**.

## `.asmdef` essentials

```json
{
  "name": "MyGame.Runtime",
  "rootNamespace": "MyGame",
  "references": ["UnityEngine.UI"],
  "includePlatforms": [],
  "excludePlatforms": [],
  "autoReferenced": true
}
```

- `name` MUST match the file name without extension.
- `rootNamespace` is auto-prefixed by Unity when generating new scripts.
- `references` is a list of other assembly **names** (not folder paths,
  not GUIDs).  This is where missing-assembly errors get fixed.

## Resolution rules

1. A script can only see types from its own assembly + assemblies listed
   in `references`.
2. Built-in modules (`UnityEngine.UI`, `UnityEngine.AIModule`, …) must be
   added to `references` if any script uses them.
3. Cyclic dependencies (`A → B → A`) are **errors** — Unity refuses to
   compile them.
4. Adding `noEngineReferences: true` strips all UnityEngine modules — use
   only for pure-CSharp helper assemblies.

## Common Unity 6 namespaces

| using | provided by |
| --- | --- |
| `UnityEngine` | always available |
| `UnityEngine.UI` | `UnityEngine.UI` |
| `UnityEngine.UIElements` | `UnityEngine.UIElementsModule` |
| `Unity.InputSystem` | `Unity.InputSystem` (package) |
| `Unity.Mathematics` | `Unity.Mathematics` (package) |
| `Cinemachine` | `Unity.Cinemachine` (package) |
| `System.Collections.Generic` | always available (BCL) |
