extends Node


func _ready() -> void:
	Global.map_seed = Time.get_ticks_msec() + randi()
	_build_ui()


func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)

	var bg := TextureRect.new()
	bg.texture = load("res://splash-screen.png")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	canvas.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(520, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_left", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 40)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = " "
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Build the ultimate dungeon.\nAdventurers will come to explore — and rate — your creation."
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(subtitle)

	vbox.add_child(HSeparator.new())

	# ── Save Slots ────────────────────────────────────────────────────────
	for i in range(3):
		var slot_name: String = "dungeon_" + str(i + 1)
		var has_save: bool
		if OS.has_feature("web"):
			has_save = Global.web_has_save(slot_name)
		else:
			has_save = FileAccess.file_exists("user://" + slot_name + ".res")

		var slot_hbox := HBoxContainer.new()
		slot_hbox.add_theme_constant_override("separation", 12)
		vbox.add_child(slot_hbox)

		var slot_label := Label.new()
		slot_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot_label.add_theme_font_size_override("font_size", 18)
		if has_save:
			slot_label.text = "Slot %d  —  Saved Game" % (i + 1)
		else:
			slot_label.text = "Slot %d  —  Empty" % (i + 1)
		slot_hbox.add_child(slot_label)

		var new_btn := Button.new()
		new_btn.text = "New Game"
		new_btn.custom_minimum_size = Vector2(120, 36)
		new_btn.pressed.connect(_start.bind(slot_name))
		slot_hbox.add_child(new_btn)

		if has_save:
			var load_btn := Button.new()
			load_btn.text = "Continue ▶"
			load_btn.custom_minimum_size = Vector2(120, 36)
			load_btn.pressed.connect(_load_save.bind(slot_name))
			slot_hbox.add_child(load_btn)

			var delete_btn := Button.new()
			delete_btn.text = "✕"
			delete_btn.tooltip_text = "Delete save"
			delete_btn.custom_minimum_size = Vector2(36, 36)
			delete_btn.pressed.connect(_delete_save.bind(slot_name, slot_label, load_btn, delete_btn))
			slot_hbox.add_child(delete_btn)

	vbox.add_child(HSeparator.new())

	var info := Label.new()
	info.text = "Map: 150 × 150  •  Starting Gold: 2,000"
	info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	vbox.add_child(info)


func _start(slot: String) -> void:
	Global.map_size      = 150
	Global.map_seed      = Time.get_ticks_msec() + randi()
	Global.starting_cash = 2000
	Global.save_slot     = slot
	Global.pending_load  = false
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _load_save(slot: String) -> void:
	Global.map_size      = 150   # will be overridden from save
	Global.starting_cash = 2000
	Global.save_slot     = slot
	Global.pending_load  = true
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _delete_save(slot: String, label: Label, load_btn: Button, del_btn: Button) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval('localStorage.removeItem("dungeonbuilder_' + slot + '")')
	else:
		var path: String = "user://" + slot + ".res"
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	label.text = label.text.split("  —")[0] + "  —  Empty"
	load_btn.queue_free()
	del_btn.queue_free()
