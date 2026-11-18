@tool
extends VBoxContainer
## "PortMaster" dock: port settings, controls table, Build button and log.

const Builder := preload("builder.gd")
const DeviceInstall := preload("device_install.gd")

## key, label, kind ("line", "text", "file", "dir"), dock section
const FIELDS := [
	["port_name", "Port name", "line", "Port details"],
	["title", "Title", "line", "Port details"],
	["porter", "Porter", "line", "Port details"],
	["developer", "Developer", "line", "Port details"],
	["description", "Description", "text", "Port details"],
	["genres", "Genres", "line", "Port details"],
	["itch_url", "Store URL", "line", "Port details"],
	["credits", "README credits", "text", "Port details"],
	["release_date", "Release date", "line", "Port details"],
	["screenshot", "Screenshot", "file", "Files"],
	["cover", "Cover (optional)", "file", "Files"],
	["licenses", "Licences folder", "dir", "Files"],
	["output", "Output folder", "dir", "Files"],
	["godot_runtime", "Godot runtime", "line", "Advanced"],
]

const HINTS := {
	"port_name": "Lowercase a-z, 0-9, '.' and '_'; unique in PortMaster's catalogue.",
	"genres": "Comma-separated PortMaster genres: action, adventure, arcade, casino/card, fps, platformer, puzzle, racing, rhythm, rpg, simulation, sports, strategy, visual novel, other.",
	"credits": "One or two sentences for the README, e.g. 'Music by X (link).'",
	"itch_url": "The game's page: itch.io, Steam, GOG, GitHub... Goes into port.json's store entry.",
	"release_date": "The game's release date (YYYYMMDD) for gameinfo.xml; left out when empty.",
	"godot_runtime": "Leave empty to use the runtime shown in grey: PortMaster's runtime that matches this editor (a patch release like 4.7.2 uses 4.7.1). Type a version such as 4.8 only to force one, e.g. when PortMaster has added a runtime and you're offline; a runtime from another Godot series can't load this editor's export.",
	"screenshot": "PortMaster wants screenshot.png or .jpg at 640x480, showing gameplay. A grab that's an exact multiple of 320x240 is scaled down; other formats are converted to PNG.",
	"output": "The port folder <output>/<port>/ is written here.",
}

var project_dir := ""
var settings := {}
var inputs := {}
var name_status: Label
var control_grid: GridContainer
var control_rows := []  # [{row, key_edit, label_edit}]
var log_box: TextEdit
var build_button: Button
var install_button: Button
var device_pick: OptionButton
var device_root := ""  # the chosen card's root folder; "" when none
var device_browsing := false  # the folder dialog is choosing a card
var rescan_button: Button
var scan_task := -1  # WorkerThreadPool task looking for cards; -1 when none
var check_task := -1  # WorkerThreadPool task checking the card before an install; -1 when none
var check_cancelled := false  # Cancel was pressed while the card check ran; ignore its result
var install_root := ""  # the card checked for the install in progress; it doesn't follow the dropdown
var runtime_versions: Array = Builder.KNOWN_GODOT_RUNTIMES  # PortMaster's list once fetched
## The dropdown's last item, which opens a folder picker (e.g. for a network share).
const OTHER_FOLDER := ":other"
var runtimes_check: CheckBox
var build_first_check: CheckBox
var install_after_build := false  # Install port started this build; install when it succeeds
var file_dialog: EditorFileDialog
var dialog_target: LineEdit
var big_dialog: ConfirmationDialog
var big_edit: TextEdit
var big_target: TextEdit
var thread: Thread
var builder: RefCounted  # the running build or install, so closing the editor can cancel it
var confirmed_issues := ""  # issues shown last time; pressing again with the same issues builds anyway
var refresh_timer: Timer
var last_settings_change_ms := -100000  # when ProjectSettings last changed (Time.get_ticks_msec)
## Godot writes Project Settings / Input Map edits to project.godot 1.5 s after a
## change; waiting a little longer means the export sees them.
const SETTINGS_SAVE_WAIT_MS := 2000


