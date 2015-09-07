#!/bin/bash
# +------------------------------------------------------------------+
# |             ____ _               _        __  __ _  __           |
# |            / ___| |__   ___  ___| | __   |  \/  | |/ /           |
# |           | |   | '_ \ / _ \/ __| |/ /   | |\/| | ' /            |
# |           | |___| | | |  __/ (__|   <    | |  | | . \            |
# |            \____|_| |_|\___|\___|_|\_\___|_|  |_|_|\_\           |
# |                                                                  |
# | Copyright Mathias Kettner 2014             mk@mathias-kettner.de |
# +------------------------------------------------------------------+
#
# This file is part of Check_MK.
# The official homepage is at http://mathias-kettner.de/check_mk.
#
# check_mk is free software;  you can redistribute it and/or modify it
# under the  terms of the  GNU General Public License  as published by
# the Free Software Foundation in version 2.  check_mk is  distributed
# in the hope that it will be useful, but WITHOUT ANY WARRANTY;  with-
# out even the implied warranty of  MERCHANTABILITY  or  FITNESS FOR A
# PARTICULAR PURPOSE. See the  GNU General Public License for more de-
# ails.  You should have  received  a copy of the  GNU  General Public
# License along with GNU Make; see the file  COPYING.  If  not,  write
# to the Free Software Foundation, Inc., 51 Franklin St,  Fifth Floor,
# Boston, MA 02110-1301 USA.

# Remove locale settings to eliminate localized outputs where possible
export LC_ALL=C
unset LANG

export MK_LIBDIR="/usr/lib/check_mk_agent"
export MK_CONFDIR="/etc/check_mk"
export MK_VARDIR="/var/lib/check_mk_agent"

# Provide information about the remote host. That helps when data
# is being sent only once to each remote host.
if [ "$REMOTE_HOST" ] ; then
    export REMOTE=$REMOTE_HOST
elif [ "$SSH_CLIENT" ] ; then
    export REMOTE=${SSH_CLIENT%% *}
fi

# Make sure, locally installed binaries are found
PATH=$PATH:/usr/local/bin

# All executables in PLUGINSDIR will simply be executed and their
# ouput appended to the output of the agent. Plugins define their own
# sections and must output headers with '<<<' and '>>>'
PLUGINSDIR=$MK_LIBDIR/plugins

# All executables in LOCALDIR will by executabled and their
# output inserted into the section <<<local>>>. Please
# refer to online documentation for details about local checks.
LOCALDIR=$MK_LIBDIR/local

# All files in SPOOLDIR will simply appended to the agent
# output if they are not outdated (see below)
SPOOLDIR=$MK_VARDIR/spool

# close standard input (for security reasons) and stderr
if [ "$1" = -d ]
then
    set -xv
else
    exec </dev/null 2>/dev/null
fi

