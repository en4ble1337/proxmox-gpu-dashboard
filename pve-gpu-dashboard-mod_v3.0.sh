#!/usr/bin/env bash
#
# PVE GPU Dashboard Mod v3.0
#
# This bash script installs a modification to the Proxmox Virtual Environment (PVE)
# web user interface (UI) to display NVIDIA GPU information embedded in the main
# node status dashboard alongside CPU, RAM, and other system metrics.
#
# v3.0 adds PVE 9.x compatibility while maintaining PVE 8.x support.
# - Historical RRD graphs for GPU metrics (VRAM, Temperature, Power)
# - Compatible with both PVE 8.x and PVE 9.x
#
# Author: Modified from pve-mod-gui-nvidia.sh by Meliox
# License: MIT
#

################### Configuration #############

# Temperature thresholds (Celsius)
TEMP_WARNING=70
TEMP_CRITICAL=85

# Overwrite default backup location (leave empty for default ~/PVE-GPU-DASHBOARD)
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################

# Script version
SCRIPT_VERSION="3.0"

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
    msgb "\nPVE GPU Dashboard Mod v${SCRIPT_VERSION}"
    msgb "\nUsage:\n$0 [install | uninstall]\n"
    msgb "Options:"
    echo "  install     Install the GPU dashboard integration with historical graphs"
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
function get_cuda_version() {
    local cuda_ver

    # Primary method: Parse CUDA version from nvidia-smi header
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
    DETECTED_GPU_COUNT="$gpu_count"

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

    # History duration selection for GPU graphs
    msgb "\n=== Historical Graph Settings ==="
    echo "Select how much GPU history to store in browser localStorage:"
    echo ""
    echo "  [1] 24 hours  (1-minute intervals, 1,440 points, ~144 KB per GPU)"
    echo "      Maximum detail for recent troubleshooting"
    echo ""
    echo "  [2] 1 week    (1-minute intervals, 10,080 points, ~1 MB per GPU)"
    echo "      Still detailed for weekly patterns"
    echo ""
    echo "  [3] 30 days   (5-minute intervals, 8,640 points, ~864 KB per GPU)"
    echo "      Good balance for long-term trends"
    echo ""
    local history_choice
    history_choice=$(ask "Choose history duration [1/2/3]")
    case "$history_choice" in
        2)
            HISTORY_MAX_POINTS=10080     # 1 week at 1-min intervals
            HISTORY_POLL_INTERVAL=60000  # 1 minute in ms
            HISTORY_DURATION="1 week"
            info "Using 1 week history (1-minute intervals)."
            ;;
        3)
            HISTORY_MAX_POINTS=8640      # 30 days at 5-min intervals
            HISTORY_POLL_INTERVAL=300000 # 5 minutes in ms
            HISTORY_DURATION="30 days"
            info "Using 30 days history (5-minute intervals)."
            ;;
        *)
            HISTORY_MAX_POINTS=1440      # 24 hours at 1-min intervals
            HISTORY_POLL_INTERVAL=60000  # 1 minute in ms
            HISTORY_DURATION="24 hours"
            info "Using 24 hours history (1-minute intervals)."
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
function insert_node_info() {
    msgb "\n=== Inserting GPU data retrieval code into API ==="

    # Create temporary file with the Perl code to insert
    local temp_perl_code="/tmp/gpu_perl_code.txt"

    cat > "$temp_perl_code" << 'PERL_CODE'
# Collect NVIDIA GPU data for dashboard integration (v3.0)
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
            $res->{"gpu${gpu_index}_temp"} = $temp + 0;  # Force numeric
            $res->{"gpu${gpu_index}_util"} = $gpu_util + 0;  # Force numeric
            $res->{"gpu${gpu_index}_mem_util"} = ($parts[4] =~ s/^\s+|\s+$//gr) + 0;
            $res->{"gpu${gpu_index}_mem_used"} = $mem_used + 0;
            $res->{"gpu${gpu_index}_mem_total"} = $mem_total + 0;
            $res->{"gpu${gpu_index}_power_draw"} = $power_draw + 0;  # Force numeric
            $res->{"gpu${gpu_index}_power_limit"} = $power_limit + 0;  # Force numeric
            $res->{"gpu${gpu_index}_fan"} = $fan_speed;  # -1 if N/A

            # Create a combined metrics string for the textField renderer
            # Format: temp,gpu_util,power_draw,power_limit,fan_speed
            $res->{"gpu${gpu_index}_metrics"} = "${temp},${gpu_util},${power_draw},${power_limit},${fan_speed}";

            $gpu_index++;
        }
    }
    $res->{gpuCount} = $gpu_index;

    # Add server timestamp for historical charts (matches native RRD behavior)
    $res->{gpu_server_time} = time();
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

