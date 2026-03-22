extends Node3D

var structures: Array[Structure] = []

var map:DataMap

var index:int = 0 # Index of structure being built

@export var selector: Node3D           # The 'cursor'
@export var selector_container: Node3D # Node that holds a preview of the structure
@export var view_camera: Camera3D      # Used for raycasting mouse
@export var view_node: Node3D          # The View node (camera pivot for orbit)
@export var gridmap: GridMap            # Layer 0 — player-placed floor tiles
@export var decoration_gridmap: GridMap # Layer 1 — walls (sits on top of floors)
@export var items_gridmap: GridMap      # Layer 2 — items (sits on top of everything)
@export var terrain_gridmap: GridMap    # Auto-generated terrain floor
@export var underlay_gridmap: GridMap   # Permanent floor underlay — never cleared
@export var cash_display: Label
@export var date_display: Label
@export var week_clock: TextureRect
@export var report_panel: Control
@export var building_picker: BuildingPicker
@export var help_panel: Control

# Week progress clock textures (timer_0 → timer_100)
const _CLOCK_TEXTURES: Array = [
	preload("res://graphics/timer_0.png"),
	preload("res://graphics/timer_CCW_25.png"),
	preload("res://graphics/timer_CCW_50.png"),
	preload("res://graphics/timer_CCW_75.png"),
	preload("res://graphics/timer_100.png"),
]

var plane: Plane # Used for raycasting mouse
var last_gridmap_position: Vector3 = Vector3.ZERO
var _placing: bool = false  # true when a structure is selected and ready to place

# Per-structure mesh library IDs and layer assignments (built in _ready)
var _struct_mesh_id: Array[int] = []
var _struct_layer:   Array[int] = []

# Reverse-lookup: mesh library id -> structure index (for refund on demolish)
var _base_id_to_struct: Dictionary = {}
var _deco_id_to_struct: Dictionary = {}
var _item_id_to_struct: Dictionary = {}

# Economy / time
var _cell_placed_week: Dictionary = {}  # kept for save compat but unused
var _multi_cell_anchor: Dictionary = {} # Vector3i -> Vector3i (child cell -> anchor cell for multi-tile structures)
var _day_timer: float = 0.0
const DAY_DURATION: float = 30.0         # real seconds per in-game day
const VISIT_INTERVAL_DAYS: int = 7       # adventurers visit every week

# Adventurer visit history (newest first)
var _visit_history: Array = []
const MAX_VISIT_HISTORY: int = 10

# Intermission state
var _visit_pending: bool = false        # true from announcement dialog until visit finishes
var _intermission_active: bool = false
var _intermission_timer: float = 0.0
const INTERMISSION_DURATION: float = 10.0
var _saved_cam_pos: Vector3
var _saved_cam_rot: Vector3
var _saved_cam_zoom: float
var _orbit_center: Vector3
var _pending_visit_stats: Dictionary = {}  # stored until intermission ends

# Loot chances per display_name keyword → chance (0.0–1.0)
const LOOT_CHANCES: Dictionary = {
	"Coin": 1.0,
	"Chest": 0.80,
	"Trophy": 0.70,
	"Sword": 0.50,    "Spear": 0.50,
	"Shield": 0.50,
	"Weapon Rack": 0.40,
	"Barrel": 0.25,
	"Banner": 0.15,
	"Statue": 0.10,
	"Column": 0.05,   "Damaged Column": 0.05,
	"Wood Structure": 0.05, "Wood Support": 0.05,
}

# Rating point values per item
const RATING_POINTS: Dictionary = {
	"Trap": 10, "Human": 8, "Orc": 8, "Soldier": 8,
	"Chest": 6, "Sword": 4, "Spear": 4, "Shield": 4,
	"Coin": 3,  "Trophy": 4, "Weapon Rack": 4,
	"Barrel": 3, "Banner": 3, "Column": 3, "Damaged Column": 3,
	"Statue": 3, "Wood Structure": 2, "Wood Support": 2,
}

# Star thresholds and payouts
const STAR_THRESHOLDS: Array[int] = [0, 50, 100, 200, 350]
const STAR_PAYOUTS: Array[int]    = [50, 125, 250, 400, 600]

# ── Adventurer Party Types ────────────────────────────────────────────────────
enum PartyType { WARRIORS, ROGUES, SCHOLARS }

# Score multipliers per party type → category
const PARTY_MULTIPLIERS: Dictionary = {
	PartyType.WARRIORS: { "danger": 2.0, "treasure": 0.8, "atmosphere": 0.5 },
	PartyType.ROGUES:   { "danger": 0.8, "treasure": 2.0, "atmosphere": 0.8 },
	PartyType.SCHOLARS: { "danger": 0.5, "treasure": 0.8, "atmosphere": 2.0 },
}

# Loot chance multipliers per party type
const PARTY_LOOT_MULT: Dictionary = {
	PartyType.WARRIORS: 0.7,   # warriors care about glory, not loot
	PartyType.ROGUES:   1.5,   # rogues grab everything they can
	PartyType.SCHOLARS: 0.4,   # scholars observe, rarely take things
}

# Party names that hint at their type
const WARRIOR_NAMES: Array[String] = [
	"The Iron Wolves", "The Steel Legion", "Hammer's Guard",
	"The Blade Crusaders", "Battleborn Company", "The War Hawks",
	"The Armored Fist", "Grimjaw's Raiders", "The Bronze Knights",
	"Ironside's Battalion", "The Shield Breakers", "The Axe Wardens",
]
const ROGUE_NAMES: Array[String] = [
	"Steve's Scoundrels", "The Shadow Foxes", "Silent Daggers",
	"The Quick Fingers", "Sly Pete's Gang", "The Dark Rats",
	"Cunning Company", "The Night Crawlers", "Whisper's Thieves",
	"The Velvet Blades", "Lockpick Larry's Crew", "The Coin Snatchers",
]
const SCHOLAR_NAMES: Array[String] = [
	"The Wise Council", "Ancient Seekers", "The Mystic Circle",
	"Sage Aldric's Order", "The Learned Few", "The Crystal Scribes",
	"The Arcane Society", "Elder's Expedition", "The Lore Keepers",
	"The Tome Bearers", "Merlin's Apprentices", "The Stargazers",
]

var _current_party_type: int = PartyType.WARRIORS
var _current_party_name: String = ""
var _next_party_type: int = -1        # -1 = not yet determined
var _next_party_name: String = ""

# ── Milestones / Achievements ─────────────────────────────────────────────────
var _milestones_earned: Dictionary = {}   # key -> true
var _total_visit_gold: int = 0            # lifetime gold earned from visits

