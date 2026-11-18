@tool
extends "task.gd"
## Installs a built port onto a device's SD card the way PortMaster's own
## installer would, for testing before the port is in the catalogue.
##
## Supported layouts (see detect()):
## - NextUI with the minui-portmaster pak (tested on a TrimUI Brick): ports in
##   "Roms/Ports (PORTS)/.ports", launchers there and in its parent, thumbnails
##   in ".media".
## - EmulationStation firmwares: Knulli (tested on a TrimUI Brick), Batocera,
##   REG-Linux, ArkOS, dArkOS, ROCKNIX, JELOS, AmberELEC, UnofficialOS. Ports and
##   launchers in "<roms>/ports", game details merged into its gamelist.xml (as
##   PortMaster's gamelist_add does).
##
## Never deletes a port's conf/ (saves) and never replaces a runtime that is
## already on the card (NextUI ships its own patched Weston).

const Builder := preload("builder.gd")
const PORTS_JSON_URL := "https://github.com/PortsMaster/PortMaster-New/releases/latest/download/ports.json"
## How long a download may go without receiving data before it's abandoned.
const DOWNLOAD_IDLE_MS := 60000
## PortMaster's own Weston build (Westonpack 0.2, 2025-07-24): as downloaded,
## and after the NextUI pak has re-packed it. The pak ships a patched Weston;
## this one fails there ("failed to create compositor backend").
const PORTMASTER_WESTON_MD5S := ["0a761c28877625861d9c9c4326664428", "9c69abad3ae01c717b98ae4aec707d61"]

# log_callback, cancel_requested, warnings and errors come from task.gd.


## Works out which firmware the card at `root` uses, from its folders (the
## layouts are PortMaster's own, in harbourmaster's config.py and platform.py).
## Returns {} when unknown, else {firmware, root, pm_dir, ports_dir,
## launcher_dirs, libs_dir, media_dir, gamelist, image_base, nintendo_file,
## conf_file}.
static func detect(root: String) -> Dictionary:
	root = root.replace("\\", "/").trim_suffix("/")
	if root.is_empty():
		return {}  # the filesystem root of Linux/macOS is never a card
	# Windows paths ignore case, and some unsupported firmwares have folders
	# such as "Roms/PORTS" that look like a supported layout, so rule them out first.
	if not unsupported_firmware(root).is_empty():
		return {}
	var dev := {
		"firmware": "", "root": root, "pm_dir": "", "ports_dir": "", "launcher_dirs": [], "libs_dir": "",
		"media_dir": "", "gamelist": "", "image_base": "", "nintendo_file": "", "conf_file": "",
	}

	# NextUI with the minui-portmaster pak.
	var nextui_ports := root.path_join("Roms/Ports (PORTS)")
	if _is_dir(nextui_ports):
		var emus := DirAccess.open(root.path_join("Emus"))
		if emus:
			for platform in emus.get_directories():
				var pak := root.path_join("Emus").path_join(platform).path_join("PORTS.pak")
				if _is_dir(pak):
					dev["firmware"] = "NextUI"
					dev["ports_dir"] = nextui_ports.path_join(".ports")
					dev["launcher_dirs"] = [nextui_ports.path_join(".ports"), nextui_ports]
					dev["pm_dir"] = pak.path_join("PortMaster")
					dev["libs_dir"] = pak.path_join("PortMaster/libs")
					dev["media_dir"] = nextui_ports.path_join(".media")
					dev["nintendo_file"] = root.path_join(".userdata").path_join(platform).path_join("PORTS-portmaster/nintendo")
					return dev

	# Knulli, Batocera, REG-Linux: the SHARE partition (/userdata).
	if _is_dir(root.path_join("roms/ports")) and _is_dir(root.path_join("system")):
		var system := root.path_join("system")
		# PortMaster reads the first of knulli.conf, system.conf and batocera.conf
		# (platform.py, BATOCERA_CONFIG_FILES); older Knulli releases only have
		# batocera.conf, but leave knulli-machine-id and device_info_knulli_*.
		var knulli := FileAccess.file_exists(system.path_join("knulli.conf"))
		if not knulli:
			for f in DirAccess.get_files_at(system):
				if f.begins_with("knulli") or f.begins_with("device_info_knulli"):
					knulli = true
					break
		for conf in ["knulli.conf", "system.conf", "batocera.conf"]:
			if FileAccess.file_exists(system.path_join(conf)):
				dev["conf_file"] = system.path_join(conf)
				break
		if knulli:
			dev["firmware"] = "Knulli"
		elif FileAccess.file_exists(system.path_join("system.conf")):
			dev["firmware"] = "REG-Linux"
		else:
			dev["firmware"] = "Batocera"
		_es_layout(dev, root.path_join("roms"), "/userdata/roms", system.path_join(".local/share/PortMaster"))
		return dev

	# ArkOS, dArkOS: the EASYROMS partition (/roms), PortMaster in tools/.
	if _is_dir(root.path_join("tools")) and _is_dir(root.path_join("ports")):
		var pm := root.path_join("tools/PortMaster")
		if not _is_dir(pm):
			pm = root.path_join("ports/PortMaster")
		if _is_dir(pm):
			dev["firmware"] = "ArkOS"
			_es_layout(dev, root, "/roms", pm)
			return dev

	# ROCKNIX, JELOS: a games card, whose roms/ folder becomes /storage/roms.
	if _is_dir(root.path_join("roms/ports/PortMaster")):
		dev["firmware"] = "ROCKNIX"
		_es_layout(dev, root.path_join("roms"), "/storage/roms", root.path_join("roms/ports/PortMaster"))
		return dev

	# AmberELEC, UnofficialOS (and ROCKNIX set up the same way): the games
	# partition is /storage/roms itself.
	if _is_dir(root.path_join("ports/PortMaster")):
		dev["firmware"] = "AmberELEC / UnofficialOS"
		_es_layout(dev, root, "/storage/roms", root.path_join("ports/PortMaster"))
		return dev
	return {}


