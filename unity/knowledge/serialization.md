---
id: unity-serialization
kind: knowledge
triggers: ["SerializeField", "Inspector", "FormerlySerializedAs", "serialization"]
token_budget: 450
---

# Unity serialization

- Public fields are auto-serialized.  Private fields require
  `[SerializeField]` to appear in the Inspector.
- To rename a serialized field without losing its values, keep the old
  Inspector name with `[FormerlySerializedAs("oldName")]` on the new
  field declaration.
- Static fields are NOT serialized.
- Generic fields are not serialized by Unity 5 / 6 unless the concrete
  generic type has its own `[Serializable]`-tagged container.
