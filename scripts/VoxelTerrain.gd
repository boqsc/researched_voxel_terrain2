@tool
extends Node3D

# VoxelTerrain: Chunk manager (manages chunk spawning/unloading based on player position)
# Does NOT do GPU work - that's handled by VoxelWorld singleton

@export_range(1, 10, 1) var chunk_load_radius: int = 3  # Load chunks within N chunks of player
@export var auto_load_chunks: bool = true  # Automatically load chunks around player

var player: Node3D
var active_chunks: Dictionary = {}  # Vector3i -> VoxelChunk instance
var last_player_chunk: Vector3i = Vector3i(999999, 999999, 999999)  # Force initial load

func _ready():
	if Engine.is_editor_hint():
		print("🧰 VoxelTerrain running in editor mode")
		# In editor, generate a single chunk at origin for preview
		_request_single_chunk(Vector3i.ZERO)
	else:
		print("▶️ VoxelTerrain running in game mode")

	# Connect to VoxelWorld chunk_ready signal
	if VoxelWorld:
		VoxelWorld.chunk_ready.connect(_on_chunk_ready)
		print("✅ Connected to VoxelWorld.chunk_ready signal")
	else:
		push_error("VoxelWorld singleton not found! Is it registered as autoload?")

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

	# Get player's current chunk position
	var player_chunk_pos = world_to_chunk(player.global_position)

	# Only update if player moved to a different chunk
	if player_chunk_pos != last_player_chunk:
		last_player_chunk = player_chunk_pos
		update_chunks_around_player(player_chunk_pos)

func world_to_chunk(world_pos: Vector3) -> Vector3i:
	"""Convert world position to chunk position"""
	var chunk_size = VoxelWorld.chunk_size if VoxelWorld else 80
	var voxel_size = VoxelWorld.voxel_size if VoxelWorld else 1.0
	var chunk_world_size = chunk_size * voxel_size

	return Vector3i(
		floori(world_pos.x / chunk_world_size),
		floori(world_pos.y / chunk_world_size),
		floori(world_pos.z / chunk_world_size)
	)

func update_chunks_around_player(center: Vector3i):
	"""Load chunks in radius around player, unload distant chunks"""
	# Load chunks in radius
	var chunks_to_load = []
	for x in range(-chunk_load_radius, chunk_load_radius + 1):
		for z in range(-chunk_load_radius, chunk_load_radius + 1):
			for y in range(-1, 2):  # Load 3 vertical layers (below, at, above player)
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
		if distance > chunk_load_radius + 1:  # +1 for hysteresis
			chunks_to_unload.append(chunk_pos)

	if chunks_to_unload.size() > 0:
		print("🗑️ Unloading ", chunks_to_unload.size(), " distant chunks")
		for chunk_pos in chunks_to_unload:
			_unload_chunk(chunk_pos)

func _chunk_distance(a: Vector3i, b: Vector3i) -> float:
	"""Calculate distance between two chunk positions"""
	var diff = a - b
	return sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z)

func _request_single_chunk(chunk_pos: Vector3i):
	"""Request a single chunk (used in editor mode)"""
	if VoxelWorld:
		VoxelWorld.request_chunk(chunk_pos)

func _on_chunk_ready(chunk_pos: Vector3i, mesh_data: Dictionary):
	"""Called when VoxelWorld has generated a chunk"""
	# Skip if chunk already exists
	if active_chunks.has(chunk_pos):
		print("⚠️ Chunk ", chunk_pos, " already exists, skipping")
		return

	print("📦 Spawning chunk at ", chunk_pos)

	# Create chunk instance
	var chunk = preload("res://scripts/VoxelChunk.gd").new(chunk_pos)

	# Position chunk in world
	var chunk_size = VoxelWorld.chunk_size if VoxelWorld else 80
	var voxel_size = VoxelWorld.voxel_size if VoxelWorld else 1.0
	var chunk_world_size = chunk_size * voxel_size
	chunk.global_position = Vector3(chunk_pos) * chunk_world_size

	# Add to scene
	add_child(chunk)

	# Apply mesh data
	chunk.apply_mesh_data(mesh_data)

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

func _exit_tree():
	# Cleanup all chunks
	for chunk_pos in active_chunks.keys():
		var chunk = active_chunks[chunk_pos]
		chunk.cleanup()
	active_chunks.clear()
