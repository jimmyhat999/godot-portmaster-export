@tool
extends "task.gd"
## Packages a Godot project as a PortMaster port.
##
## Usable from the editor dock or headless:
##   var b = load("res://addons/portmaster_export/builder.gd").new()
##   b.log_callback = func(msg): print(msg)
##   b.build(project_dir, b.load_settings(project_dir))

const SETTINGS_FILE := "portmaster/port.cfg"

## Godot 4.3 added --log-file, OS.get_process_exit_code() and InputEventKey.location,
## and merged the preset's texture formats into s3tc_bptc and etc2_astc. Godot
## 4.5 added the shader baker and EditorInterface.get_open_scene_roots().
static var godot_4_3_plus := int(Engine.get_version_info()["hex"]) >= 0x040300
static var godot_4_5_plus := int(Engine.get_version_info()["hex"]) >= 0x040500
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

## ROCKNIX's libMali driver check, from merged 4.7.1 ports (darkember, vertsky,
## bitfall). No merged port on an older Godot runtime has it, so it goes in only
## for 4.7+ until someone confirms older runtimes need it too. Goes after the
## CONFDIR lines, followed by a blank line.
const LIBMALI_CHECK := [
	"if [[ \"$CFW_NAME\" = \"ROCKNIX\" ]]; then",
	"    if ! glxinfo | grep \"OpenGL version string\"; then",
	"    pm_message \"This Port does not support the libMali graphics driver. Switch to Panfrost to continue.\"",
	"    sleep 5",
	"    exit 1",
	"    fi",
	"fi",
	"",
]

