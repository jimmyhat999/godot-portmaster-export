# PortMaster Export

A Godot 4 editor plugin that packages your game as a
[PortMaster](https://portmaster.games/) port for Linux handhelds, ready to copy
to an SD card or submit to the PortMaster catalogue.

It leaves your game alone. The Compatibility renderer, the gamepad mapping and
the launcher live only in the port it builds.

## What it builds

One press of **Build port**:
1. **Exports the game** as a `.pck`, which PortMaster's shared Godot runtime
   runs, through an export preset it adds for you.
2. **Switches the renderer** to Compatibility (GLES3) for the port only, with an
   `override.cfg` beside the pck. Your project keeps its own renderer.
3. **Maps the controls.** It generates the gptokeyb mapping (`.gptk`) from your
   Input Map: each gamepad button sends a keyboard key its action already uses.
   You can override any button in the dock.
4. **Writes the launcher**, PortMaster's standard Godot launcher with your
   paths and the right Godot runtime filled in.
5. **Writes the catalogue files:** `port.json`, `gameinfo.xml` and a README
   with a controls table.
6. **Copies art and licences.** The screenshot is scaled to 640x480 when it's a
   multiple of 320x240, and licences go into a flat `licenses/` folder.
7. **Checks the result** against PortMaster's rules: name, screenshot size,
   required files, file sizes, line endings and encoding.

## Requirements

- **Godot 4.5 or newer.** Tested on 4.5 and 4.7.2.
- **GDScript projects.** C# projects need PortMaster's Mono runtime, which
  this plugin doesn't support yet.
- **No export templates.** The plugin only exports a pck, so you don't need
  them.

## Install

1. Copy `addons/portmaster_export/` into your project's `addons/` folder, or
   install it from the Asset Library.
2. In Project > Project Settings > Plugins, enable **PortMaster Export**.
3. A **PortMaster** tab appears in the top-right panel, next to Inspector.
   If you can't see it, use the arrows at the end of the tab row.

## Use

1. **Fill in the dock:** port name (lowercase, unique in PortMaster's
   catalogue), title (it also names the launcher file), porter, developer,
   description, genres, store URL (itch.io, Steam, GOG...) and README credits. Long fields have an **Edit** button for a larger editor.
2. **Add a screenshot** at the screenshot path. PortMaster wants a 640x480
   `screenshot.png` or `.jpg` showing gameplay. A grab that's an exact multiple
   of 320x240 (e.g. 1280x960) is scaled down, and other formats are converted to
   PNG. A cover (`cover.png`/`.jpg`) is optional. You can build and test on a
   device without a screenshot; the log lists it under "Before submitting".
3. **Add licences:** one file per third-party asset (fonts, music, art) in the
   licences folder, by default `res://portmaster/licenses/`. Name them
   `LICENSE.<component>.txt`, as PortMaster asks.
4. **Check the controls table.** Change a key to override it, clear it to unmap
   the button, and fill in the Action column for the README. The README shows
   the d-pad as a single row, named by the D-Pad Up Action.
5. **Press Build port.** It saves your open scenes first, like Scene > Save All
   Scenes, because the export reads files from disk. If another tool edits scene
   files while they're open in Godot, reload them before building. It never
   writes `project.godot`. If you've just changed a project setting, it waits
   a moment for Godot to save it. If an open script differs from its file, or an
   untitled scene is open, it tells you and waits; press Build port again to
   build from the files on disk anyway. While it runs, the button becomes
   **Cancel build**. The Log section shows each step and the checks. If a build
   fails or is cancelled, the previous port is left as it was.

The export runs in a second, headless Godot on your project. Godot 4.5 doesn't
let a plugin export from inside the editor, so avoid editing or saving until the
build finishes. The editor rescans the project afterwards.

The controls table follows the Input Map. When you change a binding, it updates
a moment later and keeps your edits. **Reset to Input Map** also discards your
key overrides, but keeps your Action labels.
Set **Release date** (YYYYMMDD) to the game's release date; when it's blank,
`gameinfo.xml` leaves it out.

Settings are saved in `res://portmaster/port.cfg`. The `res://portmaster/`
folder gets a `.gdignore`, so Godot doesn't import the screenshot or licences
and they never end up in your game.

The first build adds a "PortMaster" export preset (Linux, arm64, pck only,
ETC2/ASTC) to `export_presets.cfg`. It copies your Windows preset's settings and
exclusions, but not encryption, custom features (such as `steam`) or
dedicated-server mode. Restart the editor to see it in
Project > Export. Restart before opening that dialog, or the editor may save
over the new preset.

## Output

The port goes to `<output>/<port>/`. By default that's
`<project>/../PortMaster/<port>/`, outside your project.

```
<port>/
  <Title>.sh              launcher
  port.json  gameinfo.xml  README.md  screenshot.png  [cover.png]
  <port>/
    <port>.gptk           gamepad -> keyboard mapping
    gamedata/<port>.pck
    gamedata/override.cfg Compatibility renderer
    licenses/
```

- **Play it:** use **Install port** (below). PortMaster installs ports in a
  slightly different layout from this one, so copying the folder by hand isn't
  enough.
- **Submit it:** copy the folder into `ports/` in a clone of
  [PortMaster-New](https://github.com/PortsMaster/PortMaster-New), run
  `python tools/build_release.py --do-check`, then follow PortMaster's
  testing and pull-request process.

## Install to an SD card

To test on a device before the port is in PortMaster's catalogue, put the
device's SD card in your computer and press **Install port**. The dock's
**SD card** list shows the drives that hold a handheld's card, with its
firmware, e.g. `E:  (Knulli)`; press **Refresh** after putting a card in. For a card reached
over the network (such as Knulli's Samba share), choose **Other folder...**
and pick the share's root folder. With **Build first** ticked (the default),
it builds the port and installs it only if the build succeeds, so the card
always gets your latest changes. Untick it to install the last build again
without rebuilding, e.g. to put the same build on another device's SD card.

It installs the port the way PortMaster's own installer would and checks every
copied file. It never deletes the port's saves (`conf/`) on the card.
PortMaster must have been run once on the device.

| Firmware | Where the port goes | Tested on a device |
|---|---|---|
| NextUI (with the PortMaster pak) | `Roms/Ports (PORTS)/.ports/`; the launcher also in `Roms/Ports (PORTS)/`; the screenshot becomes the Ports menu picture | Yes (TrimUI Brick) |
| Knulli, Batocera, REG-Linux | `roms/ports/` on the SHARE partition | Knulli (TrimUI Brick) |
| ArkOS, dArkOS | `ports/` on the EASYROMS partition | No |
| ROCKNIX, JELOS | `roms/ports/` on the games card | No |
| AmberELEC, UnofficialOS | `ports/` on the games partition | No |

The card layouts come from PortMaster's own installer. On every firmware
except NextUI, the port's title, description and screenshot are added to the
Ports game list (`gamelist.xml`), keeping play counts and favourites; the
previous list is kept as `gamelist.xml.bak`, as PortMaster does. The
installer doesn't use PortMaster's autoinstall, which can hang on Knulli.
- **Not supported yet:** muOS, TrimUI's stock firmware, CrossMix, Spruce and
  Onion use their own layouts. Their cards are listed as "not supported yet",
  and Install port explains why.
  ROCKNIX on a single card, and Knulli with an ext4 SHARE partition, can't be
  read from Windows at all.
- **Add missing runtimes** (on by default) copies the Godot runtime and Weston
  onto the card, so the first launch doesn't need Wi-Fi. It downloads the build
  for the device's CPU (aarch64, armhf or x86_64, as PortMaster recorded it on
  the card) and checks it against PortMaster's checksum; if PortMaster hasn't run
  on the device yet, it leaves the download to the first launch. Runtimes already
  on the card are never replaced. On NextUI it never adds Weston, because the pak
  ships its own, and PortMaster's doesn't run there.
- **Checks:** on NextUI, it warns when the `nintendo` file is missing, because
  without it A/B and X/Y are swapped in every port. It also warns when
  PortMaster has replaced the pak's Weston, which stops Godot ports starting.
  On Knulli, it reads the card's settings and warns when the ports' A/B X/Y
  swap (Xbox layout) is off.

Eject the card safely afterwards. The chosen card is remembered per project on
this computer, not in `port.cfg`.

## Godot runtimes

PortMaster runs your pck on its shared Godot runtime, which must match your
editor version. On each build the plugin reads PortMaster's current runtime
list, falling back to a built-in copy when offline. It then picks:
- **An exact match** when there is one, e.g. `godot_4.5`.
- **Otherwise, the newest runtime in your editor's series,** e.g. a 4.7.2 editor
  uses `godot_4.7.1`. Godot only rejects a pck from a newer *minor* version, so
  this works, but the log reminds you to test on a device.
- **If there's none for your series,** the build stops. You can force a
  runtime with the dock's **Godot runtime** field.

## Controls

The game's gamepad support is switched off on the device, and gptokeyb turns
button presses into keyboard keys instead. For each gamepad button, the
plugin:
- picks a key that the button's actions already use, preferring keys that
  don't also trigger other actions;
- leaves the button unmapped when only Godot's built-in actions use it and its
  key would trigger something else;
- points the left stick at the d-pad's keys;
- warns about any of your actions that has keyboard keys but no gamepad button
  sending one of them. Those actions can't be used on the device until you set
  a button for them in the controls table, which is typical for keyboard-only
  games.

PortMaster names face buttons by their printed letter (Nintendo layout), so A
is the right-hand button on most devices. The README tells Knulli users to
turn on the A/B X/Y swap option.

## Headless use

`builder.gd` also runs without the editor:

```gdscript
var B = load("res://addons/portmaster_export/builder.gd")
var builder = B.new()
builder.build(project_dir, B.load_settings(project_dir))
```

## Licence

MIT, see `LICENSE`. The launcher template is PortMaster's, also MIT; see
`THIRD_PARTY_NOTICES.md`.