const MILESTONE_DEFS: Dictionary = {
	"first_visit":   "First adventurer visit!",
	"first_3star":   "First ★★★ rating — Good dungeon!",
	"first_4star":   "First ★★★★ rating — Great dungeon!",
	"first_5star":   "First ★★★★★ — LEGENDARY dungeon!",
	"visits_10":     "10 visits survived!",
	"visits_25":     "25 visits — dungeon veteran!",
	"gold_1000":     "1,000g earned from adventurers!",
	"gold_5000":     "5,000g earned — the gold flows!",
	"first_room":    "First enclosed room detected!",
	"rooms_5":       "5 rooms — proper dungeon layout!",
	"all_types":     "Every item type placed!",
}

const _AWARD_ICON = preload("res://graphics/award.png")

# ── Room Detection ────────────────────────────────────────────────────────────
const ROOM_MIN_TILES: int = 4           # minimum floor tiles to count as a room
const ROOM_ENCLOSE_PCT: float = 0.75    # 75% of border must be walls/gates
const ROOM_POINTS: int = 15             # rating points per room
const TREASURE_ROOM_BONUS: int = 10     # extra points if room has treasure

# Terrain
var _terrain_noise: FastNoiseLite = null
var _terrain_mesh_ids: Dictionary = {}     # glb basename  -> mesh library id
var _terrain_rewards: Dictionary  = {}     # mesh library id -> cash reward

# Animated scene instances — spawned as real Node3D instead of GridMap cells
var _animated_instances: Dictionary = {}   # Vector3i -> Node3D (position -> scene instance)
var _animated_struct_idx: Dictionary = {}  # Vector3i -> int (position -> structure index)
var _animated_orientation: Dictionary = {} # Vector3i -> int (position -> rotation index)

# Which model basenames are animated (spawned as scenes, not GridMap cells)
const ANIMATED_MODELS: Array[String] = [
	"character-human", "character-orc", "character-soldier",
	"chest", "gate", "trap",
]

# Character animation names (indices 0-10 = base set, played randomly on placement)
const CHARACTER_ANIMS: Array[String] = [
	"static", "idle", "walk", "sprint", "jump", "fall",
	"crouch", "sit", "drive", "die", "pick-up",
]

const PICKER_WIDTH:int = 320 # Must match building_picker.gd offset_left
const _SAVE_ICON = preload("res://graphics/icon_save.png")
const _WARN_ICON = preload("res://graphics/information.png")

func _ready():

	_load_structures()

	plane = Plane(Vector3.UP, Vector3.ZERO)

	# Build separate MeshLibraries for base, decoration, and terrain layers
	_build_mesh_libraries()
	_build_terrain_mesh_library()

	if Global.pending_load:
		_do_load(Global.save_path())
	else:
		map = DataMap.new()
		map.cash = Global.starting_cash
		generate_terrain()
		# Generate the first party for a new game
		_roll_next_party()


	# Permanent floor underlay — fills gaps so the background never shows
	# through. Sits at y = -0.05 (just below terrain tiles) and is never
	# modified by build / demolish / load.
	_spawn_ground_underlay()

	# Background music looping — disabled until ambience audio is added.
	#var asp := get_parent().get_node_or_null("AudioStreamPlayer") as AudioStreamPlayer
	#if asp and not asp.finished.is_connected(asp.play):
	#	asp.finished.connect(asp.play)

	if building_picker:
		building_picker.populate(structures)
		building_picker.structure_selected.connect(select_structure)
		building_picker.report_requested.connect(_open_report)
		building_picker.help_requested.connect(_open_help)
		building_picker.save_requested.connect(_do_save)
		building_picker.skip_requested.connect(_skip_to_visit)

	# Start in browse mode — selector hidden until a building is picked
	selector.visible = false

	update_structure()
	update_cash()
	_update_date_display()


func _process(delta):

	# During intermission, only process the orbit — block all input & time
	if _intermission_active:
		_process_intermission(delta)
		return

	# Time / economy tick
	_advance_time(delta)

	# Keyboard / non-mouse controls always fire
	action_cycle_structure()
	action_rotate()
	action_save()
	action_load()
	action_load_resources()

	# Skip all mouse-position work when cursor is over the picker sidebar
	if not _is_over_picker():
		var world_position = plane.intersects_ray(
			view_camera.project_ray_origin(get_viewport().get_mouse_position()),
			view_camera.project_ray_normal(get_viewport().get_mouse_position()))
		if world_position:
			last_gridmap_position = Vector3(round(world_position.x), 0, round(world_position.z))

	selector.position = lerp(selector.position, last_gridmap_position, min(delta * 40, 1.0))

	action_build(last_gridmap_position)
	action_demolish(last_gridmap_position)

# Build three MeshLibraries — one per layer — and record per-structure IDs
func _build_mesh_libraries() -> void:
	var base_lib := MeshLibrary.new()
	var deco_lib := MeshLibrary.new()
	var item_lib := MeshLibrary.new()
	_struct_mesh_id.clear()
	_struct_layer.clear()
	_base_id_to_struct.clear()
	_deco_id_to_struct.clear()
	_item_id_to_struct.clear()
	for i in structures.size():
		var s := structures[i]
		var mesh = get_mesh(s.model)
		_struct_layer.append(s.layer)
		if mesh == null:
			_struct_mesh_id.append(-1)
			continue
		var lib: MeshLibrary
		if s.layer == 2:
			lib = item_lib
		elif s.layer == 1:
			lib = deco_lib
		else:
			lib = base_lib
		var id := lib.get_last_unused_item_id()
		lib.create_item(id)
		lib.set_item_mesh(id, mesh)
		lib.set_item_mesh_transform(id, Transform3D())
		_struct_mesh_id.append(id)
		if s.layer == 2:
			_item_id_to_struct[id] = i
		elif s.layer == 1:
			_deco_id_to_struct[id] = i
		else:
			_base_id_to_struct[id] = i
	gridmap.mesh_library = base_lib
	if decoration_gridmap:
		decoration_gridmap.mesh_library = deco_lib
	if items_gridmap:
		items_gridmap.mesh_library = item_lib

# Build terrain MeshLibrary from Nature-category structures
const TERRAIN_REWARDS: Dictionary = {
	"floor":            0,
	"floor-detail":     0,
}

func _build_terrain_mesh_library() -> void:
	if not terrain_gridmap:
		return
	var lib := MeshLibrary.new()
	_terrain_mesh_ids.clear()
	_terrain_rewards.clear()
	var id := 0
	for s in structures:
		if s.category != "Nature":
			continue
		var mesh = get_mesh(s.model)
		if mesh == null:
			continue
		var key: String = s.model.resource_path.get_file().get_basename()
		lib.create_item(id)
		lib.set_item_mesh(id, mesh)
		lib.set_item_mesh_transform(id, Transform3D())
		_terrain_mesh_ids[key] = id
		_terrain_rewards[id] = TERRAIN_REWARDS.get(key, 0)
		id += 1
	terrain_gridmap.mesh_library = lib
	print("[Builder] Terrain mesh IDs: ", _terrain_mesh_ids)
	print("[Builder] Terrain rewards: ", _terrain_rewards)


