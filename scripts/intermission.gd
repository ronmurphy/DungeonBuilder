extends Node3D
class_name Intermission

## Adventurer walk-through intermission using AStar3D pathfinding.
## Spawns a party of adventurers at the Dungeon Stairs, walks them to the
## farthest reachable point, then back. Camera follows the lead adventurer.
## Duration: 30 seconds max (one in-game day).

signal finished  # emitted when the intermission is done

var duration: float = 30.0  # set by builder before setup
const MIN_WALK_SPEED: float = 2.5    # minimum tiles per second (small dungeons)
const MAX_WALK_SPEED: float = 12.0   # maximum tiles per second (huge dungeons)
const INTERACTION_PAUSE: float = 1.5  # seconds to pause at a point of interest
var _walk_speed: float = 3.0         # actual speed — scaled to path length at setup
const PARTY_SPACING: float = 0.6      # distance between party members along path
const CAMERA_OFFSET: Vector3 = Vector3(0, 4, 4)  # camera offset behind/above leader
const CAMERA_ZOOM: float = 20.0

# Party model scenes — picked based on party type
const WARRIOR_MODELS: Array[String] = [
	"res://models/Mini Arena/Models/GLB format/character-soldier.glb",
	"res://models/Mini Arena/Models/GLB format/character-soldier.glb",
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
]
const ROGUE_MODELS: Array[String] = [
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
]
const SCHOLAR_MODELS: Array[String] = [
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
	"res://models/Mini Arena/Models/GLB format/character-soldier.glb",
	"res://models/Mini Dungeon/Models/GLB format/character-human.glb",
]

# Character animations
const WALK_ANIM: String = "walk"
const IDLE_ANIM: String = "idle"
const PICKUP_ANIM: String = "pick-up"
const JUMP_ANIM: String = "jump"     # used for trap reaction
const DIE_ANIM: String = "die"       # used for trap casualty (fun visual)

# Lighting constants
const COLUMN_LIGHT_COLOR: Color = Color(1.0, 0.75, 0.4)   # warm torch glow
const COLUMN_LIGHT_ENERGY: float = 3.5
const COLUMN_LIGHT_RANGE: float = 6.0
const COLUMN_LIGHT_ATTENUATION: float = 1.2
const TORCH_LIGHT_COLOR: Color = Color(1.0, 0.85, 0.5)    # party torch — brighter, hero light
const TORCH_LIGHT_ENERGY: float = 4.0
const TORCH_LIGHT_RANGE: float = 8.0
const COLUMN_NAMES: Array[String] = ["Dungeon Column", "Arena Column", "Damaged Column"]

# Internal state
var _timer: float = 0.0
var _active: bool = false
var _party: Array = []               # Array of { node: Node3D, anim: AnimationPlayer }
var _path_points: PackedVector3Array  # world-space waypoints (outbound + return)
var _path_index: int = 0             # current waypoint the leader is walking toward
var _leader_pos: Vector3             # current interpolated position of the lead adventurer
var _path_progress: float = 0.0      # 0-1 progress between current and next waypoint
var _paused: bool = false            # true while interacting with a point of interest
var _pause_timer: float = 0.0

var _view_node: Node3D               # camera pivot
var _poi_set: Dictionary = {}        # Vector3i -> String (point of interest type: "chest", "trap", "monster")
var _visited_pois: Dictionary = {}   # Vector3i -> true (already interacted with)
var _party_type: int = 0             # 0=Warriors, 1=Rogues, 2=Scholars

# Lighting
var _column_lights: Array[OmniLight3D] = []  # lights placed at columns
var _torch_light: OmniLight3D = null         # light carried by middle party member

# Contact-based looting — live loot rolls as the party walks past items
const LOOT_CONTACT_RADIUS: float = 1.5       # tiles away from path to count as "contacted"
var contacted_items: Dictionary = {}          # Vector3i -> true (already scanned, avoid re-rolling)
var looted_items: Array = []                  # Array of { "cell": Vector3i, "type": "grid"|"anim", "name": String, "price": int }
var _loot_chances: Dictionary = {}            # display_name keyword -> chance (passed from builder)
var _loot_mult: float = 1.0                   # party type multiplier

