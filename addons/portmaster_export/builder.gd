@tool
extends RefCounted
## Packages a Godot project as a PortMaster port.
##
## Usable from the editor dock or headless:
##   var b = load("res://addons/portmaster_export/builder.gd").new()
##   b.log_callback = func(msg): print(msg)
##   b.build(project_dir, b.load_settings(project_dir))

const SETTINGS_FILE := "portmaster/port.cfg"
const PRESET_NAME := "PortMaster"
const MAX_FILE_BYTES := 90 * 1024 * 1024

const VALID_GENRES := [
	"action", "adventure", "arcade", "casino/card", "fps", "platformer", "puzzle",
	"racing", "rhythm", "rpg", "simulation", "sports", "strategy", "visual novel", "other",
]

const KNOWN_GODOT_RUNTIMES := ["4.2.2", "4.3", "4.4", "4.4.1", "4.5", "4.6.3", "4.7.1"]

## Every gptk button, in the order they are written.
const BUTTONS := [
	"a", "b", "x", "y", "l1", "l2", "l3", "r1", "r2", "r3",
	"start", "back", "guide", "up", "down", "left", "right",
	"left_analog_up", "left_analog_down", "left_analog_left", "left_analog_right",
	"right_analog_up", "right_analog_down", "right_analog_left", "right_analog_right",
]

const BUTTON_NAMES := {
	"a": "A", "b": "B", "x": "X", "y": "Y",
	"l1": "L1", "l2": "L2", "l3": "L3", "r1": "R1", "r2": "R2", "r3": "R3",
	"start": "Start", "back": "Select", "guide": "Guide",
	"up": "D-Pad Up", "down": "D-Pad Down", "left": "D-Pad Left", "right": "D-Pad Right",
	"left_analog_up": "Left stick up", "left_analog_down": "Left stick down",
	"left_analog_left": "Left stick left", "left_analog_right": "Left stick right",
	"right_analog_up": "Right stick up", "right_analog_down": "Right stick down",
	"right_analog_left": "Right stick left", "right_analog_right": "Right stick right",
}

## Godot JoyButton index -> gptk button.
const JOY_BUTTONS := {
	JOY_BUTTON_A: "a", JOY_BUTTON_B: "b", JOY_BUTTON_X: "x", JOY_BUTTON_Y: "y",
	JOY_BUTTON_BACK: "back", JOY_BUTTON_GUIDE: "guide", JOY_BUTTON_START: "start",
	JOY_BUTTON_LEFT_STICK: "l3", JOY_BUTTON_RIGHT_STICK: "r3",
	JOY_BUTTON_LEFT_SHOULDER: "l1", JOY_BUTTON_RIGHT_SHOULDER: "r1",
	JOY_BUTTON_DPAD_UP: "up", JOY_BUTTON_DPAD_DOWN: "down",
	JOY_BUTTON_DPAD_LEFT: "left", JOY_BUTTON_DPAD_RIGHT: "right",
}

## Built-in ui_* actions that games commonly rely on (Godot's InputMap::get_builtins).
const BUILTIN_ACTIONS := [
	"ui_accept", "ui_select", "ui_cancel", "ui_focus_next", "ui_focus_prev",
	"ui_left", "ui_right", "ui_up", "ui_down",
	"ui_page_up", "ui_page_down", "ui_home", "ui_end",
]

const DEADZONE_BLOCK := """deadzone_y = 2100
deadzone_x = 1900
mouse_scale = 512
mouse_delay = 16
deadzone_mode = scaled_radial
deadzone = 2000
deadzone_scale = 8
deadzone_delay = 16
"""