func _ready() -> void:
	name = "PortMaster"
	project_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	settings = Builder.load_settings(project_dir)
	_build_ui()
	_load_into_ui()
	# Keep the controls table in step with the Input Map. Godot writes Input Map
	# changes to project.godot shortly after they're made, so wait a moment.
	refresh_timer = Timer.new()
	refresh_timer.one_shot = true
	refresh_timer.wait_time = 2.0
	refresh_timer.timeout.connect(_refresh_controls)
	add_child(refresh_timer)
	ProjectSettings.settings_changed.connect(_on_settings_changed)
	visibility_changed.connect(func():
		if is_visible_in_tree():
			_refresh_controls()
			_scan_devices())


## Only when the dock is really deleted (plugin disabled, editor closing). Moving
## the tab to another panel also exits the tree, and must not cancel a build.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_stop_build()
		# A card scan still running isn't waited for: it can be stuck on an
		# offline network drive, and its result is dropped once the dock is gone.


func _stop_build() -> void:
	if thread and thread.is_started():
		if builder:
			builder.cancel_requested = true  # kills the export so the editor isn't held up
		thread.wait_to_finish()


func _build_ui() -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(body)

	var grid: GridContainer
	var section := ""
	var details_grid: GridContainer
	for f in FIELDS:
		if f[3] != section:
			section = f[3]
			_section_header(body, section)
			grid = GridContainer.new()
			grid.columns = 2
			body.add_child(grid)
			if details_grid == null:
				details_grid = grid
		var label := Label.new()
		label.text = f[1]
		grid.add_child(label)
		var input: Control
		match f[2]:
			"text":
				var te := TextEdit.new()
				te.custom_minimum_size = Vector2(0, 54)
				te.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
				input = te
			_:
				var le := LineEdit.new()
				input = le
		input.size_flags_horizontal = SIZE_EXPAND_FILL
		input.tooltip_text = HINTS.get(f[0], "")
		inputs[f[0]] = input
		if f[2] == "file" or f[2] == "dir" or f[2] == "text":
			var row := HBoxContainer.new()
			row.size_flags_horizontal = SIZE_EXPAND_FILL
			row.add_child(input)
			var button := Button.new()
			if f[2] == "text":
				button.text = "Edit"
				button.tooltip_text = "Open %s in a larger editor." % f[1]
				button.size_flags_vertical = SIZE_SHRINK_BEGIN
				button.pressed.connect(_open_big_editor.bind(input, f[1]))
			else:
				button.text = "..."
				button.pressed.connect(_browse.bind(input, f[2] == "dir"))
			row.add_child(button)
			grid.add_child(row)
		else:
			grid.add_child(input)
	inputs["port_name"].text_changed.connect(func(_t): _validate_name())
	inputs["title"].text_changed.connect(func(_t): _validate_name())

	# The port name and title checks sit under those fields.
	name_status = Label.new()
	name_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(name_status)
	body.move_child(name_status, details_grid.get_index() + 1)

	var header := _section_header(body, "Controls")
	var regen := Button.new()
	regen.text = "Reset to Input Map"
	regen.tooltip_text = "Regenerate the keys from the project's Input Map, discarding key overrides. Your Action labels are kept."
	regen.pressed.connect(_reset_controls)
	header.add_child(regen)

	var help := Label.new()
	help.text = "Key: a gptokeyb key name, blank for none. Action: the README text. The README shows the d-pad as one row, named by the D-Pad Up Action."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.modulate = Color(1, 1, 1, 0.6)
	body.add_child(help)

	control_grid = GridContainer.new()
	control_grid.columns = 3
	body.add_child(control_grid)

	_section_header(self, "Build")
	var buttons := HBoxContainer.new()
	add_child(buttons)
	var save := Button.new()
	save.text = "Save settings"
	save.pressed.connect(_save)
	buttons.add_child(save)
	build_button = Button.new()
	build_button.text = "Build port"
	build_button.size_flags_horizontal = SIZE_EXPAND_FILL
	build_button.pressed.connect(func():
		install_after_build = false
		_on_build())
	buttons.add_child(build_button)

	# Installing onto an SD card, for testing on a device. The card's path is
	# per machine, so it's kept in the editor's project metadata, not port.cfg.
	_section_header(self, "Install to SD card")
	var device_row := HBoxContainer.new()
	add_child(device_row)
	var device_label := Label.new()
	device_label.text = "SD card"
	device_row.add_child(device_label)
	device_pick = OptionButton.new()
	device_pick.size_flags_horizontal = SIZE_EXPAND_FILL
	device_pick.clip_text = true
	device_pick.tooltip_text = "Drives that hold a supported handheld card (NextUI, Knulli, Batocera, ArkOS, ROCKNIX, AmberELEC...; see the README). Choose Other folder... for a network share."
	device_pick.item_selected.connect(_on_device_selected)
	device_row.add_child(device_pick)
	rescan_button = Button.new()
	rescan_button.text = "Refresh"
	rescan_button.tooltip_text = "Look for cards again, e.g. after putting one in."
	rescan_button.pressed.connect(_scan_devices)
	device_row.add_child(rescan_button)
	var options_row := HBoxContainer.new()
	add_child(options_row)
	build_first_check = CheckBox.new()
	build_first_check.text = "Build first"
	build_first_check.tooltip_text = "Build the port before installing it, so the card gets your latest changes. Untick to install the last build again without rebuilding, e.g. to put the same build on another device's SD card."
	build_first_check.button_pressed = true
	options_row.add_child(build_first_check)
	runtimes_check = CheckBox.new()
	runtimes_check.text = "Add missing runtimes"
	runtimes_check.tooltip_text = "Copy the Godot runtime the port needs onto the card (downloaded from PortMaster and checked against its checksum), so the first launch doesn't need Wi-Fi. Runtimes already on the card are never replaced."
	runtimes_check.button_pressed = true
	options_row.add_child(runtimes_check)
	var install_row := HBoxContainer.new()
	add_child(install_row)
	install_button = Button.new()
	install_button.text = "Install port"
	install_button.tooltip_text = "Copy the built port onto the card the way PortMaster installs it. Saves (conf/) on the card are kept."
	install_button.size_flags_horizontal = SIZE_EXPAND_FILL
	install_button.pressed.connect(_on_install)
	install_row.add_child(install_button)

	_section_header(self, "Log")

	log_box = TextEdit.new()
	log_box.editable = false
	log_box.placeholder_text = "Press Build port; progress and checks appear here."
	log_box.custom_minimum_size = Vector2(0, 180)
	log_box.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(log_box)

	big_dialog = ConfirmationDialog.new()
	big_dialog.ok_button_text = "Done"
	big_edit = TextEdit.new()
	big_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	big_edit.custom_minimum_size = Vector2(560, 300)
	big_dialog.add_child(big_edit)
	big_dialog.confirmed.connect(_on_big_editor_done)
	add_child(big_dialog)

	file_dialog = EditorFileDialog.new()
	file_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	file_dialog.file_selected.connect(_on_path_chosen)
	file_dialog.dir_selected.connect(_on_path_chosen)
	add_child(file_dialog)


