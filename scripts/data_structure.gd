extends Resource
class_name DataStructure

@export var position: Vector2i
@export var orientation: int
@export var structure: int
@export var layer: int = 0        # 0 = base GridMap, 1 = decoration GridMap
@export var placed_week: int = 0  # week number when this structure was placed
@export var job_slots: int = 0    # workers this building employs (0 for residential/roads)
@export var patience: int = 10    # 0–10 resident happiness (residential only; 0 = family moves out)
