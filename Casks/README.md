# Homebrew Cask (`agent-bento`)

[`agent-bento.rb.template`](./agent-bento.rb.template) is rendered during releases via `Scripts/render-cask.sh` into `agent-bento.rb`.

## Publishing to a Homebrew Tap (`quiinthieu/homebrew-tap`)

1. Create a public GitHub repository named `homebrew-tap` (e.g. `https://github.com/quiinthieu/homebrew-tap`).
2. Copy the rendered `dist/agent-bento.rb` artifact from a tagged GitHub Release to `Casks/agent-bento.rb` in `homebrew-tap` and push to `main`.
3. Users can then install both `Bento.app` and the `bentoctx` CLI with:

```sh
brew tap quiinthieu/tap
brew install --cask agent-bento
```

## Verifying Locally Against a Built DMG

```sh
Scripts/make-dmg.sh --output-dir dist
DMG_PATH="$(pwd)/dist/Bento-0.1.0.dmg"

brew tap-new --no-git local/bento-test
TAP_DIR="$(brew --repository local/bento-test)"
mkdir -p "${TAP_DIR}/Casks"

Scripts/render-cask.sh \
  --dmg "${DMG_PATH}" \
  --url "file://${DMG_PATH}" \
  --output "${TAP_DIR}/Casks/agent-bento.rb"

brew install --cask local/bento-test/agent-bento
# For local ad-hoc (unsigned/unnotarized) test builds only, clear Homebrew's quarantine xattr:
xattr -dr com.apple.quarantine /Applications/Bento.app
bentoctx --version

# Clean up test tap when done:
brew uninstall --cask local/bento-test/agent-bento
brew untap local/bento-test
```