## A divider line and a bold heading. Returns the heading's row, so a section
## can put a button beside its title.
func _section_header(parent: Control, text: String) -> HBoxContainer:
	if parent.get_child_count() > 0:
		parent.add_child(HSeparator.new())
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = SIZE_EXPAND_FILL
	label.add_theme_font_override("font", get_theme_font("bold", "EditorFonts"))
	row.add_child(label)
	return row


func _load_into_ui() -> void:
	for key in inputs.keys():
		inputs[key].text = str(settings.get(key, ""))
	_validate_name()
	_fill_controls(settings.get("controls", {}), settings.get("labels", {}))
	var meta := EditorInterface.get_editor_settings()
	device_root = str(meta.get_project_metadata("portmaster_export", "device_root", ""))
	runtimes_check.button_pressed = bool(meta.get_project_metadata("portmaster_export", "copy_runtimes", true))
	build_first_check.button_pressed = bool(meta.get_project_metadata("portmaster_export", "build_first", true))
	_show_runtime_default()
	_scan_devices()
	# PortMaster's current runtime list, in the background; until it arrives
	# (or when offline) the dropdown uses the plugin's built-in list.
	WorkerThreadPool.add_task(_fetch_runtimes_worker.bind(weakref(self)))


static func _fetch_runtimes_worker(dock: WeakRef) -> void:
	_deliver_runtimes.call_deferred(dock, Builder.fetch_godot_runtimes(8000))


