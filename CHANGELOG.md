# Changelog - PVE GPU Dashboard Mod

All notable changes to this project will be documented in this file.

## [v3.0] - 2025-12-26

### Added
- **PVE 9.x Compatibility**: Full support for Proxmox VE 9.x while maintaining PVE 8.x compatibility
  - Tested on PVE 9.1.2 with NVIDIA GeForce RTX 5090

### Fixed
- **Historical Charts Not Showing on PVE 9**: Fixed GPU historical charts not appearing on PVE 9.x
  - Root cause: PVE 9.x changed `'Network traffic'` to `'Network Traffic'` (capital 'T')
  - Solution: Updated regex pattern to be case-insensitive: `'Network [Tt]raffic'`
  - Also added optional `fieldTitles` matching for future compatibility

### Technical Details
- Pattern matching now handles both PVE 8.x and 9.x JavaScript structure
- PVE 9.x added new charts (CPU/IO/Memory Pressure Stall) - GPU charts insert correctly after Network Traffic
- `nodename` variable scope verified to work in both versions

### Tested On
- Proxmox VE 9.1.2 (pve-manager 9.1.2)
- NVIDIA Driver 580.82.09
- CUDA 13.0
- NVIDIA GeForce RTX 5090

---

## [v2.0] - 2025-12-26

### Added
- **Historical GPU Graphs**: Added GPU metrics graphs below Network traffic section
  - GPU Temperature graph (shows temperature trends over time)
  - GPU VRAM Usage graph (shows memory consumption over time)
  - GPU Power Draw graph (shows power consumption history)
- **Browser-side Data Collection**: Custom chart component using localStorage
  - Configurable history duration during install
  - Data persists across page refreshes (browser-specific)
- **Configurable History Duration**: Choose from three options during install:
  - 24 hours (1-minute intervals, 1,440 points, ~144 KB/GPU) - Maximum detail for recent troubleshooting
  - 1 week (1-minute intervals, 10,080 points, ~1 MB/GPU) - Still detailed for weekly patterns
  - 30 days (5-minute intervals, 8,640 points, ~864 KB/GPU) - Good balance for long-term trends
- **Native PVE Chart Styling**: Uses `proxmoxRRDChart` component for identical look to CPU/Memory/Network charts
  - Same line graph style with area fill
  - Same grid lines and Y-axis formatting
  - Same tooltip behavior
  - Same zoom interaction
  - Automatic unit formatting (bytes, percent, etc.)
- **Fan Speed Display**: Added fan speed percentage to GPU metrics display
  - Shows `Fan: X%` in metrics line (e.g., `GPU: 0% | Temp: 44°C | Power: 14/200W | Fan: 30%`)
  - Gracefully handles passively cooled GPUs that report N/A (fan info hidden)

### Changed
- **Major version bump**: v2.0 marks the addition of historical graphs as a new feature set
- **Numeric field conversion**: GPU metrics now forced to numeric type for API compatibility
- **Script version tracking**: Added `SCRIPT_VERSION` variable for easier version identification

### Technical Details
- Custom ExtJS store `PVE.data.GPUHistoryStore` extends `Ext.data.Store`
- Uses `proxmoxRRDChart` component for native PVE chart appearance
- Polling interval configured at install time (1 min for 24h/1week, 5 min for 30 days)
- localStorage keys: `pve-gpu-rrd-{node}-gpu{index}`
- Charts inserted after Network traffic section in node Summary
- API endpoint: `/nodes/{nodename}/status` (same as dashboard)
- Store format matches RRDStore: `{time, gpu_temp, gpu_mem_used, gpu_power_draw}`

### New Functions
- `insert_gpu_history_charts()` - Adds custom GPU history chart components

### Why Browser-side Collection?
PVE's RRD (Round Robin Database) has a fixed schema that doesn't automatically
store custom fields from the status API. Server-side RRD integration would
require modifying core Proxmox packages. Browser-side collection provides:
- No changes to PVE core packages required
- Works with any PVE version
- Data collection starts immediately (no wait for RRD population)
- User can clear history by clearing browser storage

### Limitations
- History is browser-specific (not shared across devices)
- History duration is set at install time (reinstall to change)
- Data lost if browser storage is cleared
- Requires page to be open to collect data

---

## [v1.7] - 2025-12-26