# References passed in from builder
var _nav_walls: Dictionary      # Vector2i -> String  (solid walls from builder)
var _nav_passable: Dictionary   # Vector2i -> String  (passable openings from builder)
var _items_gridmap: GridMap
var _animated_instances: Dictionary
var _animated_struct_idx: Dictionary
var _structures: Array[Structure]
var _item_id_to_struct: Dictionary


func setup(params: Dictionary) -> bool:
	_nav_walls = params.get("nav_walls", {})
	_nav_passable = params.get("nav_passable", {})
	_items_gridmap = params.get("items_gridmap")
	_animated_instances = params.get("animated_instances", {})
	_animated_struct_idx = params.get("animated_struct_idx", {})
	_structures = params.get("structures", [])
	_item_id_to_struct = params.get("item_id_to_struct", {})
	_view_node = params.get("view_node")
	var party_type: int = params.get("party_type", 0)
	_party_type = party_type
	_loot_chances = params.get("loot_chances", {})
	_loot_mult = params.get("loot_mult", 1.0)
	var stairs_pos = params.get("stairs_pos")  # Vector3i or null
	var trophy_pos = params.get("trophy_pos")  # Vector3i or null

	if stairs_pos == null:
		print("[Intermission] No stairs position provided")
		return false
	if trophy_pos == null:
		print("[Intermission] No trophy position provided")
		return false

	print("[Intermission] Setup — stairs at %s, trophy at %s, party type %d" % [str(stairs_pos), str(trophy_pos), party_type])

	# Build the A* graph from the builder's pre-built wall map.
	# The wall map (_nav_walls / _nav_passable) is maintained live by the
	# builder on every build/demolish, so it always has the complete picture.
	# Every cell within the bounding box is walkable UNLESS it's a solid wall.
	var astar := AStar3D.new()
	var walkable: Dictionary = {}  # Vector3i -> point_id

	# Compute bounding box from ALL wall + passable positions + items + animated
	var bounds_min_x: int = stairs_pos.x
	var bounds_max_x: int = stairs_pos.x
	var bounds_min_z: int = stairs_pos.z
	var bounds_max_z: int = stairs_pos.z
	for xz in _nav_walls:
		bounds_min_x = mini(bounds_min_x, xz.x)
		bounds_max_x = maxi(bounds_max_x, xz.x)
		bounds_min_z = mini(bounds_min_z, xz.y)
		bounds_max_z = maxi(bounds_max_z, xz.y)
	for xz in _nav_passable:
		bounds_min_x = mini(bounds_min_x, xz.x)
		bounds_max_x = maxi(bounds_max_x, xz.x)
		bounds_min_z = mini(bounds_min_z, xz.y)
		bounds_max_z = maxi(bounds_max_z, xz.y)
	for pos in _animated_instances:
		bounds_min_x = mini(bounds_min_x, pos.x)
		bounds_max_x = maxi(bounds_max_x, pos.x)
		bounds_min_z = mini(bounds_min_z, pos.z)
		bounds_max_z = maxi(bounds_max_z, pos.z)
	if _items_gridmap:
		for cell in _items_gridmap.get_used_cells():
			bounds_min_x = mini(bounds_min_x, cell.x)
			bounds_max_x = maxi(bounds_max_x, cell.x)
			bounds_min_z = mini(bounds_min_z, cell.z)
			bounds_max_z = maxi(bounds_max_z, cell.z)
	# Add margin around the dungeon
	bounds_min_x -= 2
	bounds_max_x += 2
	bounds_min_z -= 2
	bounds_max_z += 2

	# Every cell within bounds that is NOT a solid wall → walkable
	var point_id: int = 0
	for x in range(bounds_min_x, bounds_max_x + 1):
		for z in range(bounds_min_z, bounds_max_z + 1):
			var xz := Vector2i(x, z)
			if xz in _nav_walls:
				continue  # solid wall — blocked
			var cell := Vector3i(x, 0, z)
			walkable[cell] = point_id
			astar.add_point(point_id, Vector3(x, 0, z))
			point_id += 1

	print("[Intermission] Nav walls: %d, Passable: %d, Bounds: (%d,%d)-(%d,%d), Walkable: %d" % [_nav_walls.size(), _nav_passable.size(), bounds_min_x, bounds_min_z, bounds_max_x, bounds_max_z, walkable.size()])

	# Debug: print a grid map of the dungeon layout
	print("[Intermission] === DUNGEON MAP (S=stairs, T=trophy, W=wall, O=opening, .=open) ===")
	for z in range(bounds_min_z, bounds_max_z + 1):
		var row: String = ""
		for x in range(bounds_min_x, bounds_max_x + 1):
			var xz := Vector2i(x, z)
			if x == stairs_pos.x and z == stairs_pos.z:
				row += "S "
			elif x == trophy_pos.x and z == trophy_pos.z:
				row += "T "
			elif xz in _nav_walls:
				row += "W "
			elif xz in _nav_passable:
				row += "O "
			else:
				row += ". "
		print("[Map z=%2d] %s" % [z, row])
	print("[Intermission] === END MAP ===")

	# Connect cardinal neighbors
	for cell in walkable:
		var pid: int = walkable[cell]
		for neighbor in _cardinal_neighbors(cell):
			if neighbor in walkable:
				var nid: int = walkable[neighbor]
				if not astar.are_points_connected(pid, nid):
					astar.connect_points(pid, nid)

	# Ensure stairs and trophy are in the walkable graph
	var stairs_v3i := Vector3i(stairs_pos.x, 0, stairs_pos.z)
	var trophy_v3i := Vector3i(trophy_pos.x, 0, trophy_pos.z)

	for key_cell in [stairs_v3i, trophy_v3i]:
		if key_cell not in walkable:
			walkable[key_cell] = point_id
			astar.add_point(point_id, Vector3(key_cell.x, 0, key_cell.z))
			point_id += 1
			for neighbor in _cardinal_neighbors(key_cell):
				if neighbor in walkable:
					var nid: int = walkable[neighbor]
					if not astar.are_points_connected(walkable[key_cell], nid):
						astar.connect_points(walkable[key_cell], nid)

	var stairs_id: int = walkable[stairs_v3i]
	var trophy_id: int = walkable[trophy_v3i]

	# Debug: show connectivity info
	var stairs_conns := astar.get_point_connections(stairs_id)
	var trophy_conns := astar.get_point_connections(trophy_id)
	print("[Intermission] Stairs at %s — %d connections" % [str(stairs_v3i), stairs_conns.size()])
	print("[Intermission] Trophy at %s — %d connections" % [str(trophy_v3i), trophy_conns.size()])

	# If either has zero connections, try to use an adjacent walkable tile
	if stairs_conns.is_empty():
		for neighbor in _cardinal_neighbors(stairs_v3i):
			if neighbor in walkable and not astar.get_point_connections(walkable[neighbor]).is_empty():
				print("[Intermission] Stairs has no connections — using neighbor %s" % str(neighbor))
				stairs_v3i = neighbor
				stairs_id = walkable[stairs_v3i]
				break
	if trophy_conns.is_empty():
		for neighbor in _cardinal_neighbors(trophy_v3i):
			if neighbor in walkable and not astar.get_point_connections(walkable[neighbor]).is_empty():
				print("[Intermission] Trophy has no connections — using neighbor %s" % str(neighbor))
				trophy_v3i = neighbor
				trophy_id = walkable[trophy_v3i]
				break

	# ── Build points of interest map (needed BEFORE path routing) ────────────
	_poi_set.clear()
	_visited_pois.clear()

	# Check animated instances for chests, traps, monsters
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx == -1 or s_idx >= _structures.size():
			continue
		var sname: String = _structures[s_idx].display_name
		var poi_cell := Vector3i(pos.x, 0, pos.z)
		if sname.contains("Chest"):
			_poi_set[poi_cell] = "chest"
		elif sname.contains("Trap"):
			_poi_set[poi_cell] = "trap"
		elif sname.contains("Human") or sname.contains("Orc") or sname.contains("Soldier"):
			_poi_set[poi_cell] = "monster"

	# Check static items for coins, weapons, etc.
	if _items_gridmap:
		for cell in _items_gridmap.get_used_cells():
			var mid: int = _items_gridmap.get_cell_item(cell)
			if mid != -1 and mid in _item_id_to_struct:
				var s: Structure = _structures[_item_id_to_struct[mid]]
				var poi_cell := Vector3i(cell.x, 0, cell.z)
				if poi_cell in _poi_set:
					continue
				if s.display_name.contains("Coin") or s.display_name.contains("Trophy"):
					_poi_set[poi_cell] = "treasure"

	# ── Party-specific waypoint routing ──────────────────────────────────────
	# Warriors:  hunt monsters first, then trophy, then exit
	# Rogues:    seek treasure/chests first, then trophy, then exit
	# Scholars:  explore every reachable corner, then trophy, then exit
	var waypoints: Array[Vector3i] = []  # intermediate stops between stairs and trophy

	match party_type:
		0:  # Warriors — hunt monsters
			var monster_pois: Array[Vector3i] = []
			for poi_cell in _poi_set:
				if _poi_set[poi_cell] == "monster":
					if poi_cell in walkable:
						monster_pois.append(poi_cell)
			# Sort by distance from stairs so they visit nearest first
			monster_pois.sort_custom(func(a, b):
				return stairs_v3i.distance_squared_to(a) < stairs_v3i.distance_squared_to(b))
			waypoints = monster_pois
			print("[Intermission] Warriors hunting %d monsters" % waypoints.size())

		1:  # Rogues — seek treasure and chests
			var loot_pois: Array[Vector3i] = []
			for poi_cell in _poi_set:
				if _poi_set[poi_cell] in ["chest", "treasure"]:
					if poi_cell in walkable:
						loot_pois.append(poi_cell)
			# Sort by distance from stairs
			loot_pois.sort_custom(func(a, b):
				return stairs_v3i.distance_squared_to(a) < stairs_v3i.distance_squared_to(b))
			waypoints = loot_pois
			print("[Intermission] Rogues seeking %d treasure spots" % waypoints.size())

		2:  # Scholars — explore every corner of the dungeon
			# Find the farthest reachable corners/extremes to visit
			var explore_targets: Array[Vector3i] = []
			# Gather the 4 extreme walkable cells (min-x, max-x, min-z, max-z)
			var min_x_cell := stairs_v3i
			var max_x_cell := stairs_v3i
			var min_z_cell := stairs_v3i
			var max_z_cell := stairs_v3i
			for cell in walkable:
				# Only consider cells reachable from stairs
				var pid: int = walkable[cell]
				var test := astar.get_point_path(stairs_id, pid)
				if test.is_empty():
					continue
				if cell.x < min_x_cell.x:
					min_x_cell = cell
				if cell.x > max_x_cell.x:
					max_x_cell = cell
				if cell.z < min_z_cell.z:
					min_z_cell = cell
				if cell.z > max_z_cell.z:
					max_z_cell = cell
			# Visit extremes that aren't the stairs or trophy themselves
			for target in [min_z_cell, max_x_cell, max_z_cell, min_x_cell]:
				if target != stairs_v3i and target != trophy_v3i:
					if target not in explore_targets:
						explore_targets.append(target)
			waypoints = explore_targets
			print("[Intermission] Scholars exploring %d corners" % waypoints.size())

	# ── Build the full path: stairs → [waypoints] → trophy → stairs ──────
	# Filter waypoints to only those reachable from stairs
	var reachable_waypoints: Array[Vector3i] = []
	for wp in waypoints:
		if wp in walkable:
			var wp_id: int = walkable[wp]
			var test := astar.get_point_path(stairs_id, wp_id)
			if not test.is_empty():
				reachable_waypoints.append(wp)

	# Build ordered stop list: stairs → waypoints → trophy → stairs
	var stops: Array[Vector3i] = [stairs_v3i]
	stops.append_array(reachable_waypoints)
	stops.append(trophy_v3i)
	stops.append(stairs_v3i)

	# Chain A* paths between consecutive stops
	_path_points = PackedVector3Array()
	for i in range(stops.size() - 1):
		var from_id: int = walkable.get(stops[i], -1)
		var to_id: int = walkable.get(stops[i + 1], -1)
		if from_id == -1 or to_id == -1:
			continue
		var segment: PackedVector3Array = astar.get_point_path(from_id, to_id)
		if segment.is_empty():
			print("[Intermission] No path from %s to %s — skipping waypoint" % [str(stops[i]), str(stops[i + 1])])
			continue
		# Append segment (skip first point if not the first segment to avoid duplicates)
		var start_idx: int = 0 if _path_points.is_empty() else 1
		for j in range(start_idx, segment.size()):
			_path_points.append(segment[j])

	if _path_points.size() < 2:
		print("[Intermission] No valid path could be built!")
		return false

	# Scale walk speed so the party finishes comfortably within duration.
	# Measure total path length in tiles, then pick a speed that completes
	# in ~80% of duration (leaving 20% headroom for POI pauses).
	var total_path_length: float = 0.0
	for i in range(_path_points.size() - 1):
		total_path_length += _path_points[i].distance_to(_path_points[i + 1])
	var target_time: float = duration * 0.8  # 80% of total time for walking
	_walk_speed = clampf(total_path_length / target_time, MIN_WALK_SPEED, MAX_WALK_SPEED)

	var type_label: String = ["Warriors", "Rogues", "Scholars"][mini(party_type, 2)]
	print("[Intermission] %s path: %d waypoints, %.0f tiles, speed=%.1f t/s (stairs → %d detours → trophy → stairs)" % [type_label, _path_points.size(), total_path_length, _walk_speed, reachable_waypoints.size()])

	# Spawn party models
	_spawn_party(party_type)

	# ── Dungeon lighting: columns emit warm glow ───────────────────────────
	_spawn_column_lights()

	# ── Torch carrier: middle party member holds a light ───────────────────
	if _party.size() >= 2:
		_torch_light = OmniLight3D.new()
		_torch_light.light_color = TORCH_LIGHT_COLOR
		_torch_light.light_energy = TORCH_LIGHT_ENERGY
		_torch_light.omni_range = TORCH_LIGHT_RANGE
		_torch_light.omni_attenuation = COLUMN_LIGHT_ATTENUATION
		_torch_light.shadow_enabled = true
		_torch_light.position = Vector3(0, 1.2, 0)  # above the character's hand
		_party[1].node.add_child(_torch_light)

	# Initialize positions
	_path_index = 0
	_path_progress = 0.0
	_leader_pos = _path_points[0]
	_paused = false
	_pause_timer = 0.0
	_timer = 0.0
	_active = true

	# Set initial camera
	if _view_node:
		_view_node.camera_position = _leader_pos
		_view_node.zoom = CAMERA_ZOOM

	print("[Intermission] Path length: %d waypoints, %d column lights, torch on member 2" % [_path_points.size(), _column_lights.size()])
	return true