func generate_terrain() -> void:
	if not terrain_gridmap or _terrain_mesh_ids.is_empty():
		return
	_terrain_noise = FastNoiseLite.new()
	_terrain_noise.seed = Global.map_seed
	_terrain_noise.frequency = 0.07
	terrain_gridmap.clear()
	var half := Global.map_size / 2
	for x in range(-half, half):
		for z in range(-half, half):
			var tile := _get_terrain_tile(x, z)
			if tile != -1:
				terrain_gridmap.set_cell_item(Vector3i(x, 0, z), tile)
	print("[Builder] Terrain generated %dx%d seed=%d" % [Global.map_size, Global.map_size, Global.map_seed])


func _spawn_ground_underlay() -> void:
	# Fill the underlay GridMap with plain grass tiles across the entire map.
	# This layer is NEVER cleared by build / demolish / load, so it always
	# shows through any gaps in road-corner geometry or missing terrain tiles.
	if not underlay_gridmap:
		return
	# Share the same mesh library as the terrain — we only need the plain floor tile
	underlay_gridmap.mesh_library = terrain_gridmap.mesh_library
	underlay_gridmap.clear()
	var floor_id: int = _terrain_mesh_ids.get("floor", -1)
	if floor_id == -1:
		push_warning("[Builder] No floor tile found — underlay skipped")
		return
	var half := Global.map_size / 2
	for x in range(-half, half):
		for z in range(-half, half):
			underlay_gridmap.set_cell_item(Vector3i(x, 0, z), floor_id)
	print("[Builder] Ground underlay filled %dx%d with dungeon floor" % [Global.map_size, Global.map_size])


func _get_terrain_tile(_x: int, _z: int) -> int:
	if _terrain_mesh_ids.is_empty():
		return -1
	# Randomly mix floor and floor-detail for visual variety
	var floor_id: int = _terrain_mesh_ids.get("floor", -1)
	var detail_id: int = _terrain_mesh_ids.get("floor-detail", -1)
	if detail_id != -1 and randf() < 0.2:
		return detail_id
	return floor_id


# Load structures from the pre-generated static list (works in exported builds)
const _STRUCTURE_LIST = preload("res://scripts/structure_list.gd")

func _load_structures() -> void:
	structures.clear()
	for res in _STRUCTURE_LIST.ALL:
		if res is Structure:
			structures.append(res)
	structures.sort_custom(func(a, b):
		if a.category != b.category:
			return a.category < b.category
		return a.display_name < b.display_name)
	print("[Builder] Loaded %d structures" % structures.size())

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if help_panel and help_panel.visible:
			return  # let help_overlay.gd handle it
		if report_panel and report_panel.visible:
			return  # let tax_report.gd handle it
		if _placing:
			_set_placing(false)
			get_viewport().set_input_as_handled()

func _set_placing(value: bool) -> void:
	_placing = value
	selector.visible = value

# ── Animated instance helpers ─────────────────────────────────────────────

func _is_animated_structure(s: Structure) -> bool:
	var basename: String = s.model.resource_path.get_file().get_basename()
	return basename in ANIMATED_MODELS

func _is_character_model(s: Structure) -> bool:
	var basename: String = s.model.resource_path.get_file().get_basename()
	return basename.begins_with("character-")

func _spawn_animated(s: Structure, struct_idx: int, pos: Vector3i, orientation: int) -> void:
	var instance: Node3D = s.model.instantiate()
	instance.position = Vector3(pos.x, 0, pos.z)
	# Apply rotation from orientation index (0=0°, 1=90°, etc.)
	# GridMap orientation 10=90°, 22=180°, 16=270° but we'll use basis angle
	match orientation:
		10: instance.rotate_y(deg_to_rad(90))
		22: instance.rotate_y(deg_to_rad(180))
		16: instance.rotate_y(deg_to_rad(270))
	add_child(instance)
	_animated_instances[pos] = instance
	_animated_struct_idx[pos] = struct_idx
	_animated_orientation[pos] = orientation

	# Find AnimationPlayer and start appropriate animation
	var anim_player: AnimationPlayer = _find_animation_player(instance)
	if anim_player:
		if _is_character_model(s):
			_play_random_character_anim(anim_player, true)
		else:
			# Chest / gate / trap — show closed state (paused)
			var anim_list: PackedStringArray = anim_player.get_animation_list()
			if anim_list.has("close"):
				anim_player.play("close")
				anim_player.seek(0.0, true)
				anim_player.pause()
			elif anim_list.has("static"):
				anim_player.play("static")
				anim_player.pause()

func _remove_animated(pos: Vector3i) -> void:
	if pos in _animated_instances:
		var instance: Node3D = _animated_instances[pos]
		instance.queue_free()
		_animated_instances.erase(pos)
		_animated_struct_idx.erase(pos)
		_animated_orientation.erase(pos)

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node as AnimationPlayer
	for child in node.get_children():
		var found: AnimationPlayer = _find_animation_player(child)
		if found:
			return found
	return null


func _play_random_character_anim(anim_player: AnimationPlayer, randomize_start: bool = false) -> void:
	var anim_list: PackedStringArray = anim_player.get_animation_list()
	var valid_anims: Array[String] = []
	for anim_name in CHARACTER_ANIMS:
		if anim_list.has(anim_name):
			valid_anims.append(anim_name)
	if not valid_anims.is_empty():
		var pick: String = valid_anims[randi() % valid_anims.size()]
		anim_player.play(pick)
		if randomize_start:
			anim_player.seek(randf() * anim_player.current_animation_length)


