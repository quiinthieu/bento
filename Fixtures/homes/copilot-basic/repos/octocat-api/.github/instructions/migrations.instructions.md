---
applyTo:
  - "db/migrations/**/*.sql"
---

## Database Migration Instructions

- Wrap DDL statements in explicit transactions where supported.
- Never drop production columns in the same release as application code removal.
