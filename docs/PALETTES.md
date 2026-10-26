# Haven palettes (personalization)

One curated set, identical on iOS, macOS, Android, desktop (Windows/Linux). The user picks one in
Settings → Appearance. The default is `sunset` (today's look). `neutral` is the colour-free option.

Each palette is three gradient stops. **Stop 2 is the tint** (the accent used for controls, links,
selection, the Post pill). Stop 1 and 3 only appear in gradients, glows and the avatar ring. Every
place that today hard-codes violet `#7C3AED` / pink `#EC4899` / amber `#F59E0B` reads these stops
instead (violet→stop1, pink→stop2, amber→stop3). Light-mode contrast adjustments (darkening stop 2/3 for
text-on-white, as Android Theme.kt does for pink/amber) are derived per platform from the stop — do not
add per-palette overrides unless a pair fails WCAG AA.

| id | name | stop 1 | stop 2 (tint) | stop 3 |
|---|---|---|---|---|
| `sunset` | Sunset (default) | #7C3AED | #EC4899 | #F59E0B |
| `ocean` | Ocean | #2563EB | #06B6D4 | #14B8A6 |
| `forest` | Forest | #047857 | #10B981 | #84CC16 |
| `rose` | Rose | #BE123C | #F43F5E | #FB923C |
| `ember` | Ember | #B91C1C | #F97316 | #FACC15 |
| `sky` | Sky | #0EA5E9 | #6366F1 | #A78BFA |
| `grape` | Grape | #6D28D9 | #A855F7 | #F472B6 |
| `neutral` | Neutral | #374151 | #6B7280 | #9CA3AF |

`neutral` must also strip colour from decoration that is not a palette stop (glows tinted pink, the
violet/pink avatar rings, gradient pills): they render in the grey stops. Semantic colours (ok green,
warn amber, destructive red, sensitive-content blur) are NOT themed.

## Setting
- Key: `appearance.palette`, value = one of the ids above, default `sunset`, unknown → `sunset`.
- Per-device (not synced) in this wave.
- Applies live, no restart (iOS/mac: re-render root; Android: recompose; desktop: CSS variables).

## App icon
`apple/icon/make_palette_icons.py` renders `packaging/palette-icons/<id>.png` (1024px) from the table
above — re-run it if a stop changes. Per platform:
- iOS: alternate app icons (`CFBundleAlternateIcons`, one per non-default palette), applied with
  `UIApplication.setAlternateIconName` (the system shows its own "icon changed" alert; unavoidable).
- macOS: set `NSApp.applicationIconImage` at runtime and on launch. Finder/Launchpad keep the bundled
  icon — best effort, documented in the settings footer.
- Android: one `<activity-alias>` per palette (launcher icon via mipmap/adaptive icon), enable the
  chosen one and disable the rest with `PackageManager.setComponentEnabledSetting(DONT_KILL_APP)`.
- Windows/Linux (Tauri): runtime window + taskbar icon only; the packaged/Start-menu icon is fixed.

## Multi-circle posting
Long-press (right-click on desktop/macOS) the Post button → checklist of the user's circles (current
one pre-checked, DMs excluded) → "Post to N circles". A plain tap is unchanged (this circle only; no
picker or confirmation on the normal path). The post is authored once per selected circle with the same
body/media/song/retention; media is stored/uploaded once and referenced per circle where the transport
allows. Show a one-time hint after a few posts only when the user is in 2+ circles.
