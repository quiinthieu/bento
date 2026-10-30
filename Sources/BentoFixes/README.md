# BentoFixes

`BentoFixes` plans, previews (unified diff), backs up, atomically applies, verifies, rolls back, and undoes reversible configuration fixes. Outside `BentoStore`'s own database, `BentoFixes` is the sole module permitted to write, symlink, or move user files to the Trash.