### Fixed
- **CUDA Version "N/A"**: Fixed CUDA version showing "N/A" on systems where `--query-gpu=cuda_version` is not supported
  - Root cause: The `nvidia-smi --query-gpu=cuda_version` field is not available on all driver versions
  - Solution: Parse CUDA version from `nvidia-smi` header output which always displays it

### Changed
- **Improved CUDA detection method**: Now uses `nvidia-smi` header parsing as primary method
  - Parses line like: `| NVIDIA-SMI 550.144.03   Driver Version: 550.144.03   CUDA Version: 12.4 |`
  - Uses regex: `grep -oP 'CUDA Version:\s*\K[0-9.]+'`
  - Falls back to query method, then nvcc, then "N/A"

### Technical Details
- Bash function `get_cuda_version()` now tries header parsing first
- Perl code in Nodes.pm uses same approach: `nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\\s*\\K[0-9.]+'`
- More reliable across different NVIDIA driver versions

---

## [v1.6] - 2025-12-26

### Fixed
- **GPU Metrics "No GPU data"**: Fixed metrics row showing "No GPU data" despite VRAM working
  - Root cause: The `textField` renderer receives `value` (field value) as first parameter, not `record`
  - When renderer accessed `record.data.gpu0_temp`, `record` was not the expected object
  - The `record` parameter exists but has different structure in this context

### Changed
- **Added combined metrics field**: API now provides `gpu0_metrics` as a comma-separated string
  - Format: `"temp,gpu_util,power_draw,power_limit"` (e.g., `"38,0,14.40,200.00"`)
  - Renderer parses this single string instead of accessing multiple fields
  - Follows same pattern as reference `pve-mod-gui-nvidia.sh` script
- **Simplified renderer**: Now only uses `value` parameter, not `record`
  - `renderer: function(value) { ... }` instead of `function(value, metaData, record)`

### Technical Details
- Perl code adds: `$res->{"gpu${gpu_index}_metrics"} = "${temp},${gpu_util},${power_draw},${power_limit}"`
- JavaScript parses: `var parts = value.split(',');`
- Each part extracted: `parseFloat(parts[0])` for temp, `parseInt(parts[1])` for util, etc.

### API Response Addition
```json
{
  "gpu0_metrics": "38,0,14.40,200.00",
  "gpu0_mem_used": 4194304,
  "gpu0_mem_total": 10737418240,
  ...
}
```

---

## [v1.5] - 2025-12-26

### Fixed
- **GPU Data Not Displayed**: Fixed "N/A" and "No GPU data" showing despite API returning valid data
  - Root cause: StatusView widget expects flat field names for `valueField`/`maxField`
  - Nested data structure (`gpuData.gpus[0].mem_used`) was not compatible with progress bar widgets
  - Widget's internal progress bar logic couldn't access nested properties

### Changed
- **Flattened API data structure**: GPU metrics now stored as top-level fields in the API response
  - `gpu0_mem_used`, `gpu0_mem_total`, `gpu0_temp`, `gpu0_util`, etc.
  - Memory values pre-converted to bytes for direct use with `render_size_usage`
  - Metrics renderer accesses fields via `record.data.gpu0_temp` pattern
- **Simplified dashboard items**:
  - VRAM item uses standard `valueField: 'gpu0_mem_used'` and `maxField: 'gpu0_mem_total'`
  - Progress bar now works natively without custom renderer for value extraction

### Technical Details
- Perl code now creates flat fields: `$res->{"gpu${i}_mem_used"}` instead of nested hash
- Memory values converted from MiB to bytes in Perl: `$mem_used * 1024 * 1024`
- JavaScript renderer accesses `record.data.gpu0_temp` directly
- Removed nested `gpuData.gpus[]` array structure

### API Response Change
Before (v1.4):
```json
{
  "gpuData": {
    "gpus": [{ "mem_used": "4", "mem_total": "10240", ... }]
  }
}
```

After (v1.5):
```json
{
  "gpu0_mem_used": 4194304,
  "gpu0_mem_total": 10737418240,
  "gpu0_temp": "38",
  "gpu0_util": "0",
  ...
}
```

---

## [v1.4] - 2025-12-26

