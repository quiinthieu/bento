---
name: deploy-check
description: Verify build, database migrations, and rollout health checks before deploying demo-app.
---
# Deploy Check Workflow

1. Run `npm run typecheck` and `npm test` to confirm a clean build.
2. Inspect pending migrations under `db/migrations/` for backward compatibility.
3. Confirm health-check endpoints respond within 200 ms on staging.
