extends Node
class_name WeatherSystem

# ── Weather types ──────────────────────────────────────────────────────────────
enum WeatherType { CLEAR, LIGHT_RAIN, RAIN, LIGHT_SNOW, SNOW }

const WEATHER_LABEL_TEXT: Dictionary = {
	WeatherType.CLEAR:      "",
	WeatherType.LIGHT_RAIN: "Light Rain",
	WeatherType.RAIN:       "Rain",
	WeatherType.LIGHT_SNOW: "Light Snow",
	WeatherType.SNOW:       "Snowfall",
}

const WEATHER_LABEL_COLOR: Dictionary = {
	WeatherType.CLEAR:      Color.WHITE,
	WeatherType.LIGHT_RAIN: Color(0.60, 0.85, 1.00),
	WeatherType.RAIN:       Color(0.40, 0.70, 1.00),
	WeatherType.LIGHT_SNOW: Color(0.85, 0.92, 1.00),
	WeatherType.SNOW:       Color(0.92, 0.96, 1.00),
}

@export var weather_label: Label   # wired in main.tscn

var _current:        WeatherType    = WeatherType.CLEAR
var _last_day:       int            = -1
var _rain_particles: CPUParticles2D = null
var _snow_particles: CPUParticles2D = null
var _canvas:         CanvasLayer    = null


func _ready() -> void:
	# Layer 0 = in front of the 3D world, behind the HUD (which sits at layer 1)
	_canvas = CanvasLayer.new()
	_canvas.layer = 0
	add_child(_canvas)
	_build_particles()
	if weather_label:
		weather_label.visible = false


func _process(_delta: float) -> void:
	if Global.current_day != _last_day:
		_last_day = Global.current_day
		_roll_weather()


# ── Month → weather probabilities ──────────────────────────────────────────────

func _get_month() -> int:
	return (Global.current_day % 336) / 28 + 1


func _roll_weather() -> void:
	_apply_weather(_pick_weather(_get_month()))


func _pick_weather(month: int) -> WeatherType:
	var r: float = randf()
	match month:
		1, 2:        # Winter — mostly light snow, some heavy
			if r < 0.60: return WeatherType.LIGHT_SNOW
			elif r < 0.80: return WeatherType.SNOW
			return WeatherType.CLEAR
		3, 4:        # Spring — rain is likely
			if r < 0.40: return WeatherType.RAIN
			elif r < 0.60: return WeatherType.LIGHT_RAIN
			return WeatherType.CLEAR
		5, 6, 7:     # Summer — occasional shower
			if r < 0.10: return WeatherType.RAIN
			elif r < 0.25: return WeatherType.LIGHT_RAIN
			return WeatherType.CLEAR
		8, 9:        # Late summer — rare light rain
			if r < 0.10: return WeatherType.LIGHT_RAIN
			return WeatherType.CLEAR
		10, 11, 12:  # Autumn / early winter — snow returns, odd shower
			if r < 0.20: return WeatherType.LIGHT_SNOW
			elif r < 0.35: return WeatherType.SNOW
			elif r < 0.48: return WeatherType.LIGHT_RAIN
			return WeatherType.CLEAR
		_:
			return WeatherType.CLEAR


func _apply_weather(weather: WeatherType) -> void:
	_current = weather

	# Tune particle density for light vs heavy
	match weather:
		WeatherType.LIGHT_RAIN: _rain_particles.amount = 80
		WeatherType.RAIN:       _rain_particles.amount = 260
		WeatherType.LIGHT_SNOW: _snow_particles.amount = 55
		WeatherType.SNOW:       _snow_particles.amount = 160

	_rain_particles.emitting = weather in [WeatherType.RAIN,      WeatherType.LIGHT_RAIN]
	_snow_particles.emitting = weather in [WeatherType.LIGHT_SNOW, WeatherType.SNOW]

	if weather_label:
		weather_label.text    = WEATHER_LABEL_TEXT[weather]
		weather_label.visible = (weather != WeatherType.CLEAR)
		weather_label.add_theme_color_override(
				"font_color", WEATHER_LABEL_COLOR[weather])


# ── Particle setup ─────────────────────────────────────────────────────────────

func _build_particles() -> void:
	var vp: Vector2   = get_viewport().get_visible_rect().size \
						if get_viewport() else Vector2(1920.0, 1080.0)
	var half_w: float = vp.x * 0.5 + 120.0   # slight overhang so edges stay covered

	# ── Rain ────────────────────────────────────────────────────────────────
	_rain_particles = CPUParticles2D.new()
	_rain_particles.emitting              = false
	_rain_particles.amount                = 200
	_rain_particles.lifetime              = 1.2
	_rain_particles.explosiveness         = 0.0
	_rain_particles.randomness            = 0.2
	_rain_particles.emission_shape        = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_rain_particles.emission_rect_extents = Vector2(half_w, 1.0)
	_rain_particles.position              = Vector2(vp.x * 0.5, -5.0)
	_rain_particles.direction             = Vector2(0.10, 1.0).normalized()
	_rain_particles.spread                = 4.0
	_rain_particles.gravity               = Vector2(20.0, 200.0)
	_rain_particles.initial_velocity_min  = 400.0
	_rain_particles.initial_velocity_max  = 560.0
	_rain_particles.scale_amount_min      = 1.0
	_rain_particles.scale_amount_max      = 1.8
	_rain_particles.color                 = Color(0.65, 0.80, 1.0, 0.50)
	# 2×8 px raindrop streak
	var r_img := Image.create(2, 8, false, Image.FORMAT_RGBA8)
	r_img.fill(Color.WHITE)
	_rain_particles.texture = ImageTexture.create_from_image(r_img)
	_canvas.add_child(_rain_particles)

	# ── Snow ────────────────────────────────────────────────────────────────
	_snow_particles = CPUParticles2D.new()
	_snow_particles.emitting              = false
	_snow_particles.amount                = 100
	_snow_particles.lifetime              = 5.0
	_snow_particles.explosiveness         = 0.0
	_snow_particles.randomness            = 0.6
	_snow_particles.emission_shape        = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	_snow_particles.emission_rect_extents = Vector2(half_w, 1.0)
	_snow_particles.position              = Vector2(vp.x * 0.5, -5.0)
	_snow_particles.direction             = Vector2(0.0, 1.0)
	_snow_particles.spread                = 25.0
	_snow_particles.gravity               = Vector2(0.0, 15.0)
	_snow_particles.initial_velocity_min  = 30.0
	_snow_particles.initial_velocity_max  = 70.0
	_snow_particles.angular_velocity_min  = -45.0
	_snow_particles.angular_velocity_max  =  45.0
	_snow_particles.scale_amount_min      = 2.5
	_snow_particles.scale_amount_max      = 5.0
	_snow_particles.color                 = Color(0.92, 0.96, 1.0, 0.80)
	# 4×4 px snowflake dot
	var s_img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	s_img.fill(Color.WHITE)
	_snow_particles.texture = ImageTexture.create_from_image(s_img)
	_canvas.add_child(_snow_particles)
