#!/usr/bin/env bash
#
# pve-amd-gpu-dashboard-mod_v3.0.sh
#
# Installs AMD iGPU metrics into the Proxmox VE node status dashboard.
# Adapted from pve-gpu-dashboard-mod_v3.0.sh by en4ble1337 (NVIDIA version).
# Taint-safe Perl: all external command output untainted via regex capture.
#
# Usage:
#   bash pve-amd-gpu-dashboard-mod_v3.0.sh install
#   bash pve-amd-gpu-dashboard-mod_v3.0.sh uninstall
#

################### Configuration #############

TEMP_WARNING=70
TEMP_CRITICAL=85
BACKUP_DIR=""

##################### DO NOT EDIT BELOW #######################

SCRIPT_VERSION="3.0-AMD"
PVE_MANAGER_LIB_JS_FILE="/usr/share/pve-manager/js/pvemanagerlib.js"
NODES_PM_FILE="/usr/share/perl5/PVE/API2/Nodes.pm"

function msgb() { echo -e "\e[1m${1}\e[0m"; }
function info()  { echo -e "\e[0;32m[info] ${1}\e[0m"; }
function warn()  { echo -e "\e[0;33m[warning] ${1}\e[0m"; }
function err()   { echo -e "\e[0;31m[error] ${1}\e[0m"; exit 1; }
function ask()   { local r; read -p $'\n\e[1;36m'"${1}:"$'\e[0m ' r; echo "$r"; }

function usage {
    msgb "\nPVE AMD GPU Dashboard Mod v${SCRIPT_VERSION}"
    msgb "\nUsage:\n$0 [install | uninstall]\n"
    echo "  install     Install the AMD GPU dashboard integration"
    echo "  uninstall   Remove the modification and restore original files"
    exit 1
}

function check_root_privileges() {
    [[ $EUID -ne 0 ]] && err "Must be run as root."
    info "Root privileges verified."
}

function install_radeontop() {
    if ! command -v radeontop &>/dev/null; then
        info "Installing radeontop..."
        apt-get install -y radeontop || err "Failed to install radeontop"
        info "radeontop installed."
    else
        info "radeontop already installed: $(which radeontop)"
    fi
}

function check_amd_gpu() {
    [[ -e /sys/class/drm/card0/device/vendor ]] \
        || err "No DRM device at /sys/class/drm/card0."
    local vendor
    vendor=$(cat /sys/class/drm/card0/device/vendor 2>/dev/null | tr -d '[:space:]')
    [[ "$vendor" == "0x1002" ]] || err "Not an AMD GPU (vendor: $vendor)."
    info "AMD GPU confirmed."
}

function check_mod_installation() {
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null \
        && err "Already installed. Uninstall first."
}

function set_backup_directory() {
    if [[ -z "$BACKUP_DIR" ]]; then
        BACKUP_DIR="$HOME/PVE-GPU-DASHBOARD"
    else
        [[ -d "$BACKUP_DIR" ]] || err "Backup dir not found: $BACKUP_DIR"
    fi
    info "Backup directory: $BACKUP_DIR"
}

function create_backup_directory() {
    set_backup_directory
    mkdir -p "$BACKUP_DIR" || err "Cannot create backup dir: $BACKUP_DIR"
}

function create_file_backup() {
    local src="$1" ts="$2"
    local dst="$BACKUP_DIR/gpu-dashboard.$(basename $src).$ts"
    [[ -f "$src" ]] || err "File not found: $src"
    cp "$src" "$dst" || err "Backup failed: $dst"
    cmp -s "$src" "$dst" || err "Backup verify failed: $dst"
    info "Backup: $dst"
}

function perform_backup() {
    msgb "\n=== Creating backups ==="
    local ts; ts=$(date +%Y%m%d_%H%M%S)
    create_backup_directory
    create_file_backup "$NODES_PM_FILE" "$ts"
    create_file_backup "$PVE_MANAGER_LIB_JS_FILE" "$ts"
}