func process_tick(delta: float) -> void:
	if not _active:
		return

	_timer += delta

	# Skip intermission early with Escape or Space (raw key, not ui_accept
	# which would re-trigger a focused Play button).
	# Wait 0.5s before accepting skip so a held Space from the Play button
	# click doesn't immediately end the intermission.
	if _timer > 0.5:
		if Input.is_key_pressed(KEY_ESCAPE) or Input.is_physical_key_pressed(KEY_SPACE):
			print("[Intermission] Skipped by player")
			_cleanup()
			return

	# Time's up or path finished
	if _timer >= duration or _path_index >= _path_points.size() - 1:
		_cleanup()
		return

	# Pause at point of interest
	if _paused:
		_pause_timer -= delta
		if _pause_timer <= 0.0:
			_paused = false
			# Resume walk animation on ALL party members
			for member in _party:
				if member.anim and member.anim.has_animation(WALK_ANIM):
					member.anim.play(WALK_ANIM)
		else:
			_update_camera(delta)
			return

	# Move leader along path
	var current_wp: Vector3 = _path_points[_path_index]
	var next_wp: Vector3 = _path_points[_path_index + 1]
	var segment_length: float = current_wp.distance_to(next_wp)
	if segment_length < 0.01:
		segment_length = 0.01

	_path_progress += (_walk_speed * delta) / segment_length

	if _path_progress >= 1.0:
		_path_progress = 0.0
		_path_index += 1

		if _path_index >= _path_points.size() - 1:
			_cleanup()
			return

		# Check if we arrived at a point of interest
		var arrived_cell := Vector3i(int(round(next_wp.x)), 0, int(round(next_wp.z)))
		if arrived_cell in _poi_set and arrived_cell not in _visited_pois:
			_visited_pois[arrived_cell] = true
			_interact_with_poi(arrived_cell, _poi_set[arrived_cell])

		current_wp = _path_points[_path_index]
		next_wp = _path_points[mini(_path_index + 1, _path_points.size() - 1)]

	# Interpolate leader position
	_leader_pos = _path_points[_path_index].lerp(
		_path_points[mini(_path_index + 1, _path_points.size() - 1)],
		_path_progress)

	# Update party positions — leader at front, others trail behind
	_update_party_positions()
	_update_camera(delta)

	# Scan nearby items for contact-based looting
	_scan_nearby_items()


