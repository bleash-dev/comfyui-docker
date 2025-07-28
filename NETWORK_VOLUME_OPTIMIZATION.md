# Network Volume Optimization

This document describes the network volume optimization feature that improves performance by using symlinks for shared data when a persistent network volume is available.

## Overview

The optimization uses an additional environment variable `_NETWORK_VOLUME` to specify a persistent network storage location that can be shared across multiple pod instances. When available, the system creates symlinks to avoid repeatedly downloading and extracting shared data.

## Environment Variables

- `NETWORK_VOLUME`: Main pod storage volume (existing)
- `_NETWORK_VOLUME`: Additional persistent network volume for shared data optimization (new)

## Setup

During pod creation, optionally pass the network volume mount point:

```javascript
env._NETWORK_VOLUME = userVolumes.workspace.mountPath;
```

## How It Works

### During Data Restoration (sync_user_data_from_s3.sh)

1. **Check Network Volume**: If `_NETWORK_VOLUME` is set and accessible, enable optimization
2. **Try Symlinks First**: For shared folders (venv, .comfyui, .cache, custom_nodes), attempt to create symlinks from network volume
3. **Fallback to Download**: If network volume doesn't have the data or symlink fails, download from S3 as usual

### During Data Sync (sync_user_shared_data.sh)

1. **Copy to Network Volume**: If pod has shared data and network volume doesn't, copy from pod to network volume
2. **Sync from Network Volume**: Use network volume data for S3 upload instead of pod local data
3. **Preserve Data**: Subsequent pods can use the data via symlinks without re-downloading

## Supported Shared Data

### User-Level Shared Data
- `venv/` - Virtual environments (chunked optimization)
- `.comfyui/` - ComfyUI configuration
- `.cache/` - Cache directories

### ComfyUI Shared Data
- `ComfyUI/custom_nodes/` - Custom nodes and extensions

## Benefits

1. **Faster Startup**: Shared data available via symlinks instead of downloads
2. **Reduced Bandwidth**: No need to re-download shared data for each pod
3. **Consistency**: Shared data remains consistent across pod instances
4. **Backward Compatibility**: Falls back to standard sync if network volume unavailable

## File Structure

### Without Network Volume Optimization
```
NETWORK_VOLUME/
├── venv/
├── .comfyui/
├── .cache/
└── ComfyUI/
    └── custom_nodes/
```

### With Network Volume Optimization
```
NETWORK_VOLUME/
├── venv/ -> /_NETWORK_VOLUME/venv/
├── .comfyui/ -> /_NETWORK_VOLUME/.comfyui/
├── .cache/ -> /_NETWORK_VOLUME/.cache/
└── ComfyUI/
    └── custom_nodes/ -> /_NETWORK_VOLUME/ComfyUI/custom_nodes/

_NETWORK_VOLUME/
├── venv/
├── .comfyui/
├── .cache/
└── ComfyUI/
    └── custom_nodes/
```

## Implementation Details

### Helper Functions

- `is_directory_usable()`: Check if directory exists and is accessible
- `try_symlink_from_network_volume()`: Attempt to create symlink from network volume
- `copy_to_network_volume_and_sync()`: Copy data to network volume for syncing
- `get_sync_source_path()`: Determine optimal path for syncing (network volume vs pod local)

### Logging and Monitoring

The scripts provide detailed logging about:
- Network volume availability
- Symlink creation success/failure
- Data copying operations
- Optimization status in sync summaries

## Error Handling

- If `_NETWORK_VOLUME` is set but inaccessible, optimization is disabled
- If symlink creation fails, falls back to standard download
- If network volume copy fails, uses pod local data for sync
- All errors are logged with appropriate warnings

## Deployment Considerations

1. Ensure `_NETWORK_VOLUME` path is writable by the container
2. Network volume should be persistent across pod restarts
3. Consider network volume performance characteristics
4. Monitor disk usage on network volume

## Backward Compatibility

The optimization is fully backward compatible:
- If `_NETWORK_VOLUME` is not set, operates as before
- If network volume is unavailable, falls back to standard sync
- Existing S3 sync behavior remains unchanged