# Runs a command asynchronous by use of a cache file. Usage:
# run_cached [-s] NAME MAXAGE
#   -s creates the section header <<<$NAME>>>
#   NAME is the name of the section (also used as cache file name)
#   MAXAGE is the maximum cache livetime in seconds
function run_cached () {
    local NOW=$(date +%s)
    local section=
    if [ "$1" = -s ] ; then local section="echo '<<<$2:cached($NOW,$3)>>>' ; " ; shift ; fi
    local NAME=$1
    local MAXAGE=$2
    shift 2
    local CMDLINE="$section$@"

    if [ ! -d $MK_VARDIR/cache ]; then mkdir -p $MK_VARDIR/cache ; fi
    CACHEFILE="$MK_VARDIR/cache/$NAME.cache"

    # Check if the creation of the cache takes suspiciously long and return
    # nothing if the age (access time) of $CACHEFILE.new is twice the MAXAGE
    if [ -e "$CACHEFILE.new" ] ; then
        local CF_ATIME=$(stat -c %X "$CACHEFILE.new")
        if [ $((NOW - CF_ATIME)) -ge $((MAXAGE * 2)) ] ; then
            # Kill the process still accessing that file in case
            # it is still running. This avoids overlapping processes!
            fuser -k -9 "$CACHEFILE.new" >/dev/null 2>&1
            rm -f "$CACHEFILE.new"
            return
        fi
    fi

    # Check if cache file exists and is recent enough
    if [ -s "$CACHEFILE" ] ; then
        local MTIME=$(stat -c %Y "$CACHEFILE")
        if [ $((NOW - MTIME)) -le $MAXAGE ] ; then local USE_CACHEFILE=1 ; fi
        # Output the file in any case, even if it is
        # outdated. The new file will not yet be available
        cat "$CACHEFILE"
    fi

    # Cache file outdated and new job not yet running? Start it
    if [ -z "$USE_CACHEFILE" -a ! -e "$CACHEFILE.new" ] ; then
        # When the command fails, the output is throws away ignored
        echo "set -o noclobber ; exec > \"$CACHEFILE.new\" || exit 1 ; $CMDLINE && mv \"$CACHEFILE.new\" \"$CACHEFILE\" || rm -f \"$CACHEFILE\" \"$CACHEFILE.new\"" | nohup bash >/dev/null 2>&1 &
    fi
}

# Make run_cached available for subshells (plugins, local checks, etc.)
export -f run_cached

echo '<<<check_mk>>>'
echo Version: 1.2.7i2
echo AgentOS: linux
echo Hostname: $HOSTNAME
echo AgentDirectory: $MK_CONFDIR
echo DataDirectory: $MK_VARDIR
echo SpoolDirectory: $SPOOLDIR
echo PluginsDirectory: $PLUGINSDIR
echo LocalDirectory: $LOCALDIR