## PortMaster's Godot 4 launcher, from the merged supermazerobo port, plus the
## pm_platform_helper call and the cd into GAMEDIR, and without the comment
## above the header, as in newer ports (stacktris) and PortMaster's checker.
## Only GAMEDIR, godot_runtime, godot_executable, pck_filename and
## gptk_filename are replaced; LIBMALI_CHECK goes in for 4.7+ runtimes.
const LAUNCHER_TEMPLATE := [
	"#!/bin/bash",
	"",
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
	"cd \"$GAMEDIR\"",
	"",
	"$GPTOKEYB \"$godot_executable\" -c \"$GAMEDIR/$gptk_filename\" &",
	"pm_platform_helper \"$godot_dir/$godot_executable\"",
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

# log_callback, cancel() (kills the export), warnings and errors come
# from task.gd.
static var _runtimes_cache: Array = []
static var _runtimes_failed_at := -1
const RUNTIMES_RETRY_MS := 5 * 60 * 1000
## Things the catalogue needs that a device test doesn't (e.g. the screenshot).
var submit_todo := PackedStringArray()
## generate_controls() result computed by the caller on the main thread; when
## empty, build() computes it itself.
var precomputed_controls := {}


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
		"output": "../PortMaster",  # relative to the project, so port.cfg works on any machine
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


## True when `path` is `dir` or below it. Case-insensitive only on Windows,
## whose file system is; elsewhere Game/ and game/ are different folders.
static func is_inside(path: String, dir: String) -> bool:
	var p := path.replace("\\", "/").simplify_path().trim_suffix("/")
	var d := dir.replace("\\", "/").simplify_path().trim_suffix("/")
	if OS.get_name() == "Windows":
		p = p.to_lower()
		d = d.to_lower()
	return p == d or p.begins_with(d + "/")


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


## The title names the launcher file (<Title>.sh), so it must be a valid filename
## on Windows, Linux and the FAT/exFAT SD cards handhelds use.
static func check_title(title: String) -> String:
	if title.is_empty():
		return "Title is empty."
	for c in title:
		if c in "\\/:*?\"<>|" or c.unicode_at(0) < 32:
			return "Title can't contain \\ / : * ? \" < > | (it becomes the launcher's filename, '%s.sh')." % title
	if title.ends_with(".") or title.ends_with(" ") or title.begins_with(" "):
		return "Title can't start with a space or end with a space or '.' (it becomes the launcher's filename)."
	var reserved := ["CON", "PRN", "AUX", "NUL"]
	for i in range(1, 10):
		reserved.append_array(["COM%d" % i, "LPT%d" % i])
	if title.get_slice(".", 0).strip_edges().to_upper() in reserved:
		return "'%s' is a reserved filename on Windows, so it can't name the launcher; choose another title." % title
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
	# A 4.2 project doesn't record the side of Shift, Ctrl or Alt, so those keys
	# map to plain shift/ctrl/alt there.
	var side := ""
	var location := int(ev.get("location")) if godot_4_3_plus else 0
	if location == 1:  # KEY_LOCATION_LEFT
		side = "left"
	elif location == 2:  # KEY_LOCATION_RIGHT
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
		var chords := PackedStringArray()
		for ev in actions[name]["events"]:
			if ev is InputEventKey:
				if ev.shift_pressed or ev.ctrl_pressed or ev.alt_pressed or ev.meta_pressed:
					chords.append(ev.as_text())  # gptokeyb sends single keys, not chords
					continue
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
		if actions[name]["project"] and keys.is_empty() and sources.is_empty() and not chords.is_empty():
			problems.append("'%s' is only bound to key combinations (%s), which gptokeyb can't send, so it can't be used on the device. Give it a single key or a gamepad button." % [name, ", ".join(chords)])
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
			for other in info.keys():
				if info[other]["keys"].has(k) and not info[other]["sources"].has(src):
					penalty += 10 if info[other]["project"] else 1
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
		var directional: bool = src in ["up", "down", "left", "right"] or src.contains("_analog_")
		if hit.size() > 0 and not directional and not bound.any(func(a): return info[a]["project"]):
			# Only Godot's defaults use this button (e.g. ui_select = Y + Space), and the
			# key would also fire other actions (Space -> ui_accept). Leave it unmapped.
			# Never for the d-pad or sticks: games often bind the arrows to their own actions.
			notes.append("%s left unmapped: only %s uses it, and %s would also trigger %s." % [src, ", ".join(bound), best, ", ".join(hit)])
			continue
		auto[src] = best
		if hit.size() > 0 and not directional:
			# Directions sharing the arrow keys with the game's own movement actions is
			# normal, so only mention clashes for buttons.
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

	# On the device only gptokeyb's keys reach the game, so a keyboard-only action
	# is unusable unless some button sends one of its keys.
	var sent := PackedStringArray()
	for r in rows:
		if not str(r["key"]).is_empty():
			sent.append(r["key"])
	for name in info.keys():
		var keys: PackedStringArray = info[name]["keys"]
		if not info[name]["project"] or keys.is_empty() or not info[name]["sources"].is_empty():
			continue
		if not Array(keys).any(func(k): return sent.has(k)):
			problems.append("'%s' has no gamepad button, and no button sends its keys (%s). Set a button to one of them in the controls table, or it can't be used on the device." % [name, ", ".join(keys)])
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
	submit_todo.clear()
	project_dir = project_dir.replace("\\", "/").simplify_path()
	var port: String = str(s.get("port_name", "")).strip_edges()
	var title: String = str(s.get("title", "")).strip_edges()

	_say("== Building PortMaster port '%s' from %s" % [port, project_dir])
	var name_problem := check_port_name(port)
	if not name_problem.is_empty():
		return _fail(name_problem)
	var title_problem := check_title(title)
	if not title_problem.is_empty():
		return _fail(title_problem)
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
	if is_inside(out_root, project_dir):
		# Godot would import the port's images and could pack them into the game.
		return _fail("Output folder %s is inside the project. Choose a folder outside it (the default is ../PortMaster)." % out_root)
	out_root = out_root.path_join(port)
	var game_dir := out_root.path_join(port)
	var gamedata := game_dir.path_join("gamedata")

	var ver := _godot_version(str(s.get("godot_runtime", "")))
	if ver.is_empty():
		return false
	if cancel_requested:
		return _fail("Build cancelled; the previous port was left as it was.")

	# 1. Export preset
	if not ensure_preset(project_dir):
		return false

	# 2. Export the pck. Nothing from an earlier build is touched until this
	# succeeds, and a failed first build leaves no empty port folder behind.
	var fresh_port := not DirAccess.dir_exists_absolute(out_root)
	DirAccess.make_dir_recursive_absolute(gamedata)
	var pck := gamedata.path_join(port + ".pck")
	if not export_pck(project_dir, pck):
		if fresh_port:
			for dir in [gamedata, game_dir, out_root]:
				DirAccess.remove_absolute(dir)  # only succeeds while empty
		return false
	# After the export: in a fresh checkout, its import is what writes
	# .godot/extension_list.cfg.
	_check_gdextensions(project_dir)
	_clean_old_output(out_root, game_dir, port)
	# The folder changes from here on, so an earlier build's zip no longer
	# matches it (a new one is written once this build succeeds).
	var zip_path := out_root.get_base_dir().path_join(port + ".zip")
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)

	# 3. Renderer override, next to the pck (loaded from the main pack's folder)
	_write(gamedata.path_join("override.cfg"),
		"[rendering]\n\nrenderer/rendering_method=\"gl_compatibility\"\nrenderer/rendering_method.mobile=\"gl_compatibility\"\n")
	_say("Wrote gamedata/override.cfg (Compatibility renderer).")

	# 4. Controls
	# The dock computes this on the main thread (it reads ProjectSettings, which
	# isn't thread-safe); headless callers let the builder do it.
	var controls := precomputed_controls if not precomputed_controls.is_empty() \
		else generate_controls(project_dir, s.get("controls", {}), s.get("labels", {}))
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

	# 6. Screenshot, cover, licences (before the metadata, which names the screenshot)
	var shot_name := _copy_image(resolve_path(str(s.get("screenshot", "")), project_dir), out_root, "screenshot", true)
	var cover := resolve_path(str(s.get("cover", "")), project_dir)
	if not cover.is_empty():
		_copy_image(cover, out_root, "cover", false)
	_copy_licenses(resolve_path(str(s.get("licenses", "")), project_dir), game_dir.path_join("licenses"), port)

	# 7. Metadata
	var genres := _genres(str(s.get("genres", "")))
	_write(out_root.path_join("port.json"), port_json_text(s, port, title, ver, genres))
	_write(out_root.path_join("gameinfo.xml"), gameinfo_text(s, title, genres, shot_name if not shot_name.is_empty() else "screenshot.png"))
	_write(out_root.path_join("README.md"), readme_text(s, title, controls["rows"]))
	_say("Wrote port.json, gameinfo.xml and README.md.")

	# 8. Checks
	run_checks(out_root, port, script_name)
	# 9. A zip of the port for testers, next to its folder. PortMaster installs
	# this layout: it moves README.md, port.json, gameinfo.xml and the
	# screenshot from beside the launcher into the port folder.
	if errors == 0:
		if FileAccess.file_exists(out_root.get_base_dir().get_base_dir().path_join("tools/build_release.py")):
			# Output is PortMaster-New's ports/: a zip there would end up in the PR.
			_say("No %s written, since the output folder is PortMaster-New's ports folder. Zip the port folder's contents to share it with testers." % zip_path.get_file())
		elif _write_zip(out_root, zip_path):
			_say("Wrote %s for testers (install it from PortMaster's autoinstall folder)." % zip_path.get_file())
	_say("== Done: %s" % out_root)
	_say("   %d warning(s), %d error(s)." % [warnings, errors])
	if errors == 0:
		_say("   To test it on a device, use Install port in the dock (an installed port is laid out differently from this folder).")
		if submit_todo.is_empty():
			_say("   To submit, copy it into PortMaster-New/ports/ and run build_release.py --do-check.")
		else:
			_say("   Before submitting: %s." % ", ".join(submit_todo))
	return errors == 0