func _update_party_positions() -> void:
	if _party.is_empty():
		return

	# Leader
	var leader = _party[0]
	leader.node.position = _leader_pos

	# Face movement direction (Kenney models face +Z, look_at faces -Z, so rotate 180°)
	if _path_index + 1 < _path_points.size():
		var dir: Vector3 = _path_points[_path_index + 1] - _path_points[_path_index]
		if dir.length_squared() > 0.001:
			dir.y = 0
			leader.node.look_at(leader.node.position + dir, Vector3.UP)
			leader.node.rotate_y(PI)

	# Followers — trail behind along the path
	for i in range(1, _party.size()):
		var follower = _party[i]
		var trail_dist: float = PARTY_SPACING * float(i)
		var follower_pos: Vector3 = _get_trail_position(trail_dist)
		follower.node.position = follower_pos

		# Face toward the person in front
		var ahead = _party[i - 1]
		var look_dir: Vector3 = ahead.node.position - follower.node.position
		if look_dir.length_squared() > 0.001:
			look_dir.y = 0
			follower.node.look_at(follower.node.position + look_dir, Vector3.UP)
			follower.node.rotate_y(PI)


func _get_trail_position(trail_distance: float) -> Vector3:
	# Walk backward along the path from the leader's position
	var remaining: float = trail_distance
	var idx: int = _path_index
	var prog: float = _path_progress

	# First, go back within current segment
	if idx < _path_points.size() - 1:
		var seg_len: float = _path_points[idx].distance_to(_path_points[idx + 1])
		var dist_in_seg: float = prog * seg_len
		if dist_in_seg >= remaining:
			var new_prog: float = (dist_in_seg - remaining) / maxf(seg_len, 0.01)
			return _path_points[idx].lerp(_path_points[idx + 1], new_prog)
		remaining -= dist_in_seg

	# Walk back through previous segments
	var prev_idx: int = idx - 1
	while prev_idx >= 0 and remaining > 0.0:
		var seg_len: float = _path_points[prev_idx].distance_to(_path_points[prev_idx + 1])
		if seg_len >= remaining:
			var new_prog: float = 1.0 - (remaining / maxf(seg_len, 0.01))
			return _path_points[prev_idx].lerp(_path_points[prev_idx + 1], new_prog)
		remaining -= seg_len
		prev_idx -= 1

	# If we ran out of path, just stay at the start
	return _path_points[0]


