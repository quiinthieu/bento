# BentoScanner

`BentoScanner` orchestrates adapter discovery, precedence resolution, and context token budget assembly (`BudgetEngine`, `Workspace.budget`) across global and repository scopes, watches filesystem changes via FSEvents (behind a `FileWatcher` protocol), and performs debounced incremental rescans.
