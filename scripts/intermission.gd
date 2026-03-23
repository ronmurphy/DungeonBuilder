extends Node3D
class_name Intermission

## Adventurer walk-through intermission using AStar3D pathfinding.
## Spawns a party of adventurers at the Dungeon Stairs, walks them to the
## farthest reachable point, then back. Camera follows the lead adventurer.
## Duration: 30 seconds max (one in-game day).

signal finished  # emitted when the intermission is done

const DURATION: float = 30.0
const WALK_SPEED: float = 3.0        # tiles per second
const INTERACTION_PAUSE: float = 1.5  # seconds to pause at a point of interest
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

# References passed in from builder
var _gridmap: GridMap
var _decoration_gridmap: GridMap
var _items_gridmap: GridMap
var _terrain_gridmap: GridMap
var _animated_instances: Dictionary
var _animated_struct_idx: Dictionary
var _structures: Array[Structure]
var _item_id_to_struct: Dictionary
var _deco_id_to_struct: Dictionary


func setup(params: Dictionary) -> bool:
	_gridmap = params.get("gridmap")
	_decoration_gridmap = params.get("decoration_gridmap")
	_items_gridmap = params.get("items_gridmap")
	_terrain_gridmap = params.get("terrain_gridmap")
	_animated_instances = params.get("animated_instances", {})
	_animated_struct_idx = params.get("animated_struct_idx", {})
	_structures = params.get("structures", [])
	_item_id_to_struct = params.get("item_id_to_struct", {})
	_deco_id_to_struct = params.get("deco_id_to_struct", {})
	_view_node = params.get("view_node")
	var party_type: int = params.get("party_type", 0)
	var stairs_pos = params.get("stairs_pos")  # Vector3i or null
	var trophy_pos = params.get("trophy_pos")  # Vector3i or null

	if stairs_pos == null:
		print("[Intermission] No stairs position provided")
		return false
	if trophy_pos == null:
		print("[Intermission] No trophy position provided")
		return false

	print("[Intermission] Setup — stairs at %s, trophy at %s, party type %d" % [str(stairs_pos), str(trophy_pos), party_type])

	# Build the A* graph
	var astar := AStar3D.new()
	var walkable: Dictionary = {}  # Vector3i -> point_id
	var wall_cells: Dictionary = {}
	var gate_cells: Dictionary = {}

	# Wall-layer items that adventurers CAN walk through
	const PASSABLE_WALLS: Array[String] = [
		"Wall Opening", "Wall Gate", "Gate",
	]

	# Gather walls — only SOLID walls block pathfinding
	if _decoration_gridmap:
		for cell in _decoration_gridmap.get_used_cells():
			var mid: int = _decoration_gridmap.get_cell_item(cell)
			var is_passable: bool = false
			if mid in _deco_id_to_struct:
				var s: Structure = _structures[_deco_id_to_struct[mid]]
				for keyword in PASSABLE_WALLS:
					if s.display_name.contains(keyword):
						is_passable = true
						break
			if is_passable:
				gate_cells[cell] = true  # treat as passable opening
			else:
				wall_cells[cell] = true

	# Gather gate positions from animated instances (animated Gate model)
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx != -1 and s_idx < _structures.size():
			if _structures[s_idx].display_name.contains("Gate"):
				gate_cells[pos] = true

	# Compute bounding box of all placed structures (walls + items + floors)
	# to limit terrain pathfinding to the dungeon area only
	var bounds_min_x: int = stairs_pos.x
	var bounds_max_x: int = stairs_pos.x
	var bounds_min_z: int = stairs_pos.z
	var bounds_max_z: int = stairs_pos.z
	var _expand_bounds := func(cells: Array) -> void:
		for cell in cells:
			bounds_min_x = mini(bounds_min_x, int(cell.x))
			bounds_max_x = maxi(bounds_max_x, int(cell.x))
			bounds_min_z = mini(bounds_min_z, int(cell.z))
			bounds_max_z = maxi(bounds_max_z, int(cell.z))
	_expand_bounds.call(_gridmap.get_used_cells())
	if _decoration_gridmap:
		_expand_bounds.call(_decoration_gridmap.get_used_cells())
	if _items_gridmap:
		_expand_bounds.call(_items_gridmap.get_used_cells())
	for pos in _animated_instances:
		bounds_min_x = mini(bounds_min_x, pos.x)
		bounds_max_x = maxi(bounds_max_x, pos.x)
		bounds_min_z = mini(bounds_min_z, pos.z)
		bounds_max_z = maxi(bounds_max_z, pos.z)
	# Add margin of 2 tiles around the dungeon
	bounds_min_x -= 2
	bounds_max_x += 2
	bounds_min_z -= 2
	bounds_max_z += 2

	# Build walkable set from ALL floor tiles — player-placed AND terrain
	print("[Intermission] Walls: %d, Gates: %d, Bounds: (%d,%d)-(%d,%d)" % [wall_cells.size(), gate_cells.size(), bounds_min_x, bounds_min_z, bounds_max_x, bounds_max_z])
	var point_id: int = 0
	# Player-placed floors (gridmap layer 0)
	for cell in _gridmap.get_used_cells():
		if cell.y != 0:
			continue
		if cell in wall_cells:
			continue
		walkable[cell] = point_id
		astar.add_point(point_id, Vector3(cell.x, 0, cell.z))
		point_id += 1
	# Terrain floors — only within the dungeon bounding box
	if _terrain_gridmap:
		for cell in _terrain_gridmap.get_used_cells():
			if cell.y != 0:
				continue
			if cell.x < bounds_min_x or cell.x > bounds_max_x:
				continue
			if cell.z < bounds_min_z or cell.z > bounds_max_z:
				continue
			if cell in wall_cells or cell in walkable:
				continue
			walkable[cell] = point_id
			astar.add_point(point_id, Vector3(cell.x, 0, cell.z))
			point_id += 1

	# Also add gate positions as walkable (gates are passable)
	for gpos in gate_cells:
		if gpos not in walkable:
			walkable[gpos] = point_id
			astar.add_point(point_id, Vector3(gpos.x, 0, gpos.z))
			point_id += 1

	print("[Intermission] Walkable tiles: %d" % walkable.size())

	# Connect cardinal neighbors
	for cell in walkable:
		var pid: int = walkable[cell]
		for neighbor in _cardinal_neighbors(cell):
			if neighbor in walkable:
				var nid: int = walkable[neighbor]
				if not astar.are_points_connected(pid, nid):
					astar.connect_points(pid, nid)

	# Ensure stairs and trophy are in the walkable graph (they sit on items layer, may lack floor)
	var stairs_v3i := Vector3i(stairs_pos.x, 0, stairs_pos.z)
	var trophy_v3i := Vector3i(trophy_pos.x, 0, trophy_pos.z)

	# Force-add both key cells and their immediate neighbors as walkable
	for key_cell in [stairs_v3i, trophy_v3i]:
		if key_cell not in walkable:
			walkable[key_cell] = point_id
			astar.add_point(point_id, Vector3(key_cell.x, 0, key_cell.z))
			point_id += 1

	# Connect ALL walkable tiles again (including newly added stairs/trophy)
	# This ensures everything is fully linked
	for cell in walkable:
		var pid: int = walkable[cell]
		for neighbor in _cardinal_neighbors(cell):
			if neighbor in walkable:
				var nid: int = walkable[neighbor]
				if not astar.are_points_connected(pid, nid):
					astar.connect_points(pid, nid)

	var stairs_id: int = walkable[stairs_v3i]
	var trophy_id: int = walkable[trophy_v3i]

	# Debug: show connectivity info
	var stairs_conns := astar.get_point_connections(stairs_id)
	var trophy_conns := astar.get_point_connections(trophy_id)
	print("[Intermission] Stairs at %s — %d connections" % [str(stairs_v3i), stairs_conns.size()])
	print("[Intermission] Trophy at %s — %d connections" % [str(trophy_v3i), trophy_conns.size()])

	# Debug: check if stairs cell is blocked by a wall
	if stairs_v3i in wall_cells:
		print("[Intermission] WARNING: Stairs position has a wall on it!")
	if trophy_v3i in wall_cells:
		print("[Intermission] WARNING: Trophy position has a wall on it!")

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

	# Try to get the path
	var path_out: PackedVector3Array = astar.get_point_path(stairs_id, trophy_id)
	if path_out.is_empty():
		print("[Intermission] No path from stairs to trophy!")
		print("[Intermission] Stairs id=%d pos=%s, Trophy id=%d pos=%s" % [stairs_id, str(astar.get_point_position(stairs_id)), trophy_id, str(astar.get_point_position(trophy_id))])
		# Debug: check what stairs CAN reach
		var reachable: int = 0
		for pid in walkable.values():
			var test := astar.get_point_path(stairs_id, pid)
			if not test.is_empty():
				reachable += 1
		print("[Intermission] Stairs can reach %d / %d walkable tiles" % [reachable, walkable.size()])
		return false

	var path_back: PackedVector3Array = astar.get_point_path(trophy_id, stairs_id)
	print("[Intermission] Path: stairs → trophy = %d tiles, trophy → stairs = %d tiles" % [path_out.size(), path_back.size()])

	# Combine into one continuous path
	_path_points = PackedVector3Array()
	for p in path_out:
		_path_points.append(p)
	# Skip first point of return path (it's the same as the last of outbound)
	for i in range(1, path_back.size()):
		_path_points.append(path_back[i])

	if _path_points.size() < 2:
		return false

	# Build points of interest map
	_poi_set.clear()
	_visited_pois.clear()

	# Check animated instances for chests, traps, monsters
	for pos in _animated_instances:
		var s_idx: int = _animated_struct_idx.get(pos, -1)
		if s_idx == -1 or s_idx >= _structures.size():
			continue
		var sname: String = _structures[s_idx].display_name
		var poi_cell := Vector3i(pos.x, 0, pos.z)  # normalize to ground y for path matching
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
					continue  # already has a more interesting POI
				if s.display_name.contains("Coin") or s.display_name.contains("Trophy"):
					_poi_set[poi_cell] = "treasure"

	# Spawn party models
	_spawn_party(party_type)

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

	print("[Intermission] Path length: %d waypoints (stairs → trophy → stairs)" % _path_points.size())
	return true