# Insert GPU fields into pve-rrd-node model for RRD historical data
function insert_rrd_model_fields() {
    msgb "\n=== Adding GPU fields to RRD data model ==="

    local gpu_count="${DETECTED_GPU_COUNT:-1}"

    # Build the GPU fields to add to pve-rrd-node model
    local gpu_fields=""
    for ((i=0; i<gpu_count; i++)); do
        gpu_fields+="
        // GPU ${i} RRD fields
        'gpu${i}_temp',
        'gpu${i}_util',
        'gpu${i}_mem_used',
        'gpu${i}_mem_total',
        'gpu${i}_power_draw',
        'gpu${i}_power_limit',"
    done

    # Create temp file with the fields
    echo "$gpu_fields" > /tmp/gpu_rrd_fields.txt

    # Insert GPU fields into pve-rrd-node model after 'swapused' field
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_rrd_fields.txt") or die "Cannot open temp file: $!";
            local $/;
            $::fields = <$fh>;
            close($fh);
        }
        # Find swapused field in pve-rrd-node and add GPU fields after it
        s/('"'"'swapused'"'"',)/$1$::fields/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    rm -f /tmp/gpu_rrd_fields.txt

    # Verify insertion
    if ! grep -q "gpu0_temp" "$PVE_MANAGER_LIB_JS_FILE"; then
        err "GPU RRD model fields insertion verification failed"
    fi

    info "GPU fields added to RRD data model."
}

