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

# Lighting state saved/restored for intermission darkness
var _saved_sun_energy: float = 1.0
var _saved_ambient_energy: float = 0.75
var _sun_node: DirectionalLight3D = null
var _env: Environment = null

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
enum PartyType { WARRIORS, ROGUES, SCHOLARS, PALADINS, RAIDERS, MYSTICS, MERCENARIES, RAGTAG }

const PARTY_TYPE_COUNT: int = 8

# Score multipliers per party type → category
const PARTY_MULTIPLIERS: Dictionary = {
	PartyType.WARRIORS:     { "danger": 2.0, "treasure": 0.8, "atmosphere": 0.5 },
	PartyType.ROGUES:       { "danger": 0.8, "treasure": 2.0, "atmosphere": 0.8 },
	PartyType.SCHOLARS:     { "danger": 0.5, "treasure": 0.8, "atmosphere": 2.0 },
	PartyType.PALADINS:     { "danger": 1.5, "treasure": 0.5, "atmosphere": 1.5 },
	PartyType.RAIDERS:      { "danger": 1.0, "treasure": 2.5, "atmosphere": 0.3 },
	PartyType.MYSTICS:      { "danger": 0.8, "treasure": 0.5, "atmosphere": 2.5 },
	PartyType.MERCENARIES:  { "danger": 1.2, "treasure": 1.2, "atmosphere": 1.2 },
	PartyType.RAGTAG:       { "danger": 1.0, "treasure": 1.0, "atmosphere": 1.0 },
}