## PortMaster's Godot 4 launcher, verbatim from the merged supermazerobo port.
## Only GAMEDIR, godot_runtime, godot_executable, pck_filename and
## gptk_filename are replaced.
const LAUNCHER_TEMPLATE := [
	"#!/bin/bash",
	"",
	"# PortMaster preamble",
	"XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}",
	"if [ -d \"/opt/system/Tools/PortMaster/\" ]; then",
	"  controlfolder=\"/opt/system/Tools/PortMaster\"",
	"elif [ -d \"/opt/tools/PortMaster/\" ]; then",
	"  controlfolder=\"/opt/tools/PortMaster\"",
	"elif [ -d \"$XDG_DATA_HOME/PortMaster/\" ]; then",
	"  controlfolder=\"$XDG_DATA_HOME/PortMaster\"",
	"else",
	"  controlfolder=\"/roms/ports/PortMaster\"",
	"fi",
	"source $controlfolder/control.txt",
	"[ -f \"${controlfolder}/mod_${CFW_NAME}.txt\" ] && source \"${controlfolder}/mod_${CFW_NAME}.txt\"",
	"get_controls",
	"",
	"# Adjust these to your paths and desired godot version",
	"GAMEDIR=/$directory/ports/supermazerobo",
	"godot_runtime=\"godot_4.5\"",
	"godot_executable=\"godot45.$DEVICE_ARCH\"",
	"pck_filename=\"SMR.pck\"",
	"gptk_filename=\"super maze robo.gptk\"",
	"",
	"# Logging",
	"> \"$GAMEDIR/log.txt\" && exec > >(tee \"$GAMEDIR/log.txt\") 2>&1",
	"",
	"# Create directory for save files",
	"CONFDIR=\"$GAMEDIR/conf/\"",
	"$ESUDO mkdir -p \"${CONFDIR}\"",
	"",
	"# Mount Weston runtime",
	"weston_dir=/tmp/weston",
	"$ESUDO mkdir -p \"${weston_dir}\"",
	"weston_runtime=\"weston_pkg_0.2\"",
	"if [ ! -f \"$controlfolder/libs/${weston_runtime}.squashfs\" ]; then",
	"  if [ ! -f \"$controlfolder/harbourmaster\" ]; then",
	"    pm_message \"This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info.\"",
	"    sleep 5",
	"    exit 1",
	"  fi",
	"  $ESUDO $controlfolder/harbourmaster --quiet --no-check runtime_check \"${weston_runtime}.squashfs\"",
	"fi",
	"if [[ \"$PM_CAN_MOUNT\" != \"N\" ]]; then",
	"    $ESUDO umount \"${weston_dir}\"",
	"fi",
	"$ESUDO mount \"$controlfolder/libs/${weston_runtime}.squashfs\" \"${weston_dir}\"",
	"",
	"# Mount Godot runtime",
	"godot_dir=/tmp/godot",
	"$ESUDO mkdir -p \"${godot_dir}\"",
	"if [ ! -f \"$controlfolder/libs/${godot_runtime}.squashfs\" ]; then",
	"  if [ ! -f \"$controlfolder/harbourmaster\" ]; then",
	"    pm_message \"This port requires the latest PortMaster to run, please go to https://portmaster.games/ for more info.\"",
	"    sleep 5",
	"    exit 1",
	"  fi",
	"  $ESUDO $controlfolder/harbourmaster --quiet --no-check runtime_check \"${godot_runtime}.squashfs\"",
	"fi",
	"if [[ \"$PM_CAN_MOUNT\" != \"N\" ]]; then",
	"    $ESUDO umount \"${godot_dir}\"",
	"fi",
	"$ESUDO mount \"$controlfolder/libs/${godot_runtime}.squashfs\" \"${godot_dir}\"",
	"",
	"$GPTOKEYB \"$godot_executable\" -c \"$GAMEDIR/$gptk_filename\" &",
	"",
	"# Start Westonpack and Godot",
	"# Put CRUSTY_SHOW_CURSOR=1 after \"env\" if you need a mouse cursor",
	"$ESUDO env CRUSTY_BLOCK_INPUT=1 $weston_dir/westonwrap.sh headless noop kiosk crusty_x11egl \\",
	"XDG_DATA_HOME=$CONFDIR $godot_dir/$godot_executable \\",
	"--resolution ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT} -f \\",
	"--rendering-driver opengl3_es --audio-driver ALSA --main-pack $GAMEDIR/gamedata/$pck_filename \\",
	"",
	"#Clean up after ourselves",
	"$ESUDO $weston_dir/westonwrap.sh cleanup",
	"if [[ \"$PM_CAN_MOUNT\" != \"N\" ]]; then",
	"    $ESUDO umount \"${weston_dir}\"",
	"    $ESUDO umount \"${godot_dir}\"",
	"fi",
	"pm_finish",
]

var log_callback: Callable
var warnings := 0
var errors := 0


# ---------------------------------------------------------------- settings

static func default_settings(project_dir: String) -> Dictionary:
	var cf := ConfigFile.new()
	var title := ""
	if cf.load(project_dir.path_join("project.godot")) == OK:
		title = str(cf.get_value("application", "config/name", ""))
	return {
		"port_name": "",
		"title": title,
		"porter": "",
		"developer": "",
		"description": "",
		"genres": "",
		"itch_url": "",
		"credits": "",
		"release_date": "",
		"godot_runtime": "",
		"screenshot": "res://portmaster/screenshot.png",
		"cover": "",
		"licenses": "res://portmaster/licenses",
		"output": project_dir.get_base_dir().path_join("PortMaster"),
		"controls": {},
		"labels": {},
	}


static func load_settings(project_dir: String) -> Dictionary:
	var s := default_settings(project_dir)
	var cf := ConfigFile.new()
	if cf.load(project_dir.path_join(SETTINGS_FILE)) != OK:
		return s
	for key in s.keys():
		if key == "controls" or key == "labels":
			continue
		if cf.has_section_key("port", key):
			s[key] = str(cf.get_value("port", key))
	for section in ["controls", "labels"]:
		var d := {}
		if cf.has_section(section):
			for key in cf.get_section_keys(section):
				d[key] = str(cf.get_value(section, key))
		s[section] = d
	return s


static func save_settings(project_dir: String, s: Dictionary) -> Error:
	var cf := ConfigFile.new()
	for key in s.keys():
		if key == "controls" or key == "labels":
			continue
		cf.set_value("port", key, str(s[key]))
	for section in ["controls", "labels"]:
		var d: Dictionary = s.get(section, {})
		for key in d.keys():
			cf.set_value(section, key, str(d[key]))
	var path := project_dir.path_join(SETTINGS_FILE)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	# Keep the editor from importing the screenshot and licence files.
	var ignore := path.get_base_dir().path_join(".gdignore")
	if not FileAccess.file_exists(ignore):
		var f := FileAccess.open(ignore, FileAccess.WRITE)
		if f:
			f.close()
	return cf.save(path)


## res:// paths are resolved against the project, relative paths against it too.
static func resolve_path(path: String, project_dir: String) -> String:
	if path.is_empty():
		return ""
	if path.begins_with("res://"):
		return project_dir.path_join(path.substr(6)).simplify_path()
	if path.is_relative_path():
		return project_dir.path_join(path).simplify_path()
	return path.simplify_path()


# ---------------------------------------------------------------- validation

## Returns "" if the name is acceptable, otherwise the reason it is not.
static func check_port_name(port: String) -> String:
	if port.is_empty():
		return "Port name is empty."
	var re := RegEx.create_from_string("^[a-z0-9][a-z0-9._]*$")
	if re.search(port) == null:
		return "Port name must be lowercase a-z, 0-9, '.' or '_' and start with a letter or digit."
	if port.contains(".."):
		return "Port name must not contain '..' (PortMaster collapses repeated dots)."
	return ""


static func valid_key_names() -> PackedStringArray:
	var keys := PackedStringArray()
	for c in "abcdefghijklmnopqrstuvwxyz0123456789":
		keys.append(c)
	keys.append_array(["space", "enter", "esc", "tab", "backspace", "delete", "insert",
		"home", "end", "pageup", "pagedown", "up", "down", "left", "right",
		"shift", "leftshift", "rightshift", "ctrl", "leftctrl", "rightctrl",
		"alt", "leftalt", "rightalt", "capslock", "menu", "pause",
		"numpadenter", "mouse_left", "mouse_right"])
	for i in range(1, 13):
		keys.append("f%d" % i)
	for i in 10:
		keys.append("numpad%d" % i)
	return keys


