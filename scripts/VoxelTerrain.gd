@tool
extends Node3D

# VoxelTerrain: Chunk manager (manages chunk spawning/unloading based on player position)
# Does NOT do GPU work - that's handled by VoxelWorld singleton

# Chunk loading settings
@export_range(1, 50, 1) var chunk_load_radius: int = 3  # Load chunks within N chunks of player
@export var auto_load_chunks: bool = true  # Automatically load chunks around player
@export_range(1, 5, 1) var vertical_chunk_layers: int = 3  # Number of vertical chunk layers to load (centered on player)
@export_range(0, 10, 1) var chunk_unload_hysteresis: int = 1  # Extra chunks beyond load_radius before unloading (prevents thrashing)

# Chunk decoding settings (controls CPU work for vertex unpacking)
@export var use_smooth_chunk_loading: bool = true:  # Spread vertex decoding over frames (true=smooth) or load instantly (false=stutter)
	set(value):
		use_smooth_chunk_loading = value
		if VoxelWorld:
			VoxelWorld.use_smooth_chunk_loading = value

@export_range(1, 100, 1) var chunk_decode_time_budget_percent: int = 10:  # % of frame time for vertex decoding (10% ≈ 1.6ms at 60fps)
	set(value):
		chunk_decode_time_budget_percent = value
		if VoxelWorld:
			VoxelWorld.chunk_decode_time_budget_percent = value

@export var generate_collision: bool = false:  # Generate collision mesh (WARNING: ~200-300ms per chunk on CPU, causes stutters)
	set(value):
		generate_collision = value
		if VoxelWorld:
			VoxelWorld.generate_collision = value

# Editor preview settings
@export_range(1, 20, 1) var editor_preview_chunks: int = 1:  # How many chunks to show in editor (was max 5, now 20)
	set(value):
		editor_preview_chunks = value
		_on_editor_param_changed()

# Terrain generation parameters (updates VoxelWorld singleton)
@export_range(8, 256, 8) var chunk_size: int = 80:
	set(value):
		chunk_size = value
		if VoxelWorld:
			VoxelWorld.chunk_size = value
		_on_editor_param_changed()

@export_range(0.1, 10.0, 0.1) var voxel_size: float = 1.0:
	set(value):
		voxel_size = value
		if VoxelWorld:
			VoxelWorld.voxel_size = value
		_on_editor_param_changed()

@export_range(0.001, 1.0, 0.001) var noise_scale: float = 0.1:
	set(value):
		noise_scale = value
		if VoxelWorld:
			VoxelWorld.noise_scale = value
		_on_editor_param_changed()

@export_range(-20.0, 20.0, 0.1) var height_scale: float = 8.0:
	set(value):
		height_scale = value
		if VoxelWorld:
			VoxelWorld.height_scale = value
		_on_editor_param_changed()

@export_range(0.005, 0.1, 0.005) var visibility_ratio: float = 0.01:
	set(value):
		visibility_ratio = value
		if VoxelWorld:
			VoxelWorld.visibility_ratio = value
		_on_editor_param_changed()

var player: Node3D
var active_chunks: Dictionary = {}  # Vector3i -> VoxelChunk instance
var last_player_chunk: Vector3i = Vector3i(999999, 999999, 999999)  # Force initial load
var initial_chunks_requested: bool = false
var _update_timer: SceneTreeTimer  # For debouncing editor updates

func _ready():
	# Apply parameters to VoxelWorld
	if VoxelWorld:
		VoxelWorld.chunk_size = chunk_size
		VoxelWorld.voxel_size = voxel_size
		VoxelWorld.noise_scale = noise_scale
		VoxelWorld.height_scale = height_scale
		VoxelWorld.visibility_ratio = visibility_ratio
		VoxelWorld.use_smooth_chunk_loading = use_smooth_chunk_loading
		VoxelWorld.chunk_decode_time_budget_percent = chunk_decode_time_budget_percent
		VoxelWorld.generate_collision = generate_collision

	# Connect to VoxelWorld signals
	if VoxelWorld:
		VoxelWorld.chunk_ready.connect(_on_chunk_ready)
		VoxelWorld.collision_ready.connect(_on_collision_ready)
		print("✅ Connected to VoxelWorld signals (chunk_ready, collision_ready)")
	else:
		push_error("VoxelWorld singleton not found! Is it registered as autoload?")

	if Engine.is_editor_hint():
		print("🧰 VoxelTerrain running in editor mode")
		# In editor, generate chunks for preview
		_generate_editor_preview()
	else:
		print("▶️ VoxelTerrain running in game mode")
		# In game mode, generate initial chunks immediately at origin
		# This ensures player has ground to land on
		print("🌍 Generating initial chunks at origin...")
		_generate_initial_chunks()

