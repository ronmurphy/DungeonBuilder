extends Resource
class_name DataMap

@export var cash: int = 10000
@export var structures: Array[DataStructure]
@export var map_size: int = 0   # stored so a save is self-contained
@export var map_seed: int = 0
@export var current_day: int = 0
@export var tax_rate: float = 0.08  # 0.0–0.20, player-controlled via City Hall
@export var payday_count: int = 0       # total paydays elapsed (tracks grace period)
@export var day_cycle_enabled: bool = true  # day/night colour cycle on or off
@export var visit_history: Array = []       # last N adventurer visit records
@export var milestones_earned: Dictionary = {}  # milestone key -> true
@export var total_visit_gold: int = 0       # lifetime gold earned from visits
@export var next_party_type: int = -1       # PartyType enum, -1 = not set
@export var next_party_name: String = ""    # name of next visiting party