function configure() {
    msgb "\n=== Detecting AMD GPU ==="
    check_amd_gpu
    install_radeontop

    DETECTED_GPU_NAME=$(lspci 2>/dev/null \
        | grep -iE 'VGA|3D|Display' \
        | grep -iE 'AMD|ATI|Radeon' \
        | head -1 \
        | sed 's/.*: //' \
        | sed 's/ (rev [0-9a-f]*)$//' \
        | sed 's/Advanced Micro Devices, Inc\. \[AMD\/ATI\] //')
    DETECTED_GPU_NAME="${DETECTED_GPU_NAME:-AMD Radeon GPU}"
    DETECTED_DRIVER_VERSION=$(uname -r)

    info "GPU name : $DETECTED_GPU_NAME"
    info "Kernel   : $DETECTED_DRIVER_VERSION"

    msgb "\n=== Display Settings ==="
    local unit; unit=$(ask "Temperatures in Celsius [C] or Fahrenheit [f]? (C/f)")
    case "$unit" in
        [fF]) TEMP_UNIT="F"; info "Using Fahrenheit." ;;
        *)    TEMP_UNIT="C"; info "Using Celsius." ;;
    esac

    msgb "\n=== Historical Graph Settings ==="
    echo "  [1] 24 hours  (1-min intervals, 1,440 points)"
    echo "  [2] 1 week    (1-min intervals, 10,080 points)"
    echo "  [3] 30 days   (5-min intervals, 8,640 points)"
    local hc; hc=$(ask "Choose [1/2/3]")
    case "$hc" in
        2) HISTORY_MAX_POINTS=10080; HISTORY_POLL_INTERVAL=60000;  HISTORY_DURATION="1 week" ;;
        3) HISTORY_MAX_POINTS=8640;  HISTORY_POLL_INTERVAL=300000; HISTORY_DURATION="30 days" ;;
        *) HISTORY_MAX_POINTS=1440;  HISTORY_POLL_INTERVAL=60000;  HISTORY_DURATION="24 hours" ;;
    esac
    info "History: $HISTORY_DURATION"
}

function restart_proxy() {
    info "Restarting pveproxy..."
    systemctl restart pveproxy
}

# ── Backend: taint-safe Perl injected into Nodes.pm ─────────────────────────
function insert_node_info() {
    msgb "\n=== Inserting AMD GPU data retrieval into Nodes.pm ==="

    cat > /tmp/gpu_perl_code.txt << 'PERL_CODE'
# AMD GPU metrics for PVE dashboard (v3.0-AMD, taint-safe)
{
    $ENV{PATH} = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    my $vendor_raw = `cat /sys/class/drm/card0/device/vendor 2>/dev/null` // '';
    my ($vendor) = $vendor_raw =~ /^(\S+)/;
    $vendor //= '';

    if ($vendor eq '0x1002') {

        # Kernel version — taint-safe via regex capture
        my $uname_raw = `uname -r 2>/dev/null` // '';
        my ($driver_version) = $uname_raw =~ /^([\w.\-]+)/;
        $driver_version //= 'N/A';
        $res->{gpuDriverVersion} = $driver_version;

        # GPU name — extracted then tainted chars stripped
        my $lspci_raw = `lspci 2>/dev/null` // '';
        my $gpu_name = 'AMD Radeon GPU';
        for my $line (split /\n/, $lspci_raw) {
            if ($line =~ /(?:VGA|3D|Display).*(?:AMD|ATI|Radeon)/i) {
                if ($line =~ /:\s+(.+)/) {
                    ($gpu_name) = $1 =~ /^([\w\s\[\]\/\(\).,\-]+)/;
                    $gpu_name //= 'AMD Radeon GPU';
                    $gpu_name =~ s/Advanced Micro Devices, Inc\. \[AMD\/ATI\] //;
                    $gpu_name =~ s/\s*\(rev [0-9a-f]+\)\s*$//;
                    $gpu_name =~ s/^\s+|\s+$//g;
                }
                last;
            }
        }

        # hwmon path — taint-safe
        my $hwmon_ls = `ls /sys/class/drm/card0/device/hwmon/ 2>/dev/null` // '';
        my ($hwmon_dir) = $hwmon_ls =~ /^(\w+)/;
        $hwmon_dir //= 'hwmon0';
        my $hwmon_path = "/sys/class/drm/card0/device/hwmon/$hwmon_dir";

        # Temperature: millidegrees → Celsius — taint-safe
        my $temp_raw = `cat $hwmon_path/temp1_input 2>/dev/null` // '';
        my ($temp_milli) = $temp_raw =~ /^(\d+)/;
        my $temp = defined($temp_milli) ? int($temp_milli / 1000) : 0;

        # GPU load % — read from radeontop-logger daemon (instant, no delay)
        my $gpu_util = 0;
        if (open(my $rt, '<', '/tmp/radeontop.dat')) {
            my $last_line = '';
            while (my $line = <$rt>) { $last_line = $line; }
            close($rt);
            if ($last_line =~ /gpu\s+([\d.]+)%/) {
                $gpu_util = int($1 + 0.5);
            }
        }

        # VRAM used — taint-safe
        my $mem_used_raw = `cat /sys/class/drm/card0/device/mem_info_vram_used 2>/dev/null` // '';
        my ($mem_used) = $mem_used_raw =~ /^(\d+)/;
        $mem_used //= 0;

        # VRAM total — taint-safe
        my $mem_total_raw = `cat /sys/class/drm/card0/device/mem_info_vram_total 2>/dev/null` // '';
        my ($mem_total) = $mem_total_raw =~ /^(\d+)/;
        $mem_total //= 0;

        # Power: power1_input microwatts → watts — taint-safe
        my $power_raw = `cat $hwmon_path/power1_input 2>/dev/null` // '';
        my ($power_uw) = $power_raw =~ /^(\d+)/;
        my $power = defined($power_uw) ? sprintf("%.1f", $power_uw / 1000000) : '0.0';

        # VCN state — pure Perl file read, avoids taint from backticks
        my $vcn_state = 'N/A';
        if (open(my $fh, '<', '/sys/kernel/debug/dri/0/amdgpu_pm_info')) {
            while (my $line = <$fh>) {
                chomp $line;
                if ($line =~ /^VCN:\s+(Powered\s+(?:up|down))/i) {
                    $vcn_state = $1;
                    last;
                }
            }
            close($fh);
        }

        # Store metrics
        $res->{'gpu0_name'}       = $gpu_name;
        $res->{'gpu0_temp'}       = $temp + 0;
        $res->{'gpu0_util'}       = $gpu_util / 100;
        $res->{'gpu0_util_max'}   = { max => 1, temp => $temp+0, power => $power+0, vcn => $vcn_state };
        $res->{'gpu0_mem_used'}   = $mem_used + 0;
        $res->{'gpu0_mem_total'}  = $mem_total + 0;
        $res->{'gpu0_power_draw'} = $power + 0;
        $res->{'gpu0_vcn_state'}  = $vcn_state;
        $res->{'gpu0_metrics'}    = "${temp},${gpu_util},${power},${vcn_state}";
        $res->{'gpuCount'}        = 1;
        $res->{'gpu_server_time'} = time();
    }
}
PERL_CODE

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
    rm -f /tmp/gpu_perl_code.txt
    [[ $exit_code -ne 0 ]] && err "Failed to insert code into Nodes.pm"
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" || err "Nodes.pm verification failed"
    info "AMD GPU data collection inserted into Nodes.pm"
}