# Loot chance multipliers per party type
const PARTY_LOOT_MULT: Dictionary = {
	PartyType.WARRIORS:     0.7,   # warriors care about glory, not loot
	PartyType.ROGUES:       1.5,   # rogues grab everything they can
	PartyType.SCHOLARS:     0.4,   # scholars observe, rarely take things
	PartyType.PALADINS:     0.5,   # honorable — won't loot chests
	PartyType.RAIDERS:      2.0,   # take everything not nailed down
	PartyType.MYSTICS:      0.3,   # fascinated by traps, ignore treasure
	PartyType.MERCENARIES:  1.0,   # balanced — take what's fair
	PartyType.RAGTAG:       1.0,   # unpredictable
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
const PALADIN_NAMES: Array[String] = [
	"The Holy Vanguard", "Order of the Dawn", "The Silver Crusade",
	"Lightbringer's Host", "The Radiant Shield", "Templar's Oath",
	"The Hallowed Blades", "Sunsworn Company", "The Golden Aegis",
	"The Righteous Few", "Dawnwatch Sentinels", "The Sacred Flame",
]
const RAIDER_NAMES: Array[String] = [
	"The Bloodhounds", "Ironjaw's Reavers", "The Plunder Pack",
	"Grakkus's Horde", "The Warg Riders", "Skull Crushers",
	"The Rust Fangs", "Gutter's Brutes", "The Loot Goblins",
	"Smash & Grab Co.", "The Chain Gang", "Pillage Inc.",
]
const MYSTIC_NAMES: Array[String] = [
	"The Veil Walkers", "Circle of Shadows", "The Third Eye",
	"Whisperwind Coven", "The Ashen Seers", "Twilight Augurs",
	"The Runed Hand", "Eldritch Seekers", "The Fatebound",
	"The Grimoire Guild", "Nethermancers", "The Pale Circle",
]
const MERCENARY_NAMES: Array[String] = [
	"Swords for Hire", "The Free Company", "Goldclaw's Band",
	"The Sellswords", "Copper & Steel Co.", "The Hired Axes",
	"No Questions Asked", "The Coin Blades", "Fortune's Edge",
	"The Contract Keepers", "Blade & Bargain", "The Odd Jobs",
]
const RAGTAG_NAMES: Array[String] = [
	"The Misfits", "Band of Nobodies", "The Unlikely Heroes",
	"Last Pick Party", "The Leftovers", "Chaos Crew",
	"The Wandering Weirdos", "Fate's Rejects", "The Lucky Fools",
	"Oops All Adventurers", "The Hot Mess", "Plan B Party",
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
	"first_3star":   "First *** rating - Good dungeon!",
	"first_4star":   "First **** rating - Great dungeon!",
	"first_5star":   "First ***** - LEGENDARY dungeon!",
	"visits_10":     "10 visits survived!",
	"visits_25":     "25 visits - dungeon veteran!",
	"gold_1000":     "1,000g earned from adventurers!",
	"gold_5000":     "5,000g earned - the gold flows!",
	"first_room":    "First enclosed room detected!",
	"rooms_5":       "5 rooms - proper dungeon layout!",
	"all_types":     "Every item type placed!",
}

const _AWARD_ICON = preload("res://graphics/award.png")

# ── Room Detection ────────────────────────────────────────────────────────────
const ROOM_MIN_TILES: int = 4           # minimum floor tiles to count as a room
const ROOM_ENCLOSE_PCT: float = 0.75    # 75% of border must be walls/gates
const ROOM_POINTS: int = 15             # rating points per room
const TREASURE_ROOM_BONUS: int = 10     # extra points if room has treasure

# Room theme definitions — keyword lists that identify a theme
const ROOM_THEMES: Dictionary = {
	"Armory":   { "keywords": ["Sword", "Spear", "Shield", "Weapon Rack"], "min": 2, "bonus": 20 },
	"Treasury": { "keywords": ["Chest", "Coin", "Barrel"],                "min": 2, "bonus": 25 },
	"Barracks": { "keywords": ["Human", "Orc", "Soldier"],                "min": 2, "bonus": 20 },
	"Trap Room":{ "keywords": ["Trap"],                                   "min": 2, "bonus": 15 },
	"Gallery":  { "keywords": ["Statue", "Banner", "Column"],             "min": 2, "bonus": 15 },
}
# Party-type theme affinity — multiplier on the theme bonus
const PARTY_THEME_AFFINITY: Dictionary = {
	PartyType.WARRIORS:     { "Barracks": 2.0, "Armory": 1.5, "Trap Room": 1.2, "Treasury": 0.8, "Gallery": 0.5 },
	PartyType.ROGUES:       { "Treasury": 2.0, "Trap Room": 1.5, "Armory": 1.0, "Barracks": 0.8, "Gallery": 0.5 },
	PartyType.SCHOLARS:     { "Gallery": 2.5, "Trap Room": 1.5, "Treasury": 1.0, "Armory": 1.0, "Barracks": 0.8 },
	PartyType.PALADINS:     { "Barracks": 1.5, "Gallery": 1.5, "Armory": 1.5, "Trap Room": 0.8, "Treasury": 0.5 },
	PartyType.RAIDERS:      { "Treasury": 2.5, "Armory": 1.5, "Barracks": 1.0, "Trap Room": 0.8, "Gallery": 0.3 },
	PartyType.MYSTICS:      { "Trap Room": 2.5, "Gallery": 2.0, "Treasury": 0.8, "Armory": 0.5, "Barracks": 0.5 },
	PartyType.MERCENARIES:  { "Armory": 1.5, "Treasury": 1.5, "Barracks": 1.2, "Trap Room": 1.0, "Gallery": 0.8 },
	PartyType.RAGTAG:       { "Barracks": 1.0, "Armory": 1.0, "Treasury": 1.0, "Trap Room": 1.0, "Gallery": 1.0 },
}

# ── Travelling Merchant — prefab themed rooms ────────────────────────────────
const MERCHANT_CHANCE: float = 0.30           # 30% chance per week
const MERCHANT_PRICE: int = 1000
const PREFAB_MIN_SIZE: int = 5
const PREFAB_MAX_SIZE: int = 15
const PREFAB_THEMES: Array[String] = ["Armory", "Treasury", "Barracks", "Trap Room", "Gallery"]
# Items to place inside each themed room (display_name keywords)
const PREFAB_ITEMS: Dictionary = {
	"Armory":    ["Dungeon Sword", "Dungeon Spear", "Rectangle Shield", "Round Shield", "Weapon Rack"],
	"Treasury":  ["Chest", "Coin", "Coin", "Barrel", "Barrel"],
	"Barracks":  ["Orc", "Orc", "Soldier", "Human"],
	"Trap Room": ["Trap", "Trap", "Stones", "Rocks"],
	"Gallery":   ["Statue", "Dungeon Banner", "Arena Banner", "Dungeon Column", "Arena Column"],
}

var _merchant_offered_this_week: bool = false
var _prefab_placing: bool = false             # true while placing a purchased prefab
var _prefab_theme: String = ""                # theme of the prefab being placed
var _prefab_w: int = 0                        # width (x)
var _prefab_h: int = 0                        # height (z)
var _prefab_outline: Node3D = null            # visual preview outline
var _prefab_valid: bool = false               # true if current position is clear

# Terrain
var _terrain_noise: FastNoiseLite = null
var _terrain_mesh_ids: Dictionary = {}     # glb basename  -> mesh library id
var _terrain_rewards: Dictionary  = {}     # mesh library id -> cash reward

# Variation groups: group name -> array of structure indices (built in _ready)
var _variation_groups: Dictionary = {}   # String -> Array[int]

# Texture variation system — swap color textures on models with Z key
var _struct_variation_ids: Array = []       # per-structure: Array of mesh library IDs [base, var_a, var_b, ...]
var _pending_mid: int = -1                  # current mesh library ID to place (base or variant)
var _pending_variation_tex: Texture2D = null # texture override for preview cursor
var _pending_variation_idx: int = 0         # current index into variation list
var _global_palette_idx: int = 0           # global palette: 0=base, 1=var_a, 2=var_b, etc.
var _max_palette_count: int = 1            # total number of palettes available (computed at startup)
var _variation_tex_cache: Dictionary = {}   # model texture dir -> Array[Texture2D]
var _variation_mat_cache: Dictionary = {}   # "mat_id:tex_path" -> Material (cached for GPU batching)
const _NO_VARIATION_CATEGORIES: Array[String] = ["Nature"]  # categories that skip texture variations

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

# Vertical stacking
const MAX_STACK_Y: int = 10     # maximum vertical cell scan height
var _mesh_heights: Dictionary = {}   # mesh library ID -> float height (cached AABB.size.y)

# Dungeon Stairs & Trophy — required entry/exit and goal for adventurers
const REQUIRED_STAIRS_NAME: String = "Dungeon Stairs [Req]"
const REQUIRED_TROPHY_NAME: String = "Trophy [Req]"
var _stairs_position: Vector3i = Vector3i(-999, -999, -999)  # sentinel = no stairs placed
var _trophy_position: Vector3i = Vector3i(-999, -999, -999)  # sentinel = no trophy placed
var _has_stairs: bool = false
var _has_trophy: bool = false
var _intermission_node: Intermission = null  # active walk-through instance

# Navigation wall map — updated on every build/demolish for A* pathfinding
# Maps Vector2i(x, z) -> String (structure display_name).  Passable openings
# (Wall Opening, Gate, etc.) are stored in _nav_passable instead.
var _nav_walls: Dictionary = {}     # Vector2i -> String  (solid walls)
var _nav_passable: Dictionary = {}  # Vector2i -> String  (passable openings)

# Freebuild mode — no gold cost for placing structures
var _freebuild: bool = false
const _FREEBUILD_COLOR: Color = Color(0.3, 0.6, 1.0)  # blue tint for gold display
var _normal_cash_color: Color = Color.WHITE             # stored on ready

# Next party display label (created in _ready, shown to right of date)
var _next_party_label: Label = null

func _ready():

	_load_structures()
	_setup_font_fallback()

	plane = Plane(Vector3.UP, Vector3.ZERO)

	# Build separate MeshLibraries for base, decoration, and terrain layers
	_build_mesh_libraries()
	_build_terrain_mesh_library()

	# Build variation group lookup
	for i in range(structures.size()):
		var grp: String = structures[i].variation_group
		if grp != "":
			if grp not in _variation_groups:
				_variation_groups[grp] = []
			_variation_groups[grp].append(i)

	if Global.pending_load:
		_do_load(Global.save_path())
	else:
		map = DataMap.new()
		map.cash = Global.starting_cash
		generate_terrain()
		# Generate the first party for a new game
		_roll_next_party()
		# Generate a BSP starter dungeon skeleton
		_generate_starter_dungeon()


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

	# Store the default cash label color for freebuild toggle
	if cash_display:
		_normal_cash_color = cash_display.modulate

	# Start in browse mode — selector hidden until a building is picked
	selector.visible = false

	update_structure()
	update_cash()
	_update_date_display()

	# Create "Next:" party label to the right of the date display
	if date_display:
		_next_party_label = Label.new()
		_next_party_label.name = "NextParty"
		_next_party_label.position = Vector2(date_display.position.x + date_display.size.x + 20, date_display.position.y)
		_next_party_label.size = Vector2(400, 28)
		if date_display.label_settings:
			_next_party_label.label_settings = date_display.label_settings.duplicate()
		_next_party_label.modulate = Color(0.9, 0.8, 0.6)  # warm gold tint
		date_display.get_parent().add_child(_next_party_label)
		_update_next_party_display()


func _setup_font_fallback() -> void:
	# Add Noto Emoji as a fallback to the Nerd Font for any missing glyphs
	var nerd_path := "res://fonts/FantasqueSansMNerdFont-Regular.ttf"
	var emoji_path := "res://fonts/NotoEmoji-Regular.ttf"
	if ResourceLoader.exists(nerd_path) and ResourceLoader.exists(emoji_path):
		var nerd_font: FontFile = load(nerd_path)
		var emoji_font: FontFile = load(emoji_path)
		if emoji_font not in nerd_font.fallbacks:
			nerd_font.fallbacks.append(emoji_font)


func _process(delta):

	# During intermission, only process the orbit — block all input & time
	if _intermission_active:
		_process_intermission(delta)
		return

	# Time / economy tick
	_advance_time(delta)

	# Keyboard / non-mouse controls always fire
	action_cycle_structure()
	action_cycle_variation()
	action_cycle_texture()
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
			var gx: int = int(round(world_position.x))
			var gz: int = int(round(world_position.z))
			# Scan vertically to find the top of whatever is at this column
			var stack_y: float = _get_stack_height(gx, gz)
			last_gridmap_position = Vector3(gx, stack_y, gz)

	selector.position = lerp(selector.position, last_gridmap_position, min(delta * 40, 1.0))

	# Prefab placement mode — update outline, handle clicks, block normal build
	if _prefab_placing:
		var gx: int = int(last_gridmap_position.x)
		var gz: int = int(last_gridmap_position.z)
		_update_prefab_outline(gx, gz)
		if not _is_over_picker():
			if Input.is_action_just_pressed("build"):
				_place_prefab(gx, gz)
			elif Input.is_action_just_pressed("demolish"):
				_cancel_prefab()
		return

	action_build(last_gridmap_position)
	action_demolish(last_gridmap_position)

# Build three MeshLibraries — one per layer — and record per-structure IDs
# Also creates texture variation meshes for each structure that has variation textures.
func _build_mesh_libraries() -> void:
	var base_lib := MeshLibrary.new()
	var deco_lib := MeshLibrary.new()
	var item_lib := MeshLibrary.new()
	_struct_mesh_id.clear()
	_struct_layer.clear()
	_struct_variation_ids.clear()
	_base_id_to_struct.clear()
	_deco_id_to_struct.clear()
	_item_id_to_struct.clear()
	for i in structures.size():
		var s := structures[i]
		var mesh = get_mesh(s.model)
		_struct_layer.append(s.layer)
		if mesh == null:
			_struct_mesh_id.append(-1)
			_struct_variation_ids.append([])
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

		# Build texture variations for this structure
		var var_ids: Array = [id]  # index 0 = base mesh
		if s.category not in _NO_VARIATION_CATEGORIES:
			var textures: Array = _get_variation_textures(s)
			for tex in textures:
				var var_mesh: Mesh = _apply_texture_to_mesh(mesh, tex)
				var vid := lib.get_last_unused_item_id()
				lib.create_item(vid)
				lib.set_item_mesh(vid, var_mesh)
				lib.set_item_mesh_transform(vid, Transform3D())
				var_ids.append(vid)
				# Map variation IDs back to the same structure for demolish refunds
				if s.layer == 2:
					_item_id_to_struct[vid] = i
				elif s.layer == 1:
					_deco_id_to_struct[vid] = i
				else:
					_base_id_to_struct[vid] = i
		_struct_variation_ids.append(var_ids)

	gridmap.mesh_library = base_lib
	if decoration_gridmap:
		decoration_gridmap.mesh_library = deco_lib
	if items_gridmap:
		items_gridmap.mesh_library = item_lib

	# Cache mesh heights for vertical stacking
	_mesh_heights.clear()
	for lib in [base_lib, deco_lib, item_lib]:
		for mid in lib.get_item_list():
			var m: Mesh = lib.get_item_mesh(mid)
			if m:
				_mesh_heights[mid] = m.get_aabb().size.y
	# Compute max palette count across all structures
	_max_palette_count = 1
	for ids in _struct_variation_ids:
		if ids.size() > _max_palette_count:
			_max_palette_count = ids.size()
	print("[Builder] Texture variations built: ", _struct_variation_ids.filter(func(a): return a.size() > 1).size(), " structures with variants, max palette count: ", _max_palette_count)


# Find variation texture files for a structure's model pack
func _get_variation_textures(s: Structure) -> Array:
	if s.model == null:
		return []
	var model_path: String = s.model.resource_path
	# Walk up from the GLB file to find the Textures folder
	# e.g. res://models/Mini Arena/Models/GLB format/wall.glb → res://models/Mini Arena/Models/Textures/
	var dir: String = model_path.get_base_dir()  # .../GLB format
	var parent_dir: String = dir.get_base_dir()   # .../Models
	var tex_dir: String = parent_dir + "/Textures/"

	# Check cache
	if tex_dir in _variation_tex_cache:
		return _variation_tex_cache[tex_dir]

	var textures: Array = []
	for letter in ["a", "b", "c", "d"]:
		var path: String = tex_dir + "variation-" + letter + ".png"
		if ResourceLoader.exists(path):
			textures.append(load(path))
		else:
			break
	_variation_tex_cache[tex_dir] = textures
	if not textures.is_empty():
		print("[Builder] Found %d variation textures in %s" % [textures.size(), tex_dir])
	return textures


# Create a duplicate mesh with a different albedo texture on all surfaces
func _apply_texture_to_mesh(base_mesh: Mesh, tex: Texture2D) -> Mesh:
	var new_mesh := base_mesh.duplicate() as Mesh
	for surf_idx in new_mesh.get_surface_count():
		var mat := new_mesh.surface_get_material(surf_idx)
		if mat == null:
			continue
		var cache_key: String = str(mat.get_instance_id()) + ":" + tex.resource_path
		if not _variation_mat_cache.has(cache_key):
			var new_mat := mat.duplicate()
			if new_mat is StandardMaterial3D:
				(new_mat as StandardMaterial3D).albedo_texture = tex
			_variation_mat_cache[cache_key] = new_mat
		new_mesh.surface_set_material(surf_idx, _variation_mat_cache[cache_key])
	return new_mesh

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
		if _prefab_placing:
			_cancel_prefab()
			get_viewport().set_input_as_handled()
			return
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
	instance.position = Vector3(pos.x, float(pos.y), pos.z)
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


# Cycle variation with C key — swap to the next structure in the same variation group
func action_cycle_variation() -> void:
	if not Input.is_action_just_pressed("cycle_variation"):
		return
	if not _placing:
		return
	var grp: String = structures[index].variation_group
	if grp == "" or grp not in _variation_groups:
		return
	var group: Array = _variation_groups[grp]
	if group.size() <= 1:
		return
	# Find current position in the group and advance to the next
	var pos: int = group.find(index)
	if pos == -1:
		return
	var next_idx: int = group[(pos + 1) % group.size()]
	index = next_idx
	_pending_variation_idx = 0
	_pending_variation_tex = null
	if building_picker:
		building_picker.set_selected_index(index)
	Audio.play("sounds/toggle.ogg", -30)
	update_structure()
	print("[Builder] cycle_variation -> %s (group: %s)" % [structures[index].display_name, grp])


# Cycle texture variation with Z key — swap albedo texture on the current structure
func action_cycle_texture() -> void:
	if not Input.is_action_just_pressed("cycle_texture"):
		return
	if not _placing:
		return
	if index >= _struct_variation_ids.size():
		return
	var ids: Array = _struct_variation_ids[index]
	if ids.size() <= 1:
		return
	_pending_variation_idx = (_pending_variation_idx + 1) % ids.size()
	_apply_variation_idx()
	_update_preview_variation()
	Audio.play("sounds/toggle.ogg", -30)
	print("[Builder] cycle_texture -> variation %d/%d for %s" % [_pending_variation_idx, ids.size(), structures[index].display_name])


# Set _pending_mid and _pending_variation_tex from the current variation index
func _apply_variation_idx() -> void:
	if index >= _struct_variation_ids.size():
		return
	var ids: Array = _struct_variation_ids[index]
	if _pending_variation_idx >= ids.size():
		_pending_variation_idx = 0
	_pending_mid = ids[_pending_variation_idx]
	# Determine which texture is active (index 0 = base, 1+ = variation textures)
	if _pending_variation_idx == 0:
		_pending_variation_tex = null
	else:
		var textures: Array = _get_variation_textures(structures[index])
		var tex_idx: int = _pending_variation_idx - 1
		if tex_idx < textures.size():
			_pending_variation_tex = textures[tex_idx]
		else:
			_pending_variation_tex = null


# Apply the current variation texture to the preview model in the selector cursor
func _update_preview_variation() -> void:
	if selector_container.get_child_count() == 0:
		return
	var model_node: Node3D = selector_container.get_child(0)
	for child in model_node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if _pending_variation_tex == null:
				# Base texture — clear all overrides
				for surf_idx in mi.get_surface_override_material_count():
					mi.set_surface_override_material(surf_idx, null)
			else:
				# Apply variation texture to all surfaces
				for surf_idx in mi.mesh.get_surface_count():
					var mat := mi.get_active_material(surf_idx)
					if mat == null:
						continue
					var new_mat := mat.duplicate()
					if new_mat is StandardMaterial3D:
						(new_mat as StandardMaterial3D).albedo_texture = _pending_variation_tex
					mi.set_surface_override_material(surf_idx, new_mat)
			break  # only process the first MeshInstance3D


# ── Global palette swap (P key) ──────────────────────────────────────────────

func _cycle_global_palette() -> void:
	_global_palette_idx = (_global_palette_idx + 1) % _max_palette_count
	var palette_name: String
	if _global_palette_idx == 0:
		palette_name = "Default"
	else:
		palette_name = "Variation " + ["A", "B", "C", "D"][_global_palette_idx - 1] if _global_palette_idx <= 4 else "Variation %d" % _global_palette_idx

	# Swap every cell in all three gridmaps
	_swap_gridmap_palette(gridmap, _base_id_to_struct)
	_swap_gridmap_palette(decoration_gridmap, _deco_id_to_struct)
	_swap_gridmap_palette(items_gridmap, _item_id_to_struct)

	# Swap animated instances (characters, chests, traps, etc.)
	_swap_animated_palette()

	Audio.play("sounds/toggle.ogg", -30)
	Toast.notify("Palette: %s" % palette_name, _SAVE_ICON)
	print("[Builder] Global palette -> %s (idx %d)" % [palette_name, _global_palette_idx])


func _swap_gridmap_palette(gmap: GridMap, id_to_struct: Dictionary) -> void:
	if gmap == null:
		return
	for cell in gmap.get_used_cells():
		var mid: int = gmap.get_cell_item(cell)
		if mid == -1:
			continue
		# Find the structure index for this mesh ID
		var s_idx: int = -1
		if mid in id_to_struct:
			s_idx = id_to_struct[mid]
		else:
			# Might be a variation ID — search all variation arrays
			for i in range(_struct_variation_ids.size()):
				if mid in _struct_variation_ids[i]:
					s_idx = i
					break
		if s_idx == -1:
			continue

		var ids: Array = _struct_variation_ids[s_idx]
		if ids.size() <= 1:
			continue  # no variations for this structure

		# Pick the target variation — wrap if this structure has fewer variations
		var target_idx: int = _global_palette_idx % ids.size()
		var new_mid: int = ids[target_idx]
		if new_mid != mid:
			var ori: int = gmap.get_cell_item_orientation(cell)
			gmap.set_cell_item(cell, new_mid, ori)


func _swap_animated_palette() -> void:
	# Get the target variation texture
	var target_tex: Texture2D = null
	if _global_palette_idx > 0:
		# All model packs share the same variation textures, so grab from any structure
		for i in range(structures.size()):
			var textures: Array = _get_variation_textures(structures[i])
			if not textures.is_empty():
				var tex_idx: int = (_global_palette_idx - 1) % textures.size()
				target_tex = textures[tex_idx]
				break

	for pos in _animated_instances:
		var instance: Node3D = _animated_instances[pos]
		if not is_instance_valid(instance):
			continue
		# Apply or clear texture override on all MeshInstance3D children (recursive)
		_apply_palette_to_node(instance, target_tex)


func _apply_palette_to_node(node: Node3D, tex: Texture2D) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			if tex == null:
				# Clear overrides — back to base texture
				for surf_idx in mi.get_surface_override_material_count():
					mi.set_surface_override_material(surf_idx, null)
			else:
				for surf_idx in mi.mesh.get_surface_count():
					var mat := mi.get_active_material(surf_idx)
					if mat == null:
						continue
					var cache_key: String = str(mat.get_instance_id()) + ":" + tex.resource_path
					if not _variation_mat_cache.has(cache_key):
						var new_mat := mat.duplicate()
						if new_mat is StandardMaterial3D:
							(new_mat as StandardMaterial3D).albedo_texture = tex
						_variation_mat_cache[cache_key] = new_mat
					mi.set_surface_override_material(surf_idx, _variation_mat_cache[cache_key])
		elif child is Node3D:
			_apply_palette_to_node(child, tex)


# ── Vertical stacking helpers ──────────────────────────────────────────────────

# Get the height of a mesh library item (cached AABB)
func _get_mesh_height(lib: MeshLibrary, mid: int) -> float:
	if mid in _mesh_heights:
		return _mesh_heights[mid]
	var m: Mesh = lib.get_item_mesh(mid)
	if m:
		var h: float = m.get_aabb().size.y
		_mesh_heights[mid] = h
		return h
	return 1.0


# Get the AABB height of an animated scene instance
func _get_instance_height(instance: Node3D) -> float:
	for child in instance.get_children():
		if child is MeshInstance3D:
			return (child as MeshInstance3D).get_aabb().size.y
	return 1.0


# Scan a single GridMap column at (x, z) from top down, return the world-Y of the top surface
func _scan_gridmap_top(gm: GridMap, x: int, z: int) -> float:
	if gm == null:
		return 0.0
	var top_y: float = 0.0
	for cy in range(MAX_STACK_Y, -1, -1):
		var cell := Vector3i(x, cy, z)
		var mid: int = gm.get_cell_item(cell)
		if mid != -1:
			var h: float = _mesh_heights.get(mid, 1.0)
			var cell_top: float = float(cy) * gm.cell_size.y + h
			top_y = maxf(top_y, cell_top)
			break  # found the topmost cell in this column
	return top_y


# Get the stacking height at a world x, z — scans all GridMaps and animated instances
func _get_stack_height(gx: int, gz: int) -> float:
	var max_y: float = 0.0

	# Scan each GridMap for the topmost cell
	max_y = maxf(max_y, _scan_gridmap_top(gridmap, gx, gz))
	max_y = maxf(max_y, _scan_gridmap_top(decoration_gridmap, gx, gz))
	max_y = maxf(max_y, _scan_gridmap_top(items_gridmap, gx, gz))

	# Check animated instances at any Y level at this x, z
	for pos in _animated_instances:
		if pos.x == gx and pos.z == gz:
			var instance: Node3D = _animated_instances[pos]
			var h: float = _get_instance_height(instance)
			var top: float = instance.position.y + h
			max_y = maxf(max_y, top)

	return max_y


# Convert a world-space Y height to a GridMap cell Y index
func _height_to_cell_y(height: float) -> int:
	# Round to nearest integer cell — cell_size.y is 1.0
	return int(round(height))


# ── Navigation Wall Map ──────────────────────────────────────────────────────
# Keeps a live 2D map of wall positions for A* pathfinding in the intermission.
# Called on every build/demolish of a decoration-layer (layer 1) structure.

const NAV_PASSABLE_WALLS: Array[String] = [
	"Wall Opening", "Wall Gate", "Gate",
]

func _nav_update_wall(xz: Vector2i, display_name: String) -> void:
	var is_passable: bool = false
	for keyword in NAV_PASSABLE_WALLS:
		if display_name.contains(keyword):
			is_passable = true
			break
	if is_passable:
		_nav_passable[xz] = display_name
		_nav_walls.erase(xz)  # passable overrides solid
	else:
		_nav_walls[xz] = display_name
		# Don't remove passable — a passable opening at this position wins
		# (player may have stacked a wall + opening at same xz)

func _nav_rebuild() -> void:
	## Rebuild the entire wall map from gridmap + animated instance data.
	## Called once after loading a save.
	_nav_walls.clear()
	_nav_passable.clear()
	# Decoration gridmap (static walls, wall openings)
	if decoration_gridmap:
		for cell in decoration_gridmap.get_used_cells():
			var mid: int = decoration_gridmap.get_cell_item(cell)
			var s_idx: int = _deco_id_to_struct.get(mid, -1)
			if s_idx == -1:
				continue
			_nav_update_wall(Vector2i(cell.x, cell.z), structures[s_idx].display_name)
	# Animated instances (gates, etc.)
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx == -1 or s_idx >= structures.size():
			continue
		if structures[s_idx].layer == 1:
			_nav_update_wall(Vector2i(pos.x, pos.z), structures[s_idx].display_name)
	print("[Builder] Nav wall map rebuilt: %d walls, %d passable" % [_nav_walls.size(), _nav_passable.size()])


# Find the topmost occupied cell Y at (x, z) for demolish — returns [GridMap/null, Vector3i, is_animated]
func _find_topmost_at(gx: int, gz: int) -> Dictionary:
	var best_y: float = -1.0
	var result: Dictionary = {}

	# Check animated instances first (they have exact float Y positions)
	for pos in _animated_instances:
		if pos.x == gx and pos.z == gz:
			var instance: Node3D = _animated_instances[pos]
			if instance.position.y >= best_y:
				best_y = instance.position.y
				result = { "type": "animated", "pos": pos, "world_y": instance.position.y }

	# Check each GridMap from top down
	for gm_info in [
		{ "gm": items_gridmap, "layer": 2, "lookup": _item_id_to_struct },
		{ "gm": decoration_gridmap, "layer": 1, "lookup": _deco_id_to_struct },
		{ "gm": gridmap, "layer": 0, "lookup": _base_id_to_struct },
	]:
		var gm: GridMap = gm_info["gm"]
		if gm == null:
			continue
		for cy in range(MAX_STACK_Y, -1, -1):
			var cell := Vector3i(gx, cy, gz)
			var mid: int = gm.get_cell_item(cell)
			if mid != -1:
				var world_y: float = float(cy) * gm.cell_size.y
				if world_y > best_y:
					best_y = world_y
					result = {
						"type": "gridmap",
						"gm": gm,
						"cell": cell,
						"mid": mid,
						"layer": gm_info["layer"],
						"lookup": gm_info["lookup"],
					}
				break  # only check topmost in this gridmap column

	return result


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
		# Use the texture-variation mesh ID if one is active, otherwise use base
		var mid: int = _pending_mid if _pending_mid >= 0 else (_struct_mesh_id[index] if index < _struct_mesh_id.size() else -1)
		if mid == -1:
			return
		var layer: int = _struct_layer[index]
		var s: Structure = structures[index]
		# Use the cursor's Y position (from stack scan) to determine cell Y
		var cell_y: int = _height_to_cell_y(gridmap_position.y)
		var anchor := Vector3i(int(gridmap_position.x), cell_y, int(gridmap_position.z))
		var fp_cells: Array = _get_footprint_cells(anchor, s)

		# Enforce single placement of required items
		if s.display_name == REQUIRED_STAIRS_NAME and _has_stairs:
			Toast.notify("Only one set of Dungeon Stairs allowed!", _WARN_ICON)
			return
		if s.display_name == REQUIRED_TROPHY_NAME and _has_trophy:
			Toast.notify("Only one Trophy allowed!", _WARN_ICON)
			return

		# Base floor tiles (layer 0) check footprint is clear before placing
		if layer == 0:
			for cell in fp_cells:
				var vcell := Vector3i(cell)
				if gridmap.get_cell_item(vcell) != -1 or _multi_cell_anchor.has(vcell):
					Toast.notify("Not enough room!", _WARN_ICON)
					return

		# Animated models (characters, chest, gate, trap) → spawn as scene instance
		if _is_animated_structure(s):
			# Don't stack animated instances on exact same position
			if anchor in _animated_instances:
				Toast.notify("Something is already here!", _WARN_ICON)
				return
			var rotation_idx: int = gridmap.get_orthogonal_index_from_basis(selector.basis)
			_spawn_animated(s, index, anchor, rotation_idx)
			# Animated gates/openings go in nav map too
			if layer == 1:
				_nav_update_wall(Vector2i(anchor.x, anchor.z), s.display_name)
			if not _freebuild:
				map.cash -= s.price
			update_cash()
			Audio.play("sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg", -20)
			return

		# Non-animated models → place in appropriate GridMap at the correct Y cell
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

		var previous_tile = target_map.get_cell_item(anchor)
		target_map.set_cell_item(anchor, mid, rotation_idx)

		# Register multi-cell footprint so child cells block future placement
		if layer == 0:
			if s.footprint.x > 1 or s.footprint.y > 1:
				for cell in fp_cells:
					_multi_cell_anchor[Vector3i(cell)] = anchor

		# Clear terrain tiles under base floor tiles (only at ground level)
		if layer == 0 and terrain_gridmap and cell_y == 0:
			for cell in fp_cells:
				var vcell := Vector3i(cell)
				var terrain_tile := terrain_gridmap.get_cell_item(vcell)
				if terrain_tile != -1:
					terrain_gridmap.set_cell_item(vcell, -1)

		if previous_tile != mid:
			if not _freebuild:
				map.cash -= s.price
			update_cash()
			Audio.play("sounds/placement-a.ogg, sounds/placement-b.ogg, sounds/placement-c.ogg, sounds/placement-d.ogg", -20)

		# Track required item placement
		if s.display_name == REQUIRED_STAIRS_NAME:
			_stairs_position = anchor
			_has_stairs = true
			print("[Builder] Dungeon Stairs placed at %s" % str(anchor))
		elif s.display_name == REQUIRED_TROPHY_NAME:
			_trophy_position = anchor
			_has_trophy = true
			print("[Builder] Trophy placed at %s" % str(anchor))

		# Update navigation wall map for pathfinding
		if layer == 1:
			_nav_update_wall(Vector2i(anchor.x, anchor.z), s.display_name)

# Demolish (remove) a structure — animated first, then items, then walls, then floors

func action_demolish(gridmap_position):
	if Input.is_action_just_pressed("demolish"):
		var gx: int = int(round(gridmap_position.x))
		var gz: int = int(round(gridmap_position.z))
		var top := _find_topmost_at(gx, gz)
		if top.is_empty():
			return
		var removed := false

		if top["type"] == "animated":
			var apos: Vector3i = top["pos"]
			var s_idx: int = _animated_struct_idx.get(apos, -1)
			if s_idx != -1 and not _freebuild:
				var refund := ceili(structures[s_idx].price / 2.0)
				map.cash += refund
				update_cash()
			_remove_animated(apos)
			removed = true
		elif top["type"] == "gridmap":
			var gm: GridMap = top["gm"]
			var cell: Vector3i = top["cell"]
			var mid: int = top["mid"]
			var layer_num: int = top["layer"]
			var lookup: Dictionary = top["lookup"]

			if layer_num == 0:
				# Floor tile — handle multi-cell footprint
				var anchor: Vector3i = _multi_cell_anchor.get(cell, cell) as Vector3i
				mid = gm.get_cell_item(anchor)
				if mid == -1:
					return
				var s_idx: int = _base_id_to_struct.get(mid, -1)
				var fp := Vector2i(1, 1)
				if s_idx != -1:
					fp = structures[s_idx].footprint
					if not _freebuild:
						var refund := ceili(structures[s_idx].price / 2.0)
						map.cash += refund
						update_cash()
				gm.set_cell_item(anchor, -1)
				var off_x: int = (fp.x - 1) / 2
				var off_z: int = (fp.y - 1) / 2
				for dx in range(fp.x):
					for dz in range(fp.y):
						var fp_cell := Vector3i(anchor.x - off_x + dx, anchor.y, anchor.z - off_z + dz)
						_multi_cell_anchor.erase(fp_cell)
						if terrain_gridmap and anchor.y == 0:
							var tile := _get_terrain_tile(fp_cell.x, fp_cell.z)
							if tile != -1:
								terrain_gridmap.set_cell_item(fp_cell, tile)
				removed = true
			else:
				# Wall or item tile
				gm.set_cell_item(cell, -1)
				if mid in lookup and not _freebuild:
					var refund := ceili(structures[lookup[mid]].price / 2.0)
					map.cash += refund
					update_cash()
				removed = true

		if removed:
			# Remove from navigation wall map
			var nav_key := Vector2i(gx, gz)
			_nav_walls.erase(nav_key)
			_nav_passable.erase(nav_key)
			# Check if we demolished a required item
			if _has_stairs and gx == _stairs_position.x and gz == _stairs_position.z:
				_has_stairs = false
				_stairs_position = Vector3i(-999, -999, -999)
			if _has_trophy and gx == _trophy_position.x and gz == _trophy_position.z:
				_has_trophy = false
				_trophy_position = Vector3i(-999, -999, -999)
			Audio.play("sounds/removal-a.ogg, sounds/removal-b.ogg, sounds/removal-c.ogg, sounds/removal-d.ogg", -20)

# ── BSP Starter Dungeon Generator ────────────────────────────────────────────
# Generates a random dungeon wall skeleton using Binary Space Partitioning.
# Placed for free on new-game only.

const BSP_MIN_PARTITION: int = 4   # minimum partition width/height (allows 2×2 interior)
const BSP_MIN_SPLIT: int = 7      # minimum size to be splittable (both halves >= 4)

func _generate_starter_dungeon() -> void:
	if not decoration_gridmap:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = Global.map_seed

	# Random dungeon size 15–26 (use global randi so size varies independently)
	var dw: int = (randi() % 12) + 15
	var dh: int = (randi() % 12) + 15

	# Center on map
	var x1: int = -dw / 2
	var z1: int = -dh / 2
	var x2: int = x1 + dw - 1
	var z2: int = z1 + dh - 1

	# Find required structure indices by display name
	var dungeon_idx: int = _find_struct_by_name("Dungeon Wall")
	var narrow_idx: int = _find_struct_by_name("Narrow Wall")

	if dungeon_idx == -1:
		push_warning("[BSP] Missing Dungeon Wall structure — skipping dungeon generation")
		return
	if narrow_idx == -1:
		push_warning("[BSP] Missing Narrow Wall structure — falling back to Dungeon Wall only")
		narrow_idx = dungeon_idx

	# Build BSP tree
	var root := _bsp_node(x1, z1, x2, z2)
	_bsp_split(root, rng)

	# Build wall grid: Vector2i(x, z) -> "wall_h" / "wall_v" / "opening"
	var grid: Dictionary = {}
	_bsp_mark_walls(root, grid)
	_bsp_mark_openings(root, grid, rng)

	# Mesh IDs for each wall type
	var dungeon_mid: int = _struct_mesh_id[dungeon_idx]
	var narrow_mid: int = _struct_mesh_id[narrow_idx]
	var walls_placed: int = 0
	var intersections: int = 0

	for pos in grid:
		var val: String = grid[pos]
		if not val.begins_with("wall"):
			continue

		# Check neighbors to classify: intersection vs straight segment
		var val_n: String = grid.get(Vector2i(pos.x, pos.y - 1), "")
		var val_s: String = grid.get(Vector2i(pos.x, pos.y + 1), "")
		var val_e: String = grid.get(Vector2i(pos.x + 1, pos.y), "")
		var val_w: String = grid.get(Vector2i(pos.x - 1, pos.y), "")

		var has_n: bool = val_n.begins_with("wall")
		var has_s: bool = val_s.begins_with("wall")
		var has_e: bool = val_e.begins_with("wall")
		var has_w: bool = val_w.begins_with("wall")

		# Count wall neighbors on each axis
		var axis_x: int = int(has_e) + int(has_w)  # east-west neighbors
		var axis_z: int = int(has_n) + int(has_s)  # north-south neighbors

		# Adjacent to an opening = doorway frame → use intersection piece
		var near_opening: bool = val_n == "opening" or val_s == "opening" or val_e == "opening" or val_w == "opening"

		# Intersection = corner/T/+ junction, OR doorway frame (next to an opening)
		var is_intersection: bool = (axis_x > 0 and axis_z > 0) or near_opening

		var cell := Vector3i(pos.x, 0, pos.y)

		if is_intersection:
			# Dungeon Wall for corners/intersections (looks same on all sides)
			decoration_gridmap.set_cell_item(cell, dungeon_mid, 0)
			intersections += 1
		else:
			# Narrow Wall for straight sections — orient so textured face is inward
			# Narrow Wall: N/S faces are textured, E/W faces are dirt/back
			# So for a horizontal run (wall_h): textured N/S faces are correct → ori 0
			# For a vertical run (wall_v): need 90° rotation → ori 10
			#
			# Additionally, check which side has open space to face the nice side inward
			var open_n: bool = not grid.get(Vector2i(pos.x, pos.y - 1), "").begins_with("wall")
			var open_s: bool = not grid.get(Vector2i(pos.x, pos.y + 1), "").begins_with("wall")
			var open_e: bool = not grid.get(Vector2i(pos.x + 1, pos.y), "").begins_with("wall")
			var open_w: bool = not grid.get(Vector2i(pos.x - 1, pos.y), "").begins_with("wall")

			if val == "wall_h" or axis_x > 0:
				# Horizontal run — N/S faces show, check if we need to flip 180°
				# Default (0): textured side faces north (-Z)
				# Flipped (22): textured side faces south (+Z)
				if open_s and not open_n:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 22)  # face south
				else:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 0)   # face north
			else:
				# Vertical run — rotate 90° so textured side faces E or W
				# 270° (16): textured side faces east (+X)
				# 90° (10): textured side faces west (-X)
				if open_w and not open_e:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 10)  # face west
				else:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 16)  # face east
		walls_placed += 1

	# Rebuild navigation wall map so pathfinding works immediately
	_nav_rebuild()
	print("[BSP] Starter dungeon: %dx%d, %d walls (%d intersections, %d narrow)" % [dw, dh, walls_placed, intersections, walls_placed - intersections])

	# Debug map — shows wall types and orientations
	# I = intersection (Dungeon Wall), H = narrow horizontal, V = narrow vertical, O = opening, . = open
	print("[BSP] === DUNGEON MAP (I=intersection, H=narrow-h, V=narrow-v, O=opening, .=open) ===")
	for z in range(z1, z2 + 1):
		var row: String = "[Map z=%2d] " % z
		for x in range(x1, x2 + 1):
			var key := Vector2i(x, z)
			var val: String = grid.get(key, "")
			if val == "opening":
				row += "O "
			elif val.begins_with("wall"):
				# Check what was actually placed — intersection or narrow?
				var hn: bool = grid.get(Vector2i(x, z - 1), "").begins_with("wall")
				var hs: bool = grid.get(Vector2i(x, z + 1), "").begins_with("wall")
				var he: bool = grid.get(Vector2i(x + 1, z), "").begins_with("wall")
				var hw: bool = grid.get(Vector2i(x - 1, z), "").begins_with("wall")
				if (int(he) + int(hw)) > 0 and (int(hn) + int(hs)) > 0:
					row += "I "  # intersection
				elif val == "wall_h" or (int(he) + int(hw)) > 0:
					row += "H "  # narrow horizontal
				else:
					row += "V "  # narrow vertical
			else:
				row += ". "
		print(row)
	print("[BSP] === END MAP ===")