## The EmulationStation layout most firmwares share: ports and launchers in
## <roms>/ports/ and the game list in <roms>/ports/gamelist.xml. `roms` is the
## folder on the card, `device_roms` the same folder as the device sees it. Some
## older setups keep launchers in <roms>/ports_scripts/; PortMaster then writes
## the game list's image paths as absolute device paths.
static func _es_layout(dev: Dictionary, roms: String, device_roms: String, pm: String) -> void:
	var ports := roms.path_join("ports")
	dev["ports_dir"] = ports
	dev["launcher_dirs"] = [ports]
	dev["gamelist"] = ports.path_join("gamelist.xml")
	dev["pm_dir"] = pm if _is_dir(pm) else ""
	dev["libs_dir"] = pm.path_join("libs") if _is_dir(pm) else ""
	if _is_dir(roms.path_join("ports_scripts")):
		dev["launcher_dirs"] = [roms.path_join("ports_scripts")]
		dev["image_base"] = device_roms.path_join("ports") + "/"


## Why the card at `root` can't be installed to, or "" when it can.
static func card_problem(root: String) -> String:
	if not detect(root).is_empty():
		return ""
	var other := unsupported_firmware(root)
	if not other.is_empty():
		return "This card looks like it runs %s, which the installer doesn't support yet. Where PortMaster runs on it, put the port's zip in PortMaster's autoinstall folder instead." % other
	return "No supported firmware found at %s. Choose the SD card's root folder (for ROCKNIX, the games card); PortMaster must have been run once on the device. Supported: NextUI, Knulli, Batocera, REG-Linux, ArkOS, dArkOS, ROCKNIX, JELOS, AmberELEC and UnofficialOS." % root


## The device's CPU architecture as PortMaster names it (aarch64, armhf,
## x86_64), from what PortMaster wrote on the card; "" when it can't tell.
static func device_arch(dev: Dictionary) -> String:
	if dev["firmware"] == "NextUI":
		return "aarch64"  # the pak only runs on TrimUI's tg5040 (Brick, Smart Pro)
	# PortMaster logs its device info on every start: ... 'primary_arch': 'aarch64' ...
	var pm := String(dev["pm_dir"])
	if not pm.is_empty() and FileAccess.file_exists(pm.path_join("log.txt")):
		var m := RegEx.create_from_string("'primary_arch':\\s*'([a-z0-9_]+)'").search(FileAccess.get_file_as_string(pm.path_join("log.txt")))
		if m:
			return m.get_string(1)
	# Its device_info script also leaves device_info_<cfw>_<device>.txt in $HOME,
	# which is the card's system/ folder on Knulli and Batocera.
	var home := DirAccess.open(String(dev["root"]).path_join("system"))
	if home:
		for f in home.get_files():
			if f.begins_with("device_info_") and f.ends_with(".txt"):
				var m := RegEx.create_from_string("(?m)^DEVICE_ARCH=\"?([a-z0-9_]+)").search(FileAccess.get_file_as_string(String(dev["root"]).path_join("system").path_join(f)))
				if m:
					return m.get_string(1)
	return ""


