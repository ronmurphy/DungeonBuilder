extends Node
class_name DayCycle

@export var camera: Camera3D
@export var sun: DirectionalLight3D

# ── Colour keyframes ───────────────────────────────────────────────────────────
# Each entry: [t, sky_top, sky_horizon, ground_horizon, ambient_color, ambient_energy, sun_color, sun_energy]
# t = 0.0 (dawn) → 1.0 (wraps back to dawn)

const _KEYS: Array = [
	# t      sky_top                      sky_horizon                  ground_horizon               amb_color                    amb_e  sun_color                    sun_e
	[0.00, Color(0.08, 0.06, 0.18, 1), Color(0.82, 0.38, 0.18, 1), Color(0.55, 0.28, 0.15, 1), Color(0.62, 0.52, 0.50, 1), 0.48, Color(1.00, 0.55, 0.25, 1), 0.45],  # dawn
	[0.15, Color(0.24, 0.44, 0.80, 1), Color(0.76, 0.78, 0.92, 1), Color(0.55, 0.52, 0.42, 1), Color(0.63, 0.66, 0.74, 1), 0.65, Color(1.00, 0.88, 0.70, 1), 0.85],  # morning
	[0.40, Color(0.12, 0.31, 0.78, 1), Color(0.52, 0.68, 0.90, 1), Color(0.40, 0.52, 0.62, 1), Color(0.66, 0.69, 0.77, 1), 0.75, Color(1.00, 0.97, 0.93, 1), 1.00],  # midday
	[0.65, Color(0.16, 0.27, 0.72, 1), Color(0.60, 0.68, 0.88, 1), Color(0.42, 0.50, 0.60, 1), Color(0.65, 0.67, 0.74, 1), 0.70, Color(1.00, 0.92, 0.80, 1), 0.88],  # afternoon
	[0.78, Color(0.20, 0.10, 0.40, 1), Color(0.92, 0.40, 0.10, 1), Color(0.60, 0.25, 0.08, 1), Color(0.65, 0.52, 0.45, 1), 0.52, Color(1.00, 0.60, 0.22, 1), 0.52],  # sunset
	[0.87, Color(0.05, 0.04, 0.16, 1), Color(0.22, 0.13, 0.28, 1), Color(0.12, 0.08, 0.15, 1), Color(0.34, 0.31, 0.44, 1), 0.42, Color(0.72, 0.78, 1.00, 1), 0.20],  # dusk
	[0.94, Color(0.02, 0.02, 0.08, 1), Color(0.05, 0.06, 0.16, 1), Color(0.04, 0.04, 0.12, 1), Color(0.28, 0.30, 0.44, 1), 0.40, Color(0.70, 0.76, 1.00, 1), 0.14],  # midnight
	[1.00, Color(0.08, 0.06, 0.18, 1), Color(0.82, 0.38, 0.18, 1), Color(0.55, 0.28, 0.15, 1), Color(0.62, 0.52, 0.50, 1), 0.48, Color(1.00, 0.55, 0.25, 1), 0.45],  # dawn (loop)
]

var _env:     Environment           = null
var _sky_mat: ProceduralSkyMaterial = null

# Original values stored so we can restore them when the cycle is turned off
var _orig_bg_mode:       int   = Environment.BG_COLOR
var _orig_bg_color:      Color = Color(0.56, 0.59, 0.67, 1)
var _orig_amb_color:     Color = Color(0.66, 0.69, 0.77, 1)
var _orig_amb_energy:    float = 0.75
var _orig_sun_color:     Color = Color.WHITE
var _orig_sun_energy:    float = 1.0
var _orig_sky_top:       Color = Color(0.38, 0.45, 0.55, 1)
var _orig_sky_horizon:   Color = Color(0.67, 0.68, 0.70, 1)
var _orig_ground_horizon:Color = Color(0.67, 0.68, 0.70, 1)
var _orig_ground_bottom: Color = Color(1, 1, 1, 1)