func _find_struct_by_name(display_name: String) -> int:
	for i in range(structures.size()):
		if structures[i].display_name == display_name:
			return i
	return -1


# ── Travelling Merchant ───────────────────────────────────────────────────────

func _show_merchant_dialog() -> void:
	var theme_a: String = PREFAB_THEMES[randi() % PREFAB_THEMES.size()]
	var theme_b: String = PREFAB_THEMES[randi() % PREFAB_THEMES.size()]
	var size_a := Vector2i(randi_range(PREFAB_MIN_SIZE, PREFAB_MAX_SIZE), randi_range(PREFAB_MIN_SIZE, PREFAB_MAX_SIZE))
	var size_b := Vector2i(randi_range(PREFAB_MIN_SIZE, PREFAB_MAX_SIZE), randi_range(PREFAB_MIN_SIZE, PREFAB_MAX_SIZE))

	var dialog := AcceptDialog.new()
	dialog.title = "Travelling Merchant"
	dialog.ok_button_text = "No thanks"

	var vbox := VBoxContainer.new()
	var msg := Label.new()
	msg.text = "A merchant offers two mystery prefab rooms for %dg each:" % MERCHANT_PRICE
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(msg)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER

	var btn_a := Button.new()
	btn_a.text = "Prefab Room A (%dx%d)" % [size_a.x, size_a.y]
	btn_a.custom_minimum_size = Vector2(160, 40)
	btn_a.pressed.connect(func():
		dialog.hide()
		dialog.queue_free()
		_purchase_prefab(theme_a, size_a.x, size_a.y)
	)
	hbox.add_child(btn_a)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(16, 0)
	hbox.add_child(gap)

	var btn_b := Button.new()
	btn_b.text = "Prefab Room B (%dx%d)" % [size_b.x, size_b.y]
	btn_b.custom_minimum_size = Vector2(160, 40)
	btn_b.pressed.connect(func():
		dialog.hide()
		dialog.queue_free()
		_purchase_prefab(theme_b, size_b.x, size_b.y)
	)
	hbox.add_child(btn_b)

	vbox.add_child(hbox)
	dialog.add_child(vbox)
	add_child(dialog)
	dialog.popup_centered(Vector2i(400, 0))
	Toast.notify("A travelling merchant has arrived!", _AWARD_ICON)


