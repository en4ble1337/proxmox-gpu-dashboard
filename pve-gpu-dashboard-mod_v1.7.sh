#!/usr/bin/env bash
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE)
# web user interface (UI) to display NVIDIA GPU information embedded in the main
# node status dashboard alongside CPU, RAM, and other system metrics.
#
# Author: Modified from pve-mod-gui-nvidia.sh by Meliox
# License: MIT
#
# This version integrates GPU metrics directly into the dashboard with the same
# visual style as CPU, RAM, SWAP, etc., rather than as a separate panel.
#

################### Configuration #############

# Temperature thresholds (Celsius)
TEMP_WARNING=70
TEMP_CRITICAL=85

# Overwrite default backup location (leave empty for default ~/PVE-GPU-DASHBOARD)
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################

# This script's working directory
SCRIPT_CWD="$(dirname "$(readlink -f "$0")")"

# File paths
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"

#region message tools
# Section header (bold)
function msgb() {
    local message="$1"
    echo -e "\e[1m${message}\e[0m"
}

# Info (green)
function info() {
    local message="$1"
    echo -e "\e[0;32m[info] ${message}\e[0m"
}

# Warning (yellow)
function warn() {
    local message="$1"
    echo -e "\e[0;33m[warning] ${message}\e[0m"
}

# Error (red)
function err() {
    local message="$1"
    echo -e "\e[0;31m[error] ${message}\e[0m"
    exit 1
}

# Prompts (cyan)
function ask() {
    local prompt="$1"
    local response
    read -p $'\n\e[1;36m'"${prompt}:"$'\e[0m ' response
    echo "$response"
}
#endregion message tools

# Function to display usage information
function usage {
    msgb "\nUsage:\n$0 [install | uninstall]\n"
    msgb "Options:"
    echo "  install     Install the GPU dashboard integration"
    echo "  uninstall   Remove the modification and restore original files"
    echo ""
    exit 1
}

# System checks
function check_root_privileges() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root. Please run it with 'sudo $0'."
    fi
    info "Root privileges verified."
}

# Check if nvidia-smi is available
function check_nvidia_smi() {
    if ! command -v nvidia-smi &>/dev/null; then
        err "nvidia-smi is not installed or not in PATH. Please install NVIDIA drivers first."
    fi
    info "nvidia-smi found."
}

# Detect NVIDIA GPUs
function detect_gpus() {
    local gpu_count
    gpu_count=$(nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)

    if [[ -z "$gpu_count" ]] || [[ "$gpu_count" -eq 0 ]]; then
        err "No NVIDIA GPUs detected by nvidia-smi."
    fi

    echo "$gpu_count"
}

