# Canonical MonoBehaviour

```csharp
using UnityEngine;

public class PlayerMovement : MonoBehaviour
{
    [SerializeField] private float speed = 5f;
    [SerializeField] private Rigidbody2D body;

    private void Awake()
    {
        if (body == null) body = GetComponent<Rigidbody2D>();
    }

    private void Update()
    {
        float h = Input.GetAxisRaw("Horizontal");
        body.linearVelocity = new Vector2(h * speed, body.linearVelocity.y);
    }
}
```

Notes:
- `[SerializeField] private` keeps the Inspector contract without exposing
  the field publicly.
- The cached `body` reference is set in `Awake`, not `Update`.
- One class per file; file is `PlayerMovement.cs`.