func _purchase_prefab(theme: String, w: int, h: int) -> void:
	if map.cash < MERCHANT_PRICE and not _freebuild:
		Toast.notify("Not enough gold! Need %dg" % MERCHANT_PRICE, _WARN_ICON)
		return
	if not _freebuild:
		map.cash -= MERCHANT_PRICE
		update_cash()

	_prefab_theme = theme
	_prefab_w = w
	_prefab_h = h
	_prefab_placing = true

	# Deselect any held structure
	if _placing:
		_set_placing(false)

	# Create outline preview
	_create_prefab_outline()
	Toast.notify("Place your %dx%d mystery room - click to build, right-click to cancel" % [w, h], _SAVE_ICON)
	print("[Merchant] Purchased prefab: %s (%dx%d)" % [theme, w, h])


func _create_prefab_outline() -> void:
	if _prefab_outline:
		_prefab_outline.queue_free()

	_prefab_outline = Node3D.new()
	add_child(_prefab_outline)

	# Build a flat colored rectangle showing the room footprint
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.8, 0.2, 0.35)  # green = valid
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Floor plane
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(_prefab_w, _prefab_h)
	var floor_inst := MeshInstance3D.new()
	floor_inst.mesh = plane_mesh
	floor_inst.material_override = mat
	floor_inst.position = Vector3(_prefab_w / 2.0 - 0.5, 0.05, _prefab_h / 2.0 - 0.5)
	_prefab_outline.add_child(floor_inst)

	# Border posts at corners (tall thin boxes)
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = Color(0.3, 1.0, 0.3, 0.7)
	post_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	post_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.1, 1.5, 0.1)
	for corner in [Vector3(-0.5, 0.75, -0.5), Vector3(_prefab_w - 0.5, 0.75, -0.5),
				   Vector3(-0.5, 0.75, _prefab_h - 0.5), Vector3(_prefab_w - 0.5, 0.75, _prefab_h - 0.5)]:
		var post := MeshInstance3D.new()
		post.mesh = post_mesh
		post.material_override = post_mat
		post.position = corner
		_prefab_outline.add_child(post)