## The name of a firmware the installer recognises but doesn't support yet,
## or "" when the card isn't one of them.
static func unsupported_firmware(root: String) -> String:
	root = root.replace("\\", "/").trim_suffix("/")
	if root.is_empty():
		return ""
	if _is_dir(root.path_join("MUOS")):
		return "muOS"
	if _is_dir(root.path_join("spruce")):
		return "Spruce"
	if _is_dir(root.path_join("Apps/PortMaster")) or _is_dir(root.path_join("Data/ports")):
		return "TrimUI / CrossMix"
	if _is_dir(root.path_join("MIYOO_EX")):
		return "Miyoo"
	if _is_dir(root.path_join(".tmp_update")):
		return "Onion"
	return ""


static func _is_dir(path: String) -> bool:
	return DirAccess.dir_exists_absolute(path)


## Installs the built port in `out_root` (= <output>/<port>) onto the card at `root`.
func install(out_root: String, port: String, title: String, root: String, copy_runtimes: bool) -> bool:
	warnings = 0
	errors = 0
	_say("== Installing '%s' onto %s" % [port, root])
	var dev := detect(root)
	if dev.is_empty():
		return _fail(card_problem(root))
	_say("Firmware: %s" % dev["firmware"])

	var game_src := out_root.path_join(port)
	var script_name := title + ".sh"
	var required := [out_root.path_join(script_name), out_root.path_join("port.json"),
		out_root.path_join("gameinfo.xml"), out_root.path_join("README.md"),
		game_src.path_join("gamedata").path_join(port + ".pck")]
	for f in required:
		if not FileAccess.file_exists(f):
			return _fail("The built port is incomplete (missing %s). Press Build port first." % f.get_file())

	# 1. The port folder, in the installed layout (port.json, gameinfo.xml,
	#    screenshot and README live inside it). conf/ and log.txt are left alone.
	var dest := String(dev["ports_dir"]).path_join(port)
	# Read before the copy replaces port.json; acted on only once the copy worked.
	var old_scripts := _old_launchers(dest, script_name)
	DirAccess.make_dir_recursive_absolute(dest)
	var pairs := []  # [src, dest]
	for f in Builder._list_files(game_src):
		pairs.append([f, dest.path_join(f.trim_prefix(game_src + "/"))])
	for f in ["port.json", "gameinfo.xml", "screenshot.png", "screenshot.jpg", "cover.png", "cover.jpg"]:
		if FileAccess.file_exists(out_root.path_join(f)):
			pairs.append([out_root.path_join(f), dest.path_join(f)])
	pairs.append([out_root.path_join("README.md"), dest.path_join(port + ".md")])
	for d in dev["launcher_dirs"]:
		pairs.append([out_root.path_join(script_name), String(d).path_join(script_name)])
	if not _copy_all(pairs):
		return false
	_say("Copied %d file(s) and verified them." % pairs.size())
	# Files an earlier build installed but this one doesn't have (a removed
	# licence, a PNG screenshot now a JPG). Only folders the build owns; conf/
	# (saves) and anything else in the port folder stay. Names are compared
	# ignoring case: FAT and exFAT cards keep a file's old capitalisation when
	# it's overwritten, so LICENSE.music.txt may now hold LICENSE.Music.txt.
	var installed := {}
	for pair in pairs:
		installed[String(pair[1]).to_lower()] = true
	for dir in [dest.path_join("licenses"), dest.path_join("gamedata")]:
		_prune(dir, installed)
	for f in ["screenshot.png", "screenshot.jpg", "cover.png", "cover.jpg"]:
		if FileAccess.file_exists(dest.path_join(f)) and not installed.has(dest.path_join(f).to_lower()):
			DirAccess.remove_absolute(dest.path_join(f))
	if not _replace_old_launchers(dev, out_root, script_name, old_scripts):
		return false

	# 2. Firmware-specific extras.
	if dev["firmware"] == "NextUI":
		_nextui_thumbnail(out_root, String(dev["media_dir"]), title)
	if not String(dev["gamelist"]).is_empty():
		var old_paths := PackedStringArray()
		for s in old_scripts:
			old_paths.append(Builder._xml("./" + s))
		if not merge_gamelist(String(dev["gamelist"]), out_root.path_join("gameinfo.xml"), String(dev["image_base"]), old_paths):
			_warn("Couldn't update %s; the game list won't show the port's details." % dev["gamelist"])
		else:
			_say("Added the port's details to %s." % String(dev["gamelist"]).get_file())

	# 3. Runtimes, only ones the card doesn't have yet.
	if copy_runtimes:
		_install_runtimes(out_root, dev)

	# 4. Device settings the port depends on (reported, never changed).
	_check_device(dev, title)

	_say("== Done: %d warning(s), %d error(s)." % [warnings, errors])
	if errors == 0:
		_say("   Eject the card safely, then refresh the game list on the device.")
	return errors == 0


