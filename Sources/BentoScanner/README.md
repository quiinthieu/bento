# BentoScanner

`BentoScanner` orchestrates adapter discovery and precedence resolution across global and repository scopes, watches filesystem changes via FSEvents (behind a `FileWatcher` protocol), and performs debounced incremental rescans.