# ---------------------------------------------------------------- controls

## gptokeyb name for a keyboard event, or "" when gptokeyb can't send it.
static func key_name(ev: InputEventKey) -> String:
	var kc: int = ev.keycode
	if kc == KEY_NONE:
		kc = ev.physical_keycode
	if kc == KEY_NONE:
		kc = ev.key_label
	if kc >= KEY_A and kc <= KEY_Z:
		return char(kc).to_lower()
	if kc >= KEY_0 and kc <= KEY_9:
		return char(kc)
	if kc >= KEY_F1 and kc <= KEY_F12:
		return "f%d" % (kc - KEY_F1 + 1)
	if kc >= KEY_KP_0 and kc <= KEY_KP_9:
		return "numpad%d" % (kc - KEY_KP_0)
	var side := ""
	if ev.location == KEY_LOCATION_LEFT:
		side = "left"
	elif ev.location == KEY_LOCATION_RIGHT:
		side = "right"
	match kc:
		KEY_SPACE: return "space"
		KEY_ENTER: return "enter"
		KEY_KP_ENTER: return "numpadenter"
		KEY_ESCAPE: return "esc"
		KEY_TAB: return "tab"
		KEY_BACKSPACE: return "backspace"
		KEY_DELETE: return "delete"
		KEY_INSERT: return "insert"
		KEY_HOME: return "home"
		KEY_END: return "end"
		KEY_PAGEUP: return "pageup"
		KEY_PAGEDOWN: return "pagedown"
		KEY_UP: return "up"
		KEY_DOWN: return "down"
		KEY_LEFT: return "left"
		KEY_RIGHT: return "right"
		KEY_SHIFT: return side + "shift"
		KEY_CTRL: return side + "ctrl"
		KEY_ALT: return side + "alt"
		KEY_CAPSLOCK: return "capslock"
		KEY_MENU: return "menu"
		KEY_PAUSE: return "pause"
	return ""


static func _humanize(action: String) -> String:
	var s := action
	if s.begins_with("ui_"):
		s = s.substr(3)
	s = s.replace("_", " ").strip_edges()
	return s.capitalize() if s.length() > 0 else action


## Reads the project's input map (project.godot) plus Godot's built-in ui_*
## defaults. Returns name -> {events: Array, project: bool}, in order.
static func read_actions(project_dir: String) -> Dictionary:
	var actions := {}
	for name in BUILTIN_ACTIONS:
		var d: Variant = ProjectSettings.property_get_revert("input/" + name)
		if d is Dictionary and d.has("events"):
			actions[name] = {"events": d["events"], "project": false}
	var cf := ConfigFile.new()
	if cf.load(project_dir.path_join("project.godot")) == OK and cf.has_section("input"):
		for name in cf.get_section_keys("input"):
			var d: Variant = cf.get_value("input", name)
			if d is Dictionary and d.has("events"):
				actions[name] = {"events": d["events"], "project": true}
	return actions


## Builds the button -> key mapping.
## Returns {rows: Array[Dictionary], problems: PackedStringArray, notes: PackedStringArray}.
## Each row: {button, key, auto_key, actions, label, auto_label}.
static func generate_controls(project_dir: String, overrides: Dictionary = {}, labels: Dictionary = {}) -> Dictionary:
	var problems := PackedStringArray()
	var notes := PackedStringArray()
	var valid := valid_key_names()
	var actions := read_actions(project_dir)

	# Per action: the keys it accepts and the gptk sources (buttons/axes) it listens to.
	var info := {}
	var by_source := {}  # source -> Array of action names
	for name in actions.keys():
		var keys := PackedStringArray()
		var sources := PackedStringArray()
		for ev in actions[name]["events"]:
			if ev is InputEventKey:
				if ev.shift_pressed or ev.ctrl_pressed or ev.alt_pressed or ev.meta_pressed:
					continue  # gptokeyb sends single keys, not chords
				var k := key_name(ev)
				if k.is_empty():
					var kc: int = ev.keycode if ev.keycode != KEY_NONE else ev.physical_keycode
					if actions[name]["project"]:
						notes.append("%s: key %s has no gptokeyb name, skipped." % [name, OS.get_keycode_string(kc)])
				elif not keys.has(k):
					keys.append(k)
			elif ev is InputEventMouseButton:
				if ev.button_index == MOUSE_BUTTON_LEFT and not keys.has("mouse_left"):
					keys.append("mouse_left")
				elif ev.button_index == MOUSE_BUTTON_RIGHT and not keys.has("mouse_right"):
					keys.append("mouse_right")
			elif ev is InputEventJoypadButton:
				if JOY_BUTTONS.has(ev.button_index):
					var b: String = JOY_BUTTONS[ev.button_index]
					if not sources.has(b):
						sources.append(b)
				else:
					problems.append("%s: joypad button %d has no gptk equivalent, skipped." % [name, ev.button_index])
			elif ev is InputEventJoypadMotion:
				var src := _axis_source(ev.axis, ev.axis_value)
				if src.is_empty():
					problems.append("%s: joypad axis %d has no gptk equivalent, skipped." % [name, ev.axis])
				elif not sources.has(src):
					sources.append(src)
		info[name] = {"keys": keys, "sources": sources, "project": actions[name]["project"]}
		for src in sources:
			if not by_source.has(src):
				by_source[src] = []
			by_source[src].append(name)

	# Pick one key per source.
	var auto := {}
	var auto_actions := {}
	for src in BUTTONS:
		if not by_source.has(src):
			continue
		var bound: Array = by_source[src]
		var candidates := PackedStringArray()
		for a in bound:
			for k in info[a]["keys"]:
				if not candidates.has(k):
					candidates.append(k)
		auto_actions[src] = bound
		if candidates.is_empty():
			if bound.any(func(a): return info[a]["project"]):
				problems.append("%s (%s) has no keyboard key, so gptokeyb can't drive it on the device. Add a key to the action or set one here." % [BUTTON_NAMES[src], ", ".join(bound)])
			continue
		var best := ""
		var best_score := []
		for i in candidates.size():
			var k := candidates[i]
			var penalty := 0
			var also := PackedStringArray()
			for other in info.keys():
				if info[other]["keys"].has(k) and not info[other]["sources"].has(src):
					penalty += 10 if info[other]["project"] else 1
					also.append(other)
			var coverage := 0
			for a in bound:
				if info[a]["keys"].has(k):
					coverage += 1
			var name_match := 1 if (k == src or src.ends_with("_" + k)) else 0
			var score := [penalty, -coverage, -name_match, i]
			if best.is_empty() or _less(score, best_score):
				best = k
				best_score = score
		var hit := PackedStringArray()
		if best_score[0] > 0:
			for other in info.keys():
				if info[other]["keys"].has(best) and not info[other]["sources"].has(src):
					hit.append(other)
		if hit.size() > 0 and not bound.any(func(a): return info[a]["project"]):
			# Only Godot's defaults use this button (e.g. ui_select = Y + Space), and the
			# key would also fire other actions (Space -> ui_accept). Leave it unmapped.
			notes.append("%s left unmapped: only %s uses it, and %s would also trigger %s." % [src, ", ".join(bound), best, ", ".join(hit)])
			continue
		auto[src] = best
		if hit.size() > 0:
			notes.append("%s = %s also triggers %s." % [src, best, ", ".join(hit)])

	# The left stick drives whatever the d-pad does when nothing binds it directly.
	for dir in ["up", "down", "left", "right"]:
		var stick: String = "left_analog_" + dir
		if not auto.has(stick) and auto.has(dir):
			auto[stick] = auto[dir]
			auto_actions[stick] = auto_actions.get(dir, [])

	var rows := []
	for b in BUTTONS:
		var auto_key: String = auto.get(b, "")
		var key := auto_key
		if overrides.has(b):
			var o := str(overrides[b]).strip_edges().to_lower()
			if o.is_empty() or valid.has(o):
				key = o
			else:
				problems.append("Override %s = %s: not a gptokeyb key name, ignored." % [b, o])
		var acts: Array = auto_actions.get(b, [])
		var names := PackedStringArray()
		for a in acts:
			names.append(_humanize(a))
		var auto_label := " / ".join(names)
		var label: String = str(labels.get(b, auto_label))
		rows.append({"button": b, "key": key, "auto_key": auto_key,
			"actions": PackedStringArray(acts), "label": label, "auto_label": auto_label})
	return {"rows": rows, "problems": problems, "notes": notes}


