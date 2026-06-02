---
id: unity-lifecycle
kind: knowledge
triggers: ["Awake", "Start", "OnEnable", "OnDisable", "Update", "FixedUpdate", "lifecycle", "MonoBehaviour"]
token_budget: 450
---

# MonoBehaviour lifecycle (essentials)

Per-object events fire in this order on a fresh GameObject:

1. **`Awake()`** — called once, even if the script is disabled.
   Use it to cache component references (`GetComponent<T>()`).
2. **`OnEnable()`** — called every time the script becomes enabled,
   including after `Awake`.  Subscribe to events here.
3. **`Start()`** — called once, only if the script is enabled, before
   the first `Update`.  Use it for setup that depends on OTHER scripts'
   `Awake` having already run.
4. **`Update()`** — every frame.  Keep it light.
5. **`FixedUpdate()`** — at a fixed timestep (default 0.02 s).  Use it
   for physics (`Rigidbody`/`Rigidbody2D`).
6. **`OnDisable()`** / **`OnDestroy()`** — symmetric to `OnEnable`/`Awake`.
   ALWAYS unsubscribe from events you subscribed to in `OnEnable`.

## Don't do

- Don't call `GetComponent<T>()` in `Update` — cache it in `Awake`.
- Don't use `FindObjectOfType` / `GameObject.Find` in hot paths — they
  scan the whole scene; cache the reference or expose a serialized
  field.
- Don't use coroutines for physics — physics needs `FixedUpdate`.

## Reading-by-imitation example

```csharp
using UnityEngine;

public class PlayerMovement : MonoBehaviour
{
    [SerializeField] private Rigidbody2D body;
    [SerializeField] private float speed = 5f;

    private void Awake()
    {
        if (body == null) body = GetComponent<Rigidbody2D>();
    }

    private void FixedUpdate()
    {
        float h = Input.GetAxisRaw("Horizontal");
        body.linearVelocity = new Vector2(h * speed, body.linearVelocity.y);
    }
}
```
