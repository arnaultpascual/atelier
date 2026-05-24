---
name: node-package-management
description: Use when adding, upgrading, or removing dependencies in a Node.js backend project. Reference for pnpm/yarn/npm lockfile semantics and CI hygiene.
---
# Node Package Management

## Detect the manager from the lockfile
- `pnpm-lock.yaml` → `pnpm`
- `yarn.lock` → `yarn`
- `package-lock.json` → `npm`
- No lockfile → use `npm`, but flag this as a setup gap.

Never mix managers in the same project. Adopt whatever the lockfile says.

## Add / remove
```bash
pnpm add <pkg>             pnpm add -D <pkg>             pnpm remove <pkg>
yarn add <pkg>             yarn add -D <pkg>             yarn remove <pkg>
npm install <pkg>          npm install -D <pkg>          npm uninstall <pkg>
```

## Upgrade rules
- Patch / minor: ok to bump.
- Major: ask before bumping unless task asks for it.
- Always commit the lockfile change with the `package.json` change.

## CI install (deterministic)
- `pnpm install --frozen-lockfile`
- `yarn install --immutable`
- `npm ci`

## Don't
- Run `npm install <pkg>` in a pnpm project.
- Delete `node_modules` to "fix" things without first checking the lockfile is intact.
- Commit `node_modules`. Add it to `.gitignore`.
- Add dependencies that already exist transitively just to "make it explicit" — bloats the tree.

## Verify
- Manager-specific `install` finishes clean.
- `node -e "require('pkg-name')"` or the project's smoke script confirms the import works.
- For type packages: `tsc --noEmit` after install.