# ---------------------------------------------------------------- copying

func _copy_all(pairs: Array) -> bool:
	for p in pairs:
		if cancel_requested:
			return _fail("Install cancelled.")
		var src: String = p[0]
		var dst: String = p[1]
		DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
		if DirAccess.copy_absolute(src, dst) != OK:
			return _fail("Couldn't copy %s to %s." % [src.get_file(), dst])
		if FileAccess.get_md5(src) != FileAccess.get_md5(dst):
			return _fail("%s didn't copy correctly (the card may be failing or full)." % dst)
	return true


## The launchers an earlier install of this port put on the card under another
## name (the title changed since, even if only its capitals). The port.json
## already on the card lists them among the port's items, so they're this
## port's own.
func _old_launchers(dest: String, script_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var path := dest.path_join("port.json")
	var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
	if old is Dictionary and old.get("items") is Array:
		for item in old["items"]:
			var item_name := str(item)
			if item_name.to_lower().ends_with(".sh") and not item_name.contains("/") and item_name != script_name:
				out.append(item_name)
	return out


## Removes the old launchers (and their NextUI menu pictures), so the Ports
## menu doesn't show the game twice. A launcher whose name only differs in
## capitals is the new launcher stored under the old name (FAT and exFAT keep
## a file's old capitalisation when it's overwritten), so it's renamed in
## place, never deleted, and so is its menu picture. Their game list entries
## are handled by merge_gamelist().
func _replace_old_launchers(dev: Dictionary, out_root: String, script_name: String, old_scripts: PackedStringArray) -> bool:
	for old in old_scripts:
		var case_only := old.to_lower() == script_name.to_lower()
		var changed := false
		for dir in dev["launcher_dirs"]:
			var path := String(dir).path_join(old)
			if not FileAccess.file_exists(path):
				continue
			changed = true
			if not case_only:
				DirAccess.remove_absolute(path)
				continue
			# On a card that tells capitals apart (ext4, from Linux), the copy
			# made a separate file under the new name: just remove the old one.
			if _has_file_named(String(dir), script_name):
				DirAccess.remove_absolute(path)
				continue
			var new_path := String(dir).path_join(script_name)
			if DirAccess.rename_absolute(path, new_path) != OK \
					or FileAccess.get_md5(new_path) != FileAccess.get_md5(out_root.path_join(script_name)):
				return _fail("Couldn't rename the launcher '%s' to '%s' on the card." % [old, script_name])
		var media := String(dev["media_dir"])
		var old_pic := old.get_basename() + ".png"
		var new_pic := script_name.get_basename() + ".png"
		if not media.is_empty() and _has_file_named(media, old_pic):
			if case_only and not _has_file_named(media, new_pic):
				DirAccess.rename_absolute(media.path_join(old_pic), media.path_join(new_pic))
			else:
				DirAccess.remove_absolute(media.path_join(old_pic))
		if changed:
			_say("%s the old launcher '%s' (the title changed)." % ["Renamed" if case_only else "Removed", old])
	return true


## Whether `dir` holds a file named exactly `file_name`, capitals included
## (FileAccess.file_exists ignores capitals on Windows).
static func _has_file_named(dir: String, file_name: String) -> bool:
	return DirAccess.get_files_at(dir).has(file_name)


## Removes the files directly in `dir` that aren't in `keep` (lowercase full paths).
func _prune(dir: String, keep: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d:
		for f in d.get_files():
			if not keep.has(dir.path_join(f).to_lower()):
				d.remove(f)


func _nextui_thumbnail(out_root: String, media_dir: String, title: String) -> void:
	var src := ""
	for f in ["cover.png", "cover.jpg", "screenshot.png", "screenshot.jpg"]:
		if FileAccess.file_exists(out_root.path_join(f)):
			src = out_root.path_join(f)
			break
	if src.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(media_dir)
	var img := Image.load_from_file(src)
	if img and not img.is_empty() and img.save_png(media_dir.path_join(title + ".png")) == OK:
		_say("Added the Ports menu picture (.media/%s.png)." % title)


# ---------------------------------------------------------------- gamelist

## Merges gameinfo.xml's fields into an EmulationStation gamelist.xml, as
## PortMaster's installer does, keeping the entry's other fields (play count,
## play time, favourite). Creates the file when there's none; leaves a file it
## can't make sense of alone.
## `image_base`, when set, turns the image path into an absolute device path.
## `old_paths` are the port's launchers under earlier titles (XML-escaped, e.g.
## "./Old Title.sh"): the first one's entry is moved to the new launcher, so play
## count and favourite carry over, and any others are removed.
static func merge_gamelist(gamelist_path: String, gameinfo_path: String, image_base: String = "",
		old_paths: PackedStringArray = PackedStringArray()) -> bool:
	var info := _parse_game(FileAccess.get_file_as_string(gameinfo_path))
	if not info.has("path"):
		return false
	if not image_base.is_empty() and info.has("image"):
		info["image"] = image_base + String(info["image"]).trim_prefix("./")
	var text := FileAccess.get_file_as_string(gamelist_path) if FileAccess.file_exists(gamelist_path) else ""
	var empty_list := RegEx.create_from_string("<gameList\\s*/>")
	if text.strip_edges().is_empty():
		text = "<?xml version=\"1.0\"?>\n<gameList>\n</gameList>\n"
	elif empty_list.search(text):
		text = empty_list.sub(text, "<gameList>\n</gameList>")
	if not text.contains("</gameList>"):
		return false

	for old in old_paths:
		var o := _find_game(text, old)
		if o.is_empty():
			continue
		if _find_game(text, info["path"]).is_empty():
			# The first old entry becomes the new launcher's.
			var inner := text.substr(o[1], o[2] - o[1])
			var p := RegEx.create_from_string("<path>[^<]*</path>").search(inner)
			inner = inner.substr(0, p.get_start()) + "<path>%s</path>" % info["path"] + inner.substr(p.get_end())
			text = text.substr(0, o[1]) + inner + text.substr(o[2])
		else:
			text = text.substr(0, o[0]) + text.substr(o[3])

	# The existing <game> (or <game id=...>) entry for this launcher.
	var found := _find_game(text, info["path"])
	var start: int = found[1] if not found.is_empty() else -1
	var end: int = found[2] if not found.is_empty() else -1

	if start < 0:
		var entry := "\t<game>\n"
		for key in info.keys():
			entry += "\t\t<%s>%s</%s>\n" % [key, info[key], key]
		entry += "\t</game>\n"
		var close := text.rfind("</gameList>")
		text = text.substr(0, close) + entry + text.substr(close)
	else:
		var block := text.substr(start, end - start)
		for key in info.keys():
			var element := "<%s>%s</%s>" % [key, info[key], key]
			var re := RegEx.create_from_string("<%s(\\s[^>]*)?(/>|>[^<]*</%s>)" % [key, key])
			var m := re.search(block)
			if m:
				block = block.substr(0, m.get_start()) + element + block.substr(m.get_end())
			else:
				block = block.rstrip("\t\n ") + "\n\t\t" + element + "\n\t"
		text = text.substr(0, start) + block + text.substr(end)

	return _write_gamelist(gamelist_path, text)


## The <game> entry whose <path> is `path`: [start, content start, content end,
## end (after its line break)], or [] when there's none.
static func _find_game(text: String, path: String) -> Array:
	for m in RegEx.create_from_string("[ \\t]*<game(\\s[^>]*)?>").search_all(text):
		var e := text.find("</game>", m.get_end())
		if e >= 0 and _tag_text(text.substr(m.get_end(), e - m.get_end()), "path").strip_edges() == path:
			var after := e + "</game>".length()
			if text.substr(after, 1) == "\n":
				after += 1
			return [m.get_start(), m.get_end(), e, after]
	return []


static func _write_gamelist(gamelist_path: String, text: String) -> bool:
	# Like PortMaster's gamelist_add: keep gamelist.xml.bak, which PortMaster
	# also restores from when it finds the list missing or empty. If the write
	# doesn't read back intact (card pulled or full), put the old list back.
	var backup := gamelist_path + ".bak"
	var had_list := FileAccess.file_exists(gamelist_path)
	if had_list and DirAccess.copy_absolute(gamelist_path, backup) != OK:
		return false
	var f := FileAccess.open(gamelist_path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	if f == null or FileAccess.get_file_as_string(gamelist_path) != text:
		if had_list:
			DirAccess.copy_absolute(backup, gamelist_path)
		return false
	return true


## The child elements of gameinfo.xml's single <game>, kept XML-escaped.
static func _parse_game(xml: String) -> Dictionary:
	var out := {}
	var s := xml.find("<game>")
	var e := xml.find("</game>")
	if s < 0 or e < 0:
		return out
	var block := xml.substr(s + 6, e - s - 6)
	var re := RegEx.create_from_string("<([a-z]+)>([^<]*)</\\1>")
	for m in re.search_all(block):
		out[m.get_string(1)] = m.get_string(2)
	return out


static func _tag_text(block: String, tag: String) -> String:
	var a := block.find("<%s>" % tag)
	var b := block.find("</%s>" % tag)
	if a < 0 or b < a:
		return ""
	return block.substr(a + tag.length() + 2, b - a - tag.length() - 2)


# ---------------------------------------------------------------- runtimes

func _install_runtimes(out_root: String, dev: Dictionary) -> void:
	var libs := String(dev["libs_dir"])
	if libs.is_empty():
		_warn("PortMaster isn't installed on this card yet, so runtimes weren't copied. Install PortMaster first.")
		return
	var pj: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_root.path_join("port.json")))
	if not pj is Dictionary:
		_warn("Couldn't read port.json, so runtimes weren't copied.")
		return
	var needed: Array = pj.get("attr", {}).get("runtime", [])
	var missing := []
	for r in needed:
		if FileAccess.file_exists(libs.path_join(str(r))):
			_say("Runtime %s is already on the card; left as it is." % r)
		elif dev["firmware"] == "NextUI" and str(r).begins_with("weston_pkg"):
			# PortMaster's Weston doesn't run on NextUI; the pak brings its own.
			_warn("%s isn't on the card. Reinstall or update the PortMaster pak (it includes a Weston that works on NextUI); PortMaster's own download won't run there." % r)
		else:
			missing.append(str(r))
	if missing.is_empty():
		return
	var arch := device_arch(dev)
	if arch.is_empty():
		_warn("Couldn't tell the device's CPU type (PortMaster records it once it has run on the device), so these runtimes weren't copied: %s. The port downloads them on first launch (needs Wi-Fi)." % ", ".join(missing))
		return
	var catalogue := _fetch_runtime_catalogue()
	if catalogue.is_empty():
		_warn("Couldn't download PortMaster's runtime list; the port will download %s on first launch (needs Wi-Fi)." % ", ".join(missing))
		return
	DirAccess.make_dir_recursive_absolute(libs)
	for r in missing:
		if cancel_requested:
			return
		var entry := _runtime_entry(catalogue, r, arch)
		if entry.is_empty():
			_warn("PortMaster lists no %s build of %s; the port will try to download it on first launch." % [arch, r])
			continue
		var cache := OS.get_cache_dir().path_join("portmaster_export_runtimes").path_join("%s.%s" % [entry["md5"], r])
		if not FileAccess.file_exists(cache) or FileAccess.get_md5(cache) != entry["md5"]:
			_say("Downloading %s for %s (%.1f MB)..." % [r, arch, float(entry.get("size", 0)) / 1048576.0])
			DirAccess.make_dir_recursive_absolute(cache.get_base_dir())
			if not _download(str(entry["url"]), cache) or FileAccess.get_md5(cache) != entry["md5"]:
				DirAccess.remove_absolute(cache)
				_warn("Downloading %s failed or didn't match PortMaster's checksum; the port will download it on first launch." % r)
				continue
		# Copied under a temporary name and renamed once it checks out, so a copy
		# cut short (card full or pulled) never leaves a broken runtime that later
		# installs, and PortMaster, would take for the real one.
		var dst := libs.path_join(r)
		var part := dst + ".part"
		if DirAccess.copy_absolute(cache, part) != OK or FileAccess.get_md5(part) != entry["md5"] 				or DirAccess.rename_absolute(part, dst) != OK:
			DirAccess.remove_absolute(part)
			_warn("Couldn't copy %s onto the card (is it full?); the port will download it on first launch." % r)
			continue
		_say("Added runtime %s for %s (checksum matches PortMaster's)." % [r, arch])


## ports.json's "utils" section, which lists each runtime's url, md5 and size.
func _fetch_runtime_catalogue() -> Dictionary:
	var tmp := OS.get_cache_dir().path_join("portmaster_export_ports.json")
	if not _download(PORTS_JSON_URL, tmp):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(tmp))
	DirAccess.remove_absolute(tmp)
	return data.get("utils", {}) if data is Dictionary else {}


