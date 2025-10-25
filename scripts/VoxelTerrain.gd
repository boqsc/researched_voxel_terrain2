@tool
extends Node3D

# VoxelTerrain: Chunk manager (manages chunk spawning/unloading based on player position)
# Does NOT do GPU work - that's handled by VoxelWorld singleton

# Chunk loading settings
@export_range(1, 50, 1) var chunk_load_radius: int = 3  # Load chunks within N chunks of player (horizontal XZ only)
@export var auto_load_chunks: bool = true  # Automatically load chunks around player
@export_range(1, 5, 1) var vertical_chunk_layers: int = 3  # Maximum chunk Y to load (loads from Y=-1 to Y=this value, ABSOLUTE not relative to player)
@export_range(0, 10, 1) var chunk_unload_hysteresis: int = 1  # Extra chunks beyond load_radius before unloading (prevents thrashing)
@export var use_priority_loading: bool = true  # Prioritize chunks by: 1) below player (ground first), 2) distance, 3) view direction

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

@export var generate_collision: bool = false:  # Generate collision mesh (WARNING: ~200ms per chunk on CPU, causes stutters if collision_radius is too large)
	set(value):
		generate_collision = value
		if VoxelWorld:
			VoxelWorld.generate_collision = value

@export_range(0, 10, 1) var collision_radius: int = 1:  # Collision generation (0=disabled, 1+=enabled for player's current chunk only)
	set(value):
		collision_radius = value
		if VoxelWorld:
			VoxelWorld.collision_radius = value

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
		VoxelWorld.collision_radius = collision_radius

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

		# Set initial player position in VoxelWorld (for distance-based collision)
		var initial_chunk_pos = world_to_chunk(player.global_position)
		if VoxelWorld:
			VoxelWorld.player_chunk_position = initial_chunk_pos
			print("   📍 Initial player chunk position: ", initial_chunk_pos)

	# Get player's current chunk position
	var player_chunk_pos = world_to_chunk(player.global_position)

	# Only update if player moved to a different chunk
	if player_chunk_pos != last_player_chunk:
		print("📍 Player moved to chunk ", player_chunk_pos, " (from ", last_player_chunk, ")")
		print("   Player world position: ", player.global_position)
		print("   Active chunks: ", active_chunks.size())
		last_player_chunk = player_chunk_pos

		# Update VoxelWorld with player position (for distance-based collision)
		if VoxelWorld:
			VoxelWorld.player_chunk_position = player_chunk_pos

		# Update collision for chunks based on new player position
		_update_collision_for_nearby_chunks(player_chunk_pos)

		update_chunks_around_player(player_chunk_pos)

func _update_collision_for_nearby_chunks(player_chunk_pos: Vector3i):
	"""Check if player's current chunk needs collision added"""
	if not generate_collision or collision_radius == 0:
		return  # Collision disabled globally

	# Only check the exact chunk player is standing in
	if active_chunks.has(player_chunk_pos):
		var chunk = active_chunks[player_chunk_pos]
		if not chunk.has_collision:
			print("   🔄 Player entered chunk ", player_chunk_pos, ", requesting collision")
			if VoxelWorld:
				VoxelWorld.request_collision_for_chunks([player_chunk_pos], active_chunks)

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

	# Use ABSOLUTE vertical range instead of relative to player
	# This prevents terrain from regenerating when player changes height
	var y_start = -1  # Load from chunk Y = -1 (below ground)
	var y_end = vertical_chunk_layers  # Up to configured layers (default = 3)

	for x in range(-chunk_load_radius, chunk_load_radius + 1):
		for z in range(-chunk_load_radius, chunk_load_radius + 1):
			for y in range(y_start, y_end):  # FIXED vertical range, not relative to player
				var chunk_pos = Vector3i(center.x + x, y, center.z + z)  # Only use center for XZ

				# Skip if already active
				if active_chunks.has(chunk_pos):
					continue

				chunks_to_load.append(chunk_pos)

	if chunks_to_load.size() > 0:
		print("📋 Loading ", chunks_to_load.size(), " chunks around player at ", center)

		# Sort chunks by priority if enabled
		if use_priority_loading:
			chunks_to_load = _sort_chunks_by_priority(chunks_to_load, center)

		for chunk_pos in chunks_to_load:
			VoxelWorld.request_chunk(chunk_pos)

	# Unload distant chunks (horizontal distance only)
	var chunks_to_unload = []
	for chunk_pos in active_chunks.keys():
		var horizontal_dist = _chunk_distance_horizontal(chunk_pos, center)
		if horizontal_dist > chunk_load_radius + chunk_unload_hysteresis:  # Use configurable hysteresis
			chunks_to_unload.append(chunk_pos)

	if chunks_to_unload.size() > 0:
		print("🗑️ Unloading ", chunks_to_unload.size(), " distant chunks")
		for chunk_pos in chunks_to_unload:
			_unload_chunk(chunk_pos)