# Insert GPU historical charts with browser-side data collection
# Uses proxmoxRRDChart with a custom localStorage-backed store for native PVE look
function insert_gpu_history_charts() {
    msgb "\n=== Inserting GPU historical charts (browser-side collection) ==="

    local gpu_count="${DETECTED_GPU_COUNT:-1}"
    local nodename=$(hostname)

    # Create the JavaScript code for GPU history store and charts
    local temp_charts_file="/tmp/gpu_history_charts.js"

    # Use configured values for history settings
    local max_points="${HISTORY_MAX_POINTS:-288}"
    local poll_interval="${HISTORY_POLL_INTERVAL:-300000}"

    cat > "$temp_charts_file" << CHARTS_JS
// GPU History Store - localStorage-backed store compatible with proxmoxRRDChart (v3.0)
// This provides the same data format as Proxmox.data.RRDStore but using browser localStorage
Ext.define('PVE.data.GPUHistoryStore', {
    extend: 'Ext.data.Store',
    alias: 'store.pveGPUHistoryStore',

    config: {
        nodename: '',
        gpuIndex: 0,
        maxPoints: ${max_points},  // Configured during install
        pollInterval: ${poll_interval}  // Configured during install (ms)
    },
CHARTS_JS

    cat >> "$temp_charts_file" << 'CHARTS_JS'

    fields: ['time', 'gpu_temp', 'gpu_mem_used', 'gpu_power_draw'],

    constructor: function(config) {
        var me = this;
        me.callParent([config]);

        me.storageKey = 'pve-gpu-rrd-' + me.getNodename() + '-gpu' + me.getGpuIndex();

        // Load existing data from localStorage
        me.loadFromStorage();

        // Start polling for new data
        me.startPolling();
    },

    getStorageKey: function() {
        return this.storageKey;
    },

    loadFromStorage: function() {
        var me = this;
        try {
            var data = localStorage.getItem(me.storageKey);
            if (data) {
                var records = JSON.parse(data);
                // Convert time from seconds to milliseconds for chart display
                records = records.map(function(rec) {
                    if (rec.time && rec.time < 10000000000) {
                        rec.time = rec.time * 1000;
                    }
                    return rec;
                });
                me.loadData(records);
            }
        } catch(e) {
            console.warn('Failed to load GPU history from localStorage:', e);
        }
    },

    saveToStorage: function() {
        var me = this;
        try {
            var records = [];
            me.each(function(rec) {
                var data = rec.getData();
                // Store time in seconds for consistency
                if (data.time && data.time > 10000000000) {
                    data.time = Math.floor(data.time / 1000);
                }
                records.push(data);
            });
            localStorage.setItem(me.storageKey, JSON.stringify(records));
        } catch(e) {
            // localStorage full, remove oldest entries
            localStorage.removeItem(me.storageKey);
        }
    },

    addDataPoint: function(temp, memUsed, powerDraw, serverTime) {
        var me = this;
        // Use server time if provided, otherwise fallback to client time
        var timestamp = serverTime || Date.now();

        me.add({
            time: timestamp,
            gpu_temp: temp,
            gpu_mem_used: memUsed,
            gpu_power_draw: powerDraw
        });

        // Keep only maxPoints
        while (me.getCount() > me.getMaxPoints()) {
            me.removeAt(0);
        }

        me.saveToStorage();
    },

    startPolling: function() {
        var me = this;

        var poll = function() {
            Proxmox.Utils.API2Request({
                url: '/nodes/' + me.getNodename() + '/status',
                method: 'GET',
                success: function(response) {
                    var data = response.result.data;
                    var gpuIdx = me.getGpuIndex();
                    var temp = data['gpu' + gpuIdx + '_temp'];
                    var memUsed = data['gpu' + gpuIdx + '_mem_used'];
                    var powerDraw = data['gpu' + gpuIdx + '_power_draw'];
                    // Use server timestamp if available, fallback to client time
                    var serverTime = data.gpu_server_time ? data.gpu_server_time * 1000 : Date.now();

                    if (temp !== undefined) {
                        me.addDataPoint(
                            parseFloat(temp) || 0,
                            parseFloat(memUsed) || 0,
                            parseFloat(powerDraw) || 0,
                            serverTime
                        );
                    }
                }
            });
        };

        // Initial poll
        poll();

        // Poll at configured interval
        me.pollTask = Ext.TaskManager.start({
            run: poll,
            interval: me.getPollInterval()
        });
    },

    destroy: function() {
        var me = this;
        if (me.pollTask) {
            Ext.TaskManager.stop(me.pollTask);
        }
        me.callParent();
    }
});
CHARTS_JS

    # Insert the store class definition before PVE.node.Summary
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_history_charts.js") or die "Cannot open charts file: $!";
            local $/;
            $::chartclass = <$fh>;
            close($fh);
        }
        # Insert before PVE.node.Summary definition
        s/(Ext\.define\('"'"'PVE\.node\.Summary'"'"')/$::chartclass\n\n$1/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    # Now create the chart instances to add to the Summary panel
    # We need to create stores and charts for each GPU
    local temp_instances_file="/tmp/gpu_chart_instances.js"

    cat > "$temp_instances_file" << INSTANCES_HEADER
	    // GPU Historical Charts (v3.0 - Browser-side collection using proxmoxRRDChart)
INSTANCES_HEADER

    for ((i=0; i<gpu_count; i++)); do
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed -n "$((i+1))p" | xargs)

        # Create store variable and three charts per GPU
        cat >> "$temp_instances_file" << INSTANCE_EOF
	    // GPU ${i} charts with shared store
	    (function() {
	        var gpuStore${i} = Ext.create('PVE.data.GPUHistoryStore', {
	            nodename: nodename,
	            gpuIndex: ${i}
	        });
	        return [
	            {
	                xtype: 'proxmoxRRDChart',
	                title: 'GPU ${i} Temperature (${gpu_name})',
	                fields: ['gpu_temp'],
	                fieldTitles: ['Temperature °C'],
	                store: gpuStore${i}
	            },
	            {
	                xtype: 'proxmoxRRDChart',
	                title: 'GPU ${i} VRAM Usage',
	                fields: ['gpu_mem_used'],
	                fieldTitles: ['VRAM Used'],
	                unit: 'bytes',
	                powerOfTwo: true,
	                store: gpuStore${i}
	            },
	            {
	                xtype: 'proxmoxRRDChart',
	                title: 'GPU ${i} Power Draw',
	                fields: ['gpu_power_draw'],
	                fieldTitles: ['Power (W)'],
	                store: gpuStore${i}
	            }
	        ];
	    })(),
