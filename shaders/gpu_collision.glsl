#[compute]
#version 450

// GPU Collision Detection Shader
// Performs raycasts and overlap tests on GPU against voxel terrain
// Results can be queried by CharacterBody3D/RigidBody3D on CPU

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Input: Voxel density data from all chunks
layout(set = 0, binding = 0, std430) restrict buffer readonly VoxelCollisionData {
    float density[];  // Flat array of all voxel densities
} voxel_collision;

// Input: Collision queries (raycasts, sphere casts, etc.)
layout(set = 0, binding = 1, std430) restrict buffer readonly CollisionQueries {
    // Each query: type(uint), origin(vec3), direction(vec3), max_distance(float), radius(float)
    // Total: 9 floats per query
    float queries[];
} collision_queries;

// Output: Collision results
layout(set = 0, binding = 2, std430) restrict buffer writeonly CollisionResults {
    // Each result: hit(uint), position(vec3), normal(vec3), distance(float)
    // Total: 8 floats per result
    float results[];
} collision_results;

// Parameters
layout(set = 0, binding = 3, std430) restrict buffer readonly CollisionParams {
    uint query_count;
    uint num_chunks;      // Number of loaded chunks (SPARSE)
    uint chunk_size;      // Voxels per chunk axis
    float voxel_size;     // Size of each voxel
    // Followed by chunk metadata: [chunk_pos_x, chunk_pos_y, chunk_pos_z, buffer_offset] * num_chunks
    int chunk_data[];     // [x, y, z, offset, x, y, z, offset, ...]
} params;

// Query types
const uint QUERY_RAYCAST = 0;
const uint QUERY_SPHERE_CAST = 1;
const uint QUERY_BOX_CAST = 2;

// Get voxel density at world position (SPARSE buffer lookup)
float get_voxel_density(vec3 world_pos) {
    // Convert world position to voxel grid coordinates
    ivec3 voxel_pos = ivec3(floor(world_pos / params.voxel_size));

    // Calculate chunk coordinates
    int chunk_size_int = int(params.chunk_size);
    ivec3 chunk_coord = voxel_pos / chunk_size_int;
    ivec3 local_voxel = voxel_pos - (chunk_coord * chunk_size_int);

    // Bounds check local voxel
    if (local_voxel.x < 0 || local_voxel.x >= chunk_size_int ||
        local_voxel.y < 0 || local_voxel.y >= chunk_size_int ||
        local_voxel.z < 0 || local_voxel.z >= chunk_size_int) {
        return -1.0;
    }

    // SPARSE: Search for chunk in loaded chunks list
    int chunk_buffer_offset = -1;
    for (uint i = 0; i < params.num_chunks; i++) {
        uint base = i * 4; // Each chunk entry: x, y, z, offset
        if (params.chunk_data[base + 0] == chunk_coord.x &&
            params.chunk_data[base + 1] == chunk_coord.y &&
            params.chunk_data[base + 2] == chunk_coord.z) {
            chunk_buffer_offset = params.chunk_data[base + 3];
            break;
        }
    }

    // Chunk not loaded
    if (chunk_buffer_offset < 0) {
        return -1.0;
    }

    // Calculate voxel offset within chunk
    uint voxel_offset = uint(local_voxel.x) +
                       uint(local_voxel.y) * params.chunk_size +
                       uint(local_voxel.z) * params.chunk_size * params.chunk_size;

    uint index = uint(chunk_buffer_offset) + voxel_offset;

    // Bounds check on buffer
    if (index >= voxel_collision.density.length()) {
        return -1.0;
    }

    return voxel_collision.density[index];
}

