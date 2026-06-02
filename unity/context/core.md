# Unity primer (always loaded, ~600 tokens)

You are editing a Unity project.  Unity is a C# game engine; the build is
performed by the Unity editor in batch mode and validated by the Roslyn
compiler.  The ground truth for compile success is the **`unity_compile`**
tool output.

## What lives where

- `Assets/` — everything you can edit.  Scripts (`*.cs`), scenes (`*.unity`),
  prefabs (`*.prefab`), ScriptableObject assets (`*.asset`), and assembly
  definitions (`*.asmdef`).
- `Packages/` — read-only.  Do not edit.
- `Library/`, `Temp/`, `Logs/`, `obj/`, `Build*` — generated; ignore.
- `*.meta` files — auto-generated GUID sidecars.  Never edit by hand.

## Reading project files

Do NOT use `read_file` on `.unity`, `.prefab` or `.asset` files — they are
large Unity YAML blobs (scene / prefab / ScriptableObject data) that
quickly exhaust the context window.  Use **`unity_graph`** instead
(`scope=scene|script|prefab|orphans`) to inspect structure.  `read_file`
will REFUSE `.prefab` and `.asset` outright; override with
`{"force": true}` only for small, hand-edited assets you genuinely need
to inspect.  `read_file` on `.cs` is always fine.

## MonoBehaviour basics

- A MonoBehaviour is a C# class that inherits from `UnityEngine.MonoBehaviour`
  and is attached to GameObjects.
- Lifecycle methods are `Awake → OnEnable → Start → Update → ...`.  They
  are private by convention.
- Inspector-visible fields use `[SerializeField] private Type name;`
  rather than `public`.
- `GetComponent<T>()` is expensive — **cache it in `Awake`**, never in `Update`.

## Common compile error families

- `CS0103` — undefined identifier.  Add a `[SerializeField]`, a `using`,
  or fix a typo.
- `CS0246` — type/namespace not found.  Usually a missing `using` or
  a missing assembly reference (`.asmdef`).
- `CS1061` — member missing on a type.  Check API spelling or version.
- `CS0029` — implicit conversion not allowed.  Match types explicitly.

When a compile fails, read the diagnostic, open the file at the reported
line, propose a minimal `patch`, and recompile.
