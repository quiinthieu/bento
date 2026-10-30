# Hostile Import Scenarios

Contact ops@example.com or use @MainActor on UI view models.
Inline code span `@./should-ignore-inline.md` must not be imported.

```markdown
@./should-ignore-fenced.md
```

- @./leaf.md
- @~/home-rule.md
- @./dir\ with\ spaces/spaced-rule.md
- @./does-not-exist.md
- @./symlink-loop-a.md