func _update_prefab_outline(gx: int, gz: int) -> void:
	if not _prefab_outline:
		return
	_prefab_outline.position = Vector3(gx, 0, gz)

	# Check if placement is valid (no overlap with existing structures)
	_prefab_valid = _check_prefab_clear(gx, gz)

	# Update color: green = valid, red = blocked
	var color: Color = Color(0.2, 0.8, 0.2, 0.35) if _prefab_valid else Color(0.9, 0.2, 0.2, 0.35)
	var post_color: Color = Color(0.3, 1.0, 0.3, 0.7) if _prefab_valid else Color(1.0, 0.3, 0.3, 0.7)
	for child in _prefab_outline.get_children():
		if child is MeshInstance3D:
			var mat: StandardMaterial3D = child.material_override
			if child.mesh is PlaneMesh:
				mat.albedo_color = color
			else:
				mat.albedo_color = post_color


func _check_prefab_clear(gx: int, gz: int) -> bool:
	for dx in range(_prefab_w):
		for dz in range(_prefab_h):
			var x: int = gx + dx
			var z: int = gz + dz
			# Check all gridmap layers for existing structures
			if decoration_gridmap and decoration_gridmap.get_cell_item(Vector3i(x, 0, z)) != -1:
				return false
			if items_gridmap and items_gridmap.get_cell_item(Vector3i(x, 0, z)) != -1:
				return false
			if gridmap and gridmap.get_cell_item(Vector3i(x, 0, z)) != -1:
				return false
			if Vector3i(x, 0, z) in _animated_instances:
				return false
	return true