static func _deliver_runtimes(dock: WeakRef, versions: Array) -> void:
	var d: Object = dock.get_ref()
	if d and not versions.is_empty():
		d.runtime_versions = versions
		d._show_runtime_default()


## Shows, in grey inside the empty Godot runtime box, the runtime the build
## uses when it's left empty: the one matching this editor.
func _show_runtime_default() -> void:
	var v := Engine.get_version_info()
	var auto := Builder.pick_runtime(v, "", runtime_versions)
	var edit: LineEdit = inputs["godot_runtime"]
	if str(auto["error"]).is_empty():
		edit.placeholder_text = "godot_%s (auto)" % auto["ver"]
	else:
		edit.placeholder_text = "none for Godot %d.%d yet" % [v["major"], v["minor"]]


func _fill_controls(overrides: Dictionary, labels: Dictionary, log_problems: bool = true) -> void:
	for c in control_grid.get_children():
		control_grid.remove_child(c)  # out of the grid now, so old and new rows never mix
		c.queue_free()
	control_rows.clear()
	var result := Builder.generate_controls(project_dir, overrides, labels)
	for head in ["Button", "Key", "Action"]:
		var l := Label.new()
		l.text = head
		control_grid.add_child(l)
	for row in result["rows"]:
		var b := Label.new()
		b.text = Builder.BUTTON_NAMES[row["button"]]
		b.tooltip_text = "gptk: %s\nInput Map: %s" % [row["button"], ", ".join(row["actions"])]
		control_grid.add_child(b)
		var key := LineEdit.new()
		key.text = row["key"]
		key.placeholder_text = "-"
		key.custom_minimum_size = Vector2(70, 0)
		key.tooltip_text = "Generated: %s" % (row["auto_key"] if row["auto_key"] != "" else "(none)")
		control_grid.add_child(key)
		var label := LineEdit.new()
		label.text = row["label"]
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		control_grid.add_child(label)
		control_rows.append({"row": row, "key": key, "label": label})
	if log_problems:
		for p in result["problems"]:
			_log("Controls: " + p)


func _reset_controls() -> void:
	# Keep the README labels the user wrote (including ones not saved yet).
	_fill_controls({}, _table_edits()["labels"])
	_log("Controls regenerated from the Input Map (save to keep).")


## Live checks for the port name and title, shown under the fields.
func _validate_name() -> void:
	var problems := PackedStringArray()
	for problem in [Builder.check_port_name(inputs["port_name"].text.strip_edges()),
			Builder.check_title(inputs["title"].text.strip_edges())]:
		if problem != "":
			problems.append(problem)
	name_status.text = "\n".join(problems)
	name_status.visible = not problems.is_empty()  # no empty gap under the fields
	name_status.modulate = Color(1, 0.45, 0.4) if not problems.is_empty() else Color.WHITE


func _collect() -> Dictionary:
	var s := settings.duplicate(true)
	for key in inputs.keys():
		s[key] = inputs[key].text.strip_edges()
	var table := _table_edits()
	s["controls"] = table["controls"]
	s["labels"] = table["labels"]
	return s


## The controls table's current edits, saved or not: key overrides (keys that
## differ from the generated ones) and labels that differ from the generated text.
func _table_edits() -> Dictionary:
	var controls := {}
	var labels: Dictionary = settings.get("labels", {}).duplicate()
	for r in control_rows:
		var row: Dictionary = r["row"]
		var b: String = row["button"]
		var key: String = r["key"].text.strip_edges().to_lower()
		if key != row["auto_key"]:
			controls[b] = key
		var label: String = r["label"].text.strip_edges()
		if label != row["auto_label"]:
			labels[b] = label
		else:
			labels.erase(b)
	return {"controls": controls, "labels": labels}


func _on_settings_changed() -> void:
	last_settings_change_ms = Time.get_ticks_msec()
	_schedule_refresh()


## (Re)starts the refresh delay. The timer can't start while the dock is out of
## the tree, e.g. mid-drag to another panel; it refreshes on becoming visible.
func _schedule_refresh() -> void:
	if refresh_timer and refresh_timer.is_inside_tree():
		refresh_timer.start()


