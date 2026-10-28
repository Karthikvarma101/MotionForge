# dmgbuild settings for scripts/make-dmg.sh; the paths arrive as -D app=… background=… icon=…
# The window: MotionForge on the left, an Applications shortcut on the right, an arrow between them.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
appname = os.path.basename(app)

format = "ULMO"  # LZMA; any Mac that can run MotionForge (macOS 26) opens it
files = [app]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: it writes Finder info onto the bundle, which `codesign --verify --strict` rejects.
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821  (background.png, with background@2x.png beside it)

window_rect = ((200, 140), (600, 432))  # 400 pt of content under the title bar
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
# Must match the centres in scripts/make-dmg-background.swift.
icon_locations = {appname: (150, 160), "Applications": (450, 160)}
