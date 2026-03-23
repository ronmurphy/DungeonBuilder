extends Control
class_name TaxReport

# Kept class_name for scene compatibility — this is now the Dungeon Report

const CROSS_TEX = preload("res://graphics/cross.png")

const PANEL_W: float = 760.0
const PANEL_H: float = 560.0

# Dungeon Stats tab
var _stats_labels: Dictionary = {}
var _stats_vbox: VBoxContainer       # reference for adding themed room rows dynamically
var _themed_rows: Array[Node] = []   # track dynamic rows for cleanup

# Visit History tab
var _history_rows: VBoxContainer

# Loot Log tab
var _loot_rows: VBoxContainer

var _tabs: TabContainer
var _built: bool = false


func _ready() -> void:
	visible = false
	# Make this Control cover the full screen so the panel can be positioned
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		visible = false
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	if _built:
		return
	_built = true

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	# Anchor to bottom-left corner with a small margin
	panel.anchor_left   = 0.0
	panel.anchor_right  = 0.0
	panel.anchor_top    = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left   = 16.0
	panel.offset_right  = 16.0 + PANEL_W
	panel.offset_top    = -(PANEL_H + 16.0)
	panel.offset_bottom = -16.0
	add_child(panel)

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_top", "margin_left", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Header row
	var header_row := HBoxContainer.new()
	vbox.add_child(header_row)

	var title := Label.new()
	title.text = "  Dungeon Reports"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(title)

	var close_btn := TextureButton.new()
	close_btn.texture_normal = CROSS_TEX
	close_btn.custom_minimum_size = Vector2(24, 24)
	close_btn.ignore_texture_size = true
	close_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	close_btn.pressed.connect(func(): visible = false)
	header_row.add_child(close_btn)

	vbox.add_child(HSeparator.new())

	# Tabs
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_tabs)

	_build_stats_tab(_tabs)
	_build_history_tab(_tabs)
	_build_loot_tab(_tabs)


func _build_stats_tab(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Dungeon Stats"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 4)
	scroll.add_child(vbox)
	_stats_vbox = vbox

	# Rating section
	_add_section_header(vbox, "Rating")
	_add_stat_row(vbox, "Total points", "total_points")
	_add_stat_row(vbox, "Stars", "stars_display")
	_add_stat_row(vbox, "Payout per visit", "payout")

	_add_section_header(vbox, "Score Breakdown")
	_add_stat_row(vbox, "Size score (tiles / 10)", "size_score")
	_add_stat_row(vbox, "Variety score (types × 5)", "variety_score")
	_add_stat_row(vbox, "Danger score (traps + monsters)", "danger_points")
	_add_stat_row(vbox, "Treasure score (chests, weapons)", "treasure_points")
	_add_stat_row(vbox, "Atmosphere score (decor)", "atmosphere_points")
	_add_stat_row(vbox, "Room bonus", "room_points")

	_add_section_header(vbox, "Dungeon Layout")
	_add_stat_row(vbox, "Total tiles placed", "total_tiles")
	_add_stat_row(vbox, "Floor tiles", "floor_count")
	_add_stat_row(vbox, "Wall tiles", "wall_count")
	_add_stat_row(vbox, "Items & characters", "item_count")
	_add_stat_row(vbox, "Unique item types", "unique_types")
	_add_stat_row(vbox, "Enclosed rooms", "room_count")
	_add_stat_row(vbox, "Treasure rooms", "treasure_rooms")

	_add_section_header(vbox, "Next Visitors")
	_add_stat_row(vbox, "Party", "next_party_name")
	_add_stat_row(vbox, "Type", "next_party_type")


func _build_history_tab(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Visit History"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)

	_history_rows = VBoxContainer.new()
	_history_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_history_rows.add_theme_constant_override("separation", 2)
	scroll.add_child(_history_rows)


func _build_loot_tab(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "Loot Log"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)

	_loot_rows = VBoxContainer.new()
	_loot_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_loot_rows.add_theme_constant_override("separation", 2)
	scroll.add_child(_loot_rows)


func _add_section_header(parent: VBoxContainer, text: String) -> void:
	parent.add_child(HSeparator.new())
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 16)
	lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
	parent.add_child(lbl)


func _add_stat_row(parent: VBoxContainer, label_text: String, key: String) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)

	var name_lbl := Label.new()
	name_lbl.text = label_text
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = "—"
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.custom_minimum_size = Vector2(120, 0)
	hbox.add_child(val_lbl)

	_stats_labels[key] = val_lbl


func _add_stat_row_direct(parent: VBoxContainer, label_text: String, value_text: String) -> void:
	var hbox := HBoxContainer.new()
	parent.add_child(hbox)

	var name_lbl := Label.new()
	name_lbl.text = "  " + label_text
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = value_text
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.custom_minimum_size = Vector2(120, 0)
	hbox.add_child(val_lbl)