func _place_prefab(gx: int, gz: int) -> void:
	if not _prefab_valid:
		Toast.notify("Can't place here - something is in the way!", _WARN_ICON)
		return

	var dungeon_idx: int = _find_struct_by_name("Dungeon Wall")
	var narrow_idx: int = _find_struct_by_name("Narrow Wall")
	if dungeon_idx == -1 or narrow_idx == -1:
		Toast.notify("Missing wall structures!", _WARN_ICON)
		return

	var dungeon_mid: int = _struct_mesh_id[dungeon_idx]
	var narrow_mid: int = _struct_mesh_id[narrow_idx]
	var x1: int = gx
	var z1: int = gz
	var x2: int = gx + _prefab_w - 1
	var z2: int = gz + _prefab_h - 1

	# Place walls on perimeter
	for x in range(x1, x2 + 1):
		for z in range(z1, z2 + 1):
			var is_border: bool = (x == x1 or x == x2 or z == z1 or z == z2)
			if not is_border:
				continue

			var is_corner: bool = (x == x1 or x == x2) and (z == z1 or z == z2)
			# Check for T-junctions on edges
			var has_h_neighbor: bool = false
			var has_v_neighbor: bool = false
			if x == x1 or x == x2:
				has_v_neighbor = true
			if z == z1 or z == z2:
				has_h_neighbor = true

			var cell := Vector3i(x, 0, z)
			if is_corner:
				decoration_gridmap.set_cell_item(cell, dungeon_mid, 0)
			elif z == z1 or z == z2:
				# Horizontal wall — match BSP-confirmed orientations
				# Bottom wall (z == z2): orientation 22
				# Top wall (z == z1): orientation 0
				if z == z2:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 22)
				else:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 0)
			else:
				# Vertical wall — match BSP-confirmed orientations
				# Left wall (x == x1): orientation 10
				# Right wall (x == x2): orientation 16
				if x == x1:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 10)
				else:
					decoration_gridmap.set_cell_item(cell, narrow_mid, 16)

	# Place themed items inside the room (interior = 1 tile in from walls)
	var interior_x1: int = x1 + 1
	var interior_z1: int = z1 + 1
	var interior_x2: int = x2 - 1
	var interior_z2: int = z2 - 1
	var interior_w: int = interior_x2 - interior_x1 + 1
	var interior_h: int = interior_z2 - interior_z1 + 1

	if interior_w > 0 and interior_h > 0:
		var item_names: Array = PREFAB_ITEMS.get(_prefab_theme, [])
		# Place items at random interior positions — roughly 1 per 4-6 tiles
		var item_count: int = clampi((interior_w * interior_h) / 5, 2, item_names.size() * 3)
		var used_positions: Dictionary = {}  # avoid stacking

		for _i in range(item_count):
			var name: String = item_names[randi() % item_names.size()]
			var s_idx: int = _find_struct_by_name(name)
			if s_idx == -1:
				continue

			# Find a random unused interior position
			var attempts: int = 0
			var px: int = 0
			var pz: int = 0
			while attempts < 20:
				px = randi_range(interior_x1, interior_x2)
				pz = randi_range(interior_z1, interior_z2)
				if Vector2i(px, pz) not in used_positions:
					break
				attempts += 1
			if attempts >= 20:
				continue
			used_positions[Vector2i(px, pz)] = true

			var s: Structure = structures[s_idx]
			var pos := Vector3i(px, 0, pz)

			if _is_animated_structure(s):
				_spawn_animated(s, s_idx, pos, 0)
			else:
				var target_map: GridMap = items_gridmap if s.layer == 2 else decoration_gridmap
				target_map.set_cell_item(pos, _struct_mesh_id[s_idx], 0)

	# Rebuild nav map
	_nav_rebuild()

	# Clean up placement mode
	_prefab_placing = false
	if _prefab_outline:
		_prefab_outline.queue_free()
		_prefab_outline = null

	Toast.notify("Mystery room placed! It's a %s!" % _prefab_theme, _AWARD_ICON)
	print("[Merchant] Prefab placed: %s (%dx%d) at (%d, %d)" % [_prefab_theme, _prefab_w, _prefab_h, gx, gz])


func _cancel_prefab() -> void:
	_prefab_placing = false
	if _prefab_outline:
		_prefab_outline.queue_free()
		_prefab_outline = null
	# Refund
	if not _freebuild:
		map.cash += MERCHANT_PRICE
		update_cash()
	Toast.notify("Prefab cancelled - gold refunded", _WARN_ICON)


func _bsp_node(bx1: int, bz1: int, bx2: int, bz2: int) -> Dictionary:
	return { "x1": bx1, "z1": bz1, "x2": bx2, "z2": bz2,
			 "left": {}, "right": {}, "split_v": false, "split_pos": 0, "is_leaf": true }


func _bsp_split(node: Dictionary, rng: RandomNumberGenerator) -> void:
	var w: int = node["x2"] - node["x1"] + 1
	var h: int = node["z2"] - node["z1"] + 1

	var can_v: bool = w >= BSP_MIN_SPLIT
	var can_h: bool = h >= BSP_MIN_SPLIT

	if not can_v and not can_h:
		return  # leaf — room fits here

	# Bias split toward the longer axis
	var split_v: bool
	if can_v and can_h:
		split_v = rng.randf() < (0.7 if w > h else (0.3 if h > w else 0.5))
	else:
		split_v = can_v

	node["split_v"] = split_v
	node["is_leaf"] = false

	if split_v:
		var min_x: int = node["x1"] + BSP_MIN_PARTITION - 1  # left half width >= 4
		var max_x: int = node["x2"] - BSP_MIN_PARTITION + 1  # right half width >= 4
		var sx: int = rng.randi_range(min_x, max_x)
		node["split_pos"] = sx
		node["left"]  = _bsp_node(node["x1"], node["z1"], sx, node["z2"])
		node["right"] = _bsp_node(sx, node["z1"], node["x2"], node["z2"])
	else:
		var min_z: int = node["z1"] + BSP_MIN_PARTITION - 1
		var max_z: int = node["z2"] - BSP_MIN_PARTITION + 1
		var sz: int = rng.randi_range(min_z, max_z)
		node["split_pos"] = sz
		node["left"]  = _bsp_node(node["x1"], node["z1"], node["x2"], sz)
		node["right"] = _bsp_node(node["x1"], sz, node["x2"], node["z2"])

	_bsp_split(node["left"], rng)
	_bsp_split(node["right"], rng)


func _bsp_mark_walls(node: Dictionary, grid: Dictionary) -> void:
	if node["is_leaf"]:
		# Mark perimeter of this room as walls with direction
		# "wall_h" = horizontal wall (runs along X, blocks Z movement) → orientation 0
		# "wall_v" = vertical wall (runs along Z, blocks X movement) → orientation 10 (90°)
		for x in range(node["x1"], node["x2"] + 1):
			grid[Vector2i(x, node["z1"])] = "wall_h"  # top edge
			grid[Vector2i(x, node["z2"])] = "wall_h"  # bottom edge
		for z in range(node["z1"] + 1, node["z2"]):
			grid[Vector2i(node["x1"], z)] = "wall_v"  # left edge
			grid[Vector2i(node["x2"], z)] = "wall_v"  # right edge
	else:
		_bsp_mark_walls(node["left"], grid)
		_bsp_mark_walls(node["right"], grid)