func _update_camera(delta: float) -> void:
	if _view_node == null:
		return
	# Follow the leader with a slight offset
	var target_pos: Vector3 = _leader_pos
	_view_node.camera_position = _view_node.camera_position.lerp(target_pos, delta * 4.0)

	# Point camera in the direction of travel
	if _path_index + 1 < _path_points.size():
		var dir: Vector3 = _path_points[_path_index + 1] - _path_points[_path_index]
		if dir.length_squared() > 0.001:
			var target_angle: float = rad_to_deg(atan2(-dir.x, -dir.z))
			var current_y: float = _view_node.camera_rotation.y
			# Smooth rotation
			_view_node.camera_rotation.y = lerp_angle(deg_to_rad(current_y), deg_to_rad(target_angle), delta * 3.0)
			_view_node.camera_rotation.y = rad_to_deg(_view_node.camera_rotation.y)


func _interact_with_poi(cell: Vector3i, poi_type: String) -> void:
	_paused = true
	_pause_timer = INTERACTION_PAUSE

	if _party.is_empty():
		return

	var leader = _party[0]

	match poi_type:
		"chest":
			_trigger_poi_animation(cell, "open")
			if _party_type == 1:  # Rogues — all rush to loot
				_pause_timer = INTERACTION_PAUSE * 1.5  # take their time looting
				for member in _party:
					_play_member_anim(member, PICKUP_ANIM)
			else:
				_play_member_anim(leader, PICKUP_ANIM)
		"trap":
			_trigger_poi_animation(cell, "open-close")
			if _party_type == 0:  # Warriors — jump over bravely
				_play_member_anim(leader, JUMP_ANIM)
			elif _party_type == 2:  # Scholars — crouch to examine
				_play_member_anim(leader, "crouch")
				_pause_timer = INTERACTION_PAUSE * 1.5  # study it
			else:  # Rogues — nimble dodge
				_play_member_anim(leader, JUMP_ANIM)
		"monster":
			if _party_type == 0:  # Warriors — everyone fights!
				_pause_timer = INTERACTION_PAUSE * 2.0  # longer battle
				for member in _party:
					_play_member_anim(member, IDLE_ANIM)  # fighting stance
			elif _party_type == 2:  # Scholars — observe cautiously
				_play_member_anim(leader, "crouch")
				_pause_timer = INTERACTION_PAUSE * 1.5
			else:  # Rogues — leader distracts, others idle
				_play_member_anim(leader, IDLE_ANIM)
		"treasure":
			if _party_type == 1:  # Rogues — everyone grabs loot
				for member in _party:
					_play_member_anim(member, PICKUP_ANIM)
			else:
				_play_member_anim(leader, PICKUP_ANIM)

	# Party members not yet animated play idle while waiting
	for i in range(1, _party.size()):
		var member = _party[i]
		if member.anim and member.anim.current_animation == WALK_ANIM:
			_play_member_anim(member, IDLE_ANIM)


