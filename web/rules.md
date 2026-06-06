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

## Data freshness — pages that read the DB must reflect writes (invariant)
- App Router **statically prerenders** a page by default. A page that reads the
  DB (`getAllPosts()`, a list/home) will be frozen at build time and will NOT
  show rows inserted/edited/deleted afterwards — it compiles and serves, but
  shows **stale data**. This is a runtime-behaviour bug.
- After ANY mutation in a Server Action, call `revalidatePath()` (from
  `next/cache`) for every route that displays the changed data — at least the
  list/home and the affected detail page:
  ```tsx
  "use server";
  import { revalidatePath } from "next/cache";
  export async function createPost(formData: FormData) {
    db.prepare("INSERT INTO posts ...").run(/* ... */);
    revalidatePath("/");        // public list
    revalidatePath("/admin");   // admin list
  }
  ```
- If a page must always be live (e.g. an admin list reflecting external writes),
  opt it out of static prerender with `export const dynamic = "force-dynamic";`
  (or `export const revalidate = 0;`) at the top of that `page.tsx`.

## Admin CRUD layout — one route per action (REQUIRED, not optional)
This is a HARD requirement, not a style preference. A single page holding the
list + the create form + an edit form for every row is FORBIDDEN — do not build
it, even though it would "work". The admin MUST be split into exactly these three
route files (create each as its own `page.tsx`):
1. `app/admin/page.tsx` — ONLY the list: each row shows the title with an `Edit`
   link to `/admin/<id>/edit` and an inline Delete `<form>` (confirm via a
   `"use client"` child button). NO create form, NO edit form on this page.
2. `app/admin/new/page.tsx` — ONLY the create form. Its own page + a create
   Server Action; on success `redirect("/admin")`.
3. `app/admin/[id]/edit/page.tsx` — ONLY the edit form for the ONE post named by
   `params` (await `params`, load the post, `notFound()` if missing, pre-fill the
   fields). Its own update Server Action; on success `redirect("/admin")`.

Checklist before you finish the admin: all THREE files above exist, the list page
contains no `<input>`/`<textarea>` for creating/editing, and `/admin/new` +
`/admin/[id]/edit` are reachable links from the list. If any is missing, the admin
is INCOMPLETE — add the missing route.

Keep every mutation a Server Action and `revalidatePath()` the public pages after
each (see Data freshness).