static func _axis_source(axis: int, value: float) -> String:
	match axis:
		JOY_AXIS_LEFT_X: return "left_analog_left" if value < 0 else "left_analog_right"
		JOY_AXIS_LEFT_Y: return "left_analog_up" if value < 0 else "left_analog_down"
		JOY_AXIS_RIGHT_X: return "right_analog_left" if value < 0 else "right_analog_right"
		JOY_AXIS_RIGHT_Y: return "right_analog_up" if value < 0 else "right_analog_down"
		JOY_AXIS_TRIGGER_LEFT: return "l2" if value > 0 else ""
		JOY_AXIS_TRIGGER_RIGHT: return "r2" if value > 0 else ""
	return ""


static func _less(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] < b[i]
	return false


static func gptk_text(rows: Array) -> String:
	var out := ""
	for r in rows:
		if not str(r["key"]).is_empty():
			out += "%s = %s\n" % [r["button"], r["key"]]
	return out + "\n" + DEADZONE_BLOCK


# ---------------------------------------------------------------- build

func build(project_dir: String, s: Dictionary) -> bool:
	warnings = 0
	errors = 0
	project_dir = project_dir.replace("\\", "/").simplify_path()
	var port: String = str(s.get("port_name", "")).strip_edges()
	var title: String = str(s.get("title", "")).strip_edges()

	_say("== Building PortMaster port '%s' from %s" % [port, project_dir])
	var name_problem := check_port_name(port)
	if not name_problem.is_empty():
		return _fail(name_problem)
	if title.is_empty() or title.contains("/"):
		return _fail("Title must be set and must not contain '/'.")
	if str(s.get("porter", "")).strip_edges().is_empty():
		return _fail("Porter must be set (your name or handle, as PortMaster should credit you).")
	if str(s.get("developer", "")).strip_edges().is_empty():
		return _fail("Developer must be set (who made the game).")
	if str(s.get("description", "")).strip_edges().is_empty():
		_warn("Description is empty; port.json and gameinfo.xml need one before submitting.")
	if not FileAccess.file_exists(project_dir.path_join("project.godot")):
		return _fail("No project.godot in %s." % project_dir)
	if FileAccess.get_file_as_string(project_dir.path_join("project.godot")).contains("[dotnet]"):
		return _fail("This is a C# project. It needs PortMaster's Mono runtime and launcher, which this addon doesn't support yet.")

	var out_root := resolve_path(str(s.get("output", "")), project_dir)
	if out_root.is_empty():
		return _fail("Output folder is not set.")
	out_root = out_root.path_join(port)
	var game_dir := out_root.path_join(port)
	var gamedata := game_dir.path_join("gamedata")
	DirAccess.make_dir_recursive_absolute(gamedata)
	_clean_old_output(out_root, game_dir, port)

	var ver := _godot_version(str(s.get("godot_runtime", "")))
	if ver.is_empty():
		return false

	# 1. Export preset
	if not ensure_preset(project_dir):
		return false

	# 2. Export the pck
	var pck := gamedata.path_join(port + ".pck")
	if not export_pck(project_dir, pck):
		return false

	# 3. Renderer override, next to the pck (loaded from the main pack's folder)
	_write(gamedata.path_join("override.cfg"),
		"[rendering]\n\nrenderer/rendering_method=\"gl_compatibility\"\nrenderer/rendering_method.mobile=\"gl_compatibility\"\n")
	_say("Wrote gamedata/override.cfg (Compatibility renderer).")

	# 4. Controls
	var controls := generate_controls(project_dir, s.get("controls", {}), s.get("labels", {}))
	for p in controls["problems"]:
		_warn(p)
	for n in controls["notes"]:
		_say("  note: " + n)
	var gptk := gptk_text(controls["rows"])
	_write(game_dir.path_join(port + ".gptk"), gptk)
	_say("Wrote %s.gptk:\n    %s" % [port, gptk.strip_edges().split("\n\n")[0].replace("\n", "\n    ")])

	# 5. Launcher
	var launcher := launcher_text(port, ver)
	if launcher.is_empty():
		return _fail("Launcher template did not match; builder.gd is damaged.")
	var script_name := title + ".sh"
	_write(out_root.path_join(script_name), launcher)
	_say("Wrote %s (runtime godot_%s)." % [script_name, ver])

	# 6. Metadata
	var genres := _genres(str(s.get("genres", "")))
	_write(out_root.path_join("port.json"), port_json_text(s, port, title, ver, genres))
	_write(out_root.path_join("gameinfo.xml"), gameinfo_text(s, title, genres))
	_write(out_root.path_join("README.md"), readme_text(s, title, controls["rows"]))
	_say("Wrote port.json, gameinfo.xml and README.md.")

	# 7. Screenshot, cover, licences
	_copy_image(resolve_path(str(s.get("screenshot", "")), project_dir), out_root, "screenshot", true)
	var cover := resolve_path(str(s.get("cover", "")), project_dir)
	if not cover.is_empty():
		_copy_image(cover, out_root, "cover", false)
	_copy_licenses(resolve_path(str(s.get("licenses", "")), project_dir), game_dir.path_join("licenses"))

	# 8. Checks
	run_checks(out_root, port, script_name)
	_say("== Done: %s" % out_root)
	_say("   %d warning(s), %d error(s)." % [warnings, errors])
	if errors == 0:
		_say("   Copy %s to the SD card's ports folder, or into PortMaster-New/ports/ and run build_release.py --do-check." % out_root.get_file())
	return errors == 0


