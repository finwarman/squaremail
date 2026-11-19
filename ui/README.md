# Shared ClassicKit themes

`themes.json` is the editable source for Classic and Pink in Mail and WordCraft Fin. It has no mail/document/provider concepts. Colours are semantic sRGB roles; metrics are logical points or milliseconds. Both native adapters are compiled constants, with no palette parsing, polling or observers during rendering.

Edit the source once, then generate both clients:

```
python3 ui/generate.py --wordcraft /path/to/wordcraft
python3 ui/generate.py --wordcraft /path/to/wordcraft --check
```

Swift output is `macos/ClassicKit/SharedClassicTokens.swift`. Rust output is `crates/ui-egui/src/theme_shared.rs` in WordCraft. Both carry the same SHA256 source digest. Generated files are vendored so either application builds offline without the other repository. Commit regenerated adapters with the source change. CI can run `--check` with both checkouts. Do not edit generated palette literals or fork the Pink table.

This package lives with ClassicKit while the projects are private. Its schema/generator and adapters are independent of the applications and can move into their own package without changing the theme contract. UI-only colours must never change stored mail or document formatting.

Optional cursor sparkles use the same shared metrics in both apps:32 particles,450ms lifetime,33ms frame interval,8pt spacing and3pt radius. Classic uses its dark accent; Pink uses plum. Square Mail View / Cursor sparkles is off by default and persists per app. A process-local event monitor returns events unchanged; no OS-wide hook or permission is used. Click/drag, Reduce Motion, inactive/hidden/occluded windows and sleep clear the trail. Idle has no timer. Up to32 reusable8x8pt views avoid a full-window overlay texture; disabling releases those views and the monitor/observers. Document/mail content and exports are unchanged.

Caption gradients use each palette’s dark/light endpoints. The fade starts at15% and reaches the palette-specific blend at70%, then continues to the light right edge. This broadens the light field while keeping white central title text at least4.5:1 against the middle stop in both palettes. Shared metrics control both toolkit adapters.

Caption glitter is an original static pixel pattern shared by both adapters. Small edge stars/flecks leave the central text band clear. The compiled source bounds marks, opacity and128 horizontal repetitions. Swift draws rectangles and Rust batches one small mesh, with no image texture, view, timer, random generator or idle repaint. Classic/Pink retain their existing gradient endpoints.

Pink uses lighter blush surfaces, a brighter rose selection and a pale pink-lilac workspace. Its caption blend is28% at the middle stop to retain white-title contrast with the brighter base; Classic remains40%. These values stay in each shared palette and are compiled into both clients.