# Called by builder.gd when the report button is pressed
func show_dungeon_report(stats: Dictionary, visit_history: Array) -> void:
	_build_ui()

	# Update stats labels
	for key in _stats_labels:
		var lbl: Label = _stats_labels[key]
		if key == "stars_display":
			var stars: int = stats.get("stars", 1)
			var star_str: String = ""
			for i in range(stars):
				star_str += "★"
			for i in range(5 - stars):
				star_str += "☆"
			lbl.text = star_str
			if stars >= 4:
				lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
			elif stars >= 3:
				lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
			elif stars >= 2:
				lbl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.15))
			else:
				lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
		elif key == "payout":
			lbl.text = "%dg" % stats.get("payout", 0)
		elif key == "next_party_name":
			lbl.text = stats.get("next_party_name", "—")
		elif key == "next_party_type":
			lbl.text = stats.get("next_party_type", "—")
		else:
			lbl.text = str(stats.get(key, 0))

	# Update themed room rows (dynamic — depends on current stats)
	for row in _themed_rows:
		if is_instance_valid(row):
			row.queue_free()
	_themed_rows.clear()
	if stats.has("themed_rooms") and _stats_vbox:
		var themed: Dictionary = stats["themed_rooms"]
		if not themed.is_empty():
			# Insert after "Treasure rooms" row — find its index
			var insert_idx: int = _stats_vbox.get_child_count()  # fallback: append
			for i in range(_stats_vbox.get_child_count()):
				var child := _stats_vbox.get_child(i)
				if child is HBoxContainer:
					var first := child.get_child(0)
					if first is Label and first.text == "Treasure rooms":
						insert_idx = i + 1
						break
			for theme_name in themed:
				var hbox := HBoxContainer.new()
				var name_lbl := Label.new()
				name_lbl.text = "  " + theme_name + " rooms"
				name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				name_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
				hbox.add_child(name_lbl)
				var val_lbl := Label.new()
				val_lbl.text = str(themed[theme_name])
				val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
				val_lbl.custom_minimum_size = Vector2(120, 0)
				val_lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
				hbox.add_child(val_lbl)
				_stats_vbox.add_child(hbox)
				_stats_vbox.move_child(hbox, insert_idx)
				_themed_rows.append(hbox)
				insert_idx += 1

	# Update visit history
	for child in _history_rows.get_children():
		child.queue_free()

	if visit_history.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No adventurer visits yet — they arrive every week."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_history_rows.add_child(empty_lbl)
	else:
		# Column headers
		var header := HBoxContainer.new()
		_history_rows.add_child(header)
		for col in ["Week", "Stars", "Points", "Rating", "Loot", "Total"]:
			var lbl := Label.new()
			lbl.text = col
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", 13)
			lbl.add_theme_color_override("font_color", Color(0.6, 0.7, 0.6))
			header.add_child(lbl)
		_history_rows.add_child(HSeparator.new())

		for entry in visit_history:
			# Show party name above the row
			var party_name: String = entry.get("party_name", "")
			var party_type: String = entry.get("party_type", "")
			if party_name != "":
				var party_lbl := Label.new()
				party_lbl.text = "  %s (%s)" % [party_name, party_type]
				party_lbl.add_theme_font_size_override("font_size", 12)
				party_lbl.add_theme_color_override("font_color", Color(0.5, 0.7, 0.9))
				_history_rows.add_child(party_lbl)

			var row := HBoxContainer.new()
			_history_rows.add_child(row)

			var stars: int = entry.get("stars", 1)
			var star_str: String = ""
			for i in range(stars):
				star_str += "★"

			var values: Array = [
				str(entry.get("week", 0)),
				star_str,
				str(entry.get("points", 0)),
				"%dg" % entry.get("payout", 0),
				"%dg" % entry.get("loot", 0),
				"%dg" % entry.get("total", 0),
			]
			for i in range(values.size()):
				var lbl := Label.new()
				lbl.text = values[i]
				lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				lbl.add_theme_font_size_override("font_size", 13)
				# Color code the total
				if i == values.size() - 1:
					var total: int = entry.get("total", 0)
					if total >= 400:
						lbl.add_theme_color_override("font_color", Color(0.3, 1.0, 0.3))
					elif total >= 200:
						lbl.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
				row.add_child(lbl)

	# Update loot log
	for child in _loot_rows.get_children():
		child.queue_free()

	if visit_history.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No loot history yet — adventurers arrive every week."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_loot_rows.add_child(empty_lbl)
	else:
		for entry in visit_history:
			var looted: Dictionary = entry.get("looted", {})
			var week_num: int = entry.get("week", 0)
			var loot_gold: int = entry.get("loot", 0)

			# Week header
			var week_hdr := Label.new()
			week_hdr.add_theme_font_size_override("font_size", 15)
			week_hdr.add_theme_color_override("font_color", Color(0.7, 0.85, 0.7))
			if looted.is_empty():
				week_hdr.text = "Week %d  —  Nothing looted" % week_num
			else:
				week_hdr.text = "Week %d  —  %dg looted" % [week_num, loot_gold]
			_loot_rows.add_child(week_hdr)

			if not looted.is_empty():
				for item_name in looted:
					var row := HBoxContainer.new()
					_loot_rows.add_child(row)

					var name_lbl := Label.new()
					name_lbl.text = "    %s" % item_name
					name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
					name_lbl.add_theme_font_size_override("font_size", 13)
					row.add_child(name_lbl)

					var count_lbl := Label.new()
					count_lbl.text = "×%d" % looted[item_name]
					count_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
					count_lbl.custom_minimum_size = Vector2(60, 0)
					count_lbl.add_theme_font_size_override("font_size", 13)
					count_lbl.add_theme_color_override("font_color", Color(1.0, 0.4, 0.4))
					row.add_child(count_lbl)

			_loot_rows.add_child(HSeparator.new())

	visible = true


# Legacy compat — old city builder code may call show_report; redirect to dungeon
func show_report(_rows: Array, _income: int, _upkeep: int, _stats: Dictionary, _tax: float, _history: Array) -> void:
	pass