## Chooses the PortMaster Godot runtime for an editor version.
## An exact match wins; otherwise the newest known runtime in the same
## major.minor series (patch releases share the pck format), e.g. 4.7.2 -> 4.7.1.
## `override` (e.g. "4.8") skips the lookup.
## Returns {ver, editor, error, note}; `ver` is "" when nothing fits.
static func pick_runtime(v: Dictionary, override: String = "", known: Array = KNOWN_GODOT_RUNTIMES) -> Dictionary:
	var editor := "%d.%d" % [v["major"], v["minor"]]
	if int(v["patch"]) > 0:
		editor += ".%d" % v["patch"]
	var out := {"ver": "", "editor": editor, "error": "", "note": ""}
	override = override.strip_edges().trim_prefix("godot_")
	if not override.is_empty():
		out["ver"] = override
		if not known.has(override):
			out["note"] = "Runtime godot_%s is set by hand and not in PortMaster's list (%s); check it exists." % [override, ", ".join(known)]
		return out
	if known.has(editor):
		out["ver"] = editor
		return out
	var series := "%d.%d" % [v["major"], v["minor"]]
	var best := ""
	var best_patch := -1
	for r in known:
		var parts: PackedStringArray = r.split(".")
		if "%s.%s" % [parts[0], parts[1]] == series:
			var p := int(parts[2]) if parts.size() > 2 else 0
			if p > best_patch:
				best = r
				best_patch = p
	if best.is_empty():
		out["error"] = "PortMaster has no Godot %s runtime (known: %s). Export with a matching editor, or set 'Godot runtime' if PortMaster has added one." % [series, ", ".join(known)]
	else:
		out["ver"] = best
		out["note"] = "Editor is Godot %s; using PortMaster's godot_%s runtime from the same %s series. Test the port on a device." % [editor, best, series]
	return out


## Runtime executable inside the squashfs: "godot" + every version digit
## (godot45, godot441, godot463, godot471 in merged ports).
static func runtime_executable(ver: String) -> String:
	return "godot" + ver.replace(".", "")


const RUNTIMES_HOST := "raw.githubusercontent.com"
const RUNTIMES_PATH := "/PortsMaster/PortMaster-New/main/runtimes/runtimes.json"


## Godot runtime versions PortMaster currently ships, read from PortMaster-New's
## runtimes.json (e.g. ["4.2.2", "4.3", ..., "4.7.1"]). Mono builds are skipped.
## Blocking; returns [] on any network or parse failure. Call off the main thread.
static func fetch_godot_runtimes(timeout_ms: int = 8000) -> Array:
	var http := HTTPClient.new()
	var deadline := Time.get_ticks_msec() + timeout_ms
	if http.connect_to_host(RUNTIMES_HOST, 443, TLSOptions.client()) != OK:
		return []
	while http.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return []
		OS.delay_msec(20)
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return []
	if http.request(HTTPClient.METHOD_GET, RUNTIMES_PATH, ["User-Agent: godot-portmaster-export"]) != OK:
		return []
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		http.poll()
		if Time.get_ticks_msec() > deadline:
			return []
		OS.delay_msec(20)
	if not http.has_response() or http.get_response_code() != 200:
		return []
	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.is_empty():
			if Time.get_ticks_msec() > deadline:
				return []
			OS.delay_msec(20)
		else:
			body.append_array(chunk)
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		return []
	var re := RegEx.create_from_string("^godot_([0-9]+[.][0-9]+(?:[.][0-9]+)?)[.]squashfs$")
	var out := []
	for key in data.keys():
		var m := re.search(str(key))
		if m:
			out.append(m.get_string(1))
	return out


