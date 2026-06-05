# Web rules — Next.js App Router / React Server Components

Curated, hard-won rules for building a Next.js (App Router) app. These are
INVARIANTS: violating them compiles fine (`tsc` passes) but breaks at RUNTIME.
Apply them to every file you write.

## Client vs Server Components (the #1 trap)
- Every component in `app/` is a **Server Component by default**. Server
  Components run only on the server and may NOT use client-only features.
- If a file uses ANY of these, it MUST start with `"use client"` on the very
  first line (before imports):
  - Hooks: `useState`, `useEffect`, `useRef`, `useReducer`, `useContext`,
    `useActionState`, `useFormStatus`, `useOptimistic`, `useRouter`,
    `usePathname`, `useSearchParams`.
  - Event handlers passed to DOM elements: `onClick`, `onChange`, `onSubmit`,
    `onInput`, `onKeyDown`, etc.
  - Browser APIs: `window`, `document`, `localStorage`.
- Do NOT put `"use client"` on a file that does server work (DB access,
  `cookies()`, reading secrets) — that code would then run in the browser.
- Pattern: keep the page a Server Component (fetch data, read cookies), and
  extract the interactive part into a SEPARATE child component file that starts
  with `"use client"` and receives data via props.

## Server Actions instead of onClick for mutations
- A Server Component must NOT wire a mutation with `onClick={...}` (that needs a
  client handler). Use a **Server Action**: a function with `"use server"` (at
  the top of the function body or in a `"use server"` module), invoked via
  `<form action={myAction}>`. Buttons inside that form submit it.
- Example (Server Component, no `"use client"` needed):
  ```tsx
  async function deletePost(formData: FormData) {
    "use server";
    const id = String(formData.get("id"));
    db.prepare("DELETE FROM posts WHERE id = ?").run(id);
    revalidatePath("/admin");
  }
  // ...
  <form action={deletePost}>
    <input type="hidden" name="id" value={post.id} />
    <button type="submit">Delete</button>
  </form>
  ```
- If you need client-side state around the form (pending UI, optimistic), THEN
  make a `"use client"` child and use `useActionState` / `useFormStatus` there.

## Async params / searchParams (Next 15+)
- In `app/.../[slug]/page.tsx`, `params` and `searchParams` are **Promises**.
  Type them as `Promise<{ slug: string }>` and `await` before use:
  ```tsx
  export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
    const { slug } = await params;
    const post = getPostBySlug(slug);
    if (!post) notFound(); // from "next/navigation" → renders the 404
  }
  ```
- Always handle the missing case with `notFound()`.

## better-sqlite3 is server-only
- `better-sqlite3` is a native module — it must NEVER be imported into a Client
  Component (a file with `"use client"`). Importing it client-side breaks the
  build/runtime.
- Put DB setup in a server-only module (e.g. `lib/db.ts`, no `"use client"`),
  create the table if missing on first import, and call it only from Server
  Components or Server Actions.

## Auth / cookies
- `cookies()` (from `next/headers`) is server-only and **async** in Next 15:
  `const store = await cookies()`. Read it in Server Components / Actions /
  middleware, never in a Client Component.
- Protect a route by checking the cookie server-side (in the page/layout or
  middleware) and `redirect("/login")` when absent. A public page must NOT gate
  its own content behind that check.