# Get CUDA version with proper error handling
# v1.7: Parse from nvidia-smi header output which always works
function get_cuda_version() {
    local cuda_ver

    # Primary method: Parse CUDA version from nvidia-smi header
    # The header contains a line like: "CUDA Version: 12.4"
    cuda_ver=$(nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\s*\K[0-9.]+' | head -1)

    # If that fails, try the query method (may not work on all drivers)
    if [[ -z "$cuda_ver" ]]; then
        cuda_ver=$(nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>&1 | grep -v "not a valid field" | grep -v "Field" | grep -v "error" | head -1 | xargs)
    fi

    # Check if we got a valid result from query method
    if [[ -z "$cuda_ver" ]] || [[ "$cuda_ver" == *"not a valid"* ]] || [[ "$cuda_ver" == *"error"* ]] || [[ "$cuda_ver" == *"invalid"* ]] || [[ "$cuda_ver" == *"Field"* ]]; then
        # Fallback: try nvcc if available
        if command -v nvcc &>/dev/null; then
            cuda_ver=$(nvcc --version 2>/dev/null | grep -oP 'release \K[0-9.]+' | head -1)
        fi
    fi

    # Final check - if still empty or invalid, return N/A
    if [[ -z "$cuda_ver" ]] || [[ ${#cuda_ver} -lt 1 ]]; then
        echo "N/A"
    else
        echo "$cuda_ver"
    fi
}

# Configure installation options
function configure() {
    msgb "\n=== Detecting NVIDIA GPUs ==="

    check_nvidia_smi

    local gpu_count
    gpu_count=$(detect_gpus)

    info "Detected $gpu_count NVIDIA GPU(s):"

    # Display detected GPUs
    nvidia-smi --query-gpu=index,name --format=csv,noheader 2>/dev/null | while read -r line; do
        echo "  GPU $line"
    done

    # Get driver and CUDA versions
    local driver_version
    local cuda_version
    driver_version=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    cuda_version=$(get_cuda_version)

    info "Driver Version: $driver_version"
    info "CUDA Version: $cuda_version"

    # Store versions globally for use in dashboard items
    DETECTED_DRIVER_VERSION="$driver_version"
    DETECTED_CUDA_VERSION="$cuda_version"

    # Temperature unit selection
    msgb "\n=== Display Settings ==="
    local unit
    unit=$(ask "Display temperatures in Celsius [C] or Fahrenheit [f]? (C/f)")
    case "$unit" in
        [fF])
            TEMP_UNIT="F"
            info "Using Fahrenheit."
            ;;
        *)
            TEMP_UNIT="C"
            info "Using Celsius."
            ;;
    esac
}

# Function to check if the modification is already installed
function check_mod_installation() {
    if grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null; then
        err "GPU dashboard mod is already installed. Please uninstall first before reinstalling."
    fi
}

# Set backup directory
function set_backup_directory() {
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$HOME/PVE-GPU-DASHBOARD"
        info "Using default backup directory: $BACKUP_DIR"
    else
        if [[ ! -d "$BACKUP_DIR" ]]; then
            err "The specified backup directory does not exist: $BACKUP_DIR"
        fi
        info "Using custom backup directory: $BACKUP_DIR"
    fi
}

# Create backup directory
function create_backup_directory() {
    set_backup_directory

    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR" 2>/dev/null || {
            err "Failed to create backup directory: $BACKUP_DIR. Please check permissions."
        }
        info "Created backup directory: $BACKUP_DIR"
    else
        info "Backup directory already exists: $BACKUP_DIR"
    fi
}

# Create file backup
function create_file_backup() {
    local source_file="$1"
    local timestamp="$2"
    local filename

    filename=$(basename "$source_file")
    local backup_file="$BACKUP_DIR/gpu-dashboard.${filename}.$timestamp"

    [[ -f "$source_file" ]] || err "Source file does not exist: $source_file"
    [[ -r "$source_file" ]] || err "Cannot read source file: $source_file"

    cp "$source_file" "$backup_file" || err "Failed to create backup: $backup_file"

    # Verify backup integrity
    if ! cmp -s "$source_file" "$backup_file"; then
        err "Backup verification failed for: $backup_file"
    fi

    info "Created backup: $backup_file"
}

# Perform backup of files
function perform_backup() {
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)

    msgb "\n=== Creating backups of modified files ==="

    create_backup_directory
    create_file_backup "$NODES_PM_FILE" "$timestamp"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$timestamp"
}

# Restart pveproxy service
function restart_proxy() {
    info "Restarting PVE proxy..."
    systemctl restart pveproxy
}