func _godot_version(override: String) -> String:
	var v := Engine.get_version_info()
	if str(v["status"]) != "stable":
		_warn("Godot %s is not a stable build; PortMaster only has runtimes for stable releases." % v["string"])
	var known := fetch_godot_runtimes()
	if known.is_empty():
		known = KNOWN_GODOT_RUNTIMES
		_say("Couldn't fetch PortMaster's runtime list; using the built-in one (%s)." % ", ".join(known))
	else:
		_say("PortMaster's Godot runtimes: %s." % ", ".join(known))
	var r := pick_runtime(v, override, known)
	if not str(r["error"]).is_empty():
		_fail(r["error"])
		return ""
	if not str(r["note"]).is_empty():
		_warn(r["note"])
	_say("Godot runtime: godot_%s (%s), editor %s." % [r["ver"], runtime_executable(r["ver"]), r["editor"]])
	return r["ver"]


func _clean_old_output(out_root: String, game_dir: String, port: String) -> void:
	# Remove stale generated files only (an old launcher title, an old screenshot format).
	var d := DirAccess.open(out_root)
	if d:
		for f in d.get_files():
			if f.ends_with(".sh") or f.begins_with("screenshot.") or f.begins_with("cover."):
				d.remove(f)
	var lic := DirAccess.open(game_dir.path_join("licenses"))
	if lic:
		for f in lic.get_files():
			lic.remove(f)


# ---------------------------------------------------------------- preset

func ensure_preset(project_dir: String) -> bool:
	var path := project_dir.path_join("export_presets.cfg")
	var cf := ConfigFile.new()
	var count := 0
	var model := ""
	if FileAccess.file_exists(path):
		if cf.load(path) != OK:
			return _fail("Can't parse %s." % path)
		while cf.has_section("preset.%d" % count):
			var sec := "preset.%d" % count
			if str(cf.get_value(sec, "name", "")) == PRESET_NAME:
				_check_preset(cf, sec)
				return true
			if model.is_empty() and str(cf.get_value(sec, "platform", "")) == "Windows Desktop":
				model = sec
			count += 1
		if model.is_empty() and count > 0:
			model = "preset.0"

	var top := {
		"name": PRESET_NAME, "platform": "Linux", "runnable": false,
		"advanced_options": false, "dedicated_server": false, "custom_features": "",
		"export_filter": "all_resources", "include_filter": "",
		"exclude_filter": "addons/portmaster_export/*, portmaster/*",
		"export_path": "", "patches": PackedStringArray(),
		"encryption_include_filters": "", "encryption_exclude_filters": "",
		"seed": 0, "encrypt_pck": false, "encrypt_directory": false, "script_export_mode": 2,
	}
	if not model.is_empty():
		# Same field set and order as the project's own preset; only our values differ.
		var copied := {}
		for key in cf.get_section_keys(model):
			copied[key] = top[key] if top.has(key) and key in ["name", "platform", "runnable", "exclude_filter", "export_path"] else cf.get_value(model, key)
		for key in top.keys():
			if not copied.has(key):
				copied[key] = top[key]
		top = copied
	var opts := {
		"custom_template/debug": "", "custom_template/release": "",
		"debug/export_console_wrapper": 1,
		"binary_format/embed_pck": false,
		"texture_format/s3tc_bptc": false,
		"texture_format/etc2_astc": true,
		"shader_baker/enabled": false,
		"binary_format/architecture": "arm64",
	}

	var text := "\n[preset.%d]\n\n" % count
	for key in top.keys():
		text += "%s=%s\n" % [key, var_to_str(top[key])]
	text += "\n[preset.%d.options]\n\n" % count
	for key in opts.keys():
		text += "%s=%s\n" % [key, var_to_str(opts[key])]

	var f: FileAccess
	if FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
		text = text.substr(1)
	if f == null:
		return _fail("Can't write %s." % path)
	f.store_string(text)
	f.close()
	_say("Added export preset '%s' (Linux, arm64, pck only, ETC2/ASTC) to export_presets.cfg." % PRESET_NAME)
	_say("  The editor shows it after a restart. Restart before opening Project > Export, or the editor may save over it.")
	return true


func _check_preset(cf: ConfigFile, sec: String) -> void:
	var o := sec + ".options"
	if str(cf.get_value(sec, "platform", "")) != "Linux":
		_warn("Preset '%s' is not a Linux preset." % PRESET_NAME)
	if str(cf.get_value(o, "binary_format/architecture", "")) != "arm64":
		_warn("Preset '%s' is not arm64; most handhelds need arm64." % PRESET_NAME)
	if not bool(cf.get_value(o, "texture_format/etc2_astc", false)):
		_warn("Preset '%s' has ETC2/ASTC off; GLES3 handhelds need it for VRAM-compressed textures." % PRESET_NAME)
	_say("Using existing export preset '%s'." % PRESET_NAME)


# ---------------------------------------------------------------- export

func export_pck(project_dir: String, pck: String) -> bool:
	if FileAccess.file_exists(pck):
		DirAccess.remove_absolute(pck)
	var godot := OS.get_executable_path()
	var log_path := OS.get_cache_dir().path_join("portmaster_export_%d.log" % Time.get_ticks_usec())
	var args := PackedStringArray(["--headless", "--path", project_dir,
		"--log-file", log_path, "--export-pack", PRESET_NAME, pck])
	_say("Exporting pck: %s %s" % [godot.get_file(), " ".join(args)])
	var output := []
	var code := OS.execute(godot, args, output, true, false)
	var text := ""
	for chunk in output:
		text += str(chunk)
	if FileAccess.file_exists(log_path):
		var lt := FileAccess.get_file_as_string(log_path)
		if lt.length() > text.length():
			text = lt
		DirAccess.remove_absolute(log_path)
	# Keep errors and warnings (with their "at:" line); drop the per-file progress.
	var interesting := PackedStringArray()
	var keep_next := false
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l.begins_with("ERROR") or l.begins_with("WARNING") or l.begins_with("SCRIPT ERROR"):
			interesting.append("    " + l)
			keep_next = true
		elif keep_next and l.begins_with("at:"):
			interesting.append("      " + l)
			keep_next = false
		else:
			keep_next = false
	if interesting.size() > 0:
		_say("  export output:\n" + "\n".join(interesting.slice(0, 40)))
	if code != 0:
		return _fail("Export failed (exit code %d). See the export output above." % code)
	if not FileAccess.file_exists(pck):
		return _fail("Export finished but %s is missing." % pck)
	var size := FileAccess.open(pck, FileAccess.READ).get_length()
	_say("Exported %s (%.1f MB)." % [pck.get_file(), size / 1048576.0])
	return true