func process_tick(delta: float) -> void:
	if not _active:
		return

	_timer += delta

	# Time's up or path finished
	if _timer >= DURATION or _path_index >= _path_points.size() - 1:
		_cleanup()
		return

	# Pause at point of interest
	if _paused:
		_pause_timer -= delta
		if _pause_timer <= 0.0:
			_paused = false
			# Resume walk animation on leader
			if not _party.is_empty():
				var leader = _party[0]
				if leader.anim and leader.anim.has_animation(WALK_ANIM):
					leader.anim.play(WALK_ANIM)
		else:
			_update_camera(delta)
			return

	# Move leader along path
	var current_wp: Vector3 = _path_points[_path_index]
	var next_wp: Vector3 = _path_points[_path_index + 1]
	var segment_length: float = current_wp.distance_to(next_wp)
	if segment_length < 0.01:
		segment_length = 0.01

	_path_progress += (WALK_SPEED * delta) / segment_length

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
			# Leader plays pick-up animation
			if leader.anim and leader.anim.has_animation(PICKUP_ANIM):
				leader.anim.play(PICKUP_ANIM)
			# Try to trigger the chest's open animation
			_trigger_poi_animation(cell, "open")
		"trap":
			# Leader plays jump (dodge) animation
			if leader.anim and leader.anim.has_animation(JUMP_ANIM):
				leader.anim.play(JUMP_ANIM)
			_trigger_poi_animation(cell, "open-close")
		"monster":
			# Leader plays idle (fighting stance) — we don't have an attack anim
			if leader.anim and leader.anim.has_animation(IDLE_ANIM):
				leader.anim.play(IDLE_ANIM)
		"treasure":
			# Leader bends down to pick up
			if leader.anim and leader.anim.has_animation(PICKUP_ANIM):
				leader.anim.play(PICKUP_ANIM)

	# Other party members play idle while waiting
	for i in range(1, _party.size()):
		var member = _party[i]
		if member.anim and member.anim.has_animation(IDLE_ANIM):
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


func _cleanup() -> void:
	_active = false
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