func _play_member_anim(member: Dictionary, anim_name: String) -> void:
	if member.anim:
		if member.anim.has_animation(anim_name):
			member.anim.play(anim_name)
		elif member.anim.has_animation(IDLE_ANIM):
			member.anim.play(IDLE_ANIM)


func _trigger_poi_animation(cell: Vector3i, anim_name: String) -> void:
	# Find the animated instance at or near this cell
	for pos in _animated_instances:
		if pos.x == cell.x and pos.z == cell.z:
			var instance: Node3D = _animated_instances[pos]
			var anim_player: AnimationPlayer = _find_anim_player(instance)
			if anim_player and anim_player.has_animation(anim_name):
				anim_player.play(anim_name)
			break


func _spawn_party(party_type: int) -> void:
	_party.clear()
	var models: Array[String]
	match party_type:
		0: models = WARRIOR_MODELS   # Warriors
		1: models = ROGUE_MODELS     # Rogues
		2: models = SCHOLAR_MODELS   # Scholars
		_: models = ROGUE_MODELS

	var count: int = mini(models.size(), 3)
	for i in range(count):
		var scene: PackedScene = load(models[i])
		if scene == null:
			continue
		var instance: Node3D = scene.instantiate()
		instance.position = _path_points[0] if not _path_points.is_empty() else Vector3.ZERO
		add_child(instance)

		var anim_player: AnimationPlayer = _find_anim_player(instance)

		# Start walking
		if anim_player:
			if anim_player.has_animation(WALK_ANIM):
				var walk_anim: Animation = anim_player.get_animation(WALK_ANIM)
				if walk_anim:
					walk_anim.loop_mode = Animation.LOOP_LINEAR
				anim_player.play(WALK_ANIM)

		_party.append({ "node": instance, "anim": anim_player })