# ---------------------------------------------------------------- text files

func launcher_text(port: String, ver: String) -> String:
	var exe := runtime_executable(ver)
	var swaps := {
		"GAMEDIR=/$directory/ports/supermazerobo": "GAMEDIR=/$directory/ports/" + port,
		"godot_runtime=\"godot_4.5\"": "godot_runtime=\"godot_%s\"" % ver,
		"godot_executable=\"godot45.$DEVICE_ARCH\"": "godot_executable=\"%s.$DEVICE_ARCH\"" % exe,
		"pck_filename=\"SMR.pck\"": "pck_filename=\"%s.pck\"" % port,
		"gptk_filename=\"super maze robo.gptk\"": "gptk_filename=\"%s.gptk\"" % port,
	}
	var lines: Array = LAUNCHER_TEMPLATE.duplicate()
	var hits := 0
	for i in lines.size():
		if swaps.has(lines[i]):
			lines[i] = swaps[lines[i]]
			hits += 1
	if hits != swaps.size():
		return ""
	return "\n".join(lines) + "\n"


func port_json_text(s: Dictionary, port: String, title: String, ver: String, genres: PackedStringArray) -> String:
	var porters := PackedStringArray()
	for p in str(s.get("porter", "")).split(","):
		if not p.strip_edges().is_empty():
			porters.append(p.strip_edges())
	var store := []
	var url := str(s.get("itch_url", "")).strip_edges()
	if not url.is_empty():
		var dev_url := url
		var m := RegEx.create_from_string("^(https?://[^/]+\\.itch\\.io/)").search(url)
		if m:
			dev_url = m.get_string(1)
		store.append({"name": "itch", "gameurl": url, "developerurl": dev_url})
	var attr := {
		"title": title,
		"porter": Array(porters),
		"desc": str(s.get("description", "")).strip_edges(),
		"desc_md": null,
		"inst": "Ready to run.",
		"inst_md": null,
		"genres": Array(genres),
		"image": null,
		"rtr": true,
		"exp": false,
		"runtime": ["godot_%s.squashfs" % ver, "weston_pkg_0.2.squashfs"],
		"store": store,
		"availability": "full",
		"reqs": [],
		"arch": [],
		"min_glibc": "",
	}
	var data := {
		"version": 4,
		"name": port + ".zip",
		"items": [title + ".sh", port],
		"items_opt": [],
		"attr": attr,
	}
	return JSON.stringify(data, "  ", false) + "\n"


func gameinfo_text(s: Dictionary, title: String, genres: PackedStringArray) -> String:
	var date := str(s.get("release_date", "")).strip_edges().replace("-", "")
	if date.length() != 8:
		var t := Time.get_date_dict_from_system()
		date = "%04d%02d%02d" % [t["year"], t["month"], t["day"]]
	var dev := str(s.get("developer", "")).strip_edges()
	var genre := genres[0].capitalize() if genres.size() > 0 else "Other"
	if genres.size() > 0 and genres[0] == "casino/card":
		genre = "Casino/Card"
	var port := str(s.get("port_name", ""))
	return """<?xml version="1.0" encoding="utf-8"?>
<gameList>
  <game>
    <path>./%s.sh</path>
    <name>%s</name>
    <desc>%s</desc>
    <releasedate>%sT000000</releasedate>
    <developer>%s</developer>
    <publisher>%s</publisher>
    <genre>%s</genre>
    <image>./%s/screenshot.png</image>
  </game>
</gameList>
""" % [_xml(title), _xml(title), _xml(str(s.get("description", "")).strip_edges()), date,
		_xml(dev), _xml(dev), _xml(genre), port]


func readme_text(s: Dictionary, title: String, rows: Array) -> String:
	var dev := str(s.get("developer", "")).strip_edges()
	var porter := str(s.get("porter", "")).strip_edges()
	var notes := ""
	if dev == porter:
		notes = "%s is made by %s, who also made this port." % [title, dev]
	else:
		notes = "%s is made by %s. Ported by %s." % [title, dev, porter]
	var credits := str(s.get("credits", "")).strip_edges()
	if not credits.is_empty():
		notes += " " + credits

	var by := {}
	for r in rows:
		if not str(r["key"]).is_empty():
			by[r["button"]] = r
	var table := "| Button | Action |\n|--|--|\n"
	var dirs := ["up", "down", "left", "right"]
	if dirs.all(func(d): return by.has(d)):
		var stick_same := dirs.all(func(d): return by.has("left_analog_" + d) and by["left_analog_" + d]["key"] == by[d]["key"])
		var lbl := str(s.get("labels", {}).get("dpad", "Move"))
		table += "|%s|%s|\n" % ["D-Pad / Left stick" if stick_same else "D-Pad", lbl]
		for d in dirs:
			by.erase(d)
			if stick_same:
				by.erase("left_analog_" + d)
	for b in BUTTONS:
		if by.has(b):
			var lbl := str(by[b]["label"])
			if lbl.is_empty():
				lbl = str(by[b]["key"])
			table += "|%s|%s|\n" % [BUTTON_NAMES[b], lbl]
	var text := "## Notes\n\n%s\n\n## Controls\n\n%s" % [notes, table]
	# PortMaster names face buttons by their printed letter (Nintendo layout);
	# Knulli only matches that with its per-port A/B X/Y swap turned on.
	if ["a", "b", "x", "y"].any(func(b): return by.has(b)):
		text += "\nOn Knulli, enable the A/B X/Y swap option.\n"
	return text