func _on_editor_param_changed():
	"""Called when parameters change in editor - regenerate terrain"""
	if not Engine.is_editor_hint():
		return

	if not is_inside_tree():
		# During initial loading, ignore updates
		return

	# Debounce rapid editor updates (e.g. dragging sliders)
	if _update_timer and _update_timer.timeout.is_connected(_do_editor_update):
		_update_timer.timeout.disconnect(_do_editor_update)
	_update_timer = get_tree().create_timer(0.3, false)  # 300ms debounce
	_update_timer.timeout.connect(_do_editor_update)

func _do_editor_update():
	"""Regenerate terrain after debounce delay"""
	if not Engine.is_editor_hint():
		return
	if not is_inside_tree():
		return

	print("🔄 Editor parameter changed — regenerating terrain...")

	# Clear all existing chunks from VoxelTerrain
	for chunk_pos in active_chunks.keys():
		var chunk = active_chunks[chunk_pos]
		chunk.cleanup()
	active_chunks.clear()

	# IMPORTANT: Also clear chunks from VoxelWorld so they can be regenerated
	if VoxelWorld:
		VoxelWorld.chunks.clear()
		VoxelWorld.generation_queue.clear()

	# Regenerate preview
	_generate_editor_preview()

func _generate_editor_preview():
	"""Generate chunks for editor preview based on editor_preview_chunks setting"""
	var half_size = floori(editor_preview_chunks / 2.0)  # Fix integer division warning
	var chunk_count = 0

	print("   📋 Generating ", editor_preview_chunks, "x", editor_preview_chunks, " chunk grid for editor preview")

	for x in range(-half_size, half_size + (editor_preview_chunks % 2)):
		for z in range(-half_size, half_size + (editor_preview_chunks % 2)):
			VoxelWorld.request_chunk(Vector3i(x, 0, z))
			chunk_count += 1

	print("   📋 Requested ", chunk_count, " chunks for editor preview")

func _generate_initial_chunks():
	"""Generate initial chunks around origin so player has ground to spawn on"""
	# Generate chunks in a 3x3 grid at y=0 (ground level)
	for x in range(-1, 2):
		for z in range(-1, 2):
			VoxelWorld.request_chunk(Vector3i(x, 0, z))
	initial_chunks_requested = true
	print("   📋 Requested 9 initial chunks (3x3 grid at ground level)")

func _process(_delta):
	if Engine.is_editor_hint():
		return  # Don't auto-load chunks in editor

	if not auto_load_chunks:
		return

	# Find player
	if not player:
		player = get_tree().get_first_node_in_group("player")
		if not player:
			return  # Player not found yet
		print("🎮 Player found! Starting chunk loading system...")

	# Get player's current chunk position
	var player_chunk_pos = world_to_chunk(player.global_position)

	# Only update if player moved to a different chunk
	if player_chunk_pos != last_player_chunk:
		print("📍 Player moved to chunk ", player_chunk_pos, " (from ", last_player_chunk, ")")
		print("   Player world position: ", player.global_position)
		print("   Active chunks: ", active_chunks.size())
		last_player_chunk = player_chunk_pos
		update_chunks_around_player(player_chunk_pos)

func world_to_chunk(world_pos: Vector3) -> Vector3i:
	"""Convert world position to chunk position"""
	var _chunk_size = VoxelWorld.chunk_size if VoxelWorld else 80
	var _voxel_size = VoxelWorld.voxel_size if VoxelWorld else 1.0
	var chunk_world_size = _chunk_size * _voxel_size

	return Vector3i(
		floori(world_pos.x / chunk_world_size),
		floori(world_pos.y / chunk_world_size),
		floori(world_pos.z / chunk_world_size)
	)

