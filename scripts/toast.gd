extends Node

# Toast notification singleton.
# Call Toast.notify("message") or Toast.notify("message", icon_texture) from anywhere.
# Call Toast.show_history() to display the last 10 notifications.

const FADE_IN    : float = 0.15
const FADE_OUT   : float = 0.4
const MAX_HISTORY: int   = 10

var _canvas        : CanvasLayer
var _panel         : PanelContainer
var _icon_rect     : TextureRect
var _label         : Label
var _tween         : Tween

var _history       : Array = []   # Array of {message: String, icon: Texture2D}
var _hist_panel    : Control = null
var _hist_rows     : VBoxContainer = null


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	_canvas = CanvasLayer.new()
	_canvas.layer = 128
	add_child(_canvas)

	_panel = PanelContainer.new()
	_panel.anchor_left     = 0.5
	_panel.anchor_right    = 0.5
	_panel.anchor_top      = 0.0
	_panel.anchor_bottom   = 0.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.offset_left     = -200.0
	_panel.offset_right    =  200.0
	_panel.offset_top      = 16.0
	_panel.offset_bottom   = 64.0
	_panel.mouse_filter    = Control.MOUSE_FILTER_IGNORE
	_panel.modulate.a      = 0.0
	_panel.visible         = false
	_canvas.add_child(_panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	_panel.add_child(margin)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	margin.add_child(hbox)

	_icon_rect = TextureRect.new()
	_icon_rect.custom_minimum_size = Vector2(24, 24)
	_icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon_rect.visible = false
	hbox.add_child(_icon_rect)

	_label = Label.new()
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 15)
	hbox.add_child(_label)


func notify(message: String, icon: Texture2D = null, duration: float = 3.0) -> void:
	# Record in history (newest first)
	_history.push_front({"message": message, "icon": icon})
	if _history.size() > MAX_HISTORY:
		_history.pop_back()

	_label.text = message
	if icon:
		_icon_rect.texture = icon
		_icon_rect.visible = true
	else:
		_icon_rect.visible = false

	if _tween:
		_tween.kill()

	_panel.modulate.a = 0.0
	_panel.visible    = true

	_tween = create_tween()
	_tween.tween_property(_panel, "modulate:a", 1.0, FADE_IN)
	_tween.tween_interval(duration)
	_tween.tween_property(_panel, "modulate:a", 0.0, FADE_OUT)
	_tween.tween_callback(func(): _panel.visible = false)


func show_history() -> void:
	if _hist_panel == null:
		_build_history_panel()
	_refresh_history_rows()
	_hist_panel.visible = true


func _build_history_panel() -> void:
	_hist_panel = Control.new()
	_hist_panel.anchor_left   = 0.0
	_hist_panel.anchor_right  = 1.0
	_hist_panel.anchor_top    = 0.0
	_hist_panel.anchor_bottom = 1.0
	_hist_panel.mouse_filter  = Control.MOUSE_FILTER_STOP
	_hist_panel.visible       = false
	_canvas.add_child(_hist_panel)

	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0, 0, 0, 0.6)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_hist_panel.add_child(bg)

	var panel := PanelContainer.new()
	panel.anchor_left   = 0.5
	panel.anchor_right  = 0.5
	panel.anchor_top    = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left   = -220.0
	panel.offset_right  =  220.0
	panel.offset_top    = -220.0
	panel.offset_bottom =  220.0
	_hist_panel.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title row
	var title_row := HBoxContainer.new()
	vbox.add_child(title_row)

	var title_lbl := Label.new()
	title_lbl.text = "Notification History"
	title_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_lbl.add_theme_font_size_override("font_size", 18)
	title_row.add_child(title_lbl)

	var close_btn := TextureButton.new()
	close_btn.texture_normal = load("res://graphics/cross.png")
	close_btn.custom_minimum_size = Vector2(20, 20)
	close_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	close_btn.ignore_texture_size = true
	close_btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	close_btn.pressed.connect(func(): _hist_panel.visible = false)
	title_row.add_child(close_btn)

	vbox.add_child(HSeparator.new())

	# Scrollable rows
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_hist_rows = VBoxContainer.new()
	_hist_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hist_rows.add_theme_constant_override("separation", 6)
	scroll.add_child(_hist_rows)


func _refresh_history_rows() -> void:
	for child in _hist_rows.get_children():
		child.queue_free()

	if _history.is_empty():
		var empty_lbl := Label.new()
		empty_lbl.text = "No notifications yet."
		empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		empty_lbl.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
		_hist_rows.add_child(empty_lbl)
		return

	for entry in _history:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		_hist_rows.add_child(row)

		var icon_rect := TextureRect.new()
		icon_rect.custom_minimum_size = Vector2(20, 20)
		icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if entry["icon"]:
			icon_rect.texture = entry["icon"]
		row.add_child(icon_rect)

		var msg_lbl := Label.new()
		msg_lbl.text = entry["message"]
		msg_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		msg_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(msg_lbl)

		_hist_rows.add_child(HSeparator.new())