## The entry for `runtime_name` built for `arch`; every architecture's build has
## the same runtime_name (godot_4.5.squashfs), only runtime_arch differs.
static func _runtime_entry(utils: Dictionary, runtime_name: String, arch: String) -> Dictionary:
	for key in utils.keys():
		var e: Variant = utils[key]
		if e is Dictionary and e.get("runtime_name") == runtime_name and e.get("runtime_arch") == arch \
				and e.has("url") and e.has("md5"):
			return e
	return {}


func _download(url: String, dest: String) -> bool:
	return http_get(url, DOWNLOAD_IDLE_MS, func(): return cancel_requested, dest)["ok"]


# ---------------------------------------------------------------- device checks

func _check_device(dev: Dictionary, title: String) -> void:
	if dev["firmware"] == "NextUI":
		if not FileAccess.file_exists(String(dev["nintendo_file"])):
			_warn("NextUI: there's no 'nintendo' file in %s, so A/B and X/Y will be swapped in every port. Create an empty file named nintendo there." % String(dev["nintendo_file"]).get_base_dir())
		var weston := String(dev["libs_dir"]).path_join("weston_pkg_0.2.squashfs")
		var sidecar := weston + ".md5"
		if FileAccess.file_exists(weston):
			var md5 := FileAccess.get_md5(weston)
			var expected := FileAccess.get_file_as_string(sidecar).strip_edges().get_slice(" ", 0) if FileAccess.file_exists(sidecar) else md5
			if md5 in PORTMASTER_WESTON_MD5S or md5 != expected:
				_warn("NextUI: PortMaster has replaced the pak's own Weston, so Godot ports won't start. Restore files/weston_pkg_0.2.squashfs from the minui-portmaster release (it must match %s), or update the pak from the Pak Store." % sidecar.get_file())
	elif dev["firmware"] == "Knulli":
		# PortMaster's Knulli support reads these keys (platform.py, PlatformKnulli).
		if knulli_xbox_layout(String(dev["conf_file"]), title) != "1":
			_warn("Knulli: the ports' Xbox layout option is off, so A/B and X/Y will be swapped. Turn on the A/B X/Y swap for this port (or for all ports) in the game's advanced settings.")


## The ports' "Xbox layout" setting in knulli.conf: the port's own
## (ports["<Title>.sh"].xbox_layout), else the one for all ports
## (ports.xbox_layout). "" when neither is set.
static func knulli_xbox_layout(conf_file: String, title: String) -> String:
	if conf_file.is_empty() or not FileAccess.file_exists(conf_file):
		return ""
	var own := ""
	var all := ""
	for line in FileAccess.get_file_as_string(conf_file).split("\n"):
		line = line.strip_edges()
		if line.begins_with("#") or not line.contains("="):
			continue
		var key := line.get_slice("=", 0).strip_edges()
		var value := line.get_slice("=", 1).strip_edges()
		if key == 'ports["%s.sh"].xbox_layout' % title:
			own = value
		elif key == "ports.xbox_layout":
			all = value
	return own if not own.is_empty() else all
