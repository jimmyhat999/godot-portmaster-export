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
	"release_date": "YYYYMMDD for gameinfo.xml; empty uses the build date.",
	"godot_runtime": "Blank = match this editor (a patch release like 4.7.2 uses PortMaster's 4.7.1). Set e.g. 4.8 only if PortMaster has a runtime this addon doesn't know.",
	"screenshot": "640x480, or an exact multiple of 320x240 (scaled down nearest-neighbour).",
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
var confirm_pending := false  # pre-build issues were shown; the next press builds anyway


func _ready() -> void:
	name = "PortMaster"
	project_dir = ProjectSettings.globalize_path("res://").trim_suffix("/")
	settings = Builder.load_settings(project_dir)
	_build_ui()
	_load_into_ui()


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
	regen.tooltip_text = "Discard the overrides below and regenerate from the project's Input Map."
	regen.pressed.connect(_reset_controls)
	header.add_child(regen)

	var help := Label.new()
	help.text = "Key: a gptokeyb key name, blank for none. Action: the README text."
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


func _fill_controls(overrides: Dictionary, labels: Dictionary) -> void:
	for c in control_grid.get_children():
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
	for p in result["problems"]:
		_log("Controls: " + p)


func _reset_controls() -> void:
	_fill_controls({}, {})
	_log("Controls regenerated from the Input Map (save to keep).")


func _validate_name() -> void:
	var problem := Builder.check_port_name(inputs["port_name"].text.strip_edges())
	name_status.text = problem
	name_status.modulate = Color(1, 0.45, 0.4) if problem != "" else Color.WHITE


func _collect() -> Dictionary:
	var s := settings.duplicate(true)
	for key in inputs.keys():
		s[key] = inputs[key].text.strip_edges()
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
	s["controls"] = controls
	s["labels"] = labels
	return s


func _save() -> void:
	settings = _collect()
	var err := Builder.save_settings(project_dir, settings)
	if err == OK:
		_log("Saved res://portmaster/port.cfg.")
	else:
		_log("Could not save port.cfg: %s" % error_string(err))


func _on_build() -> void:
	if thread and thread.is_started():
		# The button is "Cancel build" while a build runs.
		if builder:
			builder.cancel_requested = true
		build_button.disabled = true
		build_button.text = "Cancelling..."
		return
	log_box.text = ""
	# The export runs in a separate Godot that reads the project from disk, so
	# unsaved work isn't in it. Saving an untitled scene would pop up Save As, so
	# those are reported instead of saved.
	var issues := PackedStringArray()
	var untitled := EditorInterface.get_open_scene_roots().filter(func(n): return n.scene_file_path.is_empty())
	if untitled.is_empty():
		EditorInterface.save_all_scenes()
	else:
		issues.append("An untitled scene is open, so open scenes weren't saved. Save your scenes (Scene > Save All Scenes) first.")
	var differs := _unsaved_scripts()
	if not differs.is_empty():
		issues.append("These open scripts differ from the files on disk. Either they have unsaved changes (save them), or the file changed outside Godot (reload it when Godot asks):\n    %s" % "\n    ".join(differs))
	if not issues.is_empty() and not confirm_pending:
		for issue in issues:
			_log(issue)
		_log("The export uses the files on disk. Press Build port again to build from them anyway.")
		confirm_pending = true
		return
	confirm_pending = false
	_save()
	build_button.text = "Cancel build"
	builder = Builder.new()
	builder.log_callback = func(msg: String): _log.call_deferred(msg)
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
		file_dialog.add_filter("*.png, *.jpg", "Images")
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
	if path.to_lower() == base.to_lower():
		return "res://"
	if path.to_lower().begins_with(base.to_lower() + "/"):
		return "res://" + path.substr(base.length() + 1)
	var p := path.split("/")
	var b := base.split("/")
	if p[0].to_lower() != b[0].to_lower():
		return path
	var common := 0
	while common < mini(p.size(), b.size()) and p[common].to_lower() == b[common].to_lower():
		common += 1
	var parts := PackedStringArray()
	for i in b.size() - common:
		parts.append("..")
	parts.append_array(p.slice(common))
	return "/".join(parts)