## Regenerates the table from the current Input Map, keeping the user's edits.
## Rebuilds only when the generated mapping changed, and never while the user is
## typing in the table (it tries again shortly after).
func _refresh_controls() -> void:
	if control_rows.is_empty() or not is_inside_tree():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus and control_grid.is_ancestor_of(focus):
		_schedule_refresh()
		return
	var table := _table_edits()
	var fresh := Builder.generate_controls(project_dir, table["controls"], table["labels"])
	var current := control_rows.map(func(r): return r["row"])
	if _rows_signature(fresh["rows"]) == _rows_signature(current):
		return
	_fill_controls(table["controls"], table["labels"], false)


## What the Input Map contributes to the table: each button's generated key and actions.
static func _rows_signature(rows: Array) -> String:
	var parts := PackedStringArray()
	for row in rows:
		parts.append("%s=%s:%s" % [row["button"], row["auto_key"], ",".join(row["actions"])])
	return ";".join(parts)


func _save() -> void:
	settings = _collect()
	var err := Builder.save_settings(project_dir, settings)
	if err == OK:
		_log("Saved res://portmaster/port.cfg.")
	else:
		_log("Could not save port.cfg: %s" % error_string(err))


## `waited` is true on the automatic retry after waiting for Godot's settings
## save, so a press waits at most once.
func _on_build(waited: bool = false) -> void:
	if thread and thread.is_started():
		if builder is DeviceInstall:
			return
		# The button is "Cancel build" while a build runs.
		if builder:
			builder.cancel_requested = true
		build_button.disabled = true
		build_button.text = "Cancelling..."
		return
	log_box.text = ""
	# The export runs in a second, headless Godot on this project (a plugin can't
	# export from inside the editor in 4.5). Start it only once the editor has
	# finished scanning, so the two don't import the same files at once.
	if EditorInterface.get_resource_filesystem().is_scanning():
		_log("Godot is still scanning the project's files. Press the button again in a moment.")
		return
	# The export and the controls read project.godot from disk, and the plugin never
	# writes it. Godot itself saves Project Settings / Input Map edits 1.5 s after
	# each change (ProjectSettingsEditor::queue_save), so right after a change wait
	# for that save instead of second-guessing the editor's unsaved state.
	var since_change := Time.get_ticks_msec() - last_settings_change_ms
	# Wait at most once per press: another plugin changing settings every so often
	# must not postpone the build forever, and one wait covers the user's own edit.
	if not waited and since_change < SETTINGS_SAVE_WAIT_MS:
		_log("Project settings were just changed; waiting a moment for Godot to save them...")
		build_button.disabled = true
		install_button.disabled = true
		get_tree().create_timer((SETTINGS_SAVE_WAIT_MS - since_change) / 1000.0).timeout.connect(func():
			build_button.disabled = false
			install_button.disabled = false
			_on_build(true))
		return
	# The export reads the project from disk, so unsaved work isn't in it. Saving
	# an untitled scene would pop up Save As, so those are reported instead.
	var issues := PackedStringArray()
	# Scenes Godot can't save in place (never saved, or their folder is gone) would
	# make save_all_scenes() open a Save As dialog.
	var untitled := EditorInterface.get_open_scene_roots().filter(func(n):
		return n.scene_file_path.is_empty() or not DirAccess.dir_exists_absolute(n.scene_file_path.get_base_dir()))
	if untitled.is_empty():
		EditorInterface.save_all_scenes()
	else:
		issues.append("An open scene has never been saved, or its folder no longer exists, so open scenes weren't saved. Save your scenes (Scene > Save All Scenes) first.")
	var differs := _unsaved_scripts()
	if not differs.is_empty():
		issues.append("These open scripts differ from the files on disk. Either they have unsaved changes (save them), or the file changed outside Godot (reload it when Godot asks):\n    %s" % "\n    ".join(differs))
	# Pressing again builds anyway, but only past the same issues just shown.
	var issue_text := "\n".join(issues)
	if not issues.is_empty() and issue_text != confirmed_issues:
		for issue in issues:
			_log(issue)
		_log("The export uses the files on disk. Press the button again to build from them anyway.")
		confirmed_issues = issue_text
		return
	confirmed_issues = ""
	_save()
	_log("Building in a separate Godot process. Avoid editing or saving until it finishes.")
	build_button.text = "Cancel build"
	install_button.disabled = true
	builder = Builder.new()
	builder.log_callback = func(msg: String): _log.call_deferred(msg)
	# Generated here on the main thread: it reads ProjectSettings, which isn't
	# safe to read from the build thread while the editor may be changing it.
	builder.precomputed_controls = Builder.generate_controls(project_dir, settings.get("controls", {}), settings.get("labels", {}))
	thread = Thread.new()
	thread.start(_run_build.bind(settings.duplicate(true)))


