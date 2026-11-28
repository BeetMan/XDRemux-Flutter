# dmgbuild settings for the macOS installer window.
#
# Loaded by tools/apple/dmg/make_dmg.sh, which passes:
#   stage  absolute path of the staging directory
#   app    name of the .app bundle inside it
#   icon   .icns used as the volume icon ("" for none)
#   assets directory holding background.png / background@2x.png
#   decorated  directory with copies of the shortcuts that carry a custom
#               Finder icon ("" to take them from the staging folder)
#   links   directory with the website .webloc shown in the top-right corner
#           ("" for none)
#
# Everything else in the staging directory (licence files, the Privacy &
# Security shortcut) goes into a row along the bottom of the window.
#
# The window size and the icon centres are shared with gen_background.swift,
# which draws the wordmark, the arrow between the app and the Applications
# link and the hairline above the bottom row. Change both together and
# regenerate the background.

import os

# Content area of the window in points; background.png is drawn for it.
CONTENT = (660, 476)
HERO_Y = 188
SMALL_Y = 352
# Wide enough that the privacy shortcut's name, at text_size 12, fits cleanly
# inside the bottom shelf. Tightened only when four or more items are staged.
SMALL_SPACING = 186
# Website link, under the top-right corner, clear of the hero row (14pt gap
# between the bottom of the 24pt label mat and Applications' icon top) and
# far enough from the edge even when Finder shows extensions.
LINK = (548, 52)

# Finder's window bounds include the title bar, so the window is taller than
# the picture. 32 is the title bar of a toolbar-less window on macOS 26; on
# older systems it is a few points shorter and Finder shows a little more of
# the spare grid at the bottom of the picture instead.
TITLE_BAR = 32

stage = defines["stage"]
app = defines["app"]
volume_icon = defines.get("icon") or None
decorated = defines.get("decorated") or ""


links = defines.get("links") or ""


def source(name, default_dir):
    """Path for an item, preferring the icon-decorated copy."""
    copy = os.path.join(decorated, name)
    if decorated and os.path.isfile(copy):
        return copy
    return os.path.join(default_dir, name)


files = []
extras = []
hide_extensions = []
for name in sorted(os.listdir(stage)):
    if name == "Applications" or name.startswith("."):
        continue
    if name != app:
        extras.append(name)
        if name.endswith(".inetloc"):
            hide_extensions.append(name)
    files.append((source(name, stage), name))

symlinks = {"Applications": "/Applications"}

icon_locations = {app: (170, HERO_Y), "Applications": (490, HERO_Y)}
if links and os.path.isdir(links):
    for name in sorted(os.listdir(links)):
        if name.startswith("."):
            continue
        files.append((source(name, links), name))
        hide_extensions.append(name)
        icon_locations[name] = LINK
count = len(extras)
spacing = SMALL_SPACING if count < 2 else min(SMALL_SPACING, (CONTENT[0] - 120) / (count - 1))
for index, name in enumerate(extras):
    x = int(CONTENT[0] / 2 + (index - (count - 1) / 2) * spacing)
    icon_locations[name] = (x, SMALL_Y)

format = defines.get("format", "UDZO")
window_rect = ((200, 120), (CONTENT[0], CONTENT[1] + TITLE_BAR))
icon_size = 96.0
# dmgbuild's default is 16pt. At that size the privacy shortcut's name
# ("打开隐私与安全性 (Privacy & Security)", ~210pt wide at 12pt) runs into the
# neighbouring licence file and off the right edge of the window.
text_size = 12.0
icon = volume_icon
background = os.path.join(defines["assets"], "background.png")
default_view = "icon-view"
show_sidebar = False
show_toolbar = False
show_pathbar = False
show_status_bar = False
show_tab_view = False
arrange_by = None
