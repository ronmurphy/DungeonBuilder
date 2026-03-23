extends Resource
class_name Structure

@export_subgroup("Info")
@export var display_name: String = ""
@export var category: String = "Uncategorized"

@export_subgroup("Model")
@export var model:PackedScene # Model of the structure

@export_subgroup("Gameplay")
@export var price: int   # Price of the structure when building
@export var layer: int = 0  # 0 = base (floor), 1 = decoration (walls), 2 = items (on top of everything)
@export var footprint: Vector2i = Vector2i(1, 1)  # Grid cells this structure occupies (width x depth)

@export_subgroup("Variations")
@export var variation_group: String = ""  # Structures with the same non-empty group can be cycled with C

@export_subgroup("Visuals")
@export var thumbnail: Texture2D # Preview image shown in the building picker