func _bsp_mark_openings(node: Dictionary, grid: Dictionary, rng: RandomNumberGenerator) -> void:
	if node["is_leaf"]:
		return

	# Place one opening along this node's split wall.
	# The opening must NOT be at a corner (where perpendicular walls cross).
	# Find valid positions: on the split line, between the node's bounds,
	# where the cell has wall neighbors only along the split axis.
	var sp: int = node["split_pos"]
	var candidates: Array[Vector2i] = []

	if node["split_v"]:
		# Vertical split at column sp — candidates along z
		for z in range(node["z1"] + 1, node["z2"]):
			var pos := Vector2i(sp, z)
			# Skip if this position has perpendicular walls (it's a corner/intersection)
			var val_e: String = grid.get(Vector2i(sp + 1, z), "")
			var val_w: String = grid.get(Vector2i(sp - 1, z), "")
			if not val_e.begins_with("wall") and not val_w.begins_with("wall"):
				candidates.append(pos)
	else:
		# Horizontal split at row sp — candidates along x
		for x in range(node["x1"] + 1, node["x2"]):
			var pos := Vector2i(x, sp)
			# Skip if this position has perpendicular walls (it's a corner/intersection)
			var val_n: String = grid.get(Vector2i(x, sp - 1), "")
			var val_s: String = grid.get(Vector2i(x, sp + 1), "")
			if not val_n.begins_with("wall") and not val_s.begins_with("wall"):
				candidates.append(pos)

	if not candidates.is_empty():
		var pick: Vector2i = candidates[rng.randi_range(0, candidates.size() - 1)]
		grid[pick] = "opening"

	_bsp_mark_openings(node["left"], grid, rng)
	_bsp_mark_openings(node["right"], grid, rng)


# Rotates the 'cursor' 90 degrees

func action_rotate():
	if _is_over_picker():
		return
	if Input.is_action_just_pressed("rotate"):
		selector.rotate_y(deg_to_rad(90))

		Audio.play("sounds/rotate.ogg", -30)


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_F:
			_freebuild = not _freebuild
			if cash_display:
				cash_display.modulate = _FREEBUILD_COLOR if _freebuild else _normal_cash_color
			update_cash()  # refresh the display
			var mode_str: String = "ON" if _freebuild else "OFF"
			Toast.notify("Freebuild: " + mode_str, _SAVE_ICON)
			print("[Builder] Freebuild %s" % mode_str)
		elif event.physical_keycode == KEY_P:
			if _max_palette_count > 1:
				_cycle_global_palette()


# Select a structure by index (called from BuildingPicker signal)

func select_structure(new_index: int) -> void:
	index = new_index
	_pending_variation_idx = 0
	_pending_variation_tex = null
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

	# Reset texture variation to base when switching structures
	_pending_mid = _struct_mesh_id[index] if index < _struct_mesh_id.size() else -1

func update_cash():
	cash_display.text = str(map.cash) + "g"

	if _freebuild:
		cash_display.add_theme_color_override("font_color", _FREEBUILD_COLOR)
		return

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

		# Travelling merchant — chance to appear mid-week (day 3 of each week)
		if Global.current_day % 7 == 3 and not _merchant_offered_this_week:
			_merchant_offered_this_week = true
			if randf() <= MERCHANT_CHANCE:
				_show_merchant_dialog()
		if Global.current_day % 7 == 0:
			_merchant_offered_this_week = false  # reset for new week


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
		date_display.text = "Year %d - Month %d - Week %d - Day %d" % [year, month, week, day]
	# Update week-progress clock (5 frames over 7 days)
	if week_clock:
		var frame := int(float(d % 7) / 7.0 * 5.0)
		week_clock.texture = _CLOCK_TEXTURES[clampi(frame, 0, 4)]

# ── Dungeon rating & adventurer visit ─────────────────────────────────────────

# Get the loot chance for a structure by matching its display name
func _get_loot_chance(display_name: String) -> float:
	# Required items are never looted
	if display_name == REQUIRED_TROPHY_NAME or display_name == REQUIRED_STAIRS_NAME:
		return 0.0
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
	_current_party_type = _next_party_type if _next_party_type >= 0 else randi() % PARTY_TYPE_COUNT
	_current_party_name = _next_party_name if _next_party_name != "" else _random_party_name(_current_party_type)
	_roll_next_party()


func _roll_next_party() -> void:
	_next_party_type = randi() % PARTY_TYPE_COUNT
	_next_party_name = _random_party_name(_next_party_type)
	_update_next_party_display()


func _random_party_name(party_type: int) -> String:
	match party_type:
		PartyType.WARRIORS:    return WARRIOR_NAMES[randi() % WARRIOR_NAMES.size()]
		PartyType.ROGUES:      return ROGUE_NAMES[randi() % ROGUE_NAMES.size()]
		PartyType.SCHOLARS:    return SCHOLAR_NAMES[randi() % SCHOLAR_NAMES.size()]
		PartyType.PALADINS:    return PALADIN_NAMES[randi() % PALADIN_NAMES.size()]
		PartyType.RAIDERS:     return RAIDER_NAMES[randi() % RAIDER_NAMES.size()]
		PartyType.MYSTICS:     return MYSTIC_NAMES[randi() % MYSTIC_NAMES.size()]
		PartyType.MERCENARIES: return MERCENARY_NAMES[randi() % MERCENARY_NAMES.size()]
		PartyType.RAGTAG:      return RAGTAG_NAMES[randi() % RAGTAG_NAMES.size()]
	return "Unknown Party"


func _party_type_label(party_type: int) -> String:
	match party_type:
		PartyType.WARRIORS:    return "Warriors"
		PartyType.ROGUES:      return "Rogues"
		PartyType.SCHOLARS:    return "Scholars"
		PartyType.PALADINS:    return "Paladins"
		PartyType.RAIDERS:     return "Raiders"
		PartyType.MYSTICS:     return "Mystics"
		PartyType.MERCENARIES: return "Mercenaries"
		PartyType.RAGTAG:      return "Rag-tag"
	return "Adventurers"


func _update_next_party_display() -> void:
	if _next_party_label == null:
		return
	if _next_party_type >= 0 and _next_party_name != "":
		_next_party_label.text = "Next:  %s (%s)" % [_next_party_name, _party_type_label(_next_party_type)]
	else:
		_next_party_label.text = ""

# Texture variation index per party type (0=base, 1=var-a, 2=var-b, 3=var-c, 4=var-d)
const PARTY_PALETTE: Dictionary = {
	PartyType.WARRIORS:    0,  # base colors
	PartyType.ROGUES:      0,  # base colors
	PartyType.SCHOLARS:    0,  # base colors
	PartyType.PALADINS:    1,  # variation-a
	PartyType.RAIDERS:     2,  # variation-b
	PartyType.MYSTICS:     3,  # variation-c
	PartyType.MERCENARIES: 4,  # variation-d
	PartyType.RAGTAG:     -1,  # -1 = random per member
}

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
			# Inventory all items inside this room to determine theme
			var item_names: Array[String] = []
			for rcell in region:
				# Static items (check multiple Y levels for stacked items)
				if items_gridmap:
					for y in range(0, 5):
						var check := Vector3i(rcell.x, y, rcell.z)
						var mid: int = items_gridmap.get_cell_item(check)
						if mid != -1 and mid in _item_id_to_struct:
							item_names.append(structures[_item_id_to_struct[mid]].display_name)
				# Animated items (chests, characters, traps)
				if rcell in _animated_instances:
					var s_idx: int = _animated_struct_idx.get(rcell, -1)
					if s_idx != -1:
						item_names.append(structures[s_idx].display_name)

			# Check for treasure (legacy flag)
			var has_treasure: bool = false
			for iname in item_names:
				if iname.contains("Chest") or iname.contains("Coin") or iname.contains("Trophy"):
					has_treasure = true
					break

			# Classify room theme — pick the theme with the most matching items
			var best_theme: String = ""
			var best_count: int = 0
			for theme_name in ROOM_THEMES:
				var theme: Dictionary = ROOM_THEMES[theme_name]
				var count: int = 0
				for iname in item_names:
					for keyword in theme.keywords:
						if iname.contains(keyword):
							count += 1
							break  # one item matches one keyword, move to next item
				if count >= theme.min and count > best_count:
					best_count = count
					best_theme = theme_name

			rooms.append({
				"size": region.size(),
				"enclosed_pct": enclosed_pct,
				"has_treasure": has_treasure,
				"theme": best_theme,
				"theme_count": best_count,
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
		func(): Toast.notify(MILESTONE_DEFS[key], _AWARD_ICON))


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

	# Room detection — enclosed rooms grant bonus points + theme bonuses
	var rooms: Array = _detect_rooms()
	var room_points: int = 0
	var treasure_rooms: int = 0
	var themed_rooms: Dictionary = {}  # theme_name -> count
	var affinities: Dictionary = PARTY_THEME_AFFINITY.get(_current_party_type, {})

	for room in rooms:
		room_points += ROOM_POINTS
		if room.get("has_treasure", false):
			room_points += TREASURE_ROOM_BONUS
			treasure_rooms += 1

		# Theme bonus — multiplied by party affinity
		var theme: String = room.get("theme", "")
		if theme != "":
			themed_rooms[theme] = themed_rooms.get(theme, 0) + 1
			var theme_bonus: int = ROOM_THEMES[theme].bonus
			var affinity: float = affinities.get(theme, 1.0)
			room_points += int(theme_bonus * affinity)

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
		"themed_rooms":      themed_rooms,
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

	# Check if required items are placed
	if not _has_stairs:
		Toast.notify("Place Dungeon Stairs [Req] - adventurers need an entrance!", _WARN_ICON)
		return
	if not _has_trophy:
		Toast.notify("Place the Trophy [Req] - adventurers need a goal!", _WARN_ICON)
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

var _selected_duration: float = 30.0  # default intermission duration

func _show_visit_announcement() -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Adventurers Approaching!"
	var type_label: String = _party_type_label(_current_party_type)

	# Build custom content with duration picker
	var vbox := VBoxContainer.new()
	var msg := Label.new()
	msg.text = "%s (%s) are arriving to explore your dungeon!" % [_current_party_name, type_label]
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(msg)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)

	var dur_label := Label.new()
	dur_label.text = "How long should they explore?"
	vbox.add_child(dur_label)

	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	var durations := [["30 sec", 30.0], ["1 min", 60.0], ["2 min", 120.0]]
	_selected_duration = 30.0

	for entry in durations:
		var btn := Button.new()
		btn.text = entry[0]
		btn.custom_minimum_size = Vector2(80, 32)
		btn.toggle_mode = true
		btn.button_pressed = (entry[1] == 30.0)  # default selection
		btn.pressed.connect(func():
			_selected_duration = entry[1]
			# Unpress other buttons
			for child in hbox.get_children():
				if child is Button and child != btn:
					child.button_pressed = false
			btn.button_pressed = true
		)
		hbox.add_child(btn)
	vbox.add_child(hbox)

	dialog.add_child(vbox)
	dialog.ok_button_text = "Let them in!"
	dialog.confirmed.connect(_start_intermission)
	dialog.canceled.connect(_start_intermission)
	add_child(dialog)
	dialog.popup_centered(Vector2i(320, 0))