// Perform raycast in voxel grid
void raycast(vec3 origin, vec3 direction, float max_distance, uint result_index) {
    vec3 current_pos = origin;
    vec3 step_dir = normalize(direction);
    float step_size = params.voxel_size * 0.5; // Half voxel for accuracy
    float distance = 0.0;

    // DDA-like traversal
    while (distance < max_distance) {
        float density = get_voxel_density(current_pos);

        // Hit solid voxel
        if (density > 0.0) {
            // Write result
            uint offset = result_index * 8;
            collision_results.results[offset + 0] = 1.0; // hit = true
            collision_results.results[offset + 1] = current_pos.x;
            collision_results.results[offset + 2] = current_pos.y;
            collision_results.results[offset + 3] = current_pos.z;

            // Calculate normal (sample nearby voxels)
            vec3 normal = vec3(0.0, 1.0, 0.0); // Default up
            float dx = get_voxel_density(current_pos + vec3(step_size, 0, 0)) -
                      get_voxel_density(current_pos - vec3(step_size, 0, 0));
            float dy = get_voxel_density(current_pos + vec3(0, step_size, 0)) -
                      get_voxel_density(current_pos - vec3(0, step_size, 0));
            float dz = get_voxel_density(current_pos + vec3(0, 0, step_size)) -
                      get_voxel_density(current_pos - vec3(0, 0, step_size));

            vec3 gradient = vec3(dx, dy, dz);
            if (length(gradient) > 0.001) {
                normal = -normalize(gradient);
            }

            collision_results.results[offset + 4] = normal.x;
            collision_results.results[offset + 5] = normal.y;
            collision_results.results[offset + 6] = normal.z;
            collision_results.results[offset + 7] = distance;
            return;
        }

        // Step forward
        current_pos += step_dir * step_size;
        distance += step_size;
    }

    // No hit
    uint offset = result_index * 8;
    collision_results.results[offset + 0] = 0.0; // hit = false
    collision_results.results[offset + 7] = max_distance;
}

// Perform sphere cast (raycast with radius)
void sphere_cast(vec3 origin, vec3 direction, float max_distance, float radius, uint result_index) {
    // Simplified: Sample multiple raycasts around the sphere
    // For a proper sphere cast, we'd check cylinder + sphere caps

    vec3 step_dir = normalize(direction);
    vec3 current_pos = origin;
    float step_size = params.voxel_size * 0.5;
    float distance = 0.0;

    while (distance < max_distance) {
        // Check sphere at current position
        bool hit = false;

        // Sample points around sphere (simplified, 6 directions)
        vec3 offsets[6] = vec3[](
            vec3(radius, 0, 0),
            vec3(-radius, 0, 0),
            vec3(0, radius, 0),
            vec3(0, -radius, 0),
            vec3(0, 0, radius),
            vec3(0, 0, -radius)
        );

        for (int i = 0; i < 6; i++) {
            if (get_voxel_density(current_pos + offsets[i]) > 0.0) {
                hit = true;
                break;
            }
        }

        if (hit) {
            // Write hit result
            uint offset = result_index * 8;
            collision_results.results[offset + 0] = 1.0;
            collision_results.results[offset + 1] = current_pos.x;
            collision_results.results[offset + 2] = current_pos.y;
            collision_results.results[offset + 3] = current_pos.z;
            collision_results.results[offset + 4] = 0.0;
            collision_results.results[offset + 5] = 1.0;
            collision_results.results[offset + 6] = 0.0;
            collision_results.results[offset + 7] = distance;
            return;
        }

        current_pos += step_dir * step_size;
        distance += step_size;
    }

    // No hit
    uint offset = result_index * 8;
    collision_results.results[offset + 0] = 0.0;
    collision_results.results[offset + 7] = max_distance;
}

void main() {
    uint query_index = gl_GlobalInvocationID.x;

    if (query_index >= params.query_count) {
        return;
    }

    // Read query data
    uint query_offset = query_index * 9;
    uint query_type = uint(collision_queries.queries[query_offset + 0]);
    vec3 origin = vec3(
        collision_queries.queries[query_offset + 1],
        collision_queries.queries[query_offset + 2],
        collision_queries.queries[query_offset + 3]
    );
    vec3 direction = vec3(
        collision_queries.queries[query_offset + 4],
        collision_queries.queries[query_offset + 5],
        collision_queries.queries[query_offset + 6]
    );
    float max_distance = collision_queries.queries[query_offset + 7];
    float radius = collision_queries.queries[query_offset + 8];

    // Perform query based on type
    if (query_type == QUERY_RAYCAST) {
        raycast(origin, direction, max_distance, query_index);
    } else if (query_type == QUERY_SPHERE_CAST) {
        sphere_cast(origin, direction, max_distance, radius, query_index);
    }
    // Add more query types as needed
}
