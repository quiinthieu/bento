---
paths:
  - "src/api/**/*.ts"
---
# API Handler Rules

- Validate request bodies with Zod schemas before calling service methods.
- Return structured RFC 7807 problem JSON on 4xx and 5xx responses.