### Fixed
- **Dashboard Loading Hang**: Fixed "Status" section hanging/loading indefinitely
  - Root cause: Renderer functions (`Proxmox.Utils.render_gpu_vram_usage`) were not being inserted
  - The insertion point `Proxmox.Utils.render_size_usage` exists in `proxmoxlib.js`, not `pvemanagerlib.js`
  - JavaScript error: `Uncaught TypeError: Proxmox.Utils.render_gpu_vram_usage is not a function`

### Changed
- **Rewrote renderer approach**: Switched from separate `Proxmox.Utils` functions to inline renderers
  - Each dashboard item now contains its own renderer function inline
  - Eliminates dependency on finding correct insertion point in external files
  - More robust and portable across PVE versions
  - Follows the same pattern as the reference `pve-mod-gui-nvidia.sh` script

### Technical Details
- Removed separate renderer function insertion step entirely
- Dashboard items now use inline `renderer: function(value, metaData, record) { ... }`
- Temperature conversion and formatting functions are now embedded in each renderer
- Each GPU gets two items: VRAM usage (with progress bar) and metrics (text display)

### Tested On
- Proxmox VE 8.4.9 (pve-manager/8.4.9/649acf70aab54798)
- Kernel 6.8.12-13-pve

---

## [v1.3] - 2025-12-26

### Fixed
- **CUDA Version in Dashboard Title**: Fixed error message appearing in GPU title on dashboard
  - The `insert_gpu_dashboard_items()` function was querying `cuda_version` without error handling
  - Error text "not a valid field to query" was being embedded directly into the JavaScript
  - Created reusable `get_cuda_version()` function with proper error filtering
  - Dashboard items now use `DETECTED_CUDA_VERSION` variable set during configure phase
  - Perl code also improved with additional whitespace trimming and error pattern matching

### Technical Details
- Added `get_cuda_version()` bash function that:
  - Redirects stderr to stdout with `2>&1`
  - Filters out "not a valid field", "Field", and "error" messages with grep -v
  - Falls back to `nvcc --version` if nvidia-smi fails
  - Returns "N/A" if no valid version found
- Dashboard items generation now uses `DETECTED_CUDA_VERSION` global variable
- Perl code adds whitespace trimming with `$cuda_version =~ s/^\s+|\s+$//g`
- Extended error pattern matching in Perl regex

### Issue Resolved
- Dashboard no longer shows error text in GPU title
- CUDA version cleanly shows "N/A" when not available

---

## [v1.2] - 2025-12-25

### Fixed
- **CUDA Version Error Message in UI**: Fixed error message appearing in dashboard when cuda_version query fails
  - Changed from `2>/dev/null` to `2>&1` with grep filtering to catch stderr
  - Added `grep -v` to filter out "not a valid field" and "Field" error messages
  - Added additional validation to ensure no error text gets through
  - Properly sets to 'N/A' if no valid CUDA version is found

### Technical Details
- Modified Perl code to redirect stderr and filter error messages before assignment
- Added length check to ensure empty strings are caught
- More robust regex matching for error text patterns
- Prevents error messages from being displayed in the dashboard UI

### Issue Resolved
- Dashboard no longer shows spinning/loading status
- CUDA version field cleanly shows "N/A" instead of error text

---

## [v1.1] - 2025-12-25

### Fixed
- **CUDA Version Detection**: Added fallback for systems where `nvidia-smi --query-gpu=cuda_version` is not supported
  - Now tries `nvcc --version` if nvidia-smi query fails
  - Gracefully handles "not a valid field" errors
  - Falls back to "N/A" if neither method works

- **Perl Code Insertion**: Fixed syntax error when inserting GPU data collection code into Nodes.pm
  - Changed from inline variable substitution to temp file approach
  - Prevents "Bad name after smi'" error
  - More reliable multi-line code insertion

### Technical Details
- Modified `configure()` function to handle CUDA version detection failures
- Rewrote `insert_node_info()` function to use temp file instead of heredoc variable substitution
- Added proper error handling for CUDA version queries in both bash and Perl code

### Tested On
- Proxmox VE with NVIDIA GeForce RTX 3080
- NVIDIA Driver 550.144.03
- System without CUDA version support in nvidia-smi

---

## [v1.0] - 2025-12-25