# Insert NVIDIA GPU data collection into Nodes.pm
# This version provides both flat fields for progress bars and a metrics string for text display
function insert_node_info() {
    msgb "\n=== Inserting GPU data retrieval code into API ==="

    # Create temporary file with the Perl code to insert
    local temp_perl_code="/tmp/gpu_perl_code.txt"

    cat > "$temp_perl_code" << 'PERL_CODE'
# Collect NVIDIA GPU data for dashboard integration
if (-x '/usr/bin/nvidia-smi') {
    # Get driver version
    my $driver_version = `nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1`;
    chomp($driver_version);
    $res->{gpuDriverVersion} = $driver_version || 'N/A';

    # Get CUDA version from nvidia-smi header (most reliable method)
    my $cuda_version = `nvidia-smi 2>/dev/null | grep -oP 'CUDA Version:\\s*\\K[0-9.]+'`;
    chomp($cuda_version);
    $cuda_version =~ s/^\s+|\s+$//g;

    # Fallback to query method if header parsing fails
    if (!$cuda_version || length($cuda_version) < 1) {
        $cuda_version = `nvidia-smi --query-gpu=cuda_version --format=csv,noheader 2>&1 | grep -v "not a valid field" | grep -v "Field" | grep -v "error" | head -1`;
        chomp($cuda_version);
        $cuda_version =~ s/^\s+|\s+$//g;
    }

    # Final fallback: try nvcc if available
    if (!$cuda_version || $cuda_version =~ /error|invalid|field|not a valid/i || length($cuda_version) < 1) {
        if (-x '/usr/bin/nvcc') {
            $cuda_version = `nvcc --version 2>/dev/null | grep -oP 'release \\K[0-9.]+' | head -1`;
            chomp($cuda_version);
            $cuda_version =~ s/^\s+|\s+$//g;
        }
        $cuda_version = 'N/A' if !$cuda_version || length($cuda_version) < 1;
    }
    $res->{gpuCudaVersion} = $cuda_version;

    # Get per-GPU metrics and flatten into top-level fields
    my @gpu_metrics = `nvidia-smi --query-gpu=index,name,temperature.gpu,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,fan.speed --format=csv,noheader,nounits 2>/dev/null`;

    my $gpu_index = 0;
    foreach my $line (@gpu_metrics) {
        chomp($line);
        my @parts = split(',', $line);
        if (scalar @parts >= 10) {
            # Flatten GPU data into top-level fields for StatusView compatibility
            # Memory values are in MiB from nvidia-smi, convert to bytes for render_size_usage
            my $mem_used_mib = $parts[5] =~ s/^\s+|\s+$//gr;
            my $mem_total_mib = $parts[6] =~ s/^\s+|\s+$//gr;
            my $mem_used = $mem_used_mib * 1024 * 1024;
            my $mem_total = $mem_total_mib * 1024 * 1024;
            my $temp = $parts[2] =~ s/^\s+|\s+$//gr;
            my $gpu_util = $parts[3] =~ s/^\s+|\s+$//gr;
            my $power_draw = $parts[7] =~ s/^\s+|\s+$//gr;
            my $power_limit = $parts[8] =~ s/^\s+|\s+$//gr;
            my $fan_speed = $parts[9] =~ s/^\s+|\s+$//gr;
            # Handle [N/A] or [Not Supported] for fan speed (passively cooled GPUs)
            $fan_speed = ($fan_speed =~ /^\d+$/) ? $fan_speed + 0 : -1;

            $res->{"gpu${gpu_index}_name"} = $parts[1] =~ s/^\s+|\s+$//gr;
            $res->{"gpu${gpu_index}_temp"} = $temp;
            $res->{"gpu${gpu_index}_util"} = $gpu_util;
            $res->{"gpu${gpu_index}_mem_util"} = $parts[4] =~ s/^\s+|\s+$//gr;
            $res->{"gpu${gpu_index}_mem_used"} = $mem_used;
            $res->{"gpu${gpu_index}_mem_total"} = $mem_total;
            $res->{"gpu${gpu_index}_power_draw"} = $power_draw;
            $res->{"gpu${gpu_index}_power_limit"} = $power_limit;
            $res->{"gpu${gpu_index}_fan"} = $fan_speed;  # -1 if N/A

            # Create a combined metrics string for the textField renderer
            # Format: temp,gpu_util,power_draw,power_limit,fan_speed
            $res->{"gpu${gpu_index}_metrics"} = "${temp},${gpu_util},${power_draw},${power_limit},${fan_speed}";

            $gpu_index++;
        }
    }
    $res->{gpuCount} = $gpu_index;
}
PERL_CODE

    # Use perl to insert the code from the temp file
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_perl_code.txt") or die "Cannot open temp file: $!";
            local $/;
            $::code = <$fh>;
            close($fh);
        }
        s/(my \$dinfo = df\(.*?\);)/$::code\n$1/s;
    ' "$NODES_PM_FILE"

    local exit_code=$?
    rm -f "$temp_perl_code"

    if [[ $exit_code -ne 0 ]]; then
        err "Failed to insert GPU data retrieval code into Nodes.pm"
    fi

    # Verify insertion
    if ! grep -q 'gpuDriverVersion' "$NODES_PM_FILE"; then
        err "GPU data retrieval code insertion verification failed"
    fi

    info "GPU data retrieval code added to \"$NODES_PM_FILE\"."
}

# Insert GPU dashboard items into pvemanagerlib.js
function insert_gpu_dashboard_items() {
    msgb "\n=== Inserting GPU dashboard items into UI ==="

    local gpu_count
    gpu_count=$(detect_gpus)

    local temp_items_file="/tmp/gpu_dashboard_items.js"

    # Start building the items - add spacer first
    cat > "$temp_items_file" << 'ITEMS_EOF'
	{
	    xtype: 'box',
	    colspan: 2,
	    padding: '0 0 20 0',
	},
ITEMS_EOF

    # Generate items for each GPU
    for ((i=0; i<gpu_count; i++)); do
        # Get GPU name for this index
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed -n "$((i+1))p" | xargs)

        # Use the pre-validated versions
        local driver_ver="${DETECTED_DRIVER_VERSION:-N/A}"
        local cuda_ver="${DETECTED_CUDA_VERSION:-N/A}"

        # Create the VRAM usage item with proper valueField/maxField for progress bar
        cat >> "$temp_items_file" << ITEM_EOF
	{
	    itemId: 'gpu${i}_vram',
	    iconCls: 'fa fa-fw fa-television',
	    title: 'GPU ${i}: ${gpu_name} (Driver: ${driver_ver}, CUDA: ${cuda_ver})',
	    valueField: 'gpu${i}_mem_used',
	    maxField: 'gpu${i}_mem_total',
	},