## Feature tags a .gdextension [libraries] key may use and still match
## PortMaster's Godot runtime (a Linux ARM64 non-editor build).
const HANDHELD_LIBRARY_TAGS := ["linux", "arm64", "64", "pc", "single", "release", "debug",
	"template", "template_release", "template_debug"]


## Warns about each GDExtension the game loads (.godot/extension_list.cfg): the
## pck can't carry native libraries, and the plugin doesn't ship them beside it.
func _check_gdextensions(project_dir: String) -> void:
	var list := project_dir.path_join(".godot/extension_list.cfg")
	if not FileAccess.file_exists(list):
		return
	for line in FileAccess.get_file_as_string(list).split("\n"):
		var res := line.strip_edges()
		if res.is_empty():
			continue
		var ext_name := res.get_file().get_basename()
		if editor_only_extension(project_dir, res):
			continue  # an editor tool; the game never loads it
		var lib := arm64_library(project_dir, res)
		if lib.is_empty():
			_warn("The game uses the GDExtension '%s', which has no Linux ARM64 library, so it can't load on a handheld. Remove it from the game, or get a Linux ARM64 build of it." % ext_name)
		else:
			_warn("The game uses the GDExtension '%s'. Its Linux ARM64 library (%s) isn't copied into the port yet, so it won't load on the device. PortMaster-New's riseofthepenguinsgb port shows how to ship one by hand." % [ext_name, lib])


## True when every library a .gdextension (`res` path) lists is for the editor,
## so an exported game never loads it.
static func editor_only_extension(project_dir: String, res: String) -> bool:
	var cf := ConfigFile.new()
	if cf.load(project_dir.path_join(res.trim_prefix("res://"))) != OK or not cf.has_section("libraries"):
		return false
	var keys := cf.get_section_keys("libraries")
	for key in keys:
		if not str(key).split(".").has("editor"):
			return false
	return not keys.is_empty()


## The Linux ARM64 library a .gdextension (`res` path) would load on PortMaster's
## runtime, as a res:// path; "" when it has none, or the file is missing or isn't
## an ARM64 ELF library.
static func arm64_library(project_dir: String, res: String) -> String:
	var cf := ConfigFile.new()
	if cf.load(project_dir.path_join(res.trim_prefix("res://"))) != OK or not cf.has_section("libraries"):
		return ""
	for key in cf.get_section_keys("libraries"):
		var tags: PackedStringArray = str(key).split(".")
		var fits := tags.has("linux")
		for t in tags:
			fits = fits and HANDHELD_LIBRARY_TAGS.has(t)
		if not fits:
			continue
		var lib := str(cf.get_value("libraries", key))
		if not lib.begins_with("res://"):
			lib = res.get_base_dir().path_join(lib)
		var f := FileAccess.open(project_dir.path_join(lib.trim_prefix("res://")), FileAccess.READ)
		if f == null:
			continue
		var head := f.get_buffer(20)
		# ELF, 64-bit, e_machine 183 (AArch64).
		if head.size() == 20 and head.slice(0, 5) == PackedByteArray([0x7F, 0x45, 0x4C, 0x46, 2]) \
				and head[18] == 183 and head[19] == 0:
			return lib
	return ""


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
		if RegEx.create_from_string("^[0-9]+[.][0-9]+(?:[.][0-9]+)?$").search(override) == null:
			out["error"] = "Godot runtime '%s' isn't a version like 4.5 or 4.7.1. Leave it blank to match this editor." % override
			return out
		out["ver"] = override
		var series := "%d.%d" % [v["major"], v["minor"]]
		if not override.begins_with(series + ".") and override != series:
			out["note"] = "Runtime godot_%s is set by hand but this editor is Godot %s; a runtime from another series may not load this export. Set Godot runtime to Auto unless you're sure." % [override, editor]
		elif not known.has(override):
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
static func fetch_godot_runtimes(timeout_ms: int = 8000, should_cancel: Callable = Callable()) -> Array:
	var got := http_get("https://%s%s" % [RUNTIMES_HOST, RUNTIMES_PATH], timeout_ms, should_cancel, "", timeout_ms)
	if not got["ok"]:
		return []
	var data: Variant = JSON.parse_string(PackedByteArray(got["body"]).get_string_from_utf8())
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
	# Fetched once per editor session; an offline attempt isn't retried, so later
	# builds don't each wait for the network timeout.
	# A successful fetch is kept for the editor session. A failed one (offline) is
	# retried after a few minutes, so builds don't each wait for the timeout but a
	# reconnected network is picked up.
	var retry_due := _runtimes_failed_at < 0 or Time.get_ticks_msec() - _runtimes_failed_at > RUNTIMES_RETRY_MS
	if _runtimes_cache.is_empty() and retry_due:
		_runtimes_cache = fetch_godot_runtimes(8000, func(): return cancel_requested)
		if _runtimes_cache.is_empty() and not cancel_requested:
			_runtimes_failed_at = Time.get_ticks_msec()
		elif not _runtimes_cache.is_empty():
			_runtimes_failed_at = -1
	var known: Array = _runtimes_cache
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