func _start_intermission() -> void:
	_intermission_active = true
	_intermission_timer = 0.0

	# Release UI focus so Space/Enter can't re-trigger toolbar buttons
	var focused := get_viewport().gui_get_focus_owner()
	if focused:
		focused.release_focus()

	# Block camera input during intermission
	if view_node:
		view_node.block_input = true

	# Save current camera state
	if view_node:
		_saved_cam_pos = view_node.camera_position
		_saved_cam_rot = view_node.camera_rotation
		_saved_cam_zoom = view_node.zoom

	# Dim the dungeon — adventurers explore by torchlight
	_dim_dungeon_lights()

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

	# Try to start the new walk-through intermission
	if _has_stairs:
		_intermission_node = Intermission.new()
		_intermission_node.duration = _selected_duration
		add_child(_intermission_node)
		# Determine palette for this party type
		var palette_idx: int = PARTY_PALETTE.get(_current_party_type, 0)
		var palette_tex: Texture2D = null
		if palette_idx > 0:
			# Load variation texture from the dungeon character model's texture dir
			var letters := ["a", "b", "c", "d"]
			if palette_idx - 1 < letters.size():
				var path: String = "res://models/Mini Dungeon/Models/Textures/variation-%s.png" % letters[palette_idx - 1]
				if ResourceLoader.exists(path):
					palette_tex = load(path)

		var ok: bool = _intermission_node.setup({
			"nav_walls": _nav_walls,
			"nav_passable": _nav_passable,
			"items_gridmap": items_gridmap,
			"animated_instances": _animated_instances,
			"animated_struct_idx": _animated_struct_idx,
			"structures": structures,
			"item_id_to_struct": _item_id_to_struct,
			"view_node": view_node,
			"party_type": _current_party_type,
			"stairs_pos": _stairs_position,
			"trophy_pos": _trophy_position,
			"loot_chances": LOOT_CHANCES,
			"loot_mult": PARTY_LOOT_MULT.get(_current_party_type, 1.0),
			"palette_tex": palette_tex,
			"palette_idx": palette_idx,
		})
		if ok:
			_intermission_node.finished.connect(_end_intermission)
			print("[Builder] Walk-through intermission started")
		else:
			# Fallback to orbit if pathfinding fails
			print("[Builder] Walk-through failed — falling back to orbit")
			_intermission_node.queue_free()
			_intermission_node = null
			_start_orbit_fallback()
	else:
		# No stairs — use old orbit system
		_start_orbit_fallback()


func _dim_dungeon_lights() -> void:
	# Find the Sun and Environment if we haven't cached them yet
	if _sun_node == null:
		_sun_node = get_parent().get_node_or_null("Sun") as DirectionalLight3D
	if _env == null:
		var cam := get_parent().get_node_or_null("View/Camera") as Camera3D
		if cam and cam.environment:
			_env = cam.environment

	# Save current values and dim — underground by torchlight
	if _sun_node:
		_saved_sun_energy = _sun_node.light_energy
		_sun_node.light_energy = 0.0  # no sunlight underground
	if _env:
		_saved_ambient_energy = _env.ambient_light_energy
		_env.ambient_light_energy = 0.03  # bare minimum so geometry is faintly visible


func _restore_dungeon_lights() -> void:
	if _sun_node:
		_sun_node.light_energy = _saved_sun_energy
	if _env:
		_env.ambient_light_energy = _saved_ambient_energy


func _start_orbit_fallback() -> void:
	_orbit_center = _compute_dungeon_center()
	if view_node:
		view_node.camera_position = _orbit_center
		view_node.zoom = 25.0


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

	if _intermission_node != null:
		# Walk-through handles its own timing and emits finished
		_intermission_node.process_tick(delta)
	else:
		# OLD INTERMISSION — orbit camera around dungeon center
		if view_node:
			var orbit_speed: float = 36.0
			view_node.camera_rotation.y += orbit_speed * delta
		if _intermission_timer >= _selected_duration:
			_end_intermission()


var _last_looted_items: Array = []  # saved before intermission node is freed

func _end_intermission() -> void:
	_intermission_active = false

	# Grab looted items BEFORE freeing the intermission node
	_last_looted_items.clear()
	if _intermission_node != null and is_instance_valid(_intermission_node):
		_last_looted_items = _intermission_node.looted_items.duplicate(true)

	# Clean up walk-through node
	if _intermission_node != null:
		if is_instance_valid(_intermission_node):
			_intermission_node.queue_free()
		_intermission_node = null

	# Restore dungeon lighting
	_restore_dungeon_lights()

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

	# Loot was rolled LIVE during the walk-through — items already vanished
	var loot: int = 0
	var looted_counts: Dictionary = {}   # display_name -> count

	for entry in _last_looted_items:
		loot += entry.price
		looted_counts[entry.name] = looted_counts.get(entry.name, 0) + 1
		# Grid items were already removed during intermission
		# Animated instances were hidden — now fully remove them
		if entry.type == "anim":
			_remove_animated(entry.cell)

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
		star_str += "*"
	for i in range(5 - stars):
		star_str += "-"

	# Build loot summary (e.g. "2× Chest, 3× Coin, 1× Sword")
	var loot_parts: Array = []
	for item_name in looted_counts:
		loot_parts.append("%dx %s" % [looted_counts[item_name], item_name])
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
	stats["next_party_name"] = _next_party_name if _next_party_name != "" else "-"
	stats["next_party_type"] = _party_type_label(_next_party_type) if _next_party_type >= 0 else "-"
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
	_update_next_party_display()
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
	_has_stairs = false
	_stairs_position = Vector3i(-999, -999, -999)
	_has_trophy = false
	_trophy_position = Vector3i(-999, -999, -999)
	for cell in map.structures:
		var cy: int = cell.pos_y if cell.pos_y != 0 else 0
		var gpos := Vector3i(cell.position.x, cy, cell.position.y)
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
		# Detect required items on load
		if cell.layer == 2 and cell.structure in _item_id_to_struct:
			var s_idx: int = _item_id_to_struct[cell.structure]
			if s_idx < structures.size():
				if structures[s_idx].display_name == REQUIRED_STAIRS_NAME:
					_stairs_position = gpos
					_has_stairs = true
				elif structures[s_idx].display_name == REQUIRED_TROPHY_NAME:
					_trophy_position = gpos
					_has_trophy = true
		if cell.layer == 0 and terrain_gridmap and cy == 0:
			terrain_gridmap.set_cell_item(Vector3i(cell.position.x, 0, cell.position.y), -1)
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
	_nav_rebuild()
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
		ds.pos_y        = cell.y
		ds.orientation  = gridmap.get_cell_item_orientation(cell)
		ds.structure    = gridmap.get_cell_item(cell)
		ds.layer        = 0
		map.structures.append(ds)
	if decoration_gridmap:
		for cell in decoration_gridmap.get_used_cells():
			var ds := DataStructure.new()
			ds.position    = Vector2i(cell.x, cell.z)
			ds.pos_y       = cell.y
			ds.orientation = decoration_gridmap.get_cell_item_orientation(cell)
			ds.structure   = decoration_gridmap.get_cell_item(cell)
			ds.layer       = 1
			map.structures.append(ds)
	if items_gridmap:
		for cell in items_gridmap.get_used_cells():
			var ds := DataStructure.new()
			ds.position    = Vector2i(cell.x, cell.z)
			ds.pos_y       = cell.y
			ds.orientation = items_gridmap.get_cell_item_orientation(cell)
			ds.structure   = items_gridmap.get_cell_item(cell)
			ds.layer       = 2
			map.structures.append(ds)
	# Animated scene instances (layer 3 = animated, structure = struct index)
	for pos in _animated_instances:
		var ds := DataStructure.new()
		ds.position    = Vector2i(pos.x, pos.z)
		ds.pos_y       = pos.y
		ds.orientation = _animated_orientation.get(pos, 0)
		ds.structure   = _animated_struct_idx.get(pos, 0)
		ds.layer       = 3
		map.structures.append(ds)
	if OS.has_feature("web"):
		var ok: bool = Global.web_save(map)
		if ok:
			Toast.notify("Game saved!", _SAVE_ICON)
		else:
			Toast.notify("Save FAILED - localStorage unavailable!", _SAVE_ICON)
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