func _ready() -> void:
	if not camera or not camera.environment:
		push_warning("[DayCycle] No camera or environment assigned — sky cycle disabled.")
		return

	# Deep-duplicate so runtime changes never touch the .tres file on disk
	_env = camera.environment.duplicate(true)
	camera.environment = _env

	# Store originals before we touch anything
	_orig_bg_mode    = _env.background_mode
	_orig_bg_color   = _env.background_color
	_orig_amb_color  = _env.ambient_light_color
	_orig_amb_energy = _env.ambient_light_energy
	if sun:
		_orig_sun_color  = sun.light_color
		_orig_sun_energy = sun.light_energy

	if _env.sky and _env.sky.sky_material is ProceduralSkyMaterial:
		_sky_mat = _env.sky.sky_material as ProceduralSkyMaterial
		_orig_sky_top        = _sky_mat.sky_top_color
		_orig_sky_horizon    = _sky_mat.sky_horizon_color
		_orig_ground_horizon = _sky_mat.ground_horizon_color
		_orig_ground_bottom  = _sky_mat.ground_bottom_color
	else:
		push_warning("[DayCycle] Environment sky is not a ProceduralSkyMaterial — colours won't animate.")

	# Apply initial state based on saved preference
	_apply_enabled(Global.day_cycle_enabled)


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F4:
		Global.day_cycle_enabled = not Global.day_cycle_enabled
		_apply_enabled(Global.day_cycle_enabled)
		var state_str: String = "ON" if Global.day_cycle_enabled else "OFF"
		Toast.notify("Day/night cycle: %s  (F4 to toggle)" % state_str,
			preload("res://graphics/information.png"), 3.0)
		get_viewport().set_input_as_handled()


func _apply_enabled(on: bool) -> void:
	if _env == null:
		return
	if on:
		_env.background_mode = Environment.BG_SKY
	else:
		# Restore everything to the original static look
		_env.background_mode      = _orig_bg_mode
		_env.background_color     = _orig_bg_color
		_env.ambient_light_color  = _orig_amb_color
		_env.ambient_light_energy = _orig_amb_energy
		if _sky_mat:
			_sky_mat.sky_top_color        = _orig_sky_top
			_sky_mat.sky_horizon_color    = _orig_sky_horizon
			_sky_mat.ground_horizon_color = _orig_ground_horizon
			_sky_mat.ground_bottom_color  = _orig_ground_bottom
		if sun:
			sun.light_color  = _orig_sun_color
			sun.light_energy = _orig_sun_energy


func _process(_delta: float) -> void:
	if _env == null or _sky_mat == null:
		return
	if not Global.day_cycle_enabled:
		return
	_apply_time(Global.day_progress)


func _apply_time(t: float) -> void:
	# Find the two surrounding keyframes
	var a: Array = _KEYS[0]
	var b: Array = _KEYS[_KEYS.size() - 1]
	for i in _KEYS.size() - 1:
		if t >= (_KEYS[i][0] as float) and t < (_KEYS[i + 1][0] as float):
			a = _KEYS[i]
			b = _KEYS[i + 1]
			break

	var span: float = (b[0] as float) - (a[0] as float)
	var f: float    = 0.0 if span <= 0.0 else (t - (a[0] as float)) / span

	# Sky colours
	_sky_mat.sky_top_color      = (a[1] as Color).lerp(b[1] as Color, f)
	_sky_mat.sky_horizon_color  = (a[2] as Color).lerp(b[2] as Color, f)
	_sky_mat.ground_horizon_color = (a[3] as Color).lerp(b[3] as Color, f)
	_sky_mat.ground_bottom_color  = _sky_mat.ground_horizon_color.darkened(0.3)

	# Ambient world lighting
	_env.ambient_light_color  = (a[4] as Color).lerp(b[4] as Color, f)
	_env.ambient_light_energy = lerpf(a[5] as float, b[5] as float, f)

	# Sun / moon (same DirectionalLight3D — becomes cool blue at night)
	if sun:
		sun.light_color  = (a[6] as Color).lerp(b[6] as Color, f)
		sun.light_energy = lerpf(a[7] as float, b[7] as float, f)