function insert_rrd_model_fields() {
    msgb "\n=== Adding AMD GPU fields to RRD data model ==="

    cat > /tmp/gpu_rrd_fields.txt << 'EOF'

        'gpu0_temp',
        'gpu0_util',
        'gpu0_util_max',
        'gpu0_mem_used',
        'gpu0_mem_total',
        'gpu0_power_draw',
        'gpu0_metrics',
        'gpu0_vcn_state',
EOF

    perl -i -0777 -pe '
        BEGIN {
            open(my $fh, "<", "/tmp/gpu_rrd_fields.txt") or die $!;
            local $/; $::fields = <$fh>; close($fh);
        }
        s/('"'"'swapused'"'"',)/$1$::fields/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    rm -f /tmp/gpu_rrd_fields.txt
    grep -q "gpu0_temp" "$PVE_MANAGER_LIB_JS_FILE" || err "RRD fields verification failed"
    info "AMD GPU RRD fields added"
}

function insert_gpu_history_charts() {
    msgb "\n=== Inserting AMD GPU historical charts ==="

    local gpu_name="${DETECTED_GPU_NAME:-AMD Radeon GPU}"
    local max_points="${HISTORY_MAX_POINTS:-1440}"
    local poll_interval="${HISTORY_POLL_INTERVAL:-60000}"

    cat > /tmp/gpu_history_store.js << STORE_JS
Ext.define('PVE.data.GPUHistoryStore', {
    extend: 'Ext.data.Store',
    alias: 'store.pveGPUHistoryStore',
    config: { nodename: '', gpuIndex: 0, maxPoints: ${max_points}, pollInterval: ${poll_interval} },
    fields: ['time', 'gpu_temp', 'gpu_mem_used', 'gpu_power_draw'],
    constructor: function(config) {
        var me = this; me.callParent([config]);
        me.storageKey = 'pve-gpu-rrd-' + me.getNodename() + '-gpu' + me.getGpuIndex();
        me.loadFromStorage(); me.startPolling();
    },
    loadFromStorage: function() {
        var me = this;
        try {
            var data = localStorage.getItem(me.storageKey);
            if (data) {
                var records = JSON.parse(data);
                records = records.map(function(r) { if (r.time && r.time < 10000000000) r.time *= 1000; return r; });
                me.loadData(records);
            }
        } catch(e) { console.warn('AMD GPU history load error:', e); }
    },
    saveToStorage: function() {
        var me = this;
        try {
            var records = [];
            me.each(function(r) { var d = r.getData(); if (d.time > 10000000000) d.time = Math.floor(d.time/1000); records.push(d); });
            localStorage.setItem(me.storageKey, JSON.stringify(records));
        } catch(e) { localStorage.removeItem(me.storageKey); }
    },
    addDataPoint: function(temp, memUsed, powerDraw, serverTime) {
        var me = this;
        me.add({ time: serverTime || Date.now(), gpu_temp: temp, gpu_mem_used: memUsed, gpu_power_draw: powerDraw });
        while (me.getCount() > me.getMaxPoints()) me.removeAt(0);
        me.saveToStorage();
    },
    startPolling: function() {
        var me = this;
        var poll = function() {
            Proxmox.Utils.API2Request({ url: '/nodes/' + me.getNodename() + '/status', method: 'GET',
                success: function(response) {
                    var d = response.result.data, idx = me.getGpuIndex();
                    var t = d['gpu'+idx+'_temp'], m = d['gpu'+idx+'_mem_used'], p = d['gpu'+idx+'_power_draw'];
                    var st = d.gpu_server_time ? d.gpu_server_time * 1000 : Date.now();
                    if (t !== undefined) me.addDataPoint(parseFloat(t)||0, parseFloat(m)||0, parseFloat(p)||0, st);
                }
            });
        };
        poll();
        me.pollTask = Ext.TaskManager.start({ run: poll, interval: me.getPollInterval() });
    },
    destroy: function() { var me = this; if (me.pollTask) Ext.TaskManager.stop(me.pollTask); me.callParent(); }
});
STORE_JS

    perl -i -0777 -pe '
        BEGIN { open(my $fh,"<","/tmp/gpu_history_store.js") or die $!; local $/; $::store=<$fh>; close($fh); }
        s/(Ext\.define\('"'"'PVE\.node\.Summary'"'"')/$::store\n\n$1/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    cat > /tmp/gpu_chart_instances.js << INSTANCES_JS
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Temperature (${gpu_name})',
	        fields: ['gpu_temp'],
	        fieldTitles: ['Temperature \u00b0C'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 VRAM Usage (${gpu_name})',
	        fields: ['gpu_mem_used'],
	        fieldTitles: ['VRAM Used'],
	        unit: 'bytes',
	        powerOfTwo: true,
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
	    {
	        xtype: 'proxmoxRRDChart',
	        title: 'GPU 0 Power Draw (${gpu_name})',
	        fields: ['gpu_power_draw'],
	        fieldTitles: ['Power (W)'],
	        store: Ext.create('PVE.data.GPUHistoryStore', { nodename: nodename, gpuIndex: 0 })
	    },
INSTANCES_JS

    perl -i -0777 -pe '
        BEGIN { open(my $fh,"<","/tmp/gpu_chart_instances.js") or die $!; local $/; $::inst=<$fh>; close($fh); }
        s/(title:\s*gettext\('"'"'Network [Tt]raffic'"'"'\),\s*fields:\s*\['"'"'netin'"'"',\s*'"'"'netout'"'"'\],\s*(?:fieldTitles:\s*\[.*?\],\s*)?store:\s*rrdstore,\s*\},)/$1\n$::inst/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    rm -f /tmp/gpu_history_store.js /tmp/gpu_chart_instances.js
    grep -q "GPUHistoryStore" "$PVE_MANAGER_LIB_JS_FILE" || err "History charts verification failed"
    info "AMD GPU historical charts inserted"
}

function insert_gpu_dashboard_items() {
    msgb "\n=== Inserting AMD GPU dashboard items ==="

    local gpu_name="${DETECTED_GPU_NAME:-AMD Radeon GPU}"
    local driver_ver="${DETECTED_DRIVER_VERSION:-N/A}"

    cat > /tmp/gpu_dashboard_items.js << ITEMS_EOF
	{
	    xtype: 'box',
	    colspan: 2,
	    padding: '0 0 20 0',
	},
	{
	    itemId: 'gpu0_vram',
	    iconCls: 'fa fa-fw fa-television',
	    title: 'GPU 0: ${gpu_name} (Kernel: ${driver_ver})',
	    valueField: 'gpu0_mem_used',
	    maxField: 'gpu0_mem_total',
	},
ITEMS_EOF

    if [[ "$TEMP_UNIT" == "F" ]]; then
        cat >> /tmp/gpu_dashboard_items.js << 'ITEM_METRICS'
	{
	    itemId: 'gpu0_util_bar',
	    iconCls: 'fa fa-fw fa-desktop',
	    title: 'GPU 0 usage',
	    valueField: 'gpu0_util',
	    maxField: 'gpu0_util_max',
	    renderer: function(value, record) {
	        var gpuUtil = Math.round(value * 100);
	        var temp = record.temp || 0;
	        var power = record.power || 0;
	        var vcn = record.vcn || 'N/A';
	        var tempF = (temp * 9/5) + 32;
	        var s = (tempF>=185)?'color:#ff4444;font-weight:bold;':(tempF>=158)?'color:#FFC300;font-weight:bold;':'';
	        return 'GPU: '+gpuUtil+'% | Temp: <span style="'+s+'">'+tempF.toFixed(0)+'\u00b0F</span> | Power: '+power.toFixed(1)+'W | VCN: '+vcn;
	    },
	},
ITEM_METRICS
    else
        cat >> /tmp/gpu_dashboard_items.js << 'ITEM_METRICS'
	{
	    itemId: 'gpu0_util_bar',
	    iconCls: 'fa fa-fw fa-desktop',
	    title: 'GPU 0 usage',
	    valueField: 'gpu0_util',
	    maxField: 'gpu0_util_max',
	    renderer: function(value, record) {
	        var gpuUtil = Math.round(value * 100);
	        var temp = record.temp || 0;
	        var power = record.power || 0;
	        var vcn = record.vcn || 'N/A';
	        var s = (temp>=85)?'color:#ff4444;font-weight:bold;':(temp>=70)?'color:#FFC300;font-weight:bold;':'';
	        return 'GPU: '+gpuUtil+'% | Temp: <span style="'+s+'">'+temp+'\u00b0C</span> | Power: '+power.toFixed(1)+'W | VCN: '+vcn;
	    },
	},
ITEM_METRICS
    fi

    perl -i -0777 -pe '
        BEGIN { open(my $fh,"<","/tmp/gpu_dashboard_items.js") or die $!; local $/; $::items=<$fh>; close($fh); }
        s/(itemId:\s*'"'"'swap'"'"'.*?\n\s*\},)(\s*\{\s*xtype:\s*'"'"'box'\'',\s*colspan:\s*2,\s*padding:\s*'"'"'0 0 20 0'"'"')/$1$::items$2/s;
    ' "$PVE_MANAGER_LIB_JS_FILE"

    local ec=$?
    rm -f /tmp/gpu_dashboard_items.js
    [[ $ec -ne 0 ]] && err "Failed to insert dashboard items"
    grep -q "itemId: 'gpu0_vram'" "$PVE_MANAGER_LIB_JS_FILE" || err "Dashboard items verification failed"
    info "AMD GPU dashboard items inserted"
}

function install_prerequisites() {
    msgb "\n=== Installing prerequisites ==="

    # 1. Add www-data to video and render groups (required for /dev/dri access)
    usermod -aG video,render www-data
    info "www-data added to video and render groups."

    # 2. Fix debugfs permissions (required for amdgpu_pm_info — VCN state)
    chmod 755 /sys/kernel/debug 2>/dev/null
    chmod 755 /sys/kernel/debug/dri 2>/dev/null
    chmod 644 /sys/kernel/debug/dri/0/amdgpu_pm_info 2>/dev/null
    info "debugfs permissions set."

    # 3. Create radeontop-logger systemd service (continuous background sampling)
    cat > /etc/systemd/system/radeontop-logger.service << 'EOF'
[Unit]
Description=radeontop continuous AMD GPU logger for PVE dashboard
After=multi-user.target

[Service]
ExecStart=/usr/bin/radeontop -d /tmp/radeontop.dat
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now radeontop-logger
    info "radeontop-logger service installed and started."

    # 4. Set radeontop.dat permissions so www-data can read it
    sleep 2  # wait for radeontop to create the file
    chmod 644 /tmp/radeontop.dat 2>/dev/null
    info "radeontop.dat permissions set."

    # 5. Persist radeontop.dat permissions across reboots via tmpfiles.d
    echo 'f /tmp/radeontop.dat 644 root root -' > /etc/tmpfiles.d/radeontop.conf
    info "tmpfiles.d persistence configured."
}

function uninstall_prerequisites() {
    msgb "\n=== Removing prerequisites ==="

    # Stop and disable radeontop-logger service
    if systemctl is-active --quiet radeontop-logger 2>/dev/null; then
        systemctl stop radeontop-logger
        info "radeontop-logger stopped."
    fi
    if systemctl is-enabled --quiet radeontop-logger 2>/dev/null; then
        systemctl disable radeontop-logger
        info "radeontop-logger disabled."
    fi
    rm -f /etc/systemd/system/radeontop-logger.service
    systemctl daemon-reload
    info "radeontop-logger service removed."

    # Remove tmpfiles.d config
    rm -f /etc/tmpfiles.d/radeontop.conf
    info "tmpfiles.d config removed."

    # Remove radeontop.dat
    rm -f /tmp/radeontop.dat
    info "radeontop.dat removed."

    # Remove www-data from video and render groups
    gpasswd -d www-data video 2>/dev/null && info "www-data removed from video group." \
        || warn "www-data was not in video group."
    gpasswd -d www-data render 2>/dev/null && info "www-data removed from render group." \
        || warn "www-data was not in render group."

    # Optionally remove radeontop
    local remove_rt
    remove_rt=$(ask "Remove radeontop package? (y/N)")
    if [[ "$remove_rt" =~ ^[yY]$ ]]; then
        apt-get remove -y radeontop && info "radeontop removed." \
            || warn "Failed to remove radeontop."
    else
        info "radeontop left installed."
    fi
}

function install_mod() {
    msgb "\n=== PVE AMD GPU Dashboard Mod v${SCRIPT_VERSION} ==="
    check_root_privileges
    check_mod_installation
    configure
    install_prerequisites
    perform_backup
    insert_node_info
    insert_rrd_model_fields
    insert_gpu_dashboard_items
    insert_gpu_history_charts
    msgb "\n=== Finalizing ==="
    restart_proxy
    info "Installation complete."
    msgb "\n>>> Clear browser cache (Ctrl+Shift+R) to see changes <<<"
    msgb "\nShows: GPU: X% | Temp: X°${TEMP_UNIT} | Power: X.XW | VCN: Powered up/down"
    msgb "Note: Power = total SoC (CPU+GPU) on APU."
}

function uninstall_mod() {
    msgb "\n=== Uninstalling AMD GPU Dashboard Mod ==="
    check_root_privileges
    grep -q 'gpuDriverVersion' "$NODES_PM_FILE" 2>/dev/null || err "Mod not installed."
    set_backup_directory

    local other=""
    grep -q 'sensorsOutput'   "$NODES_PM_FILE" 2>/dev/null && other="${other}pve-mod-gui-sensors "
    grep -q 'nvidiaGpuOutput' "$NODES_PM_FILE" 2>/dev/null && other="${other}pve-mod-gui-nvidia "
    if [[ -n "$other" ]]; then
        warn "Other mods detected: $other"
        local c; c=$(ask "Continue with backup restore? (y/N)")
        [[ ! "$c" =~ ^[yY]$ ]] && { info "Cancelled."; exit 0; }
    fi

    local f
    f=$(find "$BACKUP_DIR" -name "gpu-dashboard.Nodes.pm.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1 | awk '{print $2}')
    [[ -n "$f" ]] && { cp "$f" "$NODES_PM_FILE"; info "Restored Nodes.pm"; } \
        || warn "No Nodes.pm backup found. Run: apt install --reinstall pve-manager"

    f=$(find "$BACKUP_DIR" -name "gpu-dashboard.pvemanagerlib.js.*" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -1 | awk '{print $2}')
    [[ -n "$f" ]] && { cp "$f" "$PVE_MANAGER_LIB_JS_FILE"; info "Restored pvemanagerlib.js"; } \
        || warn "No pvemanagerlib.js backup found. Run: apt install --reinstall pve-manager"

    uninstall_prerequisites
    restart_proxy
    info "Uninstall complete."
    msgb "\n>>> Clear browser cache (Ctrl+Shift+R) <<<"
}

executed=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        install)   executed=$((executed+1)); install_mod ;;
        uninstall) executed=$((executed+1)); uninstall_mod ;;
        *) warn "Unknown: $1"; usage ;;
    esac
    shift
done
[[ $executed -eq 0 ]] && usage