func update_chunks_around_player(center: Vector3i):
	"""Load chunks in radius around player, unload distant chunks"""
	# Load chunks in radius
	var chunks_to_load = []
	var y_half = floori(vertical_chunk_layers / 2.0)
	var y_range_start = -y_half
	var y_range_end = y_half + (vertical_chunk_layers % 2)  # Add 1 if odd number

	for x in range(-chunk_load_radius, chunk_load_radius + 1):
		for z in range(-chunk_load_radius, chunk_load_radius + 1):
			for y in range(y_range_start, y_range_end):  # Use configurable vertical layers
				var chunk_pos = center + Vector3i(x, y, z)

				# Skip if already active
				if active_chunks.has(chunk_pos):
					continue

				chunks_to_load.append(chunk_pos)

	if chunks_to_load.size() > 0:
		print("📋 Loading ", chunks_to_load.size(), " chunks around player at ", center)
		for chunk_pos in chunks_to_load:
			VoxelWorld.request_chunk(chunk_pos)

	# Unload distant chunks
	var chunks_to_unload = []
	for chunk_pos in active_chunks.keys():
		var distance = _chunk_distance(chunk_pos, center)
		if distance > chunk_load_radius + chunk_unload_hysteresis:  # Use configurable hysteresis
			chunks_to_unload.append(chunk_pos)

	if chunks_to_unload.size() > 0:
		print("🗑️ Unloading ", chunks_to_unload.size(), " distant chunks")
		for chunk_pos in chunks_to_unload:
			_unload_chunk(chunk_pos)

func _chunk_distance(a: Vector3i, b: Vector3i) -> float:
	"""Calculate distance between two chunk positions"""
	var diff = a - b
	return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)

func _on_chunk_ready(chunk_pos: Vector3i, mesh_data: Dictionary, enable_collision: bool):
	"""Called when VoxelWorld has generated a chunk"""
	# Skip if chunk already exists
	if active_chunks.has(chunk_pos):
		print("⚠️ Chunk ", chunk_pos, " already exists, skipping")
		return

	print("📦 Spawning chunk at ", chunk_pos)

	# Create chunk instance
	var chunk = preload("res://scripts/VoxelChunk.gd").new(chunk_pos)

	# Add to scene FIRST (required before setting global_position)
	add_child(chunk)

	# Position chunk in world (after adding to tree)
	var _chunk_size = VoxelWorld.chunk_size if VoxelWorld else 80
	var _voxel_size = VoxelWorld.voxel_size if VoxelWorld else 1.0
	var chunk_world_size = _chunk_size * _voxel_size
	chunk.global_position = Vector3(chunk_pos) * chunk_world_size

	# Apply mesh data with collision setting
	chunk.apply_mesh_data(mesh_data, enable_collision)

	# Track active chunk
	active_chunks[chunk_pos] = chunk

	print("✅ Chunk ", chunk_pos, " spawned successfully (", active_chunks.size(), " chunks active)")

func _unload_chunk(chunk_pos: Vector3i):
	"""Unload a chunk and free its resources"""
	if not active_chunks.has(chunk_pos):
		return

	var chunk = active_chunks[chunk_pos]
	active_chunks.erase(chunk_pos)

	# Cleanup and remove
	chunk.cleanup()

	# Tell VoxelWorld to unload
	if VoxelWorld:
		VoxelWorld.unload_chunk(chunk_pos)

func _on_collision_ready(chunk_pos: Vector3i, mesh_data: Dictionary):
	"""Called when VoxelWorld has generated collision for a chunk"""
	# Find the chunk and add collision
	if not active_chunks.has(chunk_pos):
		print("⚠️ Collision ready for chunk ", chunk_pos, " but chunk not found")
		return

	var chunk = active_chunks[chunk_pos]
	chunk.add_collision(mesh_data)

func _exit_tree():
	# Cleanup all chunks
	for chunk_pos in active_chunks.keys():
		var chunk = active_chunks[chunk_pos]
		chunk.cleanup()
	active_chunks.clear()