func _chunk_distance(a: Vector3i, b: Vector3i) -> float:
	"""Calculate distance between two chunk positions (3D)"""
	var diff = a - b
	return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)

func _chunk_distance_horizontal(a: Vector3i, b: Vector3i) -> float:
	"""Calculate horizontal (XZ) distance between two chunk positions"""
	var diff_x = a.x - b.x
	var diff_z = a.z - b.z
	return sqrt(diff_x * diff_x + diff_z * diff_z)

func _sort_chunks_by_priority(chunks: Array, player_chunk_pos: Vector3i) -> Array:
	"""Sort chunks by loading priority: 1) below player, 2) close distance, 3) view direction"""

	# Get player camera direction if available
	var camera_forward = Vector3.FORWARD
	if player:
		var camera = player.get_node_or_null("Camera3D")
		if camera:
			camera_forward = -camera.global_transform.basis.z  # Camera forward direction

	# Calculate priority for each chunk
	var chunk_priorities = []
	for chunk_pos in chunks:
		var priority = _calculate_chunk_priority(chunk_pos, player_chunk_pos, camera_forward)
		chunk_priorities.append({"chunk_pos": chunk_pos, "priority": priority})

	# Sort by priority (higher = better = loads first)
	chunk_priorities.sort_custom(func(a, b): return a.priority > b.priority)

	# Extract sorted chunk positions
	var sorted_chunks = []
	for item in chunk_priorities:
		sorted_chunks.append(item.chunk_pos)

	return sorted_chunks

func _calculate_chunk_priority(chunk_pos: Vector3i, player_chunk_pos: Vector3i, camera_forward: Vector3) -> float:
	"""Calculate loading priority for a chunk (higher = loads sooner)"""
	var priority = 0.0

	# PRIORITY 1: Below player gets MASSIVE boost (need ground first!)
	# If chunk is at or below player's Y position, boost priority
	if chunk_pos.y <= player_chunk_pos.y:
		priority += 1000.0  # Ground chunks load first!
		# Extra boost for chunks directly below player
		if chunk_pos.y < player_chunk_pos.y:
			priority += (player_chunk_pos.y - chunk_pos.y) * 100.0

	# PRIORITY 2: Distance (closer = better)
	var distance = _chunk_distance(chunk_pos, player_chunk_pos)
	priority += 100.0 / (distance + 0.1)  # Avoid divide by zero

	# PRIORITY 3: View direction (chunks player is looking at)
	# Calculate direction from player to chunk
	var chunk_world_pos = Vector3(
		chunk_pos.x * VoxelWorld.chunk_size * VoxelWorld.voxel_size,
		chunk_pos.y * VoxelWorld.chunk_size * VoxelWorld.voxel_size,
		chunk_pos.z * VoxelWorld.chunk_size * VoxelWorld.voxel_size
	)
	var player_world_pos = Vector3(
		player_chunk_pos.x * VoxelWorld.chunk_size * VoxelWorld.voxel_size,
		player_chunk_pos.y * VoxelWorld.chunk_size * VoxelWorld.voxel_size,
		player_chunk_pos.z * VoxelWorld.chunk_size * VoxelWorld.voxel_size
	)
	var to_chunk = (chunk_world_pos - player_world_pos).normalized()

	# Dot product: 1.0 = directly ahead, -1.0 = directly behind
	var view_alignment = to_chunk.dot(camera_forward)
	if view_alignment > 0:  # In front of player
		priority += view_alignment * 50.0  # Chunks in view get boost

	return priority

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
