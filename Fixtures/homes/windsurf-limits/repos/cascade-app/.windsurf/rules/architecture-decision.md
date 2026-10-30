---
trigger: model_decision
description: Consult when altering relational database schemas or index layouts
---

# Database Architecture Guidance

- Add concurrent indexes for tables exceeding one million rows.
- Document rollback steps in every migration header comment.