## Open scripts whose text in the editor differs from the file on disk.
func _unsaved_scripts() -> PackedStringArray:
	var out := PackedStringArray()
	for script in EditorInterface.get_script_editor().get_open_scripts():
		var path: String = script.resource_path
		if path.is_empty() or path.contains("::") or not FileAccess.file_exists(path):
			continue
		var on_disk := FileAccess.get_file_as_string(path).replace("\r", "")
		if script.source_code.replace("\r", "") != on_disk:
			out.append(path)
	return out


func _run_build(s: Dictionary) -> void:
	var ok: bool = builder.build(project_dir, s)
	_build_finished.call_deferred(ok)


func _build_finished(ok: bool) -> void:
	if thread and thread.is_started():
		thread.wait_to_finish()
	builder = null
	build_button.disabled = false
	build_button.text = "Build port"
	install_button.disabled = false
	_log("Build %s." % ("succeeded" if ok else "FAILED"))
	# The export process may have (re)imported files; let the editor catch up.
	EditorInterface.get_resource_filesystem().scan()
	if install_after_build:
		install_after_build = false
		if ok:
			_log("")
			_start_install()
		else:
			_log("Not installing, because the build didn't succeed.")


## Looks for drives that hold a supported card, in the background: an offline
## network drive or an empty card reader can take seconds to answer, which
## mustn't freeze the editor. _fill_devices() then updates the dropdown.
func _scan_devices() -> void:
	if device_pick == null or scan_task != -1:
		return
	rescan_button.disabled = true
	rescan_button.text = "Looking..."
	scan_task = WorkerThreadPool.add_task(_scan_worker.bind(weakref(self), device_root))


## Runs on a worker thread. Static, and it holds the dock only weakly, so it's
## safe if the dock is deleted (plugin disabled) while it's still looking.
static func _scan_worker(dock: WeakRef, saved_root: String) -> void:
	var cards := []  # [root, label]; supported cards first, so they're the default pick
	var unsupported := []
	var drives := PackedStringArray()
	for i in DirAccess.get_drive_count():
		var drive := DirAccess.get_drive_name(i).replace("\\", "/").trim_suffix("/")
		if drive.is_empty():
			drive = "/"
		drives.append(drive)
		var dev := DeviceInstall.detect(drive)
		if not dev.is_empty():
			cards.append([drive, "%s  (%s)" % [drive, dev["firmware"]]])
		else:
			# Listed so the user sees the plugin found it; Install explains why not.
			var other := DeviceInstall.unsupported_firmware(drive)
			if not other.is_empty():
				unsupported.append([drive, "%s  (%s, not supported yet)" % [drive, other]])
	cards.append_array(unsupported)
	# A folder chosen with Other folder... stays listed while it's there, and a
	# network share (//server/share) even when it isn't answering right now. A
	# drive whose card was taken out (E:, /media/...) is dropped.
	var keep_saved := saved_root.begins_with("//") or DirAccess.dir_exists_absolute(saved_root)
	_deliver_scan.call_deferred(dock, cards, drives, saved_root, keep_saved)


static func _deliver_scan(dock: WeakRef, cards: Array, drives: PackedStringArray, saved_root: String, keep_saved: bool) -> void:
	var d: Object = dock.get_ref()
	if d:
		d._fill_devices(cards, drives, saved_root, keep_saved)