## Preset fields always set by this addon, never copied from the model preset.
## Encryption and patches must stay off: PortMaster's stock runtime can't read an
## encrypted pck, and a patch pck is useless on its own. Custom features (e.g.
## "steam") and dedicated-server mode belong to the model's own platform build.
## exclude_filter is merged separately (the model's exclusions plus the addon's).
const OWN_PRESET_KEYS := [
	"name", "platform", "runnable", "exclude_filter", "export_path", "patches",
	"encrypt_pck", "encrypt_directory", "encryption_include_filters", "encryption_exclude_filters",
	"custom_features", "dedicated_server",
]
const ADDON_EXCLUDES := ["addons/portmaster_export/*", "portmaster/*"]


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
				return _check_preset(cf, sec, path)
			if model.is_empty() and str(cf.get_value(sec, "platform", "")) == "Windows Desktop":
				model = sec
			count += 1
		if model.is_empty() and count > 0:
			model = "preset.0"

	var top := {
		"name": PRESET_NAME, "platform": "Linux", "runnable": false,
		"advanced_options": false, "dedicated_server": false, "custom_features": "",
		"export_filter": "all_resources", "include_filter": "",
		"exclude_filter": ", ".join(ADDON_EXCLUDES),
		"export_path": "", "patches": PackedStringArray(),
		"encryption_include_filters": "", "encryption_exclude_filters": "",
		"seed": 0, "encrypt_pck": false, "encrypt_directory": false, "script_export_mode": 2,
	}
	if not model.is_empty():
		# Same field set and order as the project's own preset; only our values differ.
		var copied := {}
		for key in cf.get_section_keys(model):
			copied[key] = top[key] if top.has(key) and key in OWN_PRESET_KEYS else cf.get_value(model, key)
		for key in top.keys():
			if not copied.has(key):
				copied[key] = top[key]
		# Keep whatever the developer excludes from their own builds, plus ours.
		var excludes := PackedStringArray()
		for pattern in str(cf.get_value(model, "exclude_filter", "")).split(",") + PackedStringArray(ADDON_EXCLUDES):
			var p := pattern.strip_edges()
			if not p.is_empty() and not excludes.has(p):
				excludes.append(p)
		copied["exclude_filter"] = ", ".join(excludes)
		top = copied
	var opts := {
		"custom_template/debug": "", "custom_template/release": "",
		"debug/export_console_wrapper": 1,
		"binary_format/embed_pck": false,
	}
	if godot_4_3_plus:
		opts.merge({"texture_format/s3tc_bptc": false, "texture_format/etc2_astc": true})
	else:
		opts.merge({"texture_format/bptc": false, "texture_format/s3tc": false,
			"texture_format/etc": false, "texture_format/etc2": true})
	if godot_4_5_plus:
		opts["shader_baker/enabled"] = false
	opts["binary_format/architecture"] = "arm64"

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


## Checks an existing PortMaster preset; false (with an error) when it can't work.
func _check_preset(cf: ConfigFile, sec: String, path: String) -> bool:
	var o := sec + ".options"
	# Godot 4.3 renamed the ETC2 option; a preset saved by the other side lacks
	# this version's key, so its export would leave ETC2 out.
	var etc2_key := "texture_format/etc2_astc" if godot_4_3_plus else "texture_format/etc2"
	var other_etc2_key := "texture_format/etc2" if godot_4_3_plus else "texture_format/etc2_astc"
	if cf.has_section_key(o, other_etc2_key) and not cf.has_section_key(o, etc2_key):
		_convert_texture_keys(cf, o, path)
	if bool(cf.get_value(sec, "encrypt_pck", false)):
		return _fail("Preset '%s' encrypts the pck, and PortMaster's Godot runtime can't open an encrypted pck. Turn encryption off in that preset (Project > Export)." % PRESET_NAME)
	if str(cf.get_value(sec, "platform", "")) != "Linux":
		_warn("Preset '%s' is not a Linux preset." % PRESET_NAME)
	if str(cf.get_value(o, "binary_format/architecture", "")) != "arm64":
		_warn("Preset '%s' is not arm64; most handhelds need arm64." % PRESET_NAME)
	if not bool(cf.get_value(o, etc2_key, false)):
		_warn("Preset '%s' has ETC2/ASTC off; GLES3 handhelds need it for VRAM-compressed textures." % PRESET_NAME)
	_say("Using existing export preset '%s'." % PRESET_NAME)
	return true


