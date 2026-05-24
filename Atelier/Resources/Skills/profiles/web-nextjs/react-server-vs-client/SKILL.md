---
name: react-server-vs-client
description: Use when adding or refactoring components in a Next.js App Router project. Reference for the boundary between server and client components and how to ferry data across.
---
# React Server vs Client

## Rule of thumb
- Server component: no state, no effects, no event handlers, no browser APIs. Can `await` data.
- Client component: anything reactive or browser-bound. Marked `"use client"` at the top.

## Push the boundary down
Aim: largest possible server subtree, smallest possible client leaves.

```
Page (server)
  Header (server)
  Body (server)
    Posts (server, fetches data)
      LikeButton (client) ← only this needs interactivity
```

NOT this:

```
Page (client) ← everything client because one button is interactive
```

## Crossing the boundary
- Server → Client: props are serialized. Only pass JSON-safe values. No functions, no Date that you mutate, no class instances.
- Client → Server: not via props. Use Server Actions or fetch a route handler.
- Composition pattern: server component passes server components as `children` to a client component.

```tsx
// app/layout.tsx (server)
<ClientShell>
  <ServerSidebar />   {/* server, rendered ahead of time */}
</ClientShell>
```

## Don't
- Make a component client just because one descendant needs `useState`. Refactor first.
- Pass a server-fetched object with non-serializable fields directly to a client.
- Import a client component from a server component AND assume client hooks work in the server. They don't.

## When in doubt
Start server. Convert to client only when the compiler / runtime forces it.
