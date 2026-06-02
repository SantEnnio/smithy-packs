# Project conventions

- Inspector fields: `[SerializeField] private`, never `public`.
- One class per file; the file name equals the class name.
- Cache `GetComponent` calls in `Awake`, never per-frame.
- Prefer dependency injection or serialized references over `GameObject.Find`/`FindObjectOfType`.
- No magic numbers — use `const`, `static readonly`, or a ScriptableObject config.
- New async code uses `async/await` with UniTask, not coroutines.
