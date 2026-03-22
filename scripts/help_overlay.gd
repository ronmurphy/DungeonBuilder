extends Control
class_name HelpOverlay

const INSTRUCTIONS_TEX = preload("res://sprites/instructions.png")
const CROSS_TEX        = preload("res://graphics/cross.png")


func _ready() -> void:
	anchor_left   = 0.0
	anchor_right  = 1.0
	anchor_top    = 0.0
	anchor_bottom = 1.0
	mouse_filter  = MOUSE_FILTER_STOP
	visible = false
	_build_ui()


func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	bg.mouse_filter = MOUSE_FILTER_STOP
	add_child(bg)

	var panel := PanelContainer.new()
	panel.anchor_left   = 0.5
	panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left   = -230.0
	panel.offset_right  =  230.0
	panel.offset_top    = -300.0
	panel.offset_bottom =  300.0
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	var top_row := HBoxContainer.new()
	vbox.add_child(top_row)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(spacer)

	var close_btn := TextureButton.new()
	close_btn.texture_normal = CROSS_TEX
	close_btn.custom_minimum_size = Vector2(20, 20)
	close_btn.ignore_texture_size = true
	close_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	close_btn.pressed.connect(_on_close)
	top_row.add_child(close_btn)

	var img := TextureRect.new()
	img.texture = INSTRUCTIONS_TEX
	img.custom_minimum_size = Vector2(400, 520)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	vbox.add_child(img)


func show_overlay() -> void:
	visible = true


func _on_close() -> void:
	visible = false


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_on_close()
		get_viewport().set_input_as_handled()
