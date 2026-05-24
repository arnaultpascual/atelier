---
name: nextjs-app-router
description: Use when editing a Next.js project that uses the App Router (`app/` directory). Reference for server vs client components, layouts, route handlers, and data fetching.
---
# Next.js App Router

## Project assumption
- Next.js 14+, App Router (`app/` directory, not `pages/`).
- React Server Components default. `"use client"` only when needed.

## Server vs Client — decide once
- Default: server. No `"use client"` directive.
- Add `"use client"` only if the component needs: state, effects, browser APIs, event handlers, third-party hooks.
- Push `"use client"` to the leaf. Wrap minimal subtree.

## Data fetching
- Server components: `await fetch(...)` directly. Use `{ cache: 'no-store' }` for dynamic, `{ next: { revalidate: N } }` for ISR.
- Mutations: Server Actions (`'use server'`) over API routes for form posts.
- Client components: SWR or React Query — never `fetch` in `useEffect` for new code.

## Routing layout
- `app/foo/page.tsx` → route `/foo`.
- `app/foo/layout.tsx` → wraps `page.tsx` + children.
- `app/foo/loading.tsx` → Suspense fallback automatically.
- `app/foo/error.tsx` → error boundary; must be client component.
- `app/api/x/route.ts` → API endpoint, exports `GET`/`POST`/etc.

## Don't
- `getServerSideProps`, `getStaticProps` — those are Pages Router only.
- Import server-only modules (`fs`, `path`) from a client component.
- Use `useRouter` from `next/router` — use `next/navigation`.
- Mix `app/` and `pages/` data fetching idioms.

## Verify
- `pnpm build` / `npm run build` — must succeed before reporting done.
- `pnpm lint` if ESLint configured.
- For runtime: `pnpm dev` and hit the route.
