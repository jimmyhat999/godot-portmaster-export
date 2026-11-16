@tool
extends VBoxContainer
## "PortMaster" dock: port settings, controls table, Build button and log.

const Builder := preload("builder.gd")

## key, label, kind ("line", "text", "file", "dir")
const FIELDS := [
	["port_name", "Port name", "line"],
	["title", "Title", "line"],
	["porter", "Porter", "line"],
	["developer", "Developer", "line"],
	["description", "Description", "text"],
	["genres", "Genres", "line"],
	["itch_url", "Store URL", "line"],
	["credits", "README credits", "text"],
	["release_date", "Release date", "line"],
	["godot_runtime", "Godot runtime", "line"],
	["screenshot", "Screenshot", "file"],
	["cover", "Cover (optional)", "file"],
	["licenses", "Licences folder", "dir"],
	["output", "Output folder", "dir"],
]

const HINTS := {
	"port_name": "Lowercase a-z, 0-9, '.' and '_'; unique in PortMaster's catalogue.",
	"genres": "Comma-separated PortMaster genres: action, adventure, arcade, casino/card, fps, platformer, puzzle, racing, rhythm, rpg, simulation, sports, strategy, visual novel, other.",
	"credits": "One or two sentences for the README, e.g. 'Music by X (link).'",
	"itch_url": "The game's page: itch.io, Steam, GOG, GitHub... Goes into port.json's store entry.",
	"release_date": "The game's release date (YYYYMMDD) for gameinfo.xml; left out when empty.",
	"godot_runtime": "Blank = pick from PortMaster's current runtime list to match this editor (a patch release like 4.7.2 uses 4.7.1). Set a version such as 4.5 only to force a specific runtime.",
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
var file_dialog: EditorFileDialog
var dialog_target: LineEdit
var big_dialog: ConfirmationDialog
var big_edit: TextEdit
var big_target: TextEdit
var thread: Thread
var builder: RefCounted  # the running build, so closing the editor can cancel it
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
			_refresh_controls())


## Only when the dock is really deleted (plugin disabled, editor closing). Moving
## the tab to another panel also exits the tree, and must not cancel a build.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_stop_build()


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

	var grid := GridContainer.new()
	grid.columns = 2
	body.add_child(grid)
	for f in FIELDS:
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

	name_status = Label.new()
	name_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(name_status)

	var header := HBoxContainer.new()
	body.add_child(header)
	var title := Label.new()
	title.text = "Controls (button = key)"
	title.size_flags_horizontal = SIZE_EXPAND_FILL
	header.add_child(title)
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

	var buttons := HBoxContainer.new()
	add_child(buttons)
	var save := Button.new()
	save.text = "Save settings"
	save.pressed.connect(_save)
	buttons.add_child(save)
	build_button = Button.new()
	build_button.text = "Build port"
	build_button.size_flags_horizontal = SIZE_EXPAND_FILL
	build_button.pressed.connect(_on_build)
	buttons.add_child(build_button)

	var log_heading := Label.new()
	log_heading.text = "Build log"
	add_child(log_heading)

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


func _load_into_ui() -> void:
	for key in inputs.keys():
		inputs[key].text = str(settings.get(key, ""))
	_validate_name()
	_fill_controls(settings.get("controls", {}), settings.get("labels", {}))


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
		_log("Godot is still scanning the project's files. Press Build port again in a moment.")
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
		get_tree().create_timer((SETTINGS_SAVE_WAIT_MS - since_change) / 1000.0).timeout.connect(func():
			build_button.disabled = false
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
		_log("The export uses the files on disk. Press Build port again to build from them anyway.")
		confirmed_issues = issue_text
		return
	confirmed_issues = ""
	_save()
	_log("Building in a separate Godot process. Avoid editing or saving until it finishes.")
	build_button.text = "Cancel build"
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
	_log("Build %s." % ("succeeded" if ok else "FAILED"))
	# The export process may have (re)imported files; let the editor catch up.
	EditorInterface.get_resource_filesystem().scan()


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
	file_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR if is_dir else EditorFileDialog.FILE_MODE_OPEN_FILE
	file_dialog.clear_filters()
	if not is_dir:
		file_dialog.add_filter("*.png, *.jpg, *.jpeg, *.webp, *.bmp, *.tga", "Images")
	var current := Builder.resolve_path(target.text, project_dir)
	if not current.is_empty():
		file_dialog.current_dir = current if is_dir else current.get_base_dir()
	file_dialog.popup_file_dialog()


func _on_path_chosen(path: String) -> void:
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