INSTANCE_EOF
    done

    # We need a different approach - the items array doesn't support IIFE directly
    # Let's use a simpler approach with inline store creation

    # Rewrite the instances file with a simpler pattern
    cat > "$temp_instances_file" << INSTANCES_HEADER
	    // GPU Historical Charts (v3.0 - Browser-side collection)
INSTANCES_HEADER

    for ((i=0; i<gpu_count; i++)); do
        local gpu_name
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | sed -n "$((i+1))p" | xargs)

        cat >> "$temp_instances_file" << INSTANCE_EOF
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU ${i} Temperature (${gpu_name})',
	        fields: ['gpu_temp'],
	        fieldTitles: ['Temperature °C'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: ${i} })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU ${i} VRAM Usage',
	        fields: ['gpu_mem_used'],
	        fieldTitles: ['VRAM Used'],
	        unit: 'bytes',
	        powerOfTwo: true,
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: ${i} })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU ${i} Power Draw',
	        fields: ['gpu_power_draw'],
	        fieldTitles: ['Power (W)'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: ${i} })
	    },
INSTANCE_EOF
    done

    # Insert chart instances after Network traffic chart
    # Note: PVE 8.x uses 'Network traffic', PVE 9.x uses 'Network Traffic' (case difference)
    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_chart_instances.js") or die "Cannot open instances file: $!";
            local $/;
            $::instances = <$fh>;
            close($fh);
        }
        s/(title:\s*gettext\('"'"'Network [Tt]raffic'"'"'\),\s*fields:\s*\['"'"'netin'"'"',\s*'"'"'netout'"'"'\],\s*(?:fieldTitles:\s*\[.*?\],\s*)?store:\s*rrdstore,\s*\},)/$1\n$::instances/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    local insert_status=$?
    rm -f "$temp_charts_file" "$temp_instances_file"

    if [[ $insert_status -ne 0 ]]; then
        err "Failed to insert GPU history charts"
    fi

    # Verify insertion
    if ! grep -q "GPUHistoryStore" "$PVE_MANAGER_LIB_JS_FILE"; then
        err "GPU history charts insertion verification failed"
    fi

    info "GPU historical charts inserted (browser-side data collection with native PVE styling)."
}

# Insert GPU dashboard items into pvemanagerlib.js (StatusView section)
function insert_gpu_dashboard_items() {
    msgb "\n=== Inserting GPU dashboard items into StatusView ==="

    local gpu_count="${DETECTED_GPU_COUNT:-1}"

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
    info "GPU dashboard items inserted into StatusView."
}

# Main installation function
function install_mod() {
    msgb "\n=== PVE GPU Dashboard Mod v${SCRIPT_VERSION} Installation ==="

    check_root_privileges
    check_mod_installation
    configure
    perform_backup

    # Backend: Add GPU data collection to API
    insert_node_info

    # Frontend: Add GPU items to StatusView (real-time display)
    insert_gpu_dashboard_items

    # Frontend: Add GPU history charts (browser-side data collection)
    insert_gpu_history_charts

    msgb "\n=== Finalizing installation ==="

    restart_proxy

    info "Installation completed successfully."
    msgb "\nIMPORTANT: Clear your browser cache (Ctrl+Shift+R or Cmd+Shift+R) to see the changes."
    msgb "\nFeatures installed:"
    echo "  - GPU metrics in Status section (real-time VRAM bar and metrics)"
    echo "  - GPU historical graphs below Network traffic (Temperature, VRAM, Power)"
    msgb "\nHistorical graph settings:"
    echo "  - Duration: ${HISTORY_DURATION:-24 hours}"
    echo "  - Data points: ${HISTORY_MAX_POINTS:-288}"
    local interval_mins=$(( ${HISTORY_POLL_INTERVAL:-300000} / 60000 ))
    if [[ $interval_mins -ge 60 ]]; then
        echo "  - Polling interval: $(( interval_mins / 60 )) hour(s)"
    else
        echo "  - Polling interval: ${interval_mins} minutes"
    fi
    echo "  - Storage: ~$((HISTORY_MAX_POINTS * 100 / 1024)) KB per GPU in browser localStorage"
    msgb "\nNote: History persists across page refreshes but is browser-specific."
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
            echo "  - $NODES_PM_FILE (remove GPU data collection code)"
            echo "  - $PVE_MANAGER_LIB_JS_FILE (remove GPU dashboard items and charts)"
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