static func _xml(t: String) -> String:
	return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


func _genres(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for g in text.split(","):
		var n := g.strip_edges().to_lower()
		if n.is_empty():
			continue
		if not VALID_GENRES.has(n):
			_warn("Genre '%s' is not one of PortMaster's: %s." % [n, ", ".join(VALID_GENRES)])
			continue
		out.append(n)
	if out.is_empty():
		_warn("No valid genre set; using 'other'.")
		out.append("other")
	return out


# ---------------------------------------------------------------- images & licences

func _copy_image(src: String, out_root: String, base: String, required: bool) -> void:
	if src.is_empty() or not FileAccess.file_exists(src):
		if required:
			_warn("No screenshot at '%s'. PortMaster needs a 640x480 screenshot.png (a 1280x960 grab is scaled down)." % src)
		return
	var img := Image.load_from_file(src)
	if img == null or img.is_empty():
		_warn("Can't read image %s." % src)
		return
	var w := img.get_width()
	var h := img.get_height()
	var ext := src.get_extension().to_lower()
	var dest := out_root.path_join(base + ".png")
	if base == "screenshot":
		if w == 640 and h == 480 and (ext == "png" or ext == "jpg"):
			dest = out_root.path_join("screenshot." + ext)
			DirAccess.copy_absolute(src, dest)
		elif w % 320 == 0 and h % 240 == 0 and w * 3 == h * 4:
			img.resize(640, 480, Image.INTERPOLATE_NEAREST)
			img.save_png(dest)
			_say("Scaled screenshot %dx%d -> 640x480 (nearest neighbour)." % [w, h])
		else:
			img.save_png(dest)
			_warn("Screenshot is %dx%d, not a multiple of 320x240; copied unscaled. PortMaster needs exactly 640x480." % [w, h])
		_say("Wrote %s." % dest.get_file())
	else:
		if ext == "png" or ext == "jpg":
			dest = out_root.path_join(base + "." + ext)
			DirAccess.copy_absolute(src, dest)
		else:
			img.save_png(dest)
		_say("Wrote %s." % dest.get_file())


func _copy_licenses(src: String, dest: String) -> void:
	DirAccess.make_dir_recursive_absolute(dest)
	var d := DirAccess.open(src) if not src.is_empty() else null
	if d == null:
		_warn("No licences folder at '%s'. Ship one file per third-party licence in <port>/licenses/." % src)
		return
	var n := 0
	for f in d.get_files():
		if f.begins_with(".") or f.ends_with(".import") or f.ends_with(".uid"):
			continue
		DirAccess.copy_absolute(src.path_join(f), dest.path_join(f))
		n += 1
	for sub in d.get_directories():
		_warn("Licences subfolder '%s' skipped; licenses/ must be flat." % sub)
	if n == 0:
		_warn("Licences folder %s is empty." % src)
	else:
		_say("Copied %d licence file(s)." % n)


# ---------------------------------------------------------------- checks

func run_checks(out_root: String, port: String, script_name: String) -> void:
	_say("Checks:")
	var ok := true
	var name_problem := check_port_name(port)
	ok = _check(name_problem.is_empty(), "port name '%s'" % port, name_problem) and ok

	var shot := ""
	for ext in ["png", "jpg"]:
		if FileAccess.file_exists(out_root.path_join("screenshot." + ext)):
			shot = out_root.path_join("screenshot." + ext)
	var shot_ok := false
	if not shot.is_empty():
		var img := Image.load_from_file(shot)
		shot_ok = img != null and img.get_width() == 640 and img.get_height() == 480
	ok = _check(shot_ok, "screenshot is 640x480", "missing or wrong size") and ok

	for f in ["port.json", "README.md", "gameinfo.xml", script_name,
			port + "/" + port + ".gptk", port + "/gamedata/" + port + ".pck", port + "/gamedata/override.cfg"]:
		ok = _check(FileAccess.file_exists(out_root.path_join(f)), "has " + f, "missing") and ok

	var pj: Variant = JSON.parse_string(FileAccess.get_file_as_string(out_root.path_join("port.json")))
	ok = _check(pj is Dictionary and pj.get("name") == port + ".zip", "port.json parses", "invalid JSON") and ok

	var big := PackedStringArray()
	var bad_text := PackedStringArray()
	for f in _list_files(out_root):
		var size := FileAccess.open(f, FileAccess.READ).get_length()
		if size > MAX_FILE_BYTES:
			big.append(f.trim_prefix(out_root + "/"))
		if f.get_extension().to_lower() in ["sh", "md", "json", "xml", "gptk", "cfg", "txt"]:
			var bytes := FileAccess.get_file_as_bytes(f)
			if bytes.has(13) or bytes.get_string_from_utf8().to_utf8_buffer() != bytes:
				bad_text.append(f.trim_prefix(out_root + "/"))
	ok = _check(big.is_empty(), "no file over 90 MB", ", ".join(big) + " (split with tools/build_data.py)") and ok
	ok = _check(bad_text.is_empty(), "text files are LF and UTF-8", ", ".join(bad_text)) and ok
	if ok:
		_say("  All checks passed.")


func _check(cond: bool, what: String, why: String) -> bool:
	if cond:
		_say("  ok    " + what)
	else:
		errors += 1
		_say("  FAIL  %s: %s" % [what, why])
	return cond


static func _list_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	for f in d.get_files():
		out.append(dir.path_join(f))
	for sub in d.get_directories():
		out.append_array(_list_files(dir.path_join(sub)))
	return out


# ---------------------------------------------------------------- helpers

func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("Can't write %s (%s)." % [path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(text.replace("\r\n", "\n"))
	f.close()


func _say(msg: String) -> void:
	if log_callback.is_valid():
		log_callback.call(msg)
	else:
		print(msg)


func _warn(msg: String) -> void:
	warnings += 1
	_say("  WARNING: " + msg)


func _fail(msg: String) -> bool:
	errors += 1
	_say("ERROR: " + msg)
	return false