func _scan_nearby_items() -> void:
	# Roll loot LIVE as the party walks past items — taken items vanish immediately
	var lx: int = int(round(_leader_pos.x))
	var lz: int = int(round(_leader_pos.z))
	var radius: int = int(ceil(LOOT_CONTACT_RADIUS))
	for dx in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			var cx: int = lx + dx
			var cz: int = lz + dz
			# Check static items in items gridmap (all Y levels)
			if _items_gridmap:
				for y in range(0, 5):
					var check := Vector3i(cx, y, cz)
					if check in contacted_items:
						continue
					contacted_items[check] = true
					var mid: int = _items_gridmap.get_cell_item(check)
					if mid == -1:
						continue
					var s_idx: int = _item_id_to_struct.get(mid, -1)
					if s_idx == -1:
						continue
					var s: Structure = _structures[s_idx]
					var chance: float = _get_loot_chance_for(s.display_name)
					if chance > 0.0 and randf() <= chance:
						looted_items.append({ "cell": check, "type": "grid", "name": s.display_name, "price": s.price })
						_items_gridmap.set_cell_item(check, -1)  # vanish immediately

			# Check animated instances at this (x, z)
			for pos in _animated_instances.keys():
				if pos.x == cx and pos.z == cz and pos not in contacted_items:
					contacted_items[pos] = true
					var s_idx: int = _animated_struct_idx.get(pos, -1)
					if s_idx == -1:
						continue
					var s: Structure = _structures[s_idx]
					var chance: float = _get_loot_chance_for(s.display_name)
					if chance > 0.0 and randf() <= chance:
						looted_items.append({ "cell": pos, "type": "anim", "name": s.display_name, "price": s.price })
						# Hide the animated instance immediately
						var instance: Node3D = _animated_instances[pos]
						if instance:
							instance.visible = false