## Fills the dropdown with the cards found. A folder chosen with Other
## folder... (not a drive, e.g. a network share) stays in the list unchecked;
## the install checks it.
func _fill_devices(cards: Array, drives: PackedStringArray, saved_root: String, keep_saved: bool) -> void:
	WorkerThreadPool.wait_for_task_completion(scan_task)
	scan_task = -1
	rescan_button.disabled = false
	rescan_button.text = "Refresh"
	# A folder picked while the scan ran is kept as it is.
	var keep := keep_saved or device_root != saved_root
	if not device_root.is_empty() and not drives.has(device_root) and keep:
		cards.append([device_root, device_root])
	device_pick.clear()
	for c in cards:
		device_pick.add_item(c[1])
		device_pick.set_item_metadata(device_pick.item_count - 1, c[0])
	if cards.is_empty():
		device_pick.add_item("No card found: put one in, then Refresh")
		device_pick.set_item_metadata(0, "")
	device_pick.add_separator()
	device_pick.add_item("Other folder...")
	device_pick.set_item_metadata(device_pick.item_count - 1, OTHER_FOLDER)
	# Keep the card chosen before, if it's still here; otherwise the first one.
	if not _select_device_root():
		device_pick.select(0)
		device_root = str(device_pick.get_item_metadata(0))


## Selects device_root in the dropdown; false when it isn't listed.
func _select_device_root() -> bool:
	if device_root.is_empty():
		return false
	for i in device_pick.item_count:
		if device_pick.get_item_metadata(i) == device_root:
			device_pick.select(i)
			return true
	return false


func _on_device_selected(index: int) -> void:
	var value := str(device_pick.get_item_metadata(index))
	if value != OTHER_FOLDER:
		device_root = value
		EditorInterface.get_editor_settings().set_project_metadata("portmaster_export", "device_root", device_root)
		return
	_select_device_root()  # shows the current card again if the picker is cancelled
	device_browsing = true
	dialog_target = null
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	file_dialog.clear_filters()
	if not device_root.is_empty():
		file_dialog.current_dir = device_root
	file_dialog.popup_file_dialog()


func _on_install() -> void:
	if thread and thread.is_started():
		if builder is DeviceInstall:
			builder.cancel_requested = true
			install_button.disabled = true
			install_button.text = "Cancelling..."
		return
	if check_task != -1:
		if not check_cancelled:
			# The button is "Cancel" while the card is checked.
			check_cancelled = true
			install_button.text = "Install port"
			_log("Stopped waiting for the card.")
		else:
			_log("Still waiting for the last card check to give up (an offline network drive can take a minute). Try again shortly.")
		return
	var meta := EditorInterface.get_editor_settings()
	meta.set_project_metadata("portmaster_export", "device_root", device_root)
	meta.set_project_metadata("portmaster_export", "copy_runtimes", runtimes_check.button_pressed)
	meta.set_project_metadata("portmaster_export", "build_first", build_first_check.button_pressed)
	# Check what the install needs before spending time on a build. The card is
	# checked in the background: a card swapped since the last scan is caught,
	# and an offline network drive can't freeze the editor. Build port stays
	# usable meanwhile, and Install port becomes Cancel.
	log_box.text = ""
	if _install_target(device_root).is_empty():
		return
	_log("Checking the card at %s..." % device_root)
	install_root = device_root
	check_cancelled = false
	install_button.text = "Cancel"
	check_task = WorkerThreadPool.add_task(_check_card_worker.bind(weakref(self), device_root))


static func _check_card_worker(dock: WeakRef, root: String) -> void:
	_deliver_card_check.call_deferred(dock, DeviceInstall.card_problem(root))


static func _deliver_card_check(dock: WeakRef, card_problem: String) -> void:
	var d: Object = dock.get_ref()
	if d:
		d._after_card_check(card_problem)


func _after_card_check(card_problem: String) -> void:
	WorkerThreadPool.wait_for_task_completion(check_task)
	check_task = -1
	if check_cancelled:
		return
	install_button.text = "Install port"
	if not card_problem.is_empty():
		_log(card_problem)
		return
	if thread and thread.is_started():
		_log("A build started while the card was checked. Press Install port again when it finishes.")
		return
	if build_first_check.button_pressed:
		install_after_build = true
		_on_build()  # installs from _build_finished when the build succeeds
	else:
		_log("Installing the last build, without building first.")
		_start_install()


