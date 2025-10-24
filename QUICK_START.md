# Quick Start - GPU Collision Testing

## Just 2 Steps to Test!

### Step 1: Register GPUCollisionWorld (One-Time Setup)

1. Open Godot Editor
2. **Project → Project Settings → Autoload** tab
3. Click the **folder icon** (📁) next to "Path"
4. Navigate to and select: `scripts/GPUCollisionWorld.gd`
5. Click **"Add"** button
6. Click **"Close"**
7. **File → Save** (Ctrl+S)

**Done!** You only need to do this once.

---

### Step 2: Run the Test Scene

1. Open scene: **`scenes/GPUCollisionTest.tscn`**
2. Press **F5** (or click Play button)

**That's it!**

---

## What You'll See

### Performance HUD (Top-Left)

```
=== GPU COLLISION PERFORMANCE ===
FPS: 60 (16.7 ms/frame)
Mode: GPU Collision ✓
Collision: GPU queries active
Chunks: 9 (World: 3x3x3)

WASD/Arrows: Move
Space: Jump
ESC: Quit
```

### Color Coding

- **Green FPS (55+)**: Excellent performance ✅
- **Yellow FPS (30-55)**: Acceptable performance ⚠️
- **Red FPS (<30)**: Performance issues ❌

### What Happens

1. Player spawns at Y=50 (high above terrain)
2. Falls and lands on voxel terrain
3. Can walk around with WASD/Arrows
4. Space to jump
5. Terrain generates around player (3 chunk radius)
6. Performance stats update in real-time

---

## Controls

| Key | Action |
|-----|--------|
| **W/↑** | Move forward |
| **S/↓** | Move backward |
| **A/←** | Move left |
| **D/→** | Move right |
| **Space** | Jump |
| **ESC** | Quit |
| **Mouse** | Look around (if implemented) |

---

## Expected Performance

### With GPU Collision Enabled

- **FPS:** Steady 60 FPS
- **Mode:** "GPU Collision ✓" (cyan text)
- **Chunks:** Loads smoothly around player
- **Movement:** Smooth, no falling through terrain

### If Performance is Poor

1. **Check autoload:**
   - If "GPUCollisionWorld not found!" appears
   - Revisit Step 1

2. **Try disabling GPU-only rendering:**
   - Select VoxelTerrain node
   - Uncheck "Gpu Only Rendering"
   - Run again (will use time-budgeted decode)

3. **Reduce chunk radius:**
   - VoxelTerrain → Chunk Load Radius: 2 (instead of 3)
   - Fewer chunks = better FPS

---

## Testing Different Modes

### GPU Collision vs CPU Collision

1. **Stop the game** (F8)
2. **Select TestPlayer node** in scene tree
3. **Toggle "Use GPU Collision"** in inspector
4. **Run again** (F5)
5. **Compare performance** shown in HUD

**Expected:**
- Both should work
- GPU may be slightly faster with many chunks
- FPS difference minimal for small worlds

### GPU-Only Rendering vs Traditional

1. **Stop the game**
2. **Select VoxelTerrain node**
3. **Toggle "Gpu Only Rendering"**
4. **Run again**

**GPU-Only:** Chunks appear instantly, brief stutter
**Traditional:** Chunks fade in slowly, smooth 60 FPS

---

## Troubleshooting

### "GPUCollisionWorld not found!"

**Problem:** Autoload not registered

**Fix:**
- Project Settings → Autoload
- Add `GPUCollisionWorld.gd`
- **Restart Godot** (important!)

### Player falls through terrain

**Possible causes:**

1. **Collision buffer not populated:**
   - Check console for "collision data updated" messages
   - Should see one per chunk

2. **Player starting inside terrain:**
   - Normal - player starts high and falls
   - Should land on terrain within 2 seconds

3. **GPU collision not working:**
   - HUD shows "Mode: CPU Collision"
   - Check "Use GPU Collision" is enabled in player

### Low FPS

**Solutions:**

1. **Reduce chunk radius:** VoxelTerrain → Chunk Load Radius: 2
2. **Disable collision:** Generate Collision: false
3. **Smaller chunks:** Chunk Size: 64 (instead of 80)

### Scene won't open

**Problem:** Missing dependencies

**Fix:**
- Make sure all scripts exist:
  - `scripts/GPUCollisionWorld.gd` ✓
  - `scripts/VoxelTerrain.gd` ✓
  - `scripts/GPUCharacterBody3D.gd` ✓
  - `scripts/PerformanceHUD.gd` ✓

---

## What's Happening Under the Hood

1. **VoxelWorld** generates voxel terrain on GPU
2. **Voxel density data** sent to GPUCollisionWorld
3. **Collision buffer** rebuilt on GPU
4. **Player queries** GPU for collision (raycasts)
5. **Movement system** uses GPU results
6. **Performance HUD** displays stats

All collision detection happens on GPU!

---

## Next Steps

Once you verify it works:

1. **Read full documentation:**
   - `docs/GPU_COLLISION_SYSTEM.md`
   - `docs/GPU_COLLISION_TESTING.md`

2. **Experiment with settings:**
   - Chunk size
   - Load radius
   - Player speed
   - GPU vs CPU collision

3. **Measure performance:**
   - Note FPS with different settings
   - Compare GPU vs CPU modes
   - Test with large worlds

4. **Build your game:**
   - Use GPUCharacterBody3D for players
   - Use GPURigidBody3D for physics objects
   - Enjoy smooth collision!

---

## Success Criteria

✅ **Everything is working if you see:**

1. Performance HUD appears top-left
2. FPS shows green (60)
3. Mode shows "GPU Collision ✓"
4. Chunks show count (e.g., "9")
5. Player falls and lands on terrain
6. Can walk around smoothly
7. No falling through floor

**If all ✅ above: GPU collision is working! 🎉**

---

## Quick Reference

**File Locations:**
- Test scene: `scenes/GPUCollisionTest.tscn`
- Player scene: `scenes/TestPlayer.tscn`
- Performance HUD: `scripts/PerformanceHUD.gd`
- GPU Collision: `scripts/GPUCollisionWorld.gd`

**Important Settings:**
- VoxelTerrain → Chunk Load Radius: 3
- VoxelTerrain → Gpu Only Rendering: true
- TestPlayer → Use GPU Collision: true
- TestPlayer → Collision Radius: 0.5

**Key Files to Check:**
- All green ✅ = Ready to test!
