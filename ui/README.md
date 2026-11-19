# Shared ClassicKit themes

`themes.json` is the editable source for Classic and Pink in Mail and WordCraft Fin. It has no mail/document/provider concepts. Colours are semantic sRGB roles; metrics are logical points or milliseconds. Both native adapters are compiled constants, with no palette parsing, polling or observers during rendering.

Edit the source once, then generate both clients:

```
python3 ui/generate.py --wordcraft /path/to/wordcraft
python3 ui/generate.py --wordcraft /path/to/wordcraft --check
```

Swift output is `macos/ClassicKit/SharedClassicTokens.swift`. Rust output is `crates/ui-egui/src/theme_shared.rs` in WordCraft. Both carry the same SHA256 source digest. Generated files are vendored so either application builds offline without the other repository. Commit regenerated adapters with the source change. CI can run `--check` with both checkouts. Do not edit generated palette literals or fork the Pink table.

This package lives with ClassicKit while the projects are private. Its schema/generator and adapters are independent of the applications and can move into their own package without changing the theme contract. UI-only colours must never change stored mail or document formatting.