func _set_anim_looping(anim_player: AnimationPlayer, anim_name: String) -> void:
	var anim: Animation = anim_player.get_animation(anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_LINEAR


func _set_anim_not_looping(anim_player: AnimationPlayer, anim_name: String) -> void:
	var anim: Animation = anim_player.get_animation(anim_name)
	if anim:
		anim.loop_mode = Animation.LOOP_NONE


# Returns true when the mouse is inside the right-side picker panel, or a modal is open
func _is_over_picker() -> bool:
	if help_panel and help_panel.visible:
		return true
	if report_panel and report_panel.visible:
		return true
	return get_viewport().get_mouse_position().x >= get_viewport().get_visible_rect().size.x - PICKER_WIDTH

# Retrieve the mesh from a PackedScene, used for dynamically creating a MeshLibrary

func get_mesh(packed_scene):
	var scene_state:SceneState = packed_scene.get_state()
	for i in range(scene_state.get_node_count()):
		if(scene_state.get_node_type(i) == "MeshInstance3D"):
			for j in scene_state.get_node_property_count(i):
				var prop_name = scene_state.get_node_property_name(i, j)
				if prop_name == "mesh":
					var prop_value = scene_state.get_node_property_value(i, j)

					return prop_value.duplicate()

# Cycle structure with Q / E keys

func action_cycle_structure() -> void:
	var changed := false
	if Input.is_action_just_pressed("structure_next"):
		index = (index + 1) % structures.size()
		changed = true
	elif Input.is_action_just_pressed("structure_previous"):
		index = (index - 1 + structures.size()) % structures.size()
		changed = true
	if changed:
		print("[Builder] cycle_structure -> index: ", index)
		if building_picker:
			building_picker.set_selected_index(index)
		Audio.play("sounds/toggle.ogg", -30)
		update_structure()

# Build (place) a structure

func _get_footprint_cells(anchor: Vector3i, s: Structure) -> Array:
	# Returns all Vector3i cells occupied by a structure placed at anchor.
	# For a 1×1 structure, returns just [anchor].
	# For larger structures, centers the footprint around the anchor
	# (the mesh origin is at the center of the model, not the corner).
	var cells: Array = []
	var off_x: int = (s.footprint.x - 1) / 2
	var off_z: int = (s.footprint.y - 1) / 2
	for dx in range(s.footprint.x):
		for dz in range(s.footprint.y):
			cells.append(Vector3i(anchor.x - off_x + dx, anchor.y, anchor.z - off_z + dz))
	return cells


func action_build(gridmap_position):
	if not _placing:
		return
	if _is_over_picker():
		return
	if Input.is_action_just_pressed("build"):
		var mid = _struct_mesh_id[index] if index < _struct_mesh_id.size() else -1
		if mid == -1:
			return
		var layer: int = _struct_layer[index]
		var s: Structure = structures[index]
		var anchor := Vector3i(gridmap_position)
		var fp_cells: Array = _get_footprint_cells(anchor, s)

		# Base floor tiles (layer 0) check footprint is clear before placing
		if layer == 0:
			for cell in fp_cells:
				var vcell := Vector3i(cell)
				if gridmap.get_cell_item(vcell) != -1 or _multi_cell_anchor.has(vcell):
					Toast.notify("Not enough room!", _WARN_ICON)
					return

		# Animated models (characters, chest, gate, trap) → spawn as scene instance
		if _is_animated_structure(s):
			# Don't stack animated instances on same cell
			if anchor in _animated_instances:
				Toast.notify("Something is already here!", _WARN_ICON)
				return
			var rotation_idx: int = gridmap.get_orthogonal_index_from_basis(selector.basis)
			_spawn_animated(s, index, anchor, rotation_idx)
			map.cash -= s.price
			update_cash()
			Audio.play("sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg", -20)
			return

		# Non-animated models → place in appropriate GridMap
		var target_map: GridMap
		if layer == 2:
			target_map = items_gridmap
		elif layer == 1:
			target_map = decoration_gridmap
		else:
			target_map = gridmap
		if not target_map:
			return
		var rotation_idx = target_map.get_orthogonal_index_from_basis(selector.basis)

		var previous_tile = target_map.get_cell_item(gridmap_position)
		target_map.set_cell_item(gridmap_position, mid, rotation_idx)

		# Register multi-cell footprint so child cells block future placement
		if layer == 0:
			if s.footprint.x > 1 or s.footprint.y > 1:
				for cell in fp_cells:
					_multi_cell_anchor[Vector3i(cell)] = anchor

		# Clear terrain tiles under base floor tiles
		if layer == 0 and terrain_gridmap:
			for cell in fp_cells:
				var vcell := Vector3i(cell)
				var terrain_tile := terrain_gridmap.get_cell_item(vcell)
				if terrain_tile != -1:
					terrain_gridmap.set_cell_item(vcell, -1)

		if previous_tile != mid:
			map.cash -= s.price
			update_cash()
			Audio.play("sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg", -20)

# Demolish (remove) a structure — animated first, then items, then walls, then floors

func action_demolish(gridmap_position):
	if Input.is_action_just_pressed("demolish"):
		var removed := false
		var pos := Vector3i(gridmap_position)
		# Animated instances (topmost, removed first)
		if pos in _animated_instances:
			var s_idx: int = _animated_struct_idx.get(pos, -1)
			if s_idx != -1:
				var refund := ceili(structures[s_idx].price / 2.0)
				map.cash += refund
				update_cash()
			_remove_animated(pos)
			removed = true
		# Layer 2 — static items
		elif items_gridmap and items_gridmap.get_cell_item(pos) != -1:
			var mid := items_gridmap.get_cell_item(pos)
			items_gridmap.set_cell_item(pos, -1)
			if mid in _item_id_to_struct:
				var refund := ceili(structures[_item_id_to_struct[mid]].price / 2.0)
				map.cash += refund
				update_cash()
			removed = true
		# Layer 1 — walls / decoration
		elif decoration_gridmap and decoration_gridmap.get_cell_item(pos) != -1:
			var mid := decoration_gridmap.get_cell_item(pos)
			decoration_gridmap.set_cell_item(pos, -1)
			if mid in _deco_id_to_struct:
				var refund := ceili(structures[_deco_id_to_struct[mid]].price / 2.0)
				map.cash += refund
				update_cash()
			removed = true
		# Layer 0 — base floor tiles
		elif gridmap.get_cell_item(pos) != -1 or _multi_cell_anchor.has(pos):
			var anchor: Vector3i = _multi_cell_anchor.get(pos, pos) as Vector3i
			var mid := gridmap.get_cell_item(anchor)
			if mid == -1:
				return
			var s_idx: int = _base_id_to_struct.get(mid, -1)
			var fp := Vector2i(1, 1)
			if s_idx != -1:
				fp = structures[s_idx].footprint
				var refund := ceili(structures[s_idx].price / 2.0)
				map.cash += refund
				update_cash()
			gridmap.set_cell_item(anchor, -1)
			var off_x: int = (fp.x - 1) / 2
			var off_z: int = (fp.y - 1) / 2
			for dx in range(fp.x):
				for dz in range(fp.y):
					var cell := Vector3i(anchor.x - off_x + dx, anchor.y, anchor.z - off_z + dz)
					_multi_cell_anchor.erase(cell)
					if terrain_gridmap:
						var tile := _get_terrain_tile(cell.x, cell.z)
						if tile != -1:
							terrain_gridmap.set_cell_item(cell, tile)
			removed = true
		if removed:
			Audio.play("sounds/removal-a.ogg, sounds/removal-b.ogg, sounds/removal-c.ogg, sounds/removal-d.ogg", -20)

# Rotates the 'cursor' 90 degrees

func action_rotate():
	if _is_over_picker():
		return
	if Input.is_action_just_pressed("rotate"):
		selector.rotate_y(deg_to_rad(90))

		Audio.play("sounds/rotate.ogg", -30)

# Select a structure by index (called from BuildingPicker signal)

func select_structure(new_index: int) -> void:
	index = new_index
	_set_placing(true)
	Audio.play("sounds/toggle.ogg", -30)
	update_structure()

# Update the structure visual in the 'cursor'

func update_structure():
	if structures.is_empty():
		return
	# Clear previous structure preview in selector
	for n in selector_container.get_children():
		selector_container.remove_child(n)

	# Create new structure preview in selector
	var _model = structures[index].model.instantiate()
	selector_container.add_child(_model)
	_model.position.y += 0.25

func update_cash():
	cash_display.text = str(map.cash) + "g"

	var threshold_red:    int = int(Global.starting_cash * 0.10)
	var threshold_yellow: int = int(Global.starting_cash * 0.20)
	if map.cash <= threshold_red:
		cash_display.add_theme_color_override("font_color", Color(1.0, 0.25, 0.25))
	elif map.cash <= threshold_yellow:
		cash_display.add_theme_color_override("font_color", Color(1.0, 0.85, 0.15))
	else:
		cash_display.remove_theme_color_override("font_color")

# ── Time & Economy ────────────────────────────────────────────────────────────

func _advance_time(delta: float) -> void:
	_day_timer += delta
	Global.day_progress = _day_timer / DAY_DURATION   # 0.0 – 1.0 within the current day
	if _day_timer >= DAY_DURATION:
		_day_timer -= DAY_DURATION
		Global.current_day += 1
		Global.current_week = Global.current_day / 7
		_update_date_display()
		# Adventurers visit every week
		if Global.current_day % VISIT_INTERVAL_DAYS == 0 and Global.current_day > 0:
			_do_adventurer_visit()


func _skip_to_visit() -> void:
	if _visit_pending or _intermission_active:
		return
	# Jump time forward to the next visit day
	var remainder: int = Global.current_day % VISIT_INTERVAL_DAYS
	var days_left: int
	if remainder == 0 and Global.current_day > 0:
		days_left = 0  # already on a visit day, trigger now
	else:
		days_left = VISIT_INTERVAL_DAYS - remainder
	Global.current_day += days_left
	Global.current_week = Global.current_day / 7
	_day_timer = 0.0
	Global.day_progress = 0.0
	_update_date_display()
	_do_adventurer_visit()

func _update_date_display() -> void:
	var d      := Global.current_day
	var year   := d / 336 + 1
	var month  := (d % 336) / 28 + 1
	var week   := (d % 28)  / 7  + 1
	var day    := d % 7 + 1
	if date_display:
		date_display.text = "Year %d  ·  Month %d  ·  Week %d  ·  Day %d" % [year, month, week, day]
	# Update week-progress clock (5 frames over 7 days)
	if week_clock:
		var frame := int(float(d % 7) / 7.0 * 5.0)
		week_clock.texture = _CLOCK_TEXTURES[clampi(frame, 0, 4)]

# ── Dungeon rating & adventurer visit ─────────────────────────────────────────

# Get the loot chance for a structure by matching its display name
func _get_loot_chance(display_name: String) -> float:
	for keyword in LOOT_CHANCES:
		if display_name.contains(keyword):
			return LOOT_CHANCES[keyword]
	return 0.0

# Get the rating points for a structure by matching its display name
func _get_rating_points(display_name: String) -> int:
	for keyword in RATING_POINTS:
		if display_name.contains(keyword):
			return RATING_POINTS[keyword]
	return 0

# ── Party generation ──────────────────────────────────────────────────────────

func _generate_party() -> void:
	_current_party_type = _next_party_type if _next_party_type >= 0 else randi() % 3
	_current_party_name = _next_party_name if _next_party_name != "" else _random_party_name(_current_party_type)
	_roll_next_party()


func _roll_next_party() -> void:
	_next_party_type = randi() % 3
	_next_party_name = _random_party_name(_next_party_type)


func _random_party_name(party_type: int) -> String:
	match party_type:
		PartyType.WARRIORS:
			return WARRIOR_NAMES[randi() % WARRIOR_NAMES.size()]
		PartyType.ROGUES:
			return ROGUE_NAMES[randi() % ROGUE_NAMES.size()]
		PartyType.SCHOLARS:
			return SCHOLAR_NAMES[randi() % SCHOLAR_NAMES.size()]
	return "Unknown Party"


func _party_type_label(party_type: int) -> String:
	match party_type:
		PartyType.WARRIORS: return "Warriors"
		PartyType.ROGUES:   return "Rogues"
		PartyType.SCHOLARS: return "Scholars"
	return "Adventurers"

# ── Room detection ────────────────────────────────────────────────────────────

func _cardinal_neighbors(cell: Vector3i) -> Array:
	return [
		Vector3i(cell.x + 1, cell.y, cell.z),
		Vector3i(cell.x - 1, cell.y, cell.z),
		Vector3i(cell.x, cell.y, cell.z + 1),
		Vector3i(cell.x, cell.y, cell.z - 1),
	]


func _detect_rooms() -> Array:
	# Returns array of room dicts: { size, enclosed_pct, has_treasure }
	var floor_cells: Dictionary = {}   # Vector3i -> true
	var wall_cells: Dictionary = {}    # Vector3i -> true
	var gate_cells: Dictionary = {}    # Vector3i -> true

	# Gather player-placed floor cells (layer 0)
	for cell in gridmap.get_used_cells():
		floor_cells[cell] = true

	# Gather wall cells (layer 1)
	if decoration_gridmap:
		for cell in decoration_gridmap.get_used_cells():
			wall_cells[cell] = true

	# Gather gate positions from animated instances
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx != -1:
			var s: Structure = structures[s_idx]
			if s.display_name.contains("Gate"):
				gate_cells[pos] = true

	# "Walkable" = floor cells without walls on them
	var walkable: Dictionary = {}
	for cell in floor_cells:
		if cell not in wall_cells:
			walkable[cell] = true

	# Flood fill to find connected regions of walkable tiles
	var visited: Dictionary = {}
	var rooms: Array = []

	for cell in walkable:
		if cell in visited:
			continue
		# BFS flood fill
		var region: Array = []
		var queue: Array = [cell]
		visited[cell] = true
		while not queue.is_empty():
			var current: Vector3i = queue.pop_front()
			region.append(current)
			for neighbor in _cardinal_neighbors(current):
				if neighbor in walkable and neighbor not in visited:
					visited[neighbor] = true
					queue.append(neighbor)

		# Too small to be a room
		if region.size() < ROOM_MIN_TILES:
			continue

		# Check enclosure: count border edges that have walls or gates
		var region_set: Dictionary = {}
		for rcell in region:
			region_set[rcell] = true

		var border_edges: int = 0
		var enclosed_edges: int = 0
		for rcell in region:
			for neighbor in _cardinal_neighbors(rcell):
				if neighbor not in region_set:
					border_edges += 1
					if neighbor in wall_cells or neighbor in gate_cells:
						enclosed_edges += 1

		if border_edges == 0:
			continue

		var enclosed_pct: float = float(enclosed_edges) / float(border_edges)

		if enclosed_pct >= ROOM_ENCLOSE_PCT:
			# Check for treasure inside the room
			var has_treasure: bool = false
			for rcell in region:
				# Static items
				if items_gridmap and items_gridmap.get_cell_item(rcell) != -1:
					var mid: int = items_gridmap.get_cell_item(rcell)
					if mid in _item_id_to_struct:
						var s: Structure = structures[_item_id_to_struct[mid]]
						if s.display_name.contains("Chest") or s.display_name.contains("Coin") or s.display_name.contains("Trophy"):
							has_treasure = true
							break
				# Animated items (chests)
				if rcell in _animated_instances:
					var s_idx: int = _animated_struct_idx.get(rcell, -1)
					if s_idx != -1:
						var s: Structure = structures[s_idx]
						if s.display_name.contains("Chest"):
							has_treasure = true
							break

			rooms.append({
				"size": region.size(),
				"enclosed_pct": enclosed_pct,
				"has_treasure": has_treasure,
			})

	return rooms

# ── Milestones ────────────────────────────────────────────────────────────────

func _check_milestone(key: String) -> void:
	if key in _milestones_earned:
		return
	if key not in MILESTONE_DEFS:
		return
	_milestones_earned[key] = true
	# Delay milestone toast so it doesn't overlap visit toasts
	get_tree().create_timer(5.0).timeout.connect(
		func(): Toast.notify("🏆 " + MILESTONE_DEFS[key], _AWARD_ICON))


func _check_visit_milestones(stars: int, total_gold: int, rooms: Array) -> void:
	var visit_count: int = _visit_history.size()

	_check_milestone("first_visit")

	if stars >= 3:
		_check_milestone("first_3star")
	if stars >= 4:
		_check_milestone("first_4star")
	if stars >= 5:
		_check_milestone("first_5star")

	if visit_count >= 10:
		_check_milestone("visits_10")
	if visit_count >= 25:
		_check_milestone("visits_25")

	if _total_visit_gold >= 1000:
		_check_milestone("gold_1000")
	if _total_visit_gold >= 5000:
		_check_milestone("gold_5000")

	if not rooms.is_empty():
		_check_milestone("first_room")
	if rooms.size() >= 5:
		_check_milestone("rooms_5")

# ── Stats computation ─────────────────────────────────────────────────────────

# Compute dungeon stats: total tiles, unique types, rating points breakdown
func _compute_dungeon_stats() -> Dictionary:
	var total_tiles: int = 0
	var unique_types: Dictionary = {}   # display_name -> true
	var danger_points: int = 0
	var treasure_points: int = 0
	var atmosphere_points: int = 0

	# Count floor tiles (layer 0 base gridmap)
	var floor_count: int = gridmap.get_used_cells().size()

	# Count wall tiles (layer 1 decoration gridmap)
	var wall_count: int = 0
	if decoration_gridmap:
		wall_count = decoration_gridmap.get_used_cells().size()

	# Count static items (layer 2 items gridmap)
	var item_count: int = 0
	if items_gridmap:
		for cell in items_gridmap.get_used_cells():
			var mid: int = items_gridmap.get_cell_item(cell)
			if mid != -1 and mid in _item_id_to_struct:
				var s: Structure = structures[_item_id_to_struct[mid]]
				item_count += 1
				unique_types[s.display_name] = true
				var pts: int = _get_rating_points(s.display_name)
				if pts > 0:
					atmosphere_points += pts

	# Count animated instances (layer 3)
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx == -1:
			continue
		var s: Structure = structures[s_idx]
		unique_types[s.display_name] = true
		var pts: int = _get_rating_points(s.display_name)
		if _is_character_model(s):
			danger_points += pts
		elif s.display_name.contains("Trap"):
			danger_points += pts
		elif s.display_name.contains("Chest") or s.display_name.contains("Coin"):
			treasure_points += pts
		else:
			treasure_points += pts

	total_tiles = floor_count + wall_count + item_count + _animated_instances.size()

	# Room detection — enclosed rooms grant bonus points
	var rooms: Array = _detect_rooms()
	var room_points: int = 0
	var treasure_rooms: int = 0
	for room in rooms:
		room_points += ROOM_POINTS
		if room.get("has_treasure", false):
			room_points += TREASURE_ROOM_BONUS
			treasure_rooms += 1

	# Apply party-type score multipliers
	var mults: Dictionary = PARTY_MULTIPLIERS.get(_current_party_type, {})
	var adj_danger: int      = int(danger_points * mults.get("danger", 1.0))
	var adj_treasure: int    = int(treasure_points * mults.get("treasure", 1.0))
	var adj_atmosphere: int  = int(atmosphere_points * mults.get("atmosphere", 1.0))

	var size_score: int     = total_tiles / 10
	var variety_score: int  = unique_types.size() * 5
	var total_points: int   = size_score + variety_score + adj_danger + adj_treasure + adj_atmosphere + room_points

	# Calculate stars
	var stars: int = 1
	for i in range(STAR_THRESHOLDS.size() - 1, -1, -1):
		if total_points >= STAR_THRESHOLDS[i]:
			stars = i + 1
			break

	return {
		"total_tiles":       total_tiles,
		"floor_count":       floor_count,
		"wall_count":        wall_count,
		"item_count":        item_count + _animated_instances.size(),
		"unique_types":      unique_types.size(),
		"size_score":        size_score,
		"variety_score":     variety_score,
		"danger_points":     adj_danger,
		"treasure_points":   adj_treasure,
		"atmosphere_points": adj_atmosphere,
		"room_count":        rooms.size(),
		"treasure_rooms":    treasure_rooms,
		"room_points":       room_points,
		"total_points":      total_points,
		"stars":             stars,
		"payout":            STAR_PAYOUTS[stars - 1],
		"party_type":        _current_party_type,
		"party_name":        _current_party_name,
	}

func _do_adventurer_visit() -> void:
	if _visit_pending or _intermission_active:
		return
	_visit_pending = true

	# Generate this week's party (uses _next_party if available)
	_generate_party()

	# Compute stats and store for after intermission
	_pending_visit_stats = _compute_dungeon_stats()

	# Deselect any held item so it isn't accidentally placed on OK click
	if _placing:
		_set_placing(false)

	# Show announcement dialog
	_show_visit_announcement()

func _show_visit_announcement() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Adventurers Approaching!"
	var type_label: String = _party_type_label(_current_party_type)
	dialog.dialog_text = "%s (%s) are arriving to explore your dungeon!\n\nSit back and watch..." % [_current_party_name, type_label]
	dialog.ok_button_text = "Let them in!"
	dialog.confirmed.connect(_start_intermission)
	dialog.canceled.connect(_start_intermission)  # clicking X also proceeds
	add_child(dialog)
	dialog.popup_centered()

func _start_intermission() -> void:
	_intermission_active = true
	_intermission_timer = 0.0

	# Block camera input during intermission
	if view_node:
		view_node.block_input = true

	# Save current camera state
	if view_node:
		_saved_cam_pos = view_node.camera_position
		_saved_cam_rot = view_node.camera_rotation
		_saved_cam_zoom = view_node.zoom

	# Find the center of all walls for orbit target
	_orbit_center = _compute_dungeon_center()

	# Move camera to orbit position
	if view_node:
		view_node.camera_position = _orbit_center
		view_node.zoom = 25.0  # zoom in a bit for cinematic feel

	# Activate all animated instances — play looping animations during visit
	for pos in _animated_instances:
		var instance: Node3D = _animated_instances[pos]
		var anim_player: AnimationPlayer = _find_animation_player(instance)
		if anim_player:
			var s_idx: int = _animated_struct_idx.get(pos, -1)
			if s_idx != -1 and _is_character_model(structures[s_idx]):
				_play_random_character_anim(anim_player)
				_set_anim_looping(anim_player, anim_player.current_animation)
			else:
				# Chest/gate/trap — play open-close looping
				var anim_list: PackedStringArray = anim_player.get_animation_list()
				if anim_list.has("open-close"):
					_set_anim_looping(anim_player, "open-close")
					anim_player.play("open-close")
				elif anim_list.has("open"):
					_set_anim_looping(anim_player, "open")
					anim_player.play("open")

	# Hide the selector during intermission
	selector.visible = false

func _compute_dungeon_center() -> Vector3:
	# Find the bounding box center of all placed walls
	var min_x: float = 999.0
	var max_x: float = -999.0
	var min_z: float = 999.0
	var max_z: float = -999.0
	var has_walls: bool = false

	if decoration_gridmap:
		for cell in decoration_gridmap.get_used_cells():
			has_walls = true
			min_x = minf(min_x, cell.x)
			max_x = maxf(max_x, cell.x)
			min_z = minf(min_z, cell.z)
			max_z = maxf(max_z, cell.z)

	# Fallback to floor tiles if no walls
	if not has_walls:
		for cell in gridmap.get_used_cells():
			min_x = minf(min_x, cell.x)
			max_x = maxf(max_x, cell.x)
			min_z = minf(min_z, cell.z)
			max_z = maxf(max_z, cell.z)

	return Vector3((min_x + max_x) / 2.0, 0, (min_z + max_z) / 2.0)

func _process_intermission(delta: float) -> void:
	_intermission_timer += delta

	# Orbit the camera around the dungeon center
	if view_node:
		var orbit_speed: float = 36.0  # degrees per second → full rotation in 10s
		view_node.camera_rotation.y += orbit_speed * delta

	if _intermission_timer >= INTERMISSION_DURATION:
		_end_intermission()

func _end_intermission() -> void:
	_intermission_active = false

	# Restore camera and unblock input
	if view_node:
		view_node.camera_position = _saved_cam_pos
		view_node.camera_rotation = _saved_cam_rot
		view_node.zoom = _saved_cam_zoom
		view_node.block_input = false

	# Reset animated items — stop looping, return to idle/closed states
	for pos in _animated_instances:
		var instance: Node3D = _animated_instances[pos]
		var anim_player: AnimationPlayer = _find_animation_player(instance)
		if anim_player:
			# Stop looping on whichever animation was playing
			if anim_player.current_animation != "":
				_set_anim_not_looping(anim_player, anim_player.current_animation)
			var s_idx: int = _animated_struct_idx.get(pos, -1)
			if s_idx != -1 and _is_character_model(structures[s_idx]):
				_play_random_character_anim(anim_player, true)
			else:
				# Chest/gate/trap — back to closed/paused
				var anim_list: PackedStringArray = anim_player.get_animation_list()
				if anim_list.has("close"):
					anim_player.play("close")
					anim_player.seek(0.0, true)
					anim_player.pause()

	# Now do the actual visit logic (loot + payout)
	_finalize_visit()


func _finalize_visit() -> void:
	var stats: Dictionary = _pending_visit_stats
	if stats.is_empty():
		return

	var payout: int = stats.get("payout", 0)
	var loot_mult: float = PARTY_LOOT_MULT.get(_current_party_type, 1.0)

	# Roll loot chances — adventurers take items and pay their full cost
	var loot: int = 0
	var looted_counts: Dictionary = {}   # display_name -> count
	var cells_to_clear: Array = []       # Vector3i cells to remove from items gridmap
	var anims_to_remove: Array = []      # Vector3i positions to remove animated instances

	# Check static items in items gridmap
	if items_gridmap:
		for cell in items_gridmap.get_used_cells():
			var mid: int = items_gridmap.get_cell_item(cell)
			if mid != -1 and mid in _item_id_to_struct:
				var s: Structure = structures[_item_id_to_struct[mid]]
				var chance: float = minf(_get_loot_chance(s.display_name) * loot_mult, 1.0)
				if chance > 0.0 and randf() <= chance:
					loot += s.price
					cells_to_clear.append(cell)
					looted_counts[s.display_name] = looted_counts.get(s.display_name, 0) + 1

	# Check animated instances (chests can be looted, characters/traps cannot)
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx == -1:
			continue
		var s: Structure = structures[s_idx]
		var chance: float = minf(_get_loot_chance(s.display_name) * loot_mult, 1.0)
		if chance > 0.0 and randf() <= chance:
			loot += s.price
			anims_to_remove.append(pos)
			looted_counts[s.display_name] = looted_counts.get(s.display_name, 0) + 1

	# Remove looted items from the map
	for cell in cells_to_clear:
		items_gridmap.set_cell_item(cell, -1)
	for pos in anims_to_remove:
		_remove_animated(pos)

	var total: int = payout + loot
	map.cash += total
	_total_visit_gold += total
	update_cash()

	# Record visit in history
	var week_num: int = Global.current_day / 7
	var entry: Dictionary = {
		"week":       week_num,
		"stars":      stats.get("stars", 1),
		"points":     stats.get("total_points", 0),
		"payout":     payout,
		"loot":       loot,
		"total":      total,
		"looted":     looted_counts.duplicate(),
		"party_name": _current_party_name,
		"party_type": _party_type_label(_current_party_type),
	}
	_visit_history.push_front(entry)
	if _visit_history.size() > MAX_VISIT_HISTORY:
		_visit_history.resize(MAX_VISIT_HISTORY)

	# Show toast with results
	var stars: int = stats.get("stars", 1)
	var star_str: String = ""
	for i in range(stars):
		star_str += "★"
	for i in range(5 - stars):
		star_str += "☆"

	# Build loot summary (e.g. "2× Chest, 3× Coin, 1× Sword")
	var loot_parts: Array = []
	for item_name in looted_counts:
		loot_parts.append("%d× %s" % [looted_counts[item_name], item_name])
	var loot_summary: String = ", ".join(loot_parts) if not loot_parts.is_empty() else "nothing"

	Toast.notify("%s  Rating: %dg  Loot: %dg  =  %dg total" % [star_str, payout, loot, total], _SAVE_ICON)

	# Show loot details after a short delay
	if not loot_parts.is_empty():
		get_tree().create_timer(3.0).timeout.connect(
			func(): Toast.notify("Looted: %s" % loot_summary, _WARN_ICON))

	# Show next week's party as a heads-up
	var next_type_label: String = _party_type_label(_next_party_type)
	get_tree().create_timer(6.0).timeout.connect(
		func(): Toast.notify("Next week: %s (%s)" % [_next_party_name, next_type_label], _AWARD_ICON))

	# Check milestones (use room count from pre-loot stats)
	var room_list: Array = []
	var room_count: int = stats.get("room_count", 0)
	for i in range(room_count):
		room_list.append({})  # just need the count for milestone checks
	_check_visit_milestones(stars, total, room_list)

	_pending_visit_stats = {}
	_visit_pending = false

	# Restore selector visibility if player was placing
	if _placing:
		selector.visible = true


# Stub for _gen_job_slots — no longer used but referenced in action_build
func _gen_job_slots(_category: String, _price: int) -> int:
	return 0

# ── Dungeon Report ───────────────────────────────────────────────────────────

func _open_report() -> void:
	if not report_panel:
		return
	var stats: Dictionary = _compute_dungeon_stats()
	# Add next party info for the report's "Next Visitors" section
	stats["next_party_name"] = _next_party_name if _next_party_name != "" else "—"
	stats["next_party_type"] = _party_type_label(_next_party_type) if _next_party_type >= 0 else "—"
	report_panel.show_dungeon_report(stats, _visit_history)


func _open_help() -> void:
	if help_panel:
		help_panel.show_overlay()


# Load a saved map from a path, restoring terrain and placed structures
func _do_load(path: String) -> void:
	var loaded
	if OS.has_feature("web"):
		loaded = Global.web_load()
	else:
		loaded = ResourceLoader.load(path)
	if loaded:
		map = loaded
		if map.map_size > 0:
			Global.map_size = map.map_size
		if map.map_seed != 0:
			Global.map_seed = map.map_seed
	else:
		map = DataMap.new()
		map.cash = Global.starting_cash
	Global.pending_load = false
	Global.current_day  = map.current_day
	Global.current_week = Global.current_day / 7
	Global.day_cycle_enabled = map.day_cycle_enabled
	_visit_history = map.visit_history.duplicate(true) if not map.visit_history.is_empty() else []
	_milestones_earned = map.milestones_earned.duplicate() if not map.milestones_earned.is_empty() else {}
	_total_visit_gold = map.total_visit_gold
	_next_party_type = map.next_party_type
	_next_party_name = map.next_party_name
	if _next_party_type < 0:
		_roll_next_party()  # generate first party if save predates this feature
	_multi_cell_anchor.clear()
	generate_terrain()
	gridmap.clear()
	if decoration_gridmap:
		decoration_gridmap.clear()
	if items_gridmap:
		items_gridmap.clear()
	# Clear any existing animated instances
	for pos in _animated_instances.keys():
		_remove_animated(pos)
	for cell in map.structures:
		var gpos := Vector3i(cell.position.x, 0, cell.position.y)
		# Layer 3 = animated scene instance (structure field = struct index)
		if cell.layer == 3:
			if cell.structure >= 0 and cell.structure < structures.size():
				_spawn_animated(structures[cell.structure], cell.structure, gpos, cell.orientation)
			continue
		var target: GridMap
		if cell.layer == 2 and items_gridmap:
			target = items_gridmap
		elif cell.layer == 1 and decoration_gridmap:
			target = decoration_gridmap
		else:
			target = gridmap
		target.set_cell_item(gpos, cell.structure, cell.orientation)
		if cell.layer == 0 and terrain_gridmap:
			terrain_gridmap.set_cell_item(gpos, -1)
			# Rebuild multi-cell footprint tracking for large structures
			if cell.structure in _base_id_to_struct:
				var s_idx: int = _base_id_to_struct[cell.structure]
				var fp: Vector2i = structures[s_idx].footprint
				if fp.x > 1 or fp.y > 1:
					var off_x: int = (fp.x - 1) / 2
					var off_z: int = (fp.y - 1) / 2
					for dx in range(fp.x):
						for dz in range(fp.y):
							var child := Vector3i(gpos.x - off_x + dx, gpos.y, gpos.z - off_z + dz)
							_multi_cell_anchor[child] = gpos
							terrain_gridmap.set_cell_item(child, -1)
	_update_date_display()



# Saving/load

func action_save():
	if Input.is_action_just_pressed("save"):
		_do_save()


func _do_save() -> void:
	print("Saving map to slot: ", Global.save_slot)
	map.map_size    = Global.map_size
	map.map_seed    = Global.map_seed
	map.current_day = Global.current_day
	map.day_cycle_enabled = Global.day_cycle_enabled
	map.visit_history = _visit_history.duplicate(true)
	map.milestones_earned = _milestones_earned.duplicate()
	map.total_visit_gold = _total_visit_gold
	map.next_party_type = _next_party_type
	map.next_party_name = _next_party_name
	map.structures.clear()
	for cell in gridmap.get_used_cells():
		var ds := DataStructure.new()
		ds.position     = Vector2i(cell.x, cell.z)
		ds.orientation  = gridmap.get_cell_item_orientation(cell)
		ds.structure    = gridmap.get_cell_item(cell)
		ds.layer        = 0
		map.structures.append(ds)
	if decoration_gridmap:
		for cell in decoration_gridmap.get_used_cells():
			var ds := DataStructure.new()
			ds.position    = Vector2i(cell.x, cell.z)
			ds.orientation = decoration_gridmap.get_cell_item_orientation(cell)
			ds.structure   = decoration_gridmap.get_cell_item(cell)
			ds.layer       = 1
			map.structures.append(ds)
	if items_gridmap:
		for cell in items_gridmap.get_used_cells():
			var ds := DataStructure.new()
			ds.position    = Vector2i(cell.x, cell.z)
			ds.orientation = items_gridmap.get_cell_item_orientation(cell)
			ds.structure   = items_gridmap.get_cell_item(cell)
			ds.layer       = 2
			map.structures.append(ds)
	# Animated scene instances (layer 3 = animated, structure = struct index)
	for pos in _animated_instances:
		var ds := DataStructure.new()
		ds.position    = Vector2i(pos.x, pos.z)
		ds.orientation = _animated_orientation.get(pos, 0)
		ds.structure   = _animated_struct_idx.get(pos, 0)
		ds.layer       = 3
		map.structures.append(ds)
	if OS.has_feature("web"):
		var ok: bool = Global.web_save(map)
		if ok:
			Toast.notify("Game saved!", _SAVE_ICON)
		else:
			Toast.notify("Save FAILED — localStorage unavailable!", _SAVE_ICON)
	else:
		ResourceSaver.save(map, Global.save_path())
		Toast.notify("Game saved!", _SAVE_ICON)

func action_load():
	if Input.is_action_just_pressed("load"):
		print("Loading map from slot: ", Global.save_slot)
		_do_load(Global.save_path())
		update_cash()
	

func action_load_resources():
	pass  # Removed — no sample dungeon map