ITEM_EOF

        # Create the metrics item with inline renderer
        # The renderer receives the value of textField (gpu${i}_metrics) as first parameter
        # Format: temp,gpu_util,power_draw,power_limit,fan_speed
        if [[ "$TEMP_UNIT" == "F" ]]; then
            cat >> "$temp_items_file" << ITEM_EOF
	{
	    itemId: 'gpu${i}_metrics',
	    printBar: false,
	    title: 'GPU ${i} Metrics',
	    textField: 'gpu${i}_metrics',
	    renderer: function(value) {
	        if (!value) return 'No GPU data';
	        var parts = value.split(',');
	        if (parts.length < 5) return 'Invalid data';
	        var tempC = parseFloat(parts[0]) || 0;
	        var gpuUtil = parseInt(parts[1]) || 0;
	        var powerDraw = parseFloat(parts[2]) || 0;
	        var powerLimit = parseFloat(parts[3]) || 0;
	        var fanSpeed = parseInt(parts[4]);
	        var tempF = (tempC * 9 / 5) + 32;
	        var tempStyle = '';
	        if (tempF >= 185) {
	            tempStyle = 'color: #ff4444; font-weight: bold;';
	        } else if (tempF >= 158) {
	            tempStyle = 'color: #FFC300; font-weight: bold;';
	        }
	        var tempStr = '<span style="' + tempStyle + '">' + tempF.toFixed(0) + '°F</span>';
	        var powerStr = powerDraw.toFixed(0) + 'W';
	        if (powerLimit > 0) {
	            powerStr = powerDraw.toFixed(0) + '/' + powerLimit.toFixed(0) + 'W';
	        }
	        var fanStr = (fanSpeed >= 0) ? ' | Fan: ' + fanSpeed + '%' : '';
	        return 'GPU: ' + gpuUtil + '% | Temp: ' + tempStr + ' | Power: ' + powerStr + fanStr;
	    },
	},
ITEM_EOF
        else
            cat >> "$temp_items_file" << ITEM_EOF
	{
	    itemId: 'gpu${i}_metrics',
	    printBar: false,
	    title: 'GPU ${i} Metrics',
	    textField: 'gpu${i}_metrics',
	    renderer: function(value) {
	        if (!value) return 'No GPU data';
	        var parts = value.split(',');
	        if (parts.length < 5) return 'Invalid data';
	        var temp = parseFloat(parts[0]) || 0;
	        var gpuUtil = parseInt(parts[1]) || 0;
	        var powerDraw = parseFloat(parts[2]) || 0;
	        var powerLimit = parseFloat(parts[3]) || 0;
	        var fanSpeed = parseInt(parts[4]);
	        var tempStyle = '';
	        if (temp >= 85) {
	            tempStyle = 'color: #ff4444; font-weight: bold;';
	        } else if (temp >= 70) {
	            tempStyle = 'color: #FFC300; font-weight: bold;';
	        }
	        var tempStr = '<span style="' + tempStyle + '">' + temp.toFixed(0) + '°C</span>';
	        var powerStr = powerDraw.toFixed(0) + 'W';
	        if (powerLimit > 0) {
	            powerStr = powerDraw.toFixed(0) + '/' + powerLimit.toFixed(0) + 'W';
	        }
	        var fanStr = (fanSpeed >= 0) ? ' | Fan: ' + fanSpeed + '%' : '';
	        return 'GPU: ' + gpuUtil + '% | Temp: ' + tempStr + ' | Power: ' + powerStr + fanStr;
	    },
	},
ITEM_EOF
        fi
    done

    # Insert the items into the StatusView, after the SWAP item
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_dashboard_items.js") or die "Cannot open items file: $!";
            local $/;
            $::items = <$fh>;
            close($fh);
        }
        # Find the swap item in PVE.node.StatusView and insert GPU items after it
        s/(itemId:\s*'\''swap'\''.*?\n\s*\},)(\s*\{\s*xtype:\s*'\''box'\'',\s*colspan:\s*2,\s*padding:\s*'\''0 0 20 0'\'')/$1$::items$2/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    local insert_status=$?

    if [[ $insert_status -ne 0 ]]; then
        rm -f "$temp_items_file"
        err "Failed to insert GPU dashboard items into pvemanagerlib.js"
    fi

    # Verify insertion
    if ! grep -q "itemId: 'gpu0_vram'" "$PVE_MANAGER_LIB_JS_FILE"; then
        rm -f "$temp_items_file"
        err "GPU dashboard items insertion verification failed"
    fi

    rm -f "$temp_items_file"
    info "GPU dashboard items inserted into \"$PVE_MANAGER_LIB_JS_FILE\"."
}

