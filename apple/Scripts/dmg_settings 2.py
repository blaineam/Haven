# dmgbuild settings for Haven's styled drag-to-Applications installer. dmgbuild writes the volume's
# .DS_Store directly (no Finder), so the brand background + icon layout actually apply on a headless
# CI runner — unlike a Finder AppleScript, which silently no-ops there.
#
#   dmgbuild -s dmg_settings.py -D app=/path/Haven.app -D bg=/path/dmg-background.png "Haven" out.dmg
import os.path

app = defines.get("app", "Haven.app")
bg = defines.get("bg", "dmg-background.png")

files = [app]
symlinks = {"Applications": "/Applications"}
background = bg

# 660×400 window — matches the background art.
window_rect = ((200, 200), (660, 400))
icon_size = 100
icon_locations = {
    os.path.basename(app): (165, 200),
    "Applications": (495, 200),
}