func _get_loot_chance_for(display_name: String) -> float:
	# Required items are never looted
	if display_name.contains("Stairs") or display_name.contains("[Req]"):
		return 0.0
	for keyword in _loot_chances:
		if display_name.contains(keyword):
			return minf(_loot_chances[keyword] * _loot_mult, 1.0)
	return 0.0


func _spawn_column_lights() -> void:
	_column_lights.clear()
	# Find all column positions in the items gridmap and animated instances
	if _items_gridmap:
		for cell in _items_gridmap.get_used_cells():
			var mid: int = _items_gridmap.get_cell_item(cell)
			var s_idx: int = _item_id_to_struct.get(mid, -1)
			if s_idx != -1 and _structures[s_idx].display_name in COLUMN_NAMES:
				var light := OmniLight3D.new()
				light.light_color = COLUMN_LIGHT_COLOR
				light.light_energy = COLUMN_LIGHT_ENERGY
				light.omni_range = COLUMN_LIGHT_RANGE
				light.omni_attenuation = COLUMN_LIGHT_ATTENUATION
				light.shadow_enabled = false        # no shadows (perf)
				light.distance_fade_enabled = true   # GPU culls distant lights
				light.distance_fade_begin = 8.0
				light.distance_fade_length = 4.0     # fades out 8–12 tiles from camera
				light.position = Vector3(cell.x + 0.5, 1.5, cell.z + 0.5)
				add_child(light)
				_column_lights.append(light)


func _cleanup() -> void:
	_active = false
	# Remove column lights
	for light in _column_lights:
		if is_instance_valid(light):
			light.queue_free()
	_column_lights.clear()
	_torch_light = null  # freed with party member node

	# Despawn party members
	for member in _party:
		if member.node:
			member.node.queue_free()
	_party.clear()

	# Reset any POI animations we triggered (chests back to closed, etc.)
	for cell in _visited_pois:
		for pos in _animated_instances:
			if pos.x == cell.x and pos.z == cell.z:
				var instance: Node3D = _animated_instances[pos]
				var anim_player: AnimationPlayer = _find_anim_player(instance)
				if anim_player and anim_player.has_animation("close"):
					anim_player.play("close")
					anim_player.seek(0.0, true)
					anim_player.pause()
				break

	emit_signal("finished")
	queue_free()


func _find_anim_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var result: AnimationPlayer = _find_anim_player(child)
		if result:
			return result
	return null


func _cardinal_neighbors(cell: Vector3i) -> Array:
	return [
		Vector3i(cell.x + 1, cell.y, cell.z),
		Vector3i(cell.x - 1, cell.y, cell.z),
		Vector3i(cell.x, cell.y, cell.z + 1),
		Vector3i(cell.x, cell.y, cell.z - 1),
	]