# If we are called via xinetd, try to find only_from configuration
if [ -n "$REMOTE_HOST" ]
then
    echo -n 'OnlyFrom: '
    echo $(sed -n '/^service[[:space:]]*check_mk/,/}/s/^[[:space:]]*only_from[[:space:]]*=[[:space:]]*\(.*\)/\1/p' /etc/xinetd.d/* | head -n1)
fi

# Print out Partitions / Filesystems. (-P gives non-wrapped POSIXed output)
# Heads up: NFS-mounts are generally supressed to avoid agent hangs.
# If hard NFS mounts are configured or you have too large nfs retry/timeout
# settings, accessing those mounts from the agent would leave you with
# thousands of agent processes and, ultimately, a dead monitored system.
# These should generally be monitored on the NFS server, not on the clients.

echo '<<<df>>>'
# The exclusion list is getting a bit of a problem. -l should hide any remote FS but seems
# to be all but working.
excludefs="-x smbfs -x cifs -x iso9660 -x udf -x nfsv4 -x nfs -x mvfs -x zfs"
df -PTlk $excludefs | sed 1d

# df inodes information
echo '<<<df>>>'
echo '[df_inodes_start]'
df -PTli $excludefs | sed 1d
echo '[df_inodes_end]'

# Filesystem usage for ZFS
if type zfs > /dev/null 2>&1 ; then
    echo '<<<zfsget>>>'
    zfs get -Hp name,quota,used,avail,mountpoint,type -t filesystem,volume || \
       zfs get -Hp name,quota,used,avail,mountpoint,type
    echo '[df]'
    df -PTlk -t zfs | sed 1d
fi

# Check NFS mounts by accessing them with stat -f (System
# call statfs()). If this lasts more then 2 seconds we
# consider it as hanging. We need waitmax.
if type waitmax >/dev/null
then
    STAT_VERSION=$(stat --version | head -1 | cut -d" " -f4)
    STAT_BROKE="5.3.0"

    echo '<<<nfsmounts>>>'
    sed -n '/ nfs4\? /s/[^ ]* \([^ ]*\) .*/\1/p' < /proc/mounts |
        sed 's/\\040/ /g' |
        while read MP
	do
	 if [ $STAT_VERSION != $STAT_BROKE ]; then
	    waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" || \
		echo "$MP hanging 0 0 0 0"
	 else
	    waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" && \
	    printf '\n'|| echo "$MP hanging 0 0 0 0"
	 fi
	done

    echo '<<<cifsmounts>>>'
    sed -n '/ cifs\? /s/[^ ]* \([^ ]*\) .*/\1/p' < /proc/mounts |
        sed 's/\\040/ /g' |
        while read MP
        do
         if [ $STAT_VERSION != $STAT_BROKE ]; then
            waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" || \
                echo "$MP hanging 0 0 0 0"
         else
            waitmax -s 9 2 stat -f -c "$MP ok %b %f %a %s" "$MP" && \
            printf '\n'|| echo "$MP hanging 0 0 0 0"
         fi
        done
fi

# Check mount options. Filesystems may switch to 'ro' in case
# of a read error.
echo '<<<mounts>>>'
grep ^/dev < /proc/mounts

# processes including username, without kernel processes
echo '<<<ps>>>'
ps ax -o user,vsz,rss,cputime,etime,pid,command --columns 10000 | sed -e 1d -e 's/ *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) *\([^ ]*\) */(\1,\2,\3,\4\/\5,\6) /'

# Memory usage
echo '<<<mem>>>'
egrep -v '^Swap:|^Mem:|total:' < /proc/meminfo

# Load and number of processes
echo '<<<cpu>>>'
echo "$(cat /proc/loadavg) $(grep -E '^CPU|^processor' < /proc/cpuinfo | wc -l)"

# Uptime
echo '<<<uptime>>>'
cat /proc/uptime


# New variant: Information about speed and state in one section
echo '<<<lnx_if:sep(58)>>>'
#sed 1,2d /proc/net/dev
#if type ethtool > /dev/null
#then
#    for eth in $(sed -e 1,2d < /proc/net/dev | cut -d':' -f1 | sort)
#    do
#        echo "[$eth]"
#        ethtool $eth | egrep '(Speed|Duplex|Link detected|Auto-negotiation):'
#        echo -en "\tAddress: " ; cat /sys/class/net/$eth/address ; echo
#    done
#fi
for i in $(ovs-vsctl list Interface | grep name | cut -c 24- | sed 's/"$//') ; do
    if [ $(ovs-vsctl get Interface $i admin_state | grep "up") ]
    then
        echo $i: $(ovs-vsctl get Interface $i statistics:rx_bytes) $(ovs-vsctl get Interface $i statistics:rx_packets) $(ovs-vsctl get Interface $i statistics:rx_crc_err) $(ovs-vsctl get Interface $i stati
stics:rx_dropped) 0 0 0 0 $(ovs-vsctl get Interface $i statistics:tx_bytes) $(ovs-vsctl get Interface $i statistics:rx_packets) $(ovs-vsctl get Interface $i statistics:rx_crc_err) $(ovs-vsctl get Interface
 $i statistics:rx_dropped) 0 $(ovs-vsctl get Interface $i statistics:collisions) 0 0
    fi
done
for i in $(ovs-vsctl list Interface | grep name | cut -c 24- | sed 's/"$//') ; do
    if [ $(ovs-vsctl get Interface $i admin_state | grep "up") ]
    then
        echo [$i]
        echo -e "\tSpeed: $(ovs-vsctl get Interface $i link_speed | sed 's/.\{5\}$//')Mb/s"
        echo -e "\tDuplex: $(ovs-vsctl get Interface $i duplex | sed -e "s/\b\(.\)/\u\1/g")"
        echo -e "\tAuto-negotiation: "
        echo -e "\tLink detected: $(ovs-vsctl get Interface $i link_state | sed -e 's/up/yes/g' -e 's/down/no/g')"
        echo -e "\tAddress: $(ovs-vsctl get Interface $i mac_in_use | sed -e 's/"//g')"
    fi
done

# Current state of bonding interfaces
if [ -e /proc/net/bonding ] ; then
    echo '<<<lnx_bonding:sep(58)>>>'
    pushd /proc/net/bonding > /dev/null ; head -v -n 1000 * ; popd
fi

# Same for Open vSwitch bonding
if type ovs-appctl > /dev/null ; then
    echo '<<<ovs_bonding:sep(58)>>>'
    for bond in $(ovs-appctl bond/list | sed -e 1d | rev | cut -f3 | rev) ; do
        echo "[$bond]"
        ovs-appctl bond/show $bond
    done
fi


# Number of TCP connections in the various states
echo '<<<tcp_conn_stats>>>'
# waitmax 10 netstat -nt | awk ' /^tcp/ { c[$6]++; } END { for (x in c) { print x, c[x]; } }'
# New implementation: netstat is very slow for large TCP tables
cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk ' /:/ { c[$4]++; } END { for (x in c) { print x, c[x]; } }'

# Linux Multipathing
if type multipath >/dev/null ; then
    if [ -f /etc/multipath.conf ] ; then
        echo '<<<multipath>>>'
        multipath -l
    fi
fi

# Performancecounter Platten
echo '<<<diskstat>>>'
date +%s
egrep ' (x?[shv]d[a-z]*|cciss/c[0-9]+d[0-9]+|emcpower[a-z]+|dm-[0-9]+|VxVM.*|mmcblk.*) ' < /proc/diskstats
if type dmsetup >/dev/null ; then
    echo '[dmsetup_info]'
    dmsetup info -c --noheadings --separator ' ' -o name,devno,vg_name,lv_name
fi
if [ -d /dev/vx/dsk ] ; then
    echo '[vx_dsk]'
    stat -c "%t %T %n" /dev/vx/dsk/*/*
fi


# Performancecounter Kernel
echo '<<<kernel>>>'
date +%s
cat /proc/vmstat /proc/stat

# Hardware sensors via IPMI (need ipmitool)
if type ipmitool > /dev/null
then
    run_cached -s ipmi 300 "ipmitool sensor list | grep -v 'command failed' | sed -e 's/ *| */|/g' -e 's/ /_/g' -e 's/_*"'$'"//' -e 's/|/ /g' | egrep -v '^[^ ]+ na ' | grep -v ' discrete '"
fi


# IPMI data via ipmi-sensors (of freeipmi). Please make sure, that if you
# have installed freeipmi that IPMI is really support by your hardware.
if type ipmi-sensors >/dev/null
then
    echo '<<<ipmi_sensors>>>'
    # Newer ipmi-sensors version have new output format; Legacy format can be used
    if ipmi-sensors --help | grep -q legacy-output; then
        IPMI_FORMAT="--legacy-output"
    else
        IPMI_FORMAT=""
    fi
    # At least with ipmi-sensoirs 0.7.16 this group is Power_Unit instead of "Power Unit"
    run_cached -s ipmi_sensors 300 "for class in Temperature Power_Unit Fan
    do
        ipmi-sensors $IPMI_FORMAT --sdr-cache-directory /var/cache -g "$class" | sed -e 's/ /_/g' -e 's/:_\?/ /g' -e 's@ \([^(]*\)_(\([^)]*\))@ \2_\1@'
        # In case of a timeout immediately leave loop.
        if [ $? = 255 ] ; then break ; fi
    done"
fi

# RAID status of Linux software RAID
echo '<<<md>>>'
cat /proc/mdstat

# RAID status of Linux RAID via device mapper
if type dmraid >/dev/null && DMSTATUS=$(dmraid -r)
then
    echo '<<<dmraid>>>'

    # Output name and status
    dmraid -s | grep -e ^name -e ^status

    # Output disk names of the RAID disks
    DISKS=$(echo "$DMSTATUS" | cut -f1 -d\:)

    for disk in $DISKS ; do
        device=$(cat /sys/block/$(basename $disk)/device/model )
        status=$(echo "$DMSTATUS" | grep ^${disk})
        echo "$status Model: $device"
    done
fi

# RAID status of LSI controllers via cfggen
if type cfggen > /dev/null ; then
   echo '<<<lsi>>>'
   cfggen 0 DISPLAY | egrep '(Target ID|State|Volume ID|Status of volume)[[:space:]]*:' | sed -e 's/ *//g' -e 's/:/ /'
fi

# RAID status of LSI MegaRAID controller via MegaCli. You can download that tool from:
# http://www.lsi.com/downloads/Public/MegaRAID%20Common%20Files/8.02.16_MegaCLI.zip
if type MegaCli >/dev/null ; then
    MegaCli_bin="MegaCli"
elif type MegaCli64 >/dev/null ; then
    MegaCli_bin="MegaCli64"
elif type megacli >/dev/null ; then
    MegaCli_bin="megacli"
else
    MegaCli_bin="unknown"
fi

if [ "$MegaCli_bin" != "unknown" ]; then
    echo '<<<megaraid_pdisks>>>'
    for part in $($MegaCli_bin -EncInfo -aALL -NoLog < /dev/null \
        | sed -rn 's/:/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//; s/Number of enclosures on adapter ([0-9]+).*/adapter \1/g; /^(Enclosure|Device ID|adapter) [0-9]+$/ p'); do
        [ $part = adapter ] && echo ""
        [ $part = 'Enclosure' ] && echo -ne "\ndev2enc"
        echo -n " $part"
    done
    echo
    $MegaCli_bin -PDList -aALL -NoLog < /dev/null | egrep 'Enclosure|Raw Size|Slot Number|Device Id|Firmware state|Inquiry|Adapter'
    echo '<<<megaraid_ldisks>>>'
    $MegaCli_bin -LDInfo -Lall -aALL -NoLog < /dev/null | egrep 'Size|State|Number|Adapter|Virtual'
    echo '<<<megaraid_bbu>>>'
    $MegaCli_bin -AdpBbuCmd -GetBbuStatus -aALL -NoLog < /dev/null | grep -v Exit
fi

# RAID status of 3WARE disk controller (by Radoslaw Bak)
if type tw_cli > /dev/null ; then
    for C in $(tw_cli show | awk 'NR < 4 { next } { print $1 }'); do
        echo '<<<3ware_info>>>'
        tw_cli /$C show all | egrep 'Model =|Firmware|Serial'
        echo '<<<3ware_disks>>>'
        tw_cli /$C show drivestatus | egrep 'p[0-9]' | sed "s/^/$C\//"
        echo '<<<3ware_units>>>'
        tw_cli /$C show unitstatus | egrep 'u[0-9]' | sed "s/^/$C\//"
    done
fi

# RAID controllers from areca (Taiwan)
# cli64 can be found at ftp://ftp.areca.com.tw/RaidCards/AP_Drivers/Linux/CLI/
if type cli64 >/dev/null ; then
    run_cached -s arc_raid_status 300 "cli64 rsf info | tail -n +3 | head -n -2"
fi

# VirtualBox Guests. Section must always been output. Otherwise the
# check would not be executed in case no guest additions are installed.
# And that is something the check wants to detect
echo '<<<vbox_guest>>>'
if type VBoxControl >/dev/null 2>&1 ; then
    VBoxControl -nologo guestproperty enumerate | cut -d, -f1,2
    [ ${PIPESTATUS[0]} = 0 ] || echo "ERROR"
fi

# OpenVPN Clients. Currently we assume that the configuration # is in
# /etc/openvpn. We might find a safer way to find the configuration later.
if [ -e /etc/openvpn/openvpn-status.log ] ; then
    echo '<<<openvpn_clients:sep(44)>>>'
    sed -n -e '/CLIENT LIST/,/ROUTING TABLE/p' < /etc/openvpn/openvpn-status.log  | sed -e 1,3d -e '$d'
fi

# Time synchronization with NTP
if type ntpq > /dev/null 2>&1 ; then
   # remove heading, make first column space separated
   run_cached -s ntp 30 "waitmax 5 ntpq -np | sed -e 1,2d -e 's/^\(.\)/\1 /' -e 's/^ /%/' || true"
fi

# Time synchronization with Chrony
if type chronyc > /dev/null 2>&1 ; then
    # Force successful exit code. Otherwise section will be missing if daemon not running
    run_cached -s chrony 30 "waitmax 5 chronyc tracking || true"
fi

if type nvidia-settings >/dev/null && [ -S /tmp/.X11-unix/X0 ]
then
    echo '<<<nvidia>>>'
    for var in GPUErrors GPUCoreTemp
    do
        DISPLAY=:0 waitmax 2 nvidia-settings -t -q $var | sed "s/^/$var: /"
    done
fi

if [ -e /proc/drbd ]; then
  echo '<<<drbd>>>'
  cat /proc/drbd
fi

# Status of CUPS printer queues
if type lpstat > /dev/null 2>&1; then
    if pgrep cups > /dev/null 2>&1; then
        # first define a function to check cups
        function cups_queues () {
            CPRINTCONF=/etc/cups/printers.conf
            if [ -r "$CPRINTCONF" ] ; then
                LOCAL_PRINTERS=$(grep -E "<(Default)?Printer .*>" $CPRINTCONF | awk '{print $2}' | sed -e 's/>//')
                lpstat -p | while read LINE
                do
                    PRINTER=$(echo $LINE | awk '{print $2}')
                    if echo "$LOCAL_PRINTERS" | grep -q "$PRINTER"; then
                        echo $LINE
                    fi
                done
                echo '---'
                lpstat -o | while read LINE
                do
                    PRINTER=${LINE%%-*}
                    if echo $LOCAL_PRINTERS | grep -q $PRINTER; then
                        echo $LINE
                    fi
                done
            else
                lpstat -p
                echo '---'
                lpstat -o | sort
                fi
        }
        # Make cups_queues available for subshell
        export -f cups_queues
        # Use cups_queues function with run_cached and cache time of 5 mins
        run_cached -s cups_queues 300 "cups_queues"
    fi
fi

# Heartbeat monitoring
# Different handling for heartbeat clusters with and without CRM
# for the resource state
if [ -S /var/run/heartbeat/crm/cib_ro -o -S /var/run/crm/cib_ro ] || pgrep crmd > /dev/null 2>&1; then
  echo '<<<heartbeat_crm>>>'
  crm_mon -1 -r | grep -v ^$ | sed 's/^ //; /^\sResource Group:/,$ s/^\s//; s/^\s/_/g'
fi
if type cl_status > /dev/null 2>&1; then
  echo '<<<heartbeat_rscstatus>>>'
  cl_status rscstatus

  echo '<<<heartbeat_nodes>>>'
  for NODE in $(cl_status listnodes); do
    if [ $NODE != $(echo $HOSTNAME | tr 'A-Z' 'a-z') ]; then
      STATUS=$(cl_status nodestatus $NODE)
      echo -n "$NODE $STATUS"
      for LINK in $(cl_status listhblinks $NODE 2>/dev/null); do
        echo -n " $LINK $(cl_status hblinkstatus $NODE $LINK)"
      done
      echo
    fi
  done
fi

# Postfix mailqueue monitoring
#
# we determine the number of mails and their size in several postfix mail queues
if type postconf >/dev/null ; then
    echo '<<<postfix_mailq>>>'
    postfix_queue_dir=$(postconf -h queue_directory)

    for queue in deferred active
    do
        count=$(find $postfix_queue_dir/$queue -type f | wc -l)
        size=$(du -s $postfix_queue_dir/$queue | awk '{print $1 }')
        echo "QUEUE_${queue} $size $count"
    done
elif [ -x /usr/sbin/ssmtp ] ; then
    echo '<<<postfix_mailq>>>'
    mailq 2>&1 | sed 's/^[^:]*: \(.*\)/\1/' | tail -n 6
fi

# Check status of qmail mailqueue
if type qmail-qstat >/dev/null
then
   echo "<<<qmail_stats>>>"
   qmail-qstat
fi

# Check status of OMD sites and Check_MK Notification spooler
if type omd >/dev/null
then
    run_cached -s omd_status 60 "omd status --bare --auto || true"
    echo '<<<mknotifyd:sep(0)>>>'
    for statefile in /omd/sites/*/var/log/mknotifyd.state ; do
	if [ -e "$statefile" ] ; then
	    site=${statefile%/var/log*}
	    site=${site#/omd/sites/}
	    echo "[$site]"
	    grep -v '^#' < $statefile
        fi
    done

    echo '<<<omd_apache:sep(124)>>>'
    for statsfile in /omd/sites/*/var/log/apache/stats; do
	if [ -e "$statsfile" ] ; then
	    site=${statsfile%/var/log*}
	    site=${site#/omd/sites/}
	    echo "[$site]"
            cat $statsfile
            > $statsfile
        fi
    done
fi

# Status of Check_MK Notification Spooler



# Welcome the ZFS check on Linux
# We do not endorse running ZFS on linux if your vendor doesnt support it ;)
# check zpool status
if type zpool >/dev/null; then
   echo "<<<zpool_status>>>"
   zpool status -x
fi


# Fileinfo-Check: put patterns for files into /etc/check_mk/fileinfo.cfg
if [ -r "$MK_CONFDIR/fileinfo.cfg" ] ; then
    echo '<<<fileinfo:sep(124)>>>'
    date +%s
    for line in $(cat "$MK_CONFDIR/fileinfo.cfg")
    do
        stat -c "%n|%s|%Y" $line 2>/dev/null

        if [ $? -ne 0 ]; then
            echo "$line|missing|$(date +%s)"
        fi
    done
fi

# Get stats about OMD monitoring cores running on this machine.
# Since cd is a shell builtin the check does not affect the performance
# on non-OMD machines.
if cd /omd/sites
then
    echo '<<<livestatus_status:sep(59)>>>'
    for site in *
    do
        if [ -S "/omd/sites/$site/tmp/run/live" ] ; then
            echo "[$site]"
            echo -e "GET status" | waitmax 3 /omd/sites/$site/bin/unixcat /omd/sites/$site/tmp/run/live
        fi
    done
fi

# Get statistics about monitored jobs. Below the job directory there
# is a sub directory per user that ran a job. That directory must be
# owned by the user so that a symlink or hardlink attack for reading
# arbitrary files can be avoided.
if pushd $MK_VARDIR/job >/dev/null; then
    echo '<<<job>>>'
    for username in *
    do
        if [ -d "$username" ] && cd "$username" ; then
            su "$username" -c "head -n -0 -v *"
            cd ..
        fi
    done
    popd > /dev/null
fi

# Gather thermal information provided e.g. by acpi
# At the moment only supporting thermal sensors
if ls /sys/class/thermal/thermal_zone* >/dev/null 2>&1; then
    echo '<<<lnx_thermal>>>'
    for F in /sys/class/thermal/thermal_zone*; do
        echo -n "${F##*/} "
        if [ ! -e $F/mode ] ; then echo -n "- " ; fi
        cat $F/{mode,type,temp,trip_point_*} | tr \\n " "
        echo
    done
fi

# Libelle Business Shadow
if type trd >/dev/null; then
   echo "<<<libelle_business_shadow:sep(58)>>>"
   trd -s
fi

# MK's Remote Plugin Executor
if [ -e "$MK_CONFDIR/mrpe.cfg" ]
then
    echo '<<<mrpe>>>'
    grep -Ev '^[[:space:]]*($|#)' "$MK_CONFDIR/mrpe.cfg" | \
    while read descr cmdline
    do
        PLUGIN=${cmdline%% *}
        OUTPUT=$(eval "$cmdline")
        echo -n "(${PLUGIN##*/}) $descr $? $OUTPUT" | tr \\n \\1
        echo
    done
fi

# MK's runas Executor
if [ -e "$MK_CONFDIR/runas.cfg" ]
then
    grep -Ev '^[[:space:]]*($|#)' "$MK_CONFDIR/runas.cfg" | \
    while read type user include
    do
        if [ -d $include -o \( "$type" == "mrpe" -a -f $include \) ] ; then
            PREFIX=""
            if [ "$user" != "-" ] ; then
                PREFIX="su $user -c "
            fi

            # mrpe includes
            if [ "$type" == "mrpe" ] ; then
                echo "<<<mrpe>>>"
                grep -Ev '^[[:space:]]*($|#)' "$include" | \
                while read descr cmdline
                do
                    PLUGIN=${cmdline%% *}

                    if [ -n "$PREFIX" ] ; then
                        cmdline="$PREFIX\"$cmdline\""
                    fi

                    OUTPUT=$(eval "$cmdline")
                    echo -n "(${PLUGIN##*/}) $descr $? $OUTPUT" | tr \\n \\1
                    echo
                done

            # local and plugin includes
            elif [ "$type" == "local" -o "$type" == "plugin" ] ; then
                if [ "$type" == "local" ] ; then
                    echo "<<<local>>>"
                fi

                find $include -executable -type f | \
                while read filename
                do
                    if [ -n "$PREFIX" ] ; then
                        cmdline="$PREFIX\"$filename\""
                    else
                        cmdline=$filename
                    fi

                    $cmdline
                done
            fi
        fi
    done
fi

# Local checks
echo '<<<local>>>'
if cd $LOCALDIR ; then
    for skript in $(ls) ; do
        if [ -f "$skript" -a -x "$skript" ] ; then
            ./$skript
        fi
    done
    # Call some plugins only every X'th second
    for skript in [1-9]*/* ; do
        if [ -x "$skript" ] ; then
            run_cached local_${skript//\//\\} ${skript%/*} "$skript"
        fi
    done
fi

# Plugins
if cd $PLUGINSDIR ; then
    for skript in $(ls) ; do
        if [ -f "$skript" -a -x "$skript" ] ; then
            ./$skript
        fi
    done
    # Call some plugins only every Xth second
    for skript in [1-9]*/* ; do
        if [ -x "$skript" ] ; then
            run_cached plugins_${skript//\//\\} ${skript%/*} "$skript"
        fi
    done
fi

# Agent output snippets created by cronjobs, etc.
if [ -d "$SPOOLDIR" ]
then
    pushd "$SPOOLDIR" > /dev/null
    now=$(date +%s)

    for file in *
    do
        # output every file in this directory. If the file is prefixed
        # with a number, then that number is the maximum age of the
        # file in seconds. If the file is older than that, it is ignored.
        maxage=""
        part="$file"

        # Each away all digits from the front of the filename and
        # collect them in the variable maxage.
        while [ "${part/#[0-9]/}" != "$part" ]
        do
            maxage=$maxage${part:0:1}
            part=${part:1}
        done

        # If there is at least one digit, than we honor that.
        if [ "$maxage" ] ; then
            mtime=$(stat -c %Y "$file")
            if [ $((now - mtime)) -gt $maxage ] ; then
                continue
            fi
        fi

        # Output the file
        cat "$file"
    done
    popd > /dev/null
fi