# Main installation function
function install_mod() {
    msgb "\n=== Preparing GPU Dashboard Integration ==="

    check_root_privileges
    check_mod_installation
    configure
    perform_backup

    insert_node_info
    insert_gpu_dashboard_items

    msgb "\n=== Finalizing installation ==="

    restart_proxy

    info "Installation completed successfully."
    msgb "\nIMPORTANT: Clear your browser cache (Ctrl+Shift+R or Cmd+Shift+R) to see the changes."
    msgb "\nThe GPU metrics will appear in the node status dashboard alongside CPU, RAM, and SWAP."
}

# Uninstall the modification
function uninstall_mod() {
    msgb "\n=== Uninstalling GPU Dashboard Mod ==="

    check_root_privileges

    # Check if mod is installed
    if ! grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null; then
        err "GPU dashboard mod is not installed."
    fi

    set_backup_directory

    # Check for other mods that would be affected by backup restoration
    local other_mods_detected=false
    local detected_mods=""

    if grep -q 'sensorsOutput' "$NODES_PM_FILE" 2>/dev/null; then
        other_mods_detected=true
        detected_mods="${detected_mods}pve-mod-gui-sensors "
    fi

    if grep -q 'nvidiaGpuOutput' "$NODES_PM_FILE" 2>/dev/null; then
        other_mods_detected=true
        detected_mods="${detected_mods}pve-mod-gui-nvidia "
    fi

    if [[ "$other_mods_detected" == true ]]; then
        warn "Other PVE mods detected: $detected_mods"
        warn "Restoring from backup will remove ALL mods installed after the gpu-dashboard backup was created."
        msgb "\nYou have two options:"
        echo "  1) Continue - Restore backup, then reinstall other mods afterward"
        echo "  2) Cancel - Manually remove gpu-dashboard code from files instead"
        echo ""
        local confirm
        confirm=$(ask "Continue with backup restoration? (y/N)")
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            info "Uninstall cancelled."
            msgb "\nTo manually remove, edit these files:"
            echo "  - $NODES_PM_FILE (remove gpuData/gpuDriverVersion lines)"
            echo "  - $PVE_MANAGER_LIB_JS_FILE (remove GPU dashboard items)"
            exit 0
        fi
    fi

    info "Restoring modified files..."

    # Find the latest Nodes.pm backup
    local latest_nodes_pm
    latest_nodes_pm=$(find "$BACKUP_DIR" -name "gpu-dashboard.Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

    if [[ -n "$latest_nodes_pm" ]]; then
        msgb "Restoring Nodes.pm from backup: $latest_nodes_pm"
        cp "$latest_nodes_pm" "$NODES_PM_FILE"
        info "Restored Nodes.pm successfully."
    else
        warn "No Nodes.pm backup found."
        warn "You can reinstall pve-manager package to restore: apt install --reinstall pve-manager"
    fi

    # Find the latest pvemanagerlib.js backup
    local latest_pvemanagerlibjs
    latest_pvemanagerlibjs=$(find "$BACKUP_DIR" -name "gpu-dashboard.pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n 1 | awk '{print $2}')

    if [[ -n "$latest_pvemanagerlibjs" ]]; then
        msgb "Restoring pvemanagerlib.js from backup: $latest_pvemanagerlibjs"
        cp "$latest_pvemanagerlibjs" "$PVE_MANAGER_LIB_JS_FILE"
        info "Restored pvemanagerlib.js successfully."
    else
        warn "No pvemanagerlib.js backup found."
        warn "You can reinstall pve-manager package to restore: apt install --reinstall pve-manager"
    fi

    restart_proxy

    info "Uninstallation completed."
    msgb "\nIMPORTANT: Clear your browser cache (Ctrl+Shift+R) to see the changes."
}

# Process command line arguments
executed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        install)
            executed=$((executed + 1))
            install_mod
            ;;
        uninstall)
            executed=$((executed + 1))
            uninstall_mod
            ;;
        *)
            warn "Unknown option: $1"
            usage
            ;;
    esac
    shift
done

# If no arguments provided, show usage
if [[ $executed -eq 0 ]]; then
    usage
fi