## Godot 4.2 writes texture_format/etc2 (and etc, s3tc, bptc); 4.3+ merged them
## into etc2_astc and s3tc_bptc, and neither reads the other's keys. Adds this
## version's keys with the same choices; the other's stay for that editor.
func _convert_texture_keys(cf: ConfigFile, o: String, path: String) -> void:
	var keys := {}
	var note: String
	if godot_4_3_plus:
		var s3tc_bptc := bool(cf.get_value(o, "texture_format/s3tc", false)) or bool(cf.get_value(o, "texture_format/bptc", false))
		keys = {"texture_format/s3tc_bptc": s3tc_bptc,
			"texture_format/etc2_astc": bool(cf.get_value(o, "texture_format/etc2", false))}
		note = "Godot 4.3's texture options (it was made in Godot 4.2)"
	else:
		var s3tc_bptc := bool(cf.get_value(o, "texture_format/s3tc_bptc", false))
		keys = {"texture_format/bptc": s3tc_bptc, "texture_format/s3tc": s3tc_bptc,
			"texture_format/etc": false,
			"texture_format/etc2": bool(cf.get_value(o, "texture_format/etc2_astc", false))}
		note = "Godot 4.2's texture options (it was made in a newer Godot)"
	var text := FileAccess.get_file_as_string(path)
	var at := text.find("[%s]" % o)
	at = text.find("\n", at) + 1 if at != -1 else -1
	if at > 0 and text.substr(at, 1) == "\n":
		at += 1  # after the blank line under the section header
	if at <= 0:
		_warn("Couldn't update preset '%s' for this Godot version. Check its ETC2/ASTC option (Project > Export)." % PRESET_NAME)
		return
	var lines := ""
	for key in keys:
		lines += "%s=%s\n" % [key, keys[key]]
	text = text.insert(at, lines)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_warn("Couldn't update preset '%s' in %s (%s). Check its ETC2/ASTC option (Project > Export)." % [PRESET_NAME, path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(text)
	f.close()
	for key in keys:
		cf.set_value(o, key, keys[key])
	_say("Updated preset '%s' to %s." % [PRESET_NAME, note])
	_say("  Restart the editor before opening Project > Export, or it may save over the change.")


# ---------------------------------------------------------------- export

## Temp pck of the export running on Godot 4.2, where OS.execute gives no pid:
## cancel() finds the process by this path on its command line. The build
## thread sets it and cancel() reads it, so both go through _export_lock, which
## also makes "cancelled before the export started" and "export running" exclusive.
var _blocking_export := ""
var _export_lock := Mutex.new()
var _killer_running := false  # a kill worker is running; under _export_lock
var _killer_tasks: Array[int] = []  # their WorkerThreadPool ids; under _export_lock


## Exports to a temporary file and only replaces `pck` when the export succeeds,
## so a failed build leaves the previous port intact. Runs Godot as a child
## process that cancel() stops (e.g. when the editor closes).
func export_pck(project_dir: String, pck: String) -> bool:
	var tmp := pck.get_basename() + ".building.pck"
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(tmp)
	var godot := OS.get_executable_path()
	var args := PackedStringArray(["--headless", "--path", project_dir, "--export-pack", PRESET_NAME, tmp])
	var log_path := ""
	if godot_4_3_plus:
		log_path = OS.get_cache_dir().path_join("portmaster_export_%d.log" % Time.get_ticks_usec())
		args.insert(3, "--log-file")
		args.insert(4, log_path)
	_say("Exporting pck: %s %s" % [godot.get_file(), " ".join(args)])
	var code := 0
	var text := ""
	var crashed := false
	if not godot_4_3_plus:
		# Godot 4.2 has no --log-file or OS.get_process_exit_code(), so the export
		# runs blocking with its output captured, and cancel() kills it by its
		# command line.
		var output := []
		_export_lock.lock()
		var start := not cancel_requested
		if start:
			_blocking_export = tmp
		_export_lock.unlock()
		if start:
			var exe := godot
			var exe_args := args
			if OS.get_name() != "Windows":
				# Godot 4.2 runs this through sh on Linux and macOS: one line with
				# each argument in double quotes, where sh still reads $, `, " and \.
				exe = _escape_for_sh_quotes(godot)
				exe_args = PackedStringArray(Array(args).map(_escape_for_sh_quotes))
			code = OS.execute(exe, exe_args, output, true)
		_export_lock.lock()
		_blocking_export = ""
		var killers := _killer_tasks.duplicate()
		_killer_tasks.clear()
		_export_lock.unlock()
		# A kill worker stops once the export has ended; wait for it, so none
		# outlives the build or logs after it.
		for id in killers:
			WorkerThreadPool.wait_for_task_completion(id)
		text = "\n".join(output)
		if cancel_requested:  # before the start check: a killed export can report -1
			if FileAccess.file_exists(tmp):
				DirAccess.remove_absolute(tmp)
			return _fail("Build cancelled; the previous port was left as it was.")
		if code == -1:
			return _fail("Couldn't start %s for the export." % godot)
		# On Linux and macOS, Godot 4.2 reports an export killed by a signal as
		# exit code 0, and the pck may be cut short; its crash handler says so.
		crashed = text.contains("Program crashed with signal")
	else:
		var pid := OS.create_process(godot, args, false)
		if pid <= 0:
			return _fail("Couldn't start %s for the export." % godot)
		while OS.is_process_running(pid):
			if cancel_requested:
				OS.kill(pid)
				OS.delay_msec(200)  # let Windows release the files
				for leftover in [tmp, log_path]:
					if FileAccess.file_exists(leftover):
						DirAccess.remove_absolute(leftover)
				return _fail("Build cancelled; the previous port was left as it was.")
			OS.delay_msec(100)
		code = OS.call("get_process_exit_code", pid)  # not called directly: 4.2 can't parse it
		if FileAccess.file_exists(log_path):
			text = FileAccess.get_file_as_string(log_path)
			DirAccess.remove_absolute(log_path)
	# Keep errors and warnings (with their "at:" line); drop the per-file progress.
	var interesting := PackedStringArray()
	var keep_next := false
	for line in text.split("\n"):
		var l := line.strip_edges()
		if l.begins_with("ERROR") or l.begins_with("WARNING") or l.begins_with("SCRIPT ERROR") or l.contains("Program crashed with signal"):
			interesting.append("    " + l)
			keep_next = true
		elif keep_next and l.begins_with("at:"):
			interesting.append("      " + l)
			keep_next = false
		else:
			keep_next = false
	if interesting.size() > 0:
		_say("  export output:\n" + "\n".join(interesting.slice(0, 40)))
	if code != 0 or crashed or not FileAccess.file_exists(tmp):
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)
		if crashed:
			return _fail("The export crashed. See the export output above; the previous port was left as it was.")
		if code != 0:
			return _fail("Export failed (exit code %d). See the export output above; the previous port was left as it was." % code)
		return _fail("Export finished but wrote no pck; the previous port was left as it was.")
	if FileAccess.file_exists(pck):
		DirAccess.remove_absolute(pck)
	if DirAccess.rename_absolute(tmp, pck) != OK:
		return _fail("Couldn't move the new pck into place at %s." % pck)
	var size := FileAccess.open(pck, FileAccess.READ).get_length()
	_say("Exported %s (%.1f MB)." % [pck.get_file(), size / 1048576.0])
	return true


func cancel() -> void:
	_export_lock.lock()
	cancel_requested = true
	# Off the main thread: listing processes takes a second or two, and the
	# export may not have appeared yet. Added under the lock, so the build
	# thread sees the id once the export ends and waits for the worker.
	if not _blocking_export.is_empty() and not _killer_running:
		_killer_running = true
		_killer_tasks.append(WorkerThreadPool.add_task(_kill_export_worker.bind(self)))
	_export_lock.unlock()


func _export_marker() -> String:
	_export_lock.lock()
	var marker := _blocking_export
	_export_lock.unlock()
	return marker


func _kill_worker_done() -> void:
	_export_lock.lock()
	_killer_running = false  # a later cancel() may try again
	_export_lock.unlock()


## Kills Godot 4.2's export once it shows up in the process list. Gives up,
## saying why, when processes can't be listed or it can't be stopped in time;
## the build then ends when the export does.
static func _kill_export_worker(task: RefCounted) -> void:
	var deadline := Time.get_ticks_msec() + 10000
	var found := false
	while true:
		var marker: String = task._export_marker()
		if marker.is_empty():
			break  # the export has ended
		var r := _kill_matching(task, marker)
		if int(r["killed"]) > 0 or task._export_marker() != marker:
			break  # stopped, or it ended by itself while the list was read
		found = found or int(r["found"]) > 0
		var reason := str(r["error"])
		if reason.is_empty() and Time.get_ticks_msec() > deadline:
			reason = "found it, but stopping it failed" if found else "didn't find it"
		if not reason.is_empty():
			task._say("Couldn't stop the export (%s), so the build ends when it finishes." % reason)
			break
		OS.delay_msec(300)
	task._kill_worker_done()


## Kills the processes whose command line contains `marker`, while `task`'s
## export is still running: the temp path is the same every build, so once it
## ends, a match could be the next build's export.
## Returns {found, killed, error}; error is "" unless processes couldn't be listed.
static func _kill_matching(task: RefCounted, marker: String) -> Dictionary:
	var listed := _pids_with_arg(marker)
	var pids: Array = listed["pids"]
	var out := {"found": pids.size(), "killed": 0, "error": listed["error"]}
	for pid: int in pids:
		if task._export_marker() != marker:
			break  # the export ended while the list was read
		if pid > 0 and pid != OS.get_process_id() and OS.kill(pid) == OK:
			out["killed"] += 1
	return out


## `s` for inside the double quotes Godot 4.2's OS.execute puts around each
## argument on Linux and macOS, where sh would otherwise expand $ and `, and
## end the quotes at ".
static func _escape_for_sh_quotes(s: String) -> String:
	return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$").replace("`", "\\`")


## {pids, error}: the PIDs of the processes whose command line contains `text`,
## or an error saying why the process list couldn't be read.
static func _pids_with_arg(text: String) -> Dictionary:
	var output := []
	var pids: Array[int] = []
	var tool: String
	var code: int
	if OS.get_name() == "Windows":
		# PowerShell does the matching and prints only PIDs: Godot decodes a
		# child's output with the ANSI code page, which garbles accented paths.
		# `text` goes in as base64, so no character in a path (PowerShell also
		# treats curly quotes as quotes) can break or change the script; that
		# also keeps it off PowerShell's own command line, and the $PID check
		# is only a safeguard. By full path when it's there, as Godot may run
		# with a PATH that lacks it.
		tool = OS.get_environment("SystemRoot").path_join("System32/WindowsPowerShell/v1.0/powershell.exe")
		if not FileAccess.file_exists(tool):
			tool = "powershell"
		var script := "$m = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')); Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.Contains($m) } | ForEach-Object { $_.ProcessId }" % Marshalls.utf8_to_base64(text)
		code = OS.execute(tool, ["-NoProfile", "-NonInteractive", "-Command", script], output)
		if code == 0:
			for line in "\n".join(output).split("\n"):
				if line.strip_edges().is_valid_int():
					pids.append(line.strip_edges().to_int())
	else:
		# -ww: full command lines; the marker comes last and could be cut off.
		tool = "ps"
		code = OS.execute(tool, ["-ww", "-eo", "pid=,args="], output)
		if code == 0:
			var line_re := RegEx.create_from_string("^\\s*(\\d+) (.*)$")
			for line in "\n".join(output).split("\n"):
				var m := line_re.search(line.strip_edges(false, true))
				if m and m.get_string(2).contains(text):
					pids.append(m.get_string(1).to_int())
	var error := ""
	if code == -1:
		error = "couldn't run %s" % tool.get_file()
	elif code != 0:
		error = "%s failed with exit code %d" % [tool.get_file(), code]
	return {"pids": pids, "error": error}


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
	var v := ver.split(".")
	if int(v[0]) * 100 + int(v[1] if v.size() > 1 else "0") >= 407:
		var at := lines.find("$ESUDO mkdir -p \"${CONFDIR}\"")
		if at == -1:
			return ""
		for i in LIBMALI_CHECK.size():
			lines.insert(at + 2 + i, LIBMALI_CHECK[i])
	return "\n".join(lines) + "\n"


func port_json_text(s: Dictionary, port: String, title: String, ver: String, genres: PackedStringArray) -> String:
	var porters := PackedStringArray()
	for p in str(s.get("porter", "")).split(","):
		if not p.strip_edges().is_empty():
			porters.append(p.strip_edges())
	var store := []
	var url := str(s.get("itch_url", "")).strip_edges()  # key kept for older port.cfg files; any store URL
	if not url.is_empty():
		store.append(store_entry(url))
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


## port.json store entry for a game URL, named after the site as merged ports do.
## itch.io pages also get the developer's itch page as developerurl.
static func store_entry(url: String) -> Dictionary:
	var m := RegEx.create_from_string("^https?://([^/]+)").search(url)
	var host := m.get_string(1).to_lower() if m else ""
	if host.ends_with(".itch.io"):
		return {"name": "itch", "gameurl": url, "developerurl": "https://%s/" % host}
	var known := {"store.steampowered.com": "Steam", "www.gog.com": "GOG", "gog.com": "GOG",
		"github.com": "GitHub", "gamejolt.com": "Gamejolt", "play.google.com": "Play Store"}
	var store_name: String = known.get(host, host.trim_prefix("www."))
	return {"name": store_name, "gameurl": url, "developerurl": ""}


func gameinfo_text(s: Dictionary, title: String, genres: PackedStringArray, shot_name: String = "screenshot.png") -> String:
	# The game's release date, not the build's. Left out (with a warning) when it
	# isn't set, rather than inventing one that changes on every rebuild.
	var date := str(s.get("release_date", "")).strip_edges().replace("-", "")
	var date_line := ""
	if date.is_empty():
		_warn("Release date is empty, so gameinfo.xml has none. Set it (YYYYMMDD) to the game's release date.")
	elif date.length() != 8 or not date.is_valid_int():
		_warn("Release date '%s' isn't YYYYMMDD, so gameinfo.xml has none." % date)
	else:
		date_line = "    <releasedate>%sT000000</releasedate>\n" % date
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
%s    <developer>%s</developer>
    <publisher>%s</publisher>
    <genre>%s</genre>
    <image>./%s/%s</image>
  </game>
</gameList>
""" % [_xml(title), _xml(title), _xml(str(s.get("description", "")).strip_edges()), date_line,
		_xml(dev), _xml(dev), _xml(genre), port, shot_name]


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
		# One row for the whole d-pad. Its text is the D-Pad Up label when the user
		# wrote one in the dock, else a saved "dpad" label, else "Move".
		var lbl := str(s.get("labels", {}).get("dpad", "Move"))
		var up_label := str(by["up"]["label"]).strip_edges()
		if not up_label.is_empty() and up_label != str(by["up"]["auto_label"]):
			lbl = up_label
		table += "|%s|%s|\n" % ["D-Pad / Left stick" if stick_same else "D-Pad", _md_cell(lbl)]
		for d in dirs:
			by.erase(d)
			if stick_same:
				by.erase("left_analog_" + d)
	for b in BUTTONS:
		if by.has(b):
			var lbl := str(by[b]["label"])
			if lbl.is_empty():
				lbl = str(by[b]["key"])
			table += "|%s|%s|\n" % [BUTTON_NAMES[b], _md_cell(lbl)]
	var text := "## Notes\n\n%s\n\n## Controls\n\n%s" % [notes, table]
	# PortMaster names face buttons by their printed letter (Nintendo layout);
	# Knulli only matches that with its per-port A/B X/Y swap turned on.
	if ["a", "b", "x", "y"].any(func(b): return by.has(b)):
		text += "\nOn Knulli, enable the A/B X/Y swap option.\n"
	return text


## A Markdown table cell: '|' would start a new column.
static func _md_cell(t: String) -> String:
	return t.replace("|", "\\|")


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

## Copies (and for the screenshot, scales) an image into the port root.
## Returns the written file name, or "" when nothing was written.
func _copy_image(src: String, out_root: String, base: String, required: bool) -> String:
	if src.is_empty() or not FileAccess.file_exists(src):
		if required:
			_warn("No screenshot at '%s'. PortMaster needs a 640x480 screenshot.png (a 1280x960 grab is scaled down)." % src)
		return ""
	var img := Image.load_from_file(src)
	if img == null or img.is_empty():
		_warn("Can't read image %s." % src)
		return ""
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
	return dest.get_file()


## True for UTF-8 text with no NUL bytes (licence .txt/.md files, or a bare LICENSE).
static func _is_text(bytes: PackedByteArray) -> bool:
	return not bytes.has(0) and bytes.get_string_from_utf8().to_utf8_buffer() == bytes


func _copy_licenses(src: String, dest: String, port: String) -> void:
	DirAccess.make_dir_recursive_absolute(dest)
	var d := DirAccess.open(src) if not src.is_empty() else null
	if d == null:
		_warn("No licences folder at '%s'. Ship one file per third-party licence in <port>/licenses/." % src)
		return
	var n := 0
	for f in d.get_files():
		if f.begins_with(".") or f.ends_with(".import") or f.ends_with(".uid"):
			continue
		var bytes := FileAccess.get_file_as_bytes(src.path_join(f))
		if _is_text(bytes) and bytes.has(13):
			# Licences saved on Windows often have CRLF; PortMaster wants LF.
			var out := FileAccess.open(dest.path_join(f), FileAccess.WRITE)
			if out:
				out.store_buffer(bytes.get_string_from_utf8().replace("\r\n", "\n").replace("\r", "\n").to_utf8_buffer())
				out.close()
			_say("  %s: converted CRLF line endings to LF." % f)
		else:
			DirAccess.copy_absolute(src.path_join(f), dest.path_join(f))
		n += 1
	for sub in d.get_directories():
		_warn("Licences subfolder '%s' skipped; licenses/ must be flat." % sub)
	if n == 0:
		_warn("Licences folder %s is empty." % src)
	else:
		_say("Copied %d licence file(s)." % n)
	# PortMaster-New's AGENTS.md: "one LICENSE.<component>.txt per bundled component".
	var misnamed := PackedStringArray()
	for f in d.get_files():
		if not (f.begins_with(".") or f.ends_with(".import") or f.ends_with(".uid") or f.begins_with("LICENSE.")):
			misnamed.append(f)
	if not misnamed.is_empty():
		_warn("PortMaster asks for licences named LICENSE.<component>.txt; rename %s." % ", ".join(misnamed))
	# A ready-to-run port must also license the game itself, not just what it
	# bundles: LICENSE.<port>.txt (or .md), the name PortMaster's checker asks for.
	var has_game := false
	for f in d.get_files():
		var lower := f.to_lower()
		if lower.begins_with("license.%s." % port.to_lower()) or lower == "license." + port.to_lower():
			has_game = true
	if not has_game:
		_warn("No licence for the game itself. Add LICENSE.%s.txt to the licences folder with the game's licence, or the developer's permission to distribute it." % port)


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
	# Only the catalogue needs the screenshot; the port runs without it, so this
	# doesn't fail a build meant for testing on a device.
	if shot_ok:
		_say("  ok    screenshot is 640x480")
	else:
		submit_todo.append("add a 640x480 screenshot")
		_say("  TODO  screenshot is 640x480: missing or wrong size (needed before submitting)")

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
	if ok and submit_todo.is_empty():
		_say("  All checks passed.")
	elif ok:
		_say("  The port is complete; it needs the TODO item(s) above before submitting.")


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

## Zips the contents of `src` (not the folder itself) into `zip_path`, via a
## temporary file so a failed write leaves any previous zip as it was.
func _write_zip(src: String, zip_path: String) -> bool:
	var tmp := zip_path + ".tmp"
	var zp := ZIPPacker.new()
	var err := zp.open(tmp)
	if err == OK:
		for path in _list_files(src):
			err = zp.start_file(path.trim_prefix(src + "/"))
			if err != OK:
				break
			err = zp.write_file(FileAccess.get_file_as_bytes(path))
			var closed := zp.close_file()
			if err == OK:
				err = closed
			if err != OK:
				break
		# close() writes the zip's central directory: a failure there leaves
		# a broken zip, so it counts too.
		var finished := zp.close()
		if err == OK:
			err = finished
	if err == OK:
		if FileAccess.file_exists(zip_path):
			DirAccess.remove_absolute(zip_path)
		err = DirAccess.rename_absolute(tmp, zip_path)
	if err != OK:
		if FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(tmp)
		_warn("Couldn't write %s (%s). Zip the port folder's contents yourself to share it." % [zip_path, error_string(err)])
		return false
	return true


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_fail("Can't write %s (%s)." % [path, error_string(FileAccess.get_open_error())])
		return
	f.store_string(text.replace("\r\n", "\n"))
	f.close()
