**What changed and why**

**How it was tested**

- [ ] `swift test --package-path engine`
- [ ] `cargo test --manifest-path app/src-tauri/Cargo.toml`
- [ ] `cargo test --manifest-path engine-windows/Cargo.toml`
- [ ] `pnpm --filter minutiae check`

**Checklist**

- [ ] Protocol changes update the doc and every mirror (see `CONTRIBUTING.md`)
- [ ] No new network calls
- [ ] Measurements included if performance is affected
