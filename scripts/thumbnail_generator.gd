extends Node

## Thumbnail Generator Tool
## Run this scene once to auto-generate preview PNGs for any Kenney kit
## that has a Previews/ folder but missing thumbnails.
## It scans res://models/, renders each GLB in a SubViewport, and saves a PNG.

const THUMBNAIL_SIZE  := Vector2i(256, 256)
const MODELS_ROOT     := "res://models"

var _viewport    : SubViewport
var _model_root  : Node3D
var _queue       : Array  = []   # Array of {glb, out} dicts
var _generated   : int    = 0
var _skipped     : int    = 0

# ── Setup ────────────────────────────────────────────────────────────────────

func _ready() -> void:
	_build_viewport()
	_scan_kits()
	if _queue.is_empty():
		print("[ThumbnailGen] Nothing to generate — all previews already exist.")
		get_tree().quit()
		return
	print("[ThumbnailGen] %d thumbnail(s) to generate..." % _queue.size())
	_process_next()


func _build_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.size                    = THUMBNAIL_SIZE
	_viewport.transparent_bg          = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	# Environment
	var env                     := Environment.new()
	env.background_mode          = Environment.BG_COLOR
	env.background_color         = Color(0, 0, 0, 0)
	env.ambient_light_source     = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color      = Color(0.55, 0.60, 0.65)
	env.ambient_light_energy     = 0.9
	var world_env                := WorldEnvironment.new()
	world_env.environment        = env
	_viewport.add_child(world_env)

	# Key light  (front-right-top)
	var key                      := DirectionalLight3D.new()
	key.rotation_degrees          = Vector3(-50, -35, 0)
	key.light_energy              = 1.6
	_viewport.add_child(key)

	# Fill light (back-left)
	var fill                     := DirectionalLight3D.new()
	fill.rotation_degrees         = Vector3(-15, 145, 0)
	fill.light_energy             = 0.5
	_viewport.add_child(fill)

	# Camera — isometric angle matching Kenney's own previews
	var cam          := Camera3D.new()
	cam.position      = Vector3(1.8, 2.2, 1.8)
	cam.look_at(Vector3(0.5, 0.15, 0.5))
	cam.fov           = 32.0
	_viewport.add_child(cam)

	_model_root = Node3D.new()
	_viewport.add_child(_model_root)


# ── Kit scanning ──────────────────────────────────────────────────────────────

func _scan_kits() -> void:
	var root_dir := DirAccess.open(MODELS_ROOT)
	if not root_dir:
		push_error("[ThumbnailGen] Cannot open " + MODELS_ROOT)
		return

	root_dir.list_dir_begin()
	var kit_name := root_dir.get_next()
	while kit_name != "":
		if root_dir.current_is_dir() and not kit_name.begins_with("."):
			_scan_kit(MODELS_ROOT + "/" + kit_name)
		kit_name = root_dir.get_next()
	root_dir.list_dir_end()


func _scan_kit(kit_path: String) -> void:
	# Only process kits that have a Previews folder
	var preview_dir := kit_path + "/Previews"
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(preview_dir)):
		return

	# Find all .glb files anywhere under kit_path/Models/
	var glbs : Array[String] = []
	_find_glbs(kit_path + "/Models", glbs)

	for glb in glbs:
		var base     := glb.get_file().get_basename()
		var out_png  := preview_dir + "/" + base + ".png"
		# Skip if PNG already exists
		if FileAccess.file_exists(ProjectSettings.globalize_path(out_png)):
			_skipped += 1
			continue
		_queue.append({ "glb": glb, "out": out_png })


func _find_glbs(path: String, result: Array[String]) -> void:
	var dir := DirAccess.open(path)
	if not dir:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir() and not f.begins_with(".") and f.to_lower() != "textures":
			_find_glbs(path + "/" + f, result)
		elif f.ends_with(".glb"):
			result.append(path + "/" + f)
		f = dir.get_next()
	dir.list_dir_end()


# ── Render loop ───────────────────────────────────────────────────────────────

func _process_next() -> void:
	if _queue.is_empty():
		print("[ThumbnailGen] Done!  Generated: %d   Already existed: %d" % [_generated, _skipped])
		await get_tree().create_timer(0.5).timeout
		get_tree().quit()
		return

	var item : Dictionary = _queue.pop_front()
	_render_item(item)


func _render_item(item: Dictionary) -> void:
	# Clear previous model
	for child in _model_root.get_children():
		_model_root.remove_child(child)
		child.queue_free()

	await get_tree().process_frame

	# Load + instantiate the GLB
	var packed := ResourceLoader.load(item.glb) as PackedScene
	if not packed:
		push_warning("[ThumbnailGen] Could not load: " + item.glb)
		_process_next()
		return

	var inst := packed.instantiate()
	_model_root.add_child(inst)
	print("[ThumbnailGen] Rendering  →  " + item.glb.get_file())

	# Wait 3 frames so the renderer has time to draw
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame

	# Capture and save
	var img := _viewport.get_texture().get_image()
	if img and not img.is_empty():
		var abs_out := ProjectSettings.globalize_path(item.out)
		DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
		img.save_png(abs_out)
		_generated += 1
		print("[ThumbnailGen] Saved     →  " + item.out)
	else:
		push_warning("[ThumbnailGen] Empty image for: " + item.glb.get_file())

	_process_next()