## {root, port, title, out_root} for installing onto `root`, or {} after logging why not.
func _install_target(root: String) -> Dictionary:
	if root.is_empty():
		_log("No SD card found. Put the card in and press Refresh, or choose Other folder... for a network share.")
		return {}
	var s := _collect()
	var port := str(s["port_name"])
	var title := str(s["title"])
	for problem in [Builder.check_port_name(port), Builder.check_title(title)]:
		if problem != "":
			_log(problem)
			return {}
	return {"root": root, "port": port, "title": title,
		"out_root": Builder.resolve_path(str(s["output"]), project_dir).path_join(port)}


## Installs onto install_root, the card checked when Install port was pressed,
## even if the dropdown changed during the build (a rescan, a card swapped).
func _start_install() -> void:
	var t := _install_target(install_root)
	if t.is_empty():
		return
	builder = DeviceInstall.new()
	builder.log_callback = func(msg: String): _log.call_deferred(msg)
	install_button.text = "Cancel install"
	build_button.disabled = true
	thread = Thread.new()
	thread.start(_run_install.bind(t["out_root"], t["port"], t["title"], t["root"], runtimes_check.button_pressed))


func _run_install(out_root: String, port: String, title: String, root: String, copy_runtimes: bool) -> void:
	var ok: bool = builder.install(out_root, port, title, root, copy_runtimes)
	_install_finished.call_deferred(ok)


func _install_finished(ok: bool) -> void:
	if thread and thread.is_started():
		thread.wait_to_finish()
	builder = null
	install_button.disabled = false
	install_button.text = "Install port"
	build_button.disabled = false
	_log("Install %s." % ("succeeded" if ok else "FAILED"))


func _log(msg: String) -> void:
	log_box.text += msg + "\n"
	log_box.scroll_vertical = log_box.get_line_count()


func _open_big_editor(target: TextEdit, title: String) -> void:
	big_target = target
	big_dialog.title = title
	big_edit.text = target.text
	big_dialog.popup_centered(Vector2i(600, 380))
	big_edit.grab_focus()


func _on_big_editor_done() -> void:
	if big_target:
		big_target.text = big_edit.text


func _browse(target: LineEdit, is_dir: bool) -> void:
	dialog_target = target
	device_browsing = false
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR if is_dir else EditorFileDialog.FILE_MODE_OPEN_FILE
	file_dialog.clear_filters()
	if not is_dir:
		file_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga", "Images")
	var current := Builder.resolve_path(target.text, project_dir)
	if not current.is_empty():
		file_dialog.current_dir = current if is_dir else current.get_base_dir()
	file_dialog.popup_file_dialog()


func _on_path_chosen(path: String) -> void:
	if device_browsing:
		device_browsing = false
		device_root = path.replace("\\", "/").trim_suffix("/")  # a card, not part of the project
		if device_root.is_empty():
			device_root = "/"
		EditorInterface.get_editor_settings().set_project_metadata("portmaster_export", "device_root", device_root)
		_scan_devices()
		return
	if dialog_target == null:
		return
	dialog_target.text = portable_path(path, project_dir)


## res:// inside the project, a path relative to the project elsewhere on the
## same drive, so port.cfg works on other machines. Absolute only across drives.
static func portable_path(path: String, base: String) -> String:
	path = path.replace("\\", "/").simplify_path()
	base = base.replace("\\", "/").simplify_path()
	if Builder.is_inside(path, base):
		var rest := path.substr(base.length()).trim_prefix("/")
		return "res://" + rest
	# Windows paths are case-insensitive; Linux and macOS ones aren't.
	var fold := OS.get_name() == "Windows"
	var p := path.split("/")
	var b := base.split("/")
	if not _same(p[0], b[0], fold):
		return path
	var common := 0
	while common < mini(p.size(), b.size()) and _same(p[common], b[common], fold):
		common += 1
	var parts := PackedStringArray()
	for i in b.size() - common:
		parts.append("..")
	parts.append_array(p.slice(common))
	return "/".join(parts)


static func _same(a: String, b: String, fold: bool) -> bool:
	return a.to_lower() == b.to_lower() if fold else a == b
