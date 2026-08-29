## A saveable list of per-frame resources — the ArrayMesh of every
## animation frame of a .3D, or the textures of a .CFA viewmodel. The
## asset cache (asset_cache.gd) stores one of these per animated model
## so a whole frame strip loads with a single ResourceLoader call.

extends Resource

@export var frames: Array = []