### Added
- Initial release of GPU dashboard integration mod
- Embedded GPU metrics into main Proxmox dashboard (after SWAP section)
- Per-GPU metric boxes with VRAM usage progress bars
- GPU utilization, temperature, and power monitoring
- Driver and CUDA version display in titles
- Temperature unit selection (Celsius/Fahrenheit)
- Automatic backup creation before modifications
- Uninstall function with backup restoration

### Features
- **Dashboard Integration**: GPU metrics appear inline with CPU, RAM, SWAP
- **VRAM Usage**: Progress bar showing memory usage like RAM
- **GPU Metrics**: Utilization %, temperature (color-coded), power draw
- **Multi-GPU Support**: Automatically detects and displays all GPUs
- **Version Info**: Shows driver and CUDA versions in metric titles
- **Color Coding**:
  - VRAM: Yellow at 75%, Red at 90%
  - Temperature: Yellow at 70°C, Red at 85°C
  - GPU Utilization: Yellow at 90%
  - Power: Yellow at 75%, Red at 90%

### Modified Files
- `/usr/share/perl5/PVE/API2/Nodes.pm` - API backend for GPU data collection
- `/usr/share/pve-manager/js/pvemanagerlib.js` - Frontend UI dashboard items

### Documentation
- README.md - Comprehensive documentation
- INSTALL.md - Step-by-step installation guide
- DASHBOARD-PREVIEW.md - Visual examples and previews
- IMPORTANT-NOTES.md - Critical information and warnings

---

## Version Format

Versions follow semantic versioning: `MAJOR.MINOR`

- **MAJOR**: Breaking changes or complete rewrites
- **MINOR**: Bug fixes, improvements, new features (backward compatible)

## Upgrade Instructions

To upgrade from a previous version:

```bash
# Uninstall old version
./pve-gpu-dashboard-mod.sh uninstall

# Download/copy new version
# (Replace vX.X with actual version)
chmod +x pve-gpu-dashboard-mod_vX.X.sh

# Install new version
./pve-gpu-dashboard-mod_vX.X.sh install

# Clear browser cache
# Press Ctrl+Shift+R
```

## Known Issues

### v3.0
- None currently known

### v2.0
- Historical graphs don't appear on PVE 9.x (**FIXED in v3.0**)
- Historical graphs show "Collecting data..." until at least 2 data points are collected
- History is browser-specific (not synced across devices/browsers)
- Data collection only occurs while the page is open

### v1.7
- None currently known

### v1.6
- CUDA version shows "N/A" despite CUDA being available (**FIXED in v1.7**)

### v1.5
- GPU metrics shows "No GPU data" despite VRAM bar working (**FIXED in v1.6**)

### v1.4
- GPU data shows "N/A" despite API returning valid data (**FIXED in v1.5**)

### v1.3
- Dashboard hangs on loading due to missing renderer functions (**FIXED in v1.4**)

### v1.2
- CUDA version error still shown in dashboard title (**FIXED in v1.3**)

### v1.1
- None currently known

### v1.0
- CUDA version detection fails on some systems (**FIXED in v1.1**)
- Perl insertion syntax error with special characters (**FIXED in v1.1**)

---

**Latest Version**: v3.0
**Date**: 2025-12-26
**Status**: Stable

## Feature Summary

### v1.x - Main Dashboard (Status Section)
- **VRAM Usage**: Progress bar showing memory usage (e.g., `3.16% (324.00 MiB of 10.00 GiB)`)
- **GPU Metrics**: Utilization, temperature (color-coded), and power draw (e.g., `GPU: 0% | Temp: 46°C | Power: 15/200W | Fan: 30%`)
- **Title Info**: GPU name, driver version, and CUDA version displayed in header
- **Multi-GPU Support**: Automatically detects and displays all NVIDIA GPUs
- **Temperature Units**: Configurable Celsius or Fahrenheit display
- **Fan Speed Display**: Shows fan percentage (hidden for passively cooled GPUs)

### v2.x/v3.x - Historical Graphs (Browser-side Collection)
- **Temperature Graph**: Temperature trends over time
- **VRAM Usage Graph**: Historical memory consumption
- **Power Draw Graph**: Power consumption history
- **Configurable Duration**: Choose 24 hours, 1 week, or 30 days during install
- **Browser-side Collection**: Uses localStorage for data persistence
- **Native PVE Styling**: Uses `proxmoxRRDChart` for identical look to CPU/Memory charts
- **PVE 8.x and 9.x Support**: Works with both major PVE versions
