#!/bin/bash
# This script is designed to handle mirror syncing tasks from external mirrors.
# Each mirror is handled within a module which can be configured via the configuration file /etc/mirror-sync.conf,
# or another file named by the MIRROR_SYNC_CONF environment variable.
PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$HOME/.local/bin:$HOME/bin"

# Variables for trace generation.
PROGRAM="mirror-sync"
VERSION="20260727"
TRACEHOST=$(hostname -f)
mirror_hostname=$(hostname -f)
DATE_STARTED=$(LC_ALL=POSIX LANG=POSIX date -u -R)
INFO_TRIGGER=cron
if [[ $SUDO_USER ]]; then
    INFO_TRIGGER=ssh
fi

# Pid file temporary path.
PIDPATH="/tmp"
PIDSUFFIX="-mirror-sync.pid"
PIDFILE="" # To be filled by acquire_lock().

# Log file.
LOGPATH="/var/log/mirror-sync"
LOGFILE="" # To be filled by acquire_lock().
ERRORFILE="" # To be filled by acquire_lock().
error_count=0
max_errors=3
tmpDirBase="$HOME/tmp"
sync_timeout="timeout 1d"
# Do not check upstream unless it was updated in the last 5 hours.
upstream_max_age=18000
# Update anyway if last check was more than 24 hours ago.
upstream_timestamp_min=86400
# Publish a project trace file describing this mirror after each successful
# sync. Every sync method honors this, and an individual module can override it
# with ${MODULE}_save_trace.
save_trace="true"

# quick-fedora-mirror tool config.
QFM_GIT="https://pagure.io/quick-fedora-mirror.git"
QFM_PATH="$HOME/quick-fedora-mirror"
QFM_BIN="$QFM_PATH/quick-fedora-mirror"

# For installing Jigdo
JIGDO_SOURCE_URL="http://deb.debian.org/debian/pool/main/j/jigdo/jigdo_0.8.0.orig.tar.xz"
JIGDO_FILE_BIN="$HOME/bin/jigdo-file"
JIGDO_MIRROR_BIN="$HOME/bin/jigdo-mirror"
jigdoConf="$HOME/etc/jigdo/jigdo-mirror.conf"

# Path to s5cmd bin.
S5CMD_BIN="$HOME/bin/s5cmd"

# Path to repo-sync bin.
REPO_SYNC_BIN="$HOME/bin/repo-sync"

# Prevent run as root.
if (( EUID == 0 )); then
  echo "Do not mirror as root."
  exit 1
fi

# Load the required configuration file or quit. The default is where a system
# installation keeps it; MIRROR_SYNC_CONF names another one, so the script can
# be pointed at a configuration of its own for testing or for a mirror run out
# of a home directory.
CONFIG_FILE="${MIRROR_SYNC_CONF:-/etc/mirror-sync.conf}"
if [[ -f $CONFIG_FILE ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "No configuration file at '${CONFIG_FILE}', please setup a proper configuration file."
    exit 1
fi

# Files to remove if a sync is interrupted (Archive-Update-in-Progress markers,
# temporary stage logs, ...). The sync functions append to this list as they
# create such files so that a Ctrl-C does not leave stale state behind.
cleanup_files=()

# Handle Ctrl-C (SIGINT) and termination (SIGTERM). When run from a terminal
# the signal is delivered to the whole process group, so the rsync/aws/git/...
# process that is currently syncing receives it and stops on its own. This
# handler then cleans up after it: it removes the in-progress markers, temporary
# logs and the lock file, and exits without counting the interruption as a sync
# failure (so it does not inflate the error count or trigger error emails).
handle_interrupt() {
    # Ignore any further interrupts while we clean up.
    trap '' INT TERM

    echo
    echo "Interrupt received, stopping sync and cleaning up..."

    # Remove any files registered for cleanup by the running module.
    local _f
    for _f in "${cleanup_files[@]}"; do
        [[ $_f ]] && rm -f "$_f"
    done

    # Remove the pid lock file for this module so a later run is not blocked.
    [[ $PIDFILE ]] && rm -f "$PIDFILE"

    echo "Sync interrupted."
    exit 130
}
trap handle_interrupt INT TERM

# Print the help for this command. An exit status may be given so the paths
# that print help because of a mistake (an unknown module or option) exit
# non-zero, letting cron or a calling script tell a misconfiguration apart from
# a run that simply asked for help.
print_help() {
    echo "Mirror Sync (${VERSION})"
    echo
    echo "Usage:"
    echo "$0 [--help|--update-support-utilities|--version] {module} [--force]"
    echo
    echo "Available modules:"
    for MODULE in ${MODULES:?}; do
        echo "$MODULE"
    done
    exit "${1:-0}"
}

# Send email to admins about error.
mail_error() {
    if [[ -z $MAILTO ]]; then
        echo "MAILTO is undefined."
        return
    fi
    {
        cat <<EOF
Subject: ${PROGRAM} Error
To: ${MAILTO}
Auto-Submitted: auto-generated
MIME-Version: 1.0
Content-Type: text/plain

Host: $(hostname -f)
Module: ${MODULE}
Logfile: ${LOGFILE}

$*
EOF
    } | sendmail -i -t
}

#region Tool installation

# Installs quick-fedora-mirror and updates.
quick_fedora_mirror_install() {
    if ! [[ -f $QFM_BIN ]]; then
        echo "quick-fedora-mirror is not on this system, attempting to get it"
        [[ -e $QFM_PATH ]] && rm -Rf "$QFM_PATH"
        git clone "$QFM_GIT" "$QFM_PATH"
        if ! [[ -f $QFM_BIN ]]; then
            echo "Failed to get quick-fedora-mirror!"
            exit 1
        fi
    fi
    (
        if [[ $1 == "-u" ]]; then
            if ! cd "$QFM_PATH"; then
                echo "Unable to enter QFM path."
                exit 1
            fi
            if ! git pull; then
                echo "Unable to update QFM."
                exit 1
            fi
        fi
    ) || return 1
}

# Installs jigdo image tool.
jigdo_install() {
    # Only install if not already installed or update requested.
    if [[ $1 == "-u" ]] || ! [[ -e $JIGDO_FILE_BIN ]]; then
        # Make sure we're in the home dir and bin exists.
        if ! cd "$HOME"; then
            echo "Unable to access home dir."
            exit 1
        fi
        if [[ ! -d bin ]]; then
            mkdir -p bin
        fi

        # Download jigdo source code.
        if ! wget "$JIGDO_SOURCE_URL" -O jigdo.tar.xz; then
            echo "Unable to download jigdo utility."
            exit 1
        fi

        # Extract jigdo.
        if ! tar -xvf jigdo.tar.xz; then
            echo "Unable to unarchive jigdo."
            exit 1
        fi
        rm -f jigdo.tar.xz
        (
            if ! cd jigdo-*/; then
                echo "Unable to enter extracted archive."
                exit 1
            fi
            cat > jigdo.patch <<'EOF'
--- src/util/sha256sum.hh	2019-11-19 10:43:22.000000000 -0500
+++ src-fix/util/sha256sum.hh	2023-04-19 16:33:40.840831304 -0400
@@ -27,6 +27,7 @@
 #include <cstring>
 #include <iosfwd>
 #include <string>
+#include <stdint.h>

 #include <bstream.hh>
 #include <debug.hh>
EOF
            patch -u src/util/sha256sum.hh -i jigdo.patch
            if ! ./configure --prefix="$HOME"; then
                echo "Unable to configure jigdo."
                exit 1
            fi

            # Build fails first few times due to docs, but clears after a few builds.
            if ! make; then
                if ! make; then
                    make
                fi
            fi
            make install
        ) || return 1
    fi
}

# Installs s5cmd for aws syncing.
s5cmd_install() {
    # Only install if not installed or update requested.
    if ! [[ -f $S5CMD_BIN ]] || [[ $1 == "-u" ]]; then
        # Make sure we're in the home dir and the bin dir exists.
        if ! cd "$HOME"; then
            echo "Unable to access home dir."
            exit 1
        fi
        if [[ ! -d bin ]]; then
            mkdir -p bin
        fi

        # Get the latest download URL from github.
        download_url=$(curl -s https://api.github.com/repos/peak/s5cmd/releases/latest | jq '.assets[] | select(.browser_download_url | test("Linux-64bit.tar.gz")?) | .browser_download_url' -r)
        if [[ -z $download_url ]]; then
            echo "Unable to get download url for s5cmd."
            exit 1
        fi

        # Download s5cmd
        if ! wget "$download_url" -O s5cmd.tar.gz; then
            echo "Unable to download s5cmd."
            exit 1
        fi

        # Extract and check that s5cmd extracted correctly.
        if ! tar -xf s5cmd.tar.gz; then
            echo "Unable to extract s5cmd."
            exit 1
        fi
        if ! [[ -f s5cmd ]]; then
            echo "Unable to extract s5cmd."
            exit 1
        fi

        # Remove the tar.gz file.
        rm -f s5cmd.tar.gz

        # Move s5cmd to the bin path.
        mv s5cmd "$S5CMD_BIN"
    fi
}

# Installs repo-sync for package repository syncing.
repo_sync_install() {
    # Only install if not installed or update requested.
    if ! [[ -f $REPO_SYNC_BIN ]] || [[ $1 == "-u" ]]; then
        # Make sure we're in the home dir and the bin dir exists.
        if ! cd "$HOME"; then
            echo "Unable to access home dir."
            exit 1
        fi
        if [[ ! -d bin ]]; then
            mkdir -p bin
        fi

        # Releases are published per architecture, so map this machine's
        # architecture onto the name used in the release asset.
        machine=$(uname -m)
        case "$machine" in
            x86_64|amd64) release_arch="amd64" ;;
            i386|i486|i586|i686) release_arch="386" ;;
            aarch64|arm64) release_arch="arm64" ;;
            armv6*|armv7*|armhf|arm) release_arch="armv6" ;;
            ppc64le) release_arch="ppc64le" ;;
            *)
                echo "Unsupported architecture '${machine}' for repo-sync."
                exit 1
            ;;
        esac

        # Get the latest download URL from github.
        download_url=$(curl -s https://api.github.com/repos/grmrgecko/repo-sync/releases/latest | jq --arg suffix "_linux_${release_arch}.tar.gz" '.assets[] | select(.name | endswith($suffix)) | .browser_download_url' -r)
        if [[ -z $download_url ]]; then
            echo "Unable to get download url for repo-sync."
            exit 1
        fi

        # Download repo-sync
        if ! wget "$download_url" -O repo-sync.tar.gz; then
            echo "Unable to download repo-sync."
            exit 1
        fi

        # Extract just the binary. The archive also ships a LICENSE and
        # README.md, which would clobber files in the home directory.
        if ! tar -xf repo-sync.tar.gz repo-sync; then
            echo "Unable to extract repo-sync."
            exit 1
        fi
        if ! [[ -f repo-sync ]]; then
            echo "Unable to extract repo-sync."
            exit 1
        fi

        # Remove the tar.gz file.
        rm -f repo-sync.tar.gz

        # Move repo-sync to the bin path.
        chmod +x repo-sync
        mv repo-sync "$REPO_SYNC_BIN"
    fi
}

# Updates the mirror support utilties on server with upstream.
update_support_utilities() {
    quick_fedora_mirror_install -u
    jigdo_install -u
    s5cmd_install -u
    repo_sync_install -u
}

# Builds iso images from jigdo files.
jigdo_hook() {
    # Ensure jigdo is installed.
    jigdo_install

    # Determine the current version of Debian.
    currentVersion=$(ls -l "${repo}/current")
    currentVersion="${currentVersion##* -> }"
    versionDir="$(realpath "$repo")/${currentVersion}"

    # For each architecture, run jigdo to build iso files.
    for a in "$versionDir"/*/; do
        arch=$(basename "$a")

        # Determine what releases are needed for this architecture.
        sets=$(cat "${repo}/project/build/${currentVersion}/${arch}")

        # For each set, build iso files.
        for s in $sets; do
            # Determine the jigdo and iso dir for this set.
            jigdoDir="${repo}/${currentVersion}/${arch}/jigdo-${s}"
            imageDir="${repo}/${currentVersion}/${arch}/iso-${s}"

            # Create iso dir if not already made.
            if [[ ! -d $imageDir ]]; then
                mkdir -p "$imageDir"
            fi

            # Copy SUM files from the jigdo dir over to the new ISO dir.
            # Sums are now SHA256SUMS and SHA512SUMS.
            cp -a "${jigdoDir}"/*SUMS* "${imageDir}/"

            # Build jigdo configuration.
            cat >"${jigdoConf:?}.${arch}.${s}" <<EOF
LOGROTATE=14
jigdoFile="$JIGDO_FILE_BIN --cache=\$tmpDir/jigdo-cache.db --cache-expiry=1w --report=noprogress --no-check-files"
debianMirror="file:${jigdo_pkg_repo:-}"
nonusMirror="file:/tmp"
include='.'  # include all files,
exclude='^$' # then exclude none
jigdoDir=${jigdoDir}
imageDir=${imageDir}
tmpDir=${tmpDirBase:?}/${arch}.${s}
#logfile=${LOGPATH}/${MODULE}-${arch}.${s}.log
EOF

            # Run jigdo.
            echo "Running jigdo for ${arch}.${s}"
            $JIGDO_MIRROR_BIN "${jigdoConf:?}.${arch}.${s}"
        done
    done
}

# Sum a "Field: count" statistic across every run recorded in a log. Both
# rsync's --stats and repo-sync's run summary report in this form, and one log
# can hold several runs, as quick-fedora-mirror calls rsync once per module. A
# log that recorded no run at all counts as none.
sum_log_stat() {
    [[ -f $2 ]] || { echo 0; return; }
    awk -F': ' -v field="$1" '
        $1==field {split($2, count, " "); total+=count[1]}
        END {print total+0}
    ' "$2" 2>/dev/null
}

# Count what an rsync run changed, from the itemized change lines in one or
# more of its logs. rsync prints one line per item it acts on: "*deleting" for
# something it removed, and otherwise an eleven character summary of the change
# such as ">f+++++++++", followed by the item's path. quick-fedora-mirror
# formats those lines with a leading marker, which is skipped over.
#
# Only content counts. Directories are left out, as an unchanged directory is
# still restamped whenever something inside it changes, and so are the trace
# files this script maintains, which it rewrites after every sync no matter
# what upstream did. The two counts are printed as "transferred deleted".
count_rsync_changes() {
    local _logs=() _log
    for _log in "$@"; do
        [[ -f $_log ]] && _logs+=("$_log")
    done
    if (( ${#_logs[@]} == 0 )); then
        echo "0 0"
        return
    fi
    awk '
        {
            field = ($1 == "@") ? 2 : 1
            summary = $field
            name = $(field+1)
            if (name ~ /(^|\/)project\/trace\//) next
            if (summary == "*deleting") {
                if (name !~ /\/$/) deleted++
                next
            }
            if (summary ~ /^[<>ch.][fLDS]/) transferred++
        }
        END {print transferred+0, deleted+0}
    ' "${_logs[@]}"
}

# Count how many times a message appears in a log. Sync tools that show
# progress rewrite the current line with a carriage return rather than ending
# it, so several messages can end up sharing one line; occurrences are counted
# rather than lines, and a message is only recognized where a line or a
# carriage return puts it at the start of the output.
count_sync_events() {
    local _log=$1 _message=$2 _cr=$'\r'
    [[ -f $_log ]] || { echo 0; return; }
    grep -oE "(^|${_cr})${_message}" "$_log" 2>/dev/null | wc -l
}

# Pull a field from a trace file or rsync stats.
extract_trace_field() {
    value=$(awk -F': ' "\$1==\"$1\" {print \$2; exit}" "$2" 2>/dev/null)
    [[ $value ]] || return 1
    echo "$value"
}

# Build content for a trace file that contains info on a repository.
build_trace_content() {
    LC_ALL=POSIX LANG=POSIX date -u
    rfc822date=$(LC_ALL=POSIX LANG=POSIX date -u -R)
    echo "Date: ${rfc822date}"
    echo "Date-Started: ${DATE_STARTED}"

    if [[ -e $TRACE_MASTER_FILE ]]; then
        echo "Archive serial: $(extract_trace_field 'Archive serial' "$TRACE_MASTER_FILE" || echo unknown )"
    fi

    echo "Used ${PROGRAM} version: ${VERSION}"
    echo "Creator: ${PROGRAM} ${VERSION}"
    echo "Running on host: ${TRACEHOST}"

    if [[ ${INFO_MAINTAINER:-} ]]; then
        echo "Maintainer: ${INFO_MAINTAINER}"
    fi
    if [[ ${INFO_SPONSOR:-} ]]; then
        echo "Sponsor: ${INFO_SPONSOR}"
    fi
    if [[ ${INFO_COUNTRY:-} ]]; then
        echo "Country: ${INFO_COUNTRY}"
    fi
    if [[ ${INFO_LOCATION:-} ]]; then
        echo "Location: ${INFO_LOCATION}"
    fi
    if [[ ${INFO_THROUGHPUT:-} ]]; then
        echo "Throughput: ${INFO_THROUGHPUT}"
    fi
    if [[ ${INFO_TRIGGER:-} ]]; then
        echo "Trigger: ${INFO_TRIGGER}"
    fi

    # Depending on repo type, find architectures supported.
    ARCH_REGEX='(source|SRPMS|amd64|mips64el|mipsel|i386|x86_64|aarch64|ppc64le|ppc64el|s390x|armhf)'
    if [[ $repo_type == "deb" ]]; then
        ARCH=$(find "${repo}/dists" \( -name 'Packages.*' -o -name 'Sources.*' \) 2>/dev/null |
            sed -Ene 's#.*/binary-([^/]+)/Packages.*#\1#p; s#.*/(source)/Sources.*#\1#p' |
            sort -u | tr '\n' ' ')
        if [[ $ARCH ]]; then
            echo "Architectures: ${ARCH}"
        fi
    elif [[ $repo_type == "rpm" ]]; then
        ARCH=$(find "$repo" -name 'repomd.xml' 2>/dev/null |
            grep -Po "$ARCH_REGEX" |
            sort -u | tr '\n' ' ')
        if [[ $ARCH ]]; then
            echo "Architectures: ${ARCH}"
        fi
    elif [[ $repo_type == "iso" ]]; then
        ARCH=$(find "$repo" -name '*.iso' 2>/dev/null |
            grep -Po "$ARCH_REGEX" |
            sort -u | tr '\n' ' ')
        if [[ $ARCH ]]; then
            echo "Architectures: ${ARCH}"
        fi
    elif [[ $repo_type == "source" ]]; then
        echo "Architectures: source"
    fi
    echo "Architectures-Configuration: ${arch_configurations:-ALL}"

    echo "Upstream-mirror: ${RSYNC_HOST:-unknown}"

    # Total bytes synced per rsync stage.
    total=0
    if [[ -f $LOGFILE_SYNC ]]; then
        all_bytes=$(sed -Ene 's/(^|.* )sent ([0-9]+) bytes  received ([0-9]+) bytes.*/\3/p' "$LOGFILE_SYNC")
        for bytes in $all_bytes; do
            total=$(( total + bytes ))
        done
    elif [[ -f $LOGFILE_STAGE1 ]]; then
        all_bytes=$(sed -Ene 's/(^|.* )sent ([0-9]+) bytes  received ([0-9]+) bytes.*/\3/p' "$LOGFILE_STAGE1")
        for bytes in $all_bytes; do
            total=$(( total + bytes ))
        done
    fi
    if [[ -f $LOGFILE_STAGE2 ]]; then
        all_bytes=$(sed -Ene 's/(^|.* )sent ([0-9]+) bytes  received ([0-9]+) bytes.*/\3/p' "$LOGFILE_STAGE2")
        for bytes in $all_bytes; do
            total=$(( total + bytes ))
        done
    fi
    if (( total > 0 )); then
        echo "Total bytes received in rsync: ${total}"
    fi

    # Calculate time per rsync stage and print both stages if both were started.
    total_time=0
    if [[ $sync_started ]]; then
        STATS_TOTAL_RSYNC_TIME1=$(( sync_ended - sync_started  ))
        total_time=$STATS_TOTAL_RSYNC_TIME1
    elif [[ $stage1_started ]]; then
        STATS_TOTAL_RSYNC_TIME1=$(( stage1_ended - stage1_started  ))
        total_time=$STATS_TOTAL_RSYNC_TIME1
    fi
    if [[ $stage2_started ]]; then
        STATS_TOTAL_RSYNC_TIME2=$(( stage2_ended - stage2_started  ))
        total_time=$(( total_time + STATS_TOTAL_RSYNC_TIME2 ))
        echo "Total time spent in stage1 rsync: ${STATS_TOTAL_RSYNC_TIME1}"
        echo "Total time spent in stage2 rsync: ${STATS_TOTAL_RSYNC_TIME2}"
    fi
    echo "Total time spent in rsync: ${total_time}"
    # Only the rsync based methods report a byte count, so without one there is
    # no rate to state; printing 0 B/s would claim the sync moved nothing.
    if (( total > 0 && total_time != 0 )); then
        rate=$(( total / total_time ))
        echo "Average rate: ${rate} B/s"
    fi
}

# Reduce an upstream location to the host it names, for the trace's
# Upstream-mirror field. Sources come in several shapes across the sync
# methods: rsync URLs and rsync daemon syntax (host::module), http(s) and ftp
# URLs, s3 bucket URLs, and space separated lists of URLs. Only the first entry
# of a list is reported, as the trace names a single upstream.
upstream_host() {
    local _host="${1%% *}"    # First entry of a space separated list.
    _host="${_host#*://}"     # Drop any scheme.
    _host="${_host#*@}"       # Drop any credentials.
    _host="${_host%%/*}"      # Drop the path.
    _host="${_host%%:*}"      # Drop the port, or the rsync daemon module.
    echo "$_host"
}

# For modules that are repositories (with RPM, DEB, ISOs, or source code),
# build a project trace file with information about the repo.
save_trace_file() {
    # Trace file/dir paths.
    TRACE_DIR="${repo}/project/trace"
    mkdir -p "$TRACE_DIR"
    TRACE_FILE="${TRACE_DIR}/${mirror_hostname:?}"
    TRACE_MASTER_FILE="${TRACE_DIR}/master"
    TRACE_HIERARCHY="${TRACE_DIR}/_hierarchy"

    # Parse the upstream host. Modules define their upstream differently, so a
    # method may set trace_upstream to whatever names its source; the rsync
    # based methods leave it unset and their source is used.
    RSYNC_HOST=$(upstream_host "${trace_upstream:-${source:-}}")

    # Build trace and save to file.
    build_trace_content > "${TRACE_FILE}.new"
    mv "${TRACE_FILE}.new" "$TRACE_FILE"

    # Build the hierarchy file, which lists every mirror the content passed
    # through. The upstream entries come from the copy saved on the previous
    # run; this mirror's own entry is dropped from that base before a fresh one
    # is appended, so repeated syncs replace the entry rather than stacking a
    # new copy of it on every run.
    local _self _name _rest
    _self=$(basename "$TRACE_FILE")
    {
        if [[ -e "${TRACE_HIERARCHY}.mirror" ]]; then
            while read -r _name _rest; do
                [[ $_name ]] || continue
                [[ $_name == "$_self" ]] && continue
                echo "$_name $_rest"
            done < "${TRACE_HIERARCHY}.mirror"
        fi
        echo "${_self} $mirror_hostname $TRACEHOST ${RSYNC_HOST:-unknown}"
    } > "${TRACE_HIERARCHY}.new"
    mv "${TRACE_HIERARCHY}.new" "$TRACE_HIERARCHY"
    cp "$TRACE_HIERARCHY" "${TRACE_HIERARCHY}.mirror"

    # Output all traces to _traces file. Disabling shell check because the glob in this case is used right.
    # shellcheck disable=SC2035
    (cd "$TRACE_DIR" && find * -type f \! -name "_*") > "$TRACE_DIR/_traces"
}

# Acquire a sync lock for this command.
acquire_lock() {
    MODULE=$1
    # Pid file for this module sync.
    PIDFILE="${PIDPATH}/${MODULE}${PIDSUFFIX}"
    LOGFILE="${LOGPATH}/${MODULE}.log"
    ERRORFILE="${LOGPATH}/${MODULE}.error_count"
    if [[ -e $ERRORFILE ]]; then
        error_count=$(cat "$ERRORFILE")
    fi

    # Redirect stdout to both stdout and log file.
    mkdir -p "$LOGPATH"
    exec 1> >(tee -a "$LOGFILE")
    # Redirect errors to stdout so they also are logged.
    exec 2>&1

    # Check existing pid file.
    if [[ -f $PIDFILE ]]; then
        PID=$(cat "$PIDFILE")
        # Prevent double locks.
        if [[ $PID == "$BASHPID" ]]; then
            echo "Double lock detected."
            exit 1
        fi

        # Check if PID is active.
        if ps -p "$PID" >/dev/null; then
            echo "A sync is already in progress for ${MODULE} with pid ${PID}."
            exit 1
        fi
    fi

    # Create a new pid file for this process.
    echo "$BASHPID" >"$PIDFILE"

    # On exit, remove pid file.
    trap 'rm -f "$PIDFILE"' EXIT
}

log_start_header() {
    echo
    echo "=========================================="
    echo "Starting execution: $(date +"%Y-%m-%d %T")"
    echo "=========================================="
    echo
}

log_end_header() {
    echo
    echo "=========================================="
    echo "Execution complete: $(date +"%Y-%m-%d %T")"
    echo "=========================================="
}

# Build dsum totals files if defined.
rebuild_dusum_totals() {
    # Rebuild killo byte total.
    if [[ $dusum_kbytes_total_file ]]; then
        {
            date
            totalKBytes=0
            for _DUSUM_MODULE in ${MODULES:?}; do
                eval _dusum="\${${_DUSUM_MODULE}_dusum:-}"
                if [[ -n $_dusum ]] && [[ -f $_dusum ]]; then
                    while read -r size path; do
                        if [[ -n $size ]]; then
                            totalKBytes=$((totalKBytes+size))
                            printf "%-12s %s\n" "$size" "$path"
                        fi
                    done < "$_dusum"
                fi
            done
            printf "%-12s %s\n" "$totalKBytes" "total"
        } > "$dusum_kbytes_total_file"
    fi

    # Rebuild human readable total.
    if [[ $dusum_human_readable_total_file ]]; then
        {
            date
            totalKBytes=0
            for _DUSUM_MODULE in ${MODULES:?}; do
                eval _dusum="\${${_DUSUM_MODULE}_dusum:-}"
                if [[ -n $_dusum ]] && [[ -f $_dusum ]]; then
                    while read -r size path; do
                        if [[ -n $size ]]; then
                            totalKBytes=$((totalKBytes+size))
                            printf "%-5s %s\n" "$(echo "$size*1024" | bc | numfmt --to=iec)" "$path"
                        fi
                    done < "$_dusum"
                fi
            done
            printf "%-5s %s\n" "$(echo "$totalKBytes*1024" | bc | numfmt --to=iec)" "total"
        } > "$dusum_human_readable_total_file"
    fi
}

# Counts describing what a sync changed. Every sync method publishes these
# before it runs any hook, so a hook can stay idle on a run that found nothing
# new:
#
#   example_post_successful_sync_hook='[[ $SYNC_CHANGED ]] && do_something'
#
# They are exported so a hook that calls out to a script sees them as well.
# What counts as a file differs between the sync methods, and a few of them can
# only report what their tool chose to print, so the counts are each method's
# best statement of what it moved rather than a number to compare across
# methods. SYNC_CHANGED is the dependable part: it is set whenever a method saw
# any change at all.
reset_sync_counts() {
    SYNC_FILES_TRANSFERRED=0
    SYNC_FILES_DELETED=0
    SYNC_FILES_CHANGED=0
    SYNC_REFS_UPDATED=0
    SYNC_CHANGED=""
    export SYNC_FILES_TRANSFERRED SYNC_FILES_DELETED SYNC_FILES_CHANGED
    export SYNC_REFS_UPDATED SYNC_CHANGED
}

# Publish what a sync changed, and report it to the log. A third argument
# states whether the mirror changed for a method whose changes are not measured
# in files (git counts refs); without one, any counted file is a change.
set_sync_counts() {
    SYNC_FILES_TRANSFERRED=${1:-0}
    SYNC_FILES_DELETED=${2:-0}
    SYNC_FILES_CHANGED=$((SYNC_FILES_TRANSFERRED+SYNC_FILES_DELETED))
    if (( $# >= 3 )); then
        SYNC_CHANGED=$3
    elif (( SYNC_FILES_CHANGED > 0 )); then
        SYNC_CHANGED="true"
    else
        SYNC_CHANGED=""
    fi
    echo "Files changed: ${SYNC_FILES_CHANGED} (${SYNC_FILES_TRANSFERRED} transferred, ${SYNC_FILES_DELETED} deleted)"
}

# Items to do post an successful sync.
post_successful_sync() {
    # Save timestamp of last sync.
    if [[ $timestamp ]]; then
        date +%s > "$timestamp"
    fi
    
    # Remove error count file if existing.
    if [[ -e $ERRORFILE ]]; then
        rm -f "$ERRORFILE"
    fi

    # Update repo directory sum.
    if [[ $dusum ]]; then
        # Get a sum, store to variable first to avoid having an empty file when another cron finishes.
        SUM=$({
            # If modules are defined, sum each module directory.
            if [[ $modules ]]; then
                for module in $modules; do
                    du -s "${docroot%/}/$(module_dir "$module")/"
                done
            else
                # Standard repo sum.
                du -s "$repo"
            fi
        } 2>/dev/null)

        # Save sum to file.
        echo "$SUM" > "$dusum"

        rebuild_dusum_totals
    fi
}

# Run the configured post-successful-sync hook, if any. This is called at the
# very end of each sync method, after all cleanup has finished and the sync has
# been confirmed successful (a failed sync exits earlier via post_failed_sync).
run_post_successful_sync_hook() {
    eval post_successful_sync_hook="\$${MODULE}_post_successful_sync_hook"
    if [[ $post_successful_sync_hook ]]; then
        echo "Executing post-successful-sync hook:"
        eval "$post_successful_sync_hook"
    fi
}

# On failed sync, count failure and exit.
post_failed_sync() {
    echo "Sync failed."
    
    # Update failure count.
    new_error_count=$((error_count+1))

    # If failure count is over our maximum defined errors, email about the failure.
    if ((new_error_count>max_errors)); then
        mail_error "Unable to sync with $MODULE, check logs."
        
        # Remove the error count file so that the count resets.
        rm -f "$ERRORFILE"

        # Exit to not save the updated count.
        exit 1
    fi

    # Update the error count file and exit.
    echo "$new_error_count" > "$ERRORFILE"
    exit 1
}

# Read common configurations, start logging, and acquire lock.
module_config() {
    MODULE=$1
    acquire_lock "$MODULE"
    reset_sync_counts

    # Read the configuration for this module.
    eval repo="\$${MODULE}_repo"
    eval timestamp="\$${MODULE}_timestamp"
    eval dusum="\$${MODULE}_dusum"
    eval options="\$${MODULE}_options"

    # If configuration is not set, exit.
    if [[ ! $repo ]]; then
        echo "No configuration exists for ${MODULE}"
        exit 1
    fi
    resolve_save_trace
    log_start_header
}

# Normalize a boolean configuration in place. Only "true", "false", "1" and "0"
# are accepted, so a value that was meant to enable something but does not spell
# it one of those ways is reported instead of being quietly read as its
# opposite. An unset value takes the given default. The named variable is left
# holding "true" or the empty string, so callers can test it with [[ ]].
#
# The variable is passed by name rather than by value because a value returned
# through a command substitution would be produced in a subshell, where a
# rejected value could not stop the script.
parse_bool() {
    local _var=$1 _default=$2 _config=$3 _value _resolved
    eval _value="\$${_var}"
    _resolved="${_value:-$_default}"
    case "${_resolved,,}" in
        true|1) eval "${_var}=true" ;;
        false|0) eval "${_var}=" ;;
        *)
            echo "Invalid value '${_value}' for ${_config}, expected true, false, 1 or 0."
            exit 1
        ;;
    esac
}

# Resolve whether this module publishes a trace file. The module setting wins
# when present, otherwise the global save_trace applies, which defaults to on.
# Every sync method reads the result from save_trace_enabled.
resolve_save_trace() {
    eval save_trace_enabled="\$${MODULE}_save_trace"
    if [[ $save_trace_enabled ]]; then
        parse_bool save_trace_enabled "true" "${MODULE}_save_trace"
    else
        save_trace_enabled="${save_trace:-}"
        parse_bool save_trace_enabled "true" "save_trace"
    fi
}

# List every ref in the repository, so what a sync changed can be measured by
# comparing the listing against one taken beforehand. Tags and remote tracking
# refs are listed alongside branches, so an update that moved any of them is
# seen.
git_ref_state() {
    git -C "${repo:?}" show-ref 2>/dev/null
}

# Count the refs that differ between two listings. Refs are compared by name,
# so one that moved, one that appeared and one that was deleted each count
# once. Blank lines are ignored, which is what an empty listing (a repository
# that did not exist yet) reads as.
git_changed_refs() {
    awk '
        NF<2 {next}
        NR==FNR {before[$2]=$1; next}
        {after[$2]=$1}
        END {
            for (ref in after) if (!(ref in before) || before[ref]!=after[ref]) changed++
            for (ref in before) if (!(ref in after)) changed++
            print changed+0
        }
    ' <(echo "$1") <(echo "$2")
}

# Publish what a git sync changed, given the ref listing and the checked out
# commit from before it ran. A bare mirror has no working tree whose files
# could be counted, so refs are all it reports. A working tree also counts the
# files the update brought in, by comparing the commit checked out before
# against the one checked out now; a fresh clone has no commit from before, so
# its whole tree is new.
git_sync_counts() {
    local _refs_before=$1 _head_before=$2 _head_after _transferred=0 _deleted=0 _changed=""

    SYNC_REFS_UPDATED=$(git_changed_refs "$_refs_before" "$(git_ref_state)")

    if [[ ! $bare ]]; then
        _head_after=$(git -C "${repo:?}" rev-parse HEAD 2>/dev/null)
        if [[ $_head_before ]] && [[ $_head_after ]]; then
            _transferred=$(git -C "${repo:?}" diff --name-only --diff-filter=d "$_head_before" "$_head_after" 2>/dev/null | wc -l)
            _deleted=$(git -C "${repo:?}" diff --name-only --diff-filter=D "$_head_before" "$_head_after" 2>/dev/null | wc -l)
        elif [[ $_head_after ]]; then
            _transferred=$(git -C "${repo:?}" ls-files 2>/dev/null | wc -l)
        fi
    fi

    if (( SYNC_REFS_UPDATED > 0 || _transferred > 0 || _deleted > 0 )); then
        _changed="true"
    fi
    set_sync_counts "$_transferred" "$_deleted" "$_changed"
    echo "Refs updated: ${SYNC_REFS_UPDATED}"
}

# Maintenance to run after a successful sync (or clone) of a bare repository.
# Bare repositories are typically served to clients over "dumb" HTTP (a plain
# file server), which requires the info files kept up to date and, optionally,
# the upstream URL scrubbed so it cannot be read from the served files.
git_bare_post_sync() {
    # When hiding the remote, strip anything that records the upstream URL so it
    # cannot be probed over dumb HTTP. `config` holds it under [remote ...] and
    # `git fetch` writes it into FETCH_HEAD on every run.
    if [[ $hide_remote ]]; then
        local _remote
        for _remote in $(git -C "${repo:?}" remote 2>/dev/null); do
            git -C "${repo:?}" remote remove "$_remote"
        done
        rm -f "${repo:?}/FETCH_HEAD"
    fi

    # Regenerate the dumb-HTTP info files (info/refs and objects/info/packs).
    # A mirror fetch never fires the post-update hook (that only runs on push),
    # so this has to run explicitly after each sync. It is cheap, so rather than
    # try to detect whether it is needed we simply run it every time.
    git -C "${repo:?}" update-server-info
}

# Sync git based mirrors.
#
# This is the one method that publishes no trace file, so save_trace does not
# apply to it. A trace is an ordinary file inside the repository: in a checked
# out working tree it shows up as untracked and leaves the tree permanently
# dirty, and in a bare repository it means dropping a directory that is not part
# of the object store into the repository root. Neither is worth a trace, and
# naming the upstream would work against hide_remote besides.
git_sync() {
    # Start the module.
    module_config "$1"

    # Read git specific configuration.
    eval source="\$${MODULE}_source"
    eval bare="\$${MODULE}_bare"
    eval hide_remote="\$${MODULE}_hide_remote"

    # An unset bare flag stays empty so the repository can be auto-detected
    # below; only an explicit value is normalized here. Normalization maps
    # false to the empty string, which an unset flag also has, so whether the
    # flag was explicitly configured is remembered separately to keep an
    # explicit false from being auto-detected away.
    bare_configured=""
    if [[ $bare ]]; then
        parse_bool bare "false" "${MODULE}_bare"
        bare_configured=1
    fi

    # Hiding the remote requires a configured source, since without a stored
    # remote the URL to fetch from must come from the configuration on every
    # sync.
    parse_bool hide_remote "false" "${MODULE}_hide_remote"
    if [[ $hide_remote ]] && [[ ! $source ]]; then
        echo "hide_remote requires a source to be configured."
        exit 1
    fi

    # If the destination does not yet contain a git repository, clone it from
    # the configured source. Bare repositories are cloned with --mirror so the
    # configured fetch refspec mirrors all refs from upstream.
    if [[ ! -e "${repo:?}/.git" ]] && [[ ! -e "${repo:?}/HEAD" ]]; then
        if [[ ! $source ]]; then
            echo "No git repository at '${repo:?}' and no source defined to clone from."
            exit 1
        fi
        # There is no repository to auto-detect yet, so the bare flag is
        # whatever was configured. Refuse the same combination the update path
        # refuses rather than cloning a working tree and leaving the upstream
        # URL in the served config, which is what hide_remote exists to prevent.
        if [[ $hide_remote ]] && [[ ! $bare ]]; then
            echo "hide_remote requires a bare repository."
            exit 1
        fi
        echo "Cloning '${source}' into '${repo:?}'."
        if [[ $bare ]]; then
            eval git clone --mirror ${options:+$options} "'${source}'" "'${repo:?}'"
        else
            eval git clone ${options:+$options} "'${source}'" "'${repo:?}'"
        fi
        RT=$?
        if (( RT == 0 )); then
            # Nothing existed here before the clone, so it is measured against
            # an empty repository.
            git_sync_counts "" ""
            [[ $bare ]] && git_bare_post_sync
            post_successful_sync
        else
            post_failed_sync
        fi
        run_post_successful_sync_hook
        log_end_header
        return
    fi

    # Move into the repo folder to sync.
    if ! cd "${repo:?}"; then
        echo "Failed to access '${repo:?}' git repository."
        exit 1
    fi

    # Determine whether the repository is bare. Honor an explicit configuration
    # if set, otherwise auto-detect. Bare repositories have no working tree, so a
    # `git pull` is not possible; instead update by fetching the configured
    # refspec.
    if [[ ! $bare_configured ]] && [[ $(git rev-parse --is-bare-repository 2>/dev/null) == "true" ]]; then
        bare="true"
    fi
    # Hiding the remote only happens in the bare update path, so requiring it
    # here keeps a working tree from silently serving the upstream URL.
    if [[ $hide_remote ]] && [[ ! $bare ]]; then
        echo "hide_remote requires a bare repository."
        exit 1
    fi
    # Record what the repository holds now, so the sync can be measured
    # against it once it has run.
    refs_before=$(git_ref_state)
    head_before=$(git -C "${repo:?}" rev-parse HEAD 2>/dev/null)

    if [[ $bare ]]; then
        # When hiding the remote there is no stored remote to update, so fetch
        # directly from the source with a mirror refspec. Otherwise honor the
        # remote's configured fetch refspec (e.g. from a --mirror clone).
        if [[ $hide_remote ]]; then
            eval git fetch --prune ${options:+$options} "'${source}'" "'+refs/*:refs/*'"
        else
            eval git remote update --prune ${options:+$options}
        fi
    else
        eval git pull ${options:+$options}
    fi
    RT=$?
    if (( RT == 0 )); then
        # Count before any post-sync maintenance runs, as hiding the remote
        # drops the refs it stored and that is not a change from upstream.
        git_sync_counts "$refs_before" "$head_before"
        [[ $bare ]] && git_bare_post_sync
        post_successful_sync
    else
        post_failed_sync
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Read config common for AWS.
read_aws_config() {
    eval bucket="\$${MODULE}_aws_bucket"
    eval AWS_ACCESS_KEY_ID="\$${MODULE}_aws_access_key"
    export AWS_ACCESS_KEY_ID
    eval AWS_SECRET_ACCESS_KEY="\$${MODULE}_aws_secret_key"
    export AWS_SECRET_ACCESS_KEY
    eval AWS_ENDPOINT_URL="\$${MODULE}_aws_endpoint_url"

    # The trace names the service the objects came from, which is the endpoint
    # when one is configured and otherwise the bucket itself.
    trace_upstream="${AWS_ENDPOINT_URL:-$bucket}"
}

# The path of this mirror's own trace file, relative to the repository root.
# The sync methods that delete removed files have to be told to leave it alone,
# as it exists only locally and would otherwise be treated as removed upstream.
trace_relative_path() {
    echo "project/trace/${mirror_hostname:?}"
}

# Sync AWS S3 bucket based mirrors.
aws_sync() {
    # Start the module.
    module_config "$1"
    read_aws_config

    if [[ -n $AWS_ENDPOINT_URL ]]; then
        options="$options --endpoint-url='$AWS_ENDPOINT_URL'"
    fi

    # Keep --delete from removing the trace file this module publishes.
    if [[ $save_trace_enabled ]]; then
        options="$options --exclude='$(trace_relative_path)'"
    fi

    # Capture the sync's output so what it changed can be counted from it.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Run AWS client to sync the S3 bucket.
    sync_started=$(date +%s)
    eval "$sync_timeout" aws s3 sync \
        --no-follow-symlinks \
        --delete \
        "$options" \
        "'${bucket:?}'" "'${repo:?}'" | tee -a "$LOGFILE_SYNC"
    RT=${PIPESTATUS[0]}
    sync_ended=$(date +%s)

    # The client reports each object it downloads or removes on its own line.
    set_sync_counts \
        "$(count_sync_events "$LOGFILE_SYNC" 'download: ')" \
        "$(count_sync_events "$LOGFILE_SYNC" 'delete: ')"
    rm -f "$LOGFILE_SYNC"

    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Sync AWS S3 bucket based mirrors using s3cmd.
s3cmd_sync() {
    # Start the module.
    module_config "$1"
    read_aws_config

    # s3cmd's --host takes a bare "hostname[:port]", while the aws and s5cmd
    # methods read the same aws_endpoint_url setting as a full URL. Trim the
    # scheme and path so one endpoint value works for all three; a value that
    # was already written as a bare host passes through unchanged.
    if [[ -n $AWS_ENDPOINT_URL ]]; then
        s3cmd_host="${AWS_ENDPOINT_URL#*://}"
        s3cmd_host="${s3cmd_host%%/*}"
        options="$options --host='$s3cmd_host'"
    fi

    # Keep --delete-removed from removing the trace file this module publishes.
    if [[ $save_trace_enabled ]]; then
        options="$options --exclude='$(trace_relative_path)'"
    fi

    # Capture the sync's output so what it changed can be counted from it.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Run AWS client to sync the S3 bucket.
    sync_started=$(date +%s)
    eval "$sync_timeout" s3cmd sync \
        -v --progress \
        --skip-existing \
        --delete-removed \
        --delete-after \
        "$options" \
        "'${bucket:?}'" "'${repo:?}'" | tee -a "$LOGFILE_SYNC"
    RT=${PIPESTATUS[0]}
    sync_ended=$(date +%s)

    # s3cmd reports each object it downloads or removes with the path quoted,
    # which is also what tells those messages apart from the warnings it
    # writes about deletions it refused to make.
    set_sync_counts \
        "$(count_sync_events "$LOGFILE_SYNC" "download: '")" \
        "$(count_sync_events "$LOGFILE_SYNC" "delete: '")"
    rm -f "$LOGFILE_SYNC"

    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Sync AWS S3 bucket based mirrors using s5cmd.
s5cmd_sync() {
    # Install s5cmd if not already installed.
    s5cmd_install

    # Start the module.
    module_config "$1"
    read_aws_config
    eval sync_options="\$${MODULE}_sync_options"

    if [[ -n $AWS_ENDPOINT_URL ]]; then
        options="$options --endpoint-url='$AWS_ENDPOINT_URL'"
    fi

    # Keep --delete from removing the trace file this module publishes.
    if [[ $save_trace_enabled ]]; then
        sync_options="${sync_options:+$sync_options }--exclude='$(trace_relative_path)'"
    fi

    # Capture the sync's output so what it changed can be counted from it.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Run AWS client to sync the S3 bucket.
    sync_started=$(date +%s)
    eval "$sync_timeout" "$S5CMD_BIN" "$options" \
        sync ${sync_options:+$sync_options} \
        --no-follow-symlinks \
        --delete \
        "'${bucket:?}'" "'${repo:?}'" | tee -a "$LOGFILE_SYNC"
    RT=${PIPESTATUS[0]}
    sync_ended=$(date +%s)

    # s5cmd echoes the operation it performed for each object, so a sync
    # reports one "cp" per object copied and one "rm" per object removed.
    set_sync_counts \
        "$(count_sync_events "$LOGFILE_SYNC" 'cp ')" \
        "$(count_sync_events "$LOGFILE_SYNC" 'rm ')"
    rm -f "$LOGFILE_SYNC"

    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Sync Linux package repositories (rpm/deb/arch/apk) using repo-sync.
repo_sync_sync() {
    # Install repo-sync if not already installed.
    repo_sync_install

    # Start the module.
    module_config "$1"

    # Read repo-sync specific configuration.
    eval source="\$${MODULE}_source"
    eval repo_type="\$${MODULE}_type"
    eval prune="\$${MODULE}_prune"
    eval sync_options="\$${MODULE}_sync_options"

    # repo-sync identifies each repository from its own metadata, so a type is
    # only needed to limit which formats a run accepts, or to state the format
    # outright for a mirrorlist or metalink URL, which cannot be identified.
    # Several may be listed, separated by spaces or commas.
    type_options=""
    if [[ $repo_type ]]; then
        read -r -a repo_sync_types <<< "${repo_type//,/ }"
        for repo_sync_type in "${repo_sync_types[@]}"; do
            case "${repo_sync_type,,}" in
                rpm|deb|arch|apk) type_options+=" --type ${repo_sync_type,,}" ;;
                *)
                    echo "Unknown type '${repo_sync_type}' for ${MODULE}, expected one of: rpm, deb, arch, apk."
                    exit 1
                ;;
            esac
        done
    fi

    # Pruning removes files that upstream no longer publishes, matching the
    # delete behavior of the other sync methods. Default it on, but allow it to
    # be turned off for repositories that should keep old packages around.
    parse_bool prune "true" "${MODULE}_prune"

    # A module may mirror several repositories in one run, so the source is a
    # list of URLs. Quote each so the eval below does not glob or re-split them.
    read -r -a repo_sync_urls <<< "${source:?}"
    if (( ${#repo_sync_urls[@]} == 0 )); then
        echo "No source URLs defined for ${MODULE}."
        exit 1
    fi
    quoted_urls=""
    for repo_sync_url in "${repo_sync_urls[@]}"; do
        quoted_urls+=" '${repo_sync_url}'"
    done

    # repo-sync writes its own trace files, so rather than calling
    # save_trace_file this module tells repo-sync what to record. The details
    # are the same ones the other methods put in their trace files, passed
    # through from the INFO_* configuration rather than configured a second time
    # in repo-sync's own config file. Tracing is stated either way, so a
    # repo-sync config file cannot contradict this module's setting.
    # These values are shell quoted with printf rather than wrapped in single
    # quotes, as a maintainer name may itself contain an apostrophe.
    trace_options="--no-trace"
    if [[ $save_trace_enabled ]]; then
        trace_options="--trace --trace-host $(printf '%q' "${mirror_hostname:?}")"
        for trace_field in \
            "maintainer:${INFO_MAINTAINER:-}" \
            "sponsor:${INFO_SPONSOR:-}" \
            "country:${INFO_COUNTRY:-}" \
            "location:${INFO_LOCATION:-}" \
            "throughput:${INFO_THROUGHPUT:-}"
        do
            trace_value="${trace_field#*:}"
            if [[ $trace_value ]]; then
                trace_options+=" --trace-${trace_field%%:*} $(printf '%q' "$trace_value")"
            fi
        done
    fi

    # Capture the sync's output so its run summary can be read from it.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Run repo-sync to synchronize the repositories. The destination is always
    # the last argument.
    eval "$sync_timeout" "$REPO_SYNC_BIN" "$options" \
        ${trace_options:+$trace_options} \
        sync ${type_options:+$type_options} ${sync_options:+$sync_options} \
        ${prune:+--prune} \
        "$quoted_urls" "'${repo:?}'" | tee -a "$LOGFILE_SYNC"
    RT=${PIPESTATUS[0]}

    # repo-sync ends a run by printing a summary of what it moved. It states
    # whether the repository changed itself, which is taken as given rather
    # than inferred from the counts, as a dry run reports work it only
    # planned.
    repo_sync_changed=""
    if grep -q '^Repository changed: true' "$LOGFILE_SYNC" 2>/dev/null; then
        repo_sync_changed="true"
    fi
    set_sync_counts \
        "$(sum_log_stat "Number of files transferred" "$LOGFILE_SYNC")" \
        "$(sum_log_stat "Number of files pruned" "$LOGFILE_SYNC")" \
        "$repo_sync_changed"
    rm -f "$LOGFILE_SYNC"

    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Sync using FTP.
ftp_sync() {
    # Start the module.
    module_config "$1"
    eval source="\$${MODULE}_source"

    # Keep --delete from removing the trace file this module publishes. lftp
    # takes a glob here, matched against the path below the mirrored directory.
    trace_exclude=""
    if [[ $save_trace_enabled ]]; then
        trace_exclude="--exclude-glob $(trace_relative_path) "
    fi

    # lftp's mirror writes the commands it runs to its log, one per file it
    # transfers or removes, which is what the changes are counted from. The
    # verbose output it prints is meant for a person to read and is translated
    # to the running locale, so it is not counted from.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Mirror the source tree with lftp.
    sync_started=$(date +%s)
    $sync_timeout lftp <<< "mirror -v --log='${LOGFILE_SYNC}' --delete --no-perms ${trace_exclude}$options '${source:?}' '${repo:?}'"
    RT=${PIPESTATUS[0]}
    sync_ended=$(date +%s)

    # Transfers are logged as a get command, in whichever form lftp chose for
    # the transfer, and removals as an rm. Removed directories are logged as
    # rmdir and are not counted, as they hold no content of their own.
    set_sync_counts \
        "$(count_sync_events "$LOGFILE_SYNC" '(m|p)?get1? ')" \
        "$(count_sync_events "$LOGFILE_SYNC" 'rm ')"
    rm -f "$LOGFILE_SYNC"

    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Sync using wget.
wget_sync() {
    # Start the module.
    module_config "$1"
    eval source="\$${MODULE}_source"

    if [[ -z $options ]]; then
        options="--mirror --no-host-directories --no-parent"
    fi

    # Capture the sync's output so what it changed can be counted from it. The
    # counting happens out here rather than in the subshell below, which
    # cannot hand a count back to the hooks.
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # The sync runs in a subshell, so it is timed from out here where the
    # result is still readable once it has finished. wget never deletes, so
    # unlike the other methods the trace needs no protection from this run.
    sync_started=$(date +%s)
    (
        trap - EXIT
        # Make sure the repo directory exists and we are in it.
        if ! [[ -e $repo ]]; then
            mkdir -p "$repo"
        fi

        if ! cd "$repo"; then
            echo "Unable to enter repo directory."
            exit 1
        fi

        # Run wget with configured options. wget reports on its progress
        # through stderr, which is what has to be captured to see what it
        # retrieved.
        eval "$sync_timeout" wget "$options" "'${source:?}'" 2>&1 | tee -a "$LOGFILE_SYNC"
        RT=${PIPESTATUS[0]}
        if (( RT == 0 )); then
            post_successful_sync
        else
            post_failed_sync
        fi
    )
    RT=$?
    sync_ended=$(date +%s)

    # wget closes a run by reporting what it downloaded. Mirroring only
    # retrieves what changed upstream, so that count is the count of changed
    # files; a run that found nothing new prints no such report at all, and
    # wget never deletes.
    set_sync_counts \
        "$(awk '$1=="Downloaded:" {total+=$2} END {print total+0}' "$LOGFILE_SYNC" 2>/dev/null)" \
        0
    rm -f "$LOGFILE_SYNC"

    if (( RT != 0 )); then
        exit "$RT"
    fi

    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Common config for rsync based modules.
read_rsync_config() {
    eval pre_hook="\$${MODULE}_pre_hook"
    eval source="\$${MODULE}_source"
    eval report_mirror="\$${MODULE}_report_mirror"
    eval RSYNC_PASSWORD="\$${MODULE}_rsync_password"
    if [[ $RSYNC_PASSWORD ]]; then
        export RSYNC_PASSWORD
    fi
    eval post_hook="\$${MODULE}_post_hook"
    eval arch_configurations="\$${MODULE}_arch_configurations"
    eval repo_type="\$${MODULE}_type"
}

# Modules based on rsync.
rsync_sync() {
    # Start the module.
    module_config "$1"
    shift

    # Check for any arguments.
    force=0
    while (( $# > 0 )); do
        case $1 in
            # Force rsync, ignore upstream check.
            -f|--force)
            force=1
            shift
            ;;
            *)
            echo "Unknown option $1"
            echo
            print_help 1
            ;;
        esac
    done
    
    # Read the configuration for this module.
    read_rsync_config
    eval jigdo_pkg_repo="\$${MODULE}_jigdo_pkg_repo"
    eval options_stage2="\$${MODULE}_options_stage2"
    eval pre_stage2_hook="\$${MODULE}_pre_stage2_hook"
    eval upstream_check="\$${MODULE}_upstream_check"
    eval time_file_check="\$${MODULE}_time_file_check"

    # Check if upstream was updated recently if configured.
    # This is designed to slow down rsync so we only rsync
    #  when we detect its needed or when last rsync was a long time ago.
    if [[ $upstream_check ]] && (( force == 0 )); then
        now=$(date +%s)
        if [[ ! -f ${timestamp:?} ]]; then
            echo "Timestamp file not found, skipping upstream check."
        else
            last_timestamp=$(cat "$timestamp")

            # If last update was not that long ago, we should check if upstream was updated recently.
            if (( now-last_timestamp < ${upstream_timestamp_min:?} )); then
                echo "Checking upstream's last modified."

                # Get the last modified date.
                IFS=': ' read -r _ last_modified < <(curl -sI "${upstream_check:?}" | grep -i Last-Modified)
                last_modified="${last_modified//$'\r'/}"

                # If last modified couldn't be determined, proceed with sync.
                if [[ -z $last_modified ]]; then
                    echo "Could not determine upstream last-modified, proceeding with sync."
                else
                    # If the date cannot be parsed, proceed with the sync just
                    # as when the header is missing; an empty value would
                    # otherwise be read as the epoch and skip every sync until
                    # the timestamp minimum passes.
                    if ! last_modified_unix=$(date -u +%s -d "$last_modified" 2>/dev/null); then
                        echo "Could not parse upstream last-modified '${last_modified}', proceeding with sync."
                    # If last modified is greater than our max age, it wasn't modified recently and we should not rsync.
                    elif (( now-last_modified_unix > ${upstream_max_age:-0} )); then
                        echo "Skipping sync as upstream wasn't updated recently."
                        exit 88
                    fi
                fi
            fi
        fi
    fi

    # If a time file check was defined, and check if needed.
    if [[ ${time_file_check:-} ]] && (( force == 0 )); then
        now=$(date +%s)
        if [[ ! -f ${timestamp:?} ]]; then
            echo "Timestamp file not found, skipping time file check."
        else
            last_timestamp=$(cat "$timestamp")

            # Only check time file if the timestamp was recently updated.
            if (( now-last_timestamp < ${upstream_timestamp_min:?} )); then
                echo "Checking if time file has changed since last sync."
                checkresult=$($sync_timeout rsync \
                    --no-motd \
                    --dry-run \
                    --out-format="%n" \
                    "${source:?}/${time_file_check:?}" "${repo:?}/${time_file_check:?}")
                rsync_rt=$?
                if (( rsync_rt != 0 )); then
                    echo "time_file_check rsync failed (exit ${rsync_rt}), proceeding with sync."
                elif [[ -z $checkresult ]]; then
                    echo "The time file has not changed since last sync, we are not updating at this time."
                    exit 88
                fi
            fi
        fi
    fi

    # Run any hooks.
    if [[ $pre_hook ]]; then
        echo "Executing pre-hook:"
        eval "$pre_hook"
    fi

    # Add arguments from configurations.
    extra_args="${options:-}"
    # If 2 stage, we do not want to delete in stage 1.
    if [[ ! $options_stage2 ]]; then
        extra_args+=" --delete --delete-after"
        echo "Running rsync:"
    else
        echo "Running rsync stage 1:"
    fi

    # Create archive update file.
    mirror_update_file="${repo:?}/Archive-Update-in-Progress-${mirror_hostname:?}"
    touch "$mirror_update_file"
    LOGFILE_STAGE1="${LOGFILE}.stage1"
    echo -n > "$LOGFILE_STAGE1"
    # Register for cleanup so an interrupt does not leave these behind.
    cleanup_files+=("$mirror_update_file" "$LOGFILE_STAGE1")

    # Run the rsync. Using eval here so extra_args expands and is used as arguments.
    stage1_started=$(date +%s)
    eval "$sync_timeout" rsync -avH  \
            --progress          \
            --safe-links        \
            --delay-updates     \
            --stats             \
            --no-human-readable \
            --itemize-changes   \
            --timeout=10800     \
            "$extra_args"       \
            --exclude "Archive-Update-in-Progress-${mirror_hostname:?}" \
            --exclude "project/trace/${mirror_hostname:?}" \
            "'${source:?}'" "'${repo:?}'" | tee -a "$LOGFILE_STAGE1"
    stage1_ended=$(date +%s)

    # Check if run was successful.
    if [[ $(grep -c '^total size is' "$LOGFILE_STAGE1") -ne 1 ]]; then
        rm -f "$mirror_update_file"
        post_failed_sync
    fi

    # If 2 stage, perform second stage.
    if [[ $options_stage2 ]]; then
        # Check if upstream is currently updating.
        for aupfile in "${repo:?}/Archive-Update-in-Progress-"*; do
            case "$aupfile" in
                "$mirror_update_file")
                    :
                    ;;
                *)
                    if [[ -f $aupfile ]]; then
                        # Remove the file, it will be synced again if
                        # upstream is still not done
                        rm -f "$aupfile"
                    else
                        echo "AUIP file '${aupfile}' is not really a file, weird"
                    fi
                    echo "Upstream is currently updating their repo, skipping second stage for now."
                    rm -f "$mirror_update_file"
                    exit 0
                    ;;
            esac
        done

        # Run any hooks.
        if [[ $pre_stage2_hook ]]; then
            echo "Executing pre-stage2 hook:"
            eval "$pre_stage2_hook"
        fi

        # Add stage 2 options from configurations.
        extra_args="${options_stage2:-}"
        LOGFILE_STAGE2="${LOGFILE}.stage2"
        echo -n > "$LOGFILE_STAGE2"
        cleanup_files+=("$LOGFILE_STAGE2")

        echo
        echo "Running rsync stage 2:"

        # Run the rsync. Using eval here so extra_args expands and is used as arguments.
        stage2_started=$(date +%s)
        eval "$sync_timeout" rsync -avH  \
                --progress          \
                --safe-links        \
                --delete            \
                --delete-after      \
                --delay-updates     \
                --stats             \
                --no-human-readable \
                --itemize-changes   \
                --timeout=10800     \
                "$extra_args"       \
                --exclude "Archive-Update-in-Progress-${mirror_hostname:?}" \
                --exclude "project/trace/${mirror_hostname:?}" \
                "'${source:?}'" "'${repo:?}'" | tee -a "$LOGFILE_STAGE2"
        stage2_ended=$(date +%s)

        # Check if run was successful.
        if [[ $(grep -c '^total size is' "$LOGFILE_STAGE2") -ne 1 ]]; then
            rm -f "$mirror_update_file"
            post_failed_sync
        fi
    fi
    
    # Count what the sync changed, before the logs it is counted from are
    # cleaned up below. Both stages write into the same repository, so their
    # logs are read as one.
    read -r rsync_transferred rsync_deleted < <(count_rsync_changes "$LOGFILE_STAGE1" "${LOGFILE_STAGE2:-}")
    set_sync_counts "$rsync_transferred" "$rsync_deleted"

    # At this point we are successful.
    post_successful_sync

    # Run any hooks.
    if [[ $post_hook ]]; then
        echo "Executing post hook:"
        eval "$post_hook"
    fi

    # Save trace information.
    if [[ $save_trace_enabled ]]; then
        save_trace_file
    fi
    rm -f "$LOGFILE_STAGE1"
    [[ -n ${LOGFILE_STAGE2:-} ]] && rm -f "$LOGFILE_STAGE2"

    # Remove archive update file.
    rm -f "$mirror_update_file"

    # If report mirror configuration file provided, run report mirror.
    if [[ $report_mirror ]]; then
        echo
        echo "Reporting mirror update:"
        /bin/report_mirror -c "${report_mirror:?}"
    fi

    run_post_successful_sync_hook
    log_end_header
}

# Modules based on quick-fedora-mirror.
quick_fedora_mirror_sync() {
    # Start the module.
    module_config "$1"

    # We need a mapping so we can know the final directory name.
    MODULEMAPPING=(
    fedora-alt          alt
    fedora-archive      archive
    fedora-enchilada    fedora
    fedora-epel         epel
    fedora-secondary    fedora-secondary
    )

    # Helper function to map to dir name.
    module_dir() {
        for ((M=0; M<${#MODULEMAPPING[@]}; M++)); do
            N=$((M+1))
            if [[ "${MODULEMAPPING[$M]}" == "$1" ]]; then
                echo "${MODULEMAPPING[$N]}"
                break
            fi
            M=$N
        done
    }

    # Read the configuration for this module.
    read_rsync_config
    eval master_module="\$${MODULE}_master_module"
    eval module_mapping="\$${MODULE}_module_mapping"
    eval mirror_manager_mapping="\$${MODULE}_mirror_manager_mapping"
    eval modules="\$${MODULE}_modules"
    eval filterexp="\$${MODULE}_filterexp"
    eval rsync_options="\$${MODULE}_rsync_options"

    # Install QFM if not already installed.
    quick_fedora_mirror_install

    # Build configuration file for QFM.
    conf_path="${QFM_PATH}/${MODULE}_qfm.conf"
    cat <<EOF > "$conf_path"
DESTD="$repo"
TIMEFILE="${LOGPATH}/${MODULE}_timefile.txt"
REMOTE="$source"
MODULES=(${modules:?})
FILTEREXP='${filterexp:-}'
VERBOSE=7
LOGITEMS=aeEl
RSYNCOPTS=(-aSH -f 'R .~tmp~' --stats --no-human-readable --preallocate --delay-updates ${rsync_options:-} --out-format='@ %i  %n%L')
EOF
    if [[ $master_module ]]; then
        echo "MASTERMODULE='$master_module'" >> "$conf_path"
    fi
    if [[ $module_mapping ]]; then
        echo "MODULEMAPPING=($module_mapping)" >> "$conf_path"
        IFS=" " read -ra MODULEMAPPING < <(echo "$module_mapping")
    fi
    if [[ $mirror_manager_mapping ]]; then
        echo "MIRRORMANAGERMAPPING=($mirror_manager_mapping)" >> "$conf_path"
    fi

    # Run any hooks.
    if [[ $pre_hook ]]; then
        echo "Executing pre-hook:"
        eval "$pre_hook"
    fi

    # Create archive update file. The repo path is normalized without its
    # trailing slash so module paths can be built with an explicit separator
    # regardless of how the configuration spelled it.
    docroot=${repo%/}
    for module in $modules; do
        _auip="${docroot}/$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
        touch "$_auip"
        # Register for cleanup so an interrupt does not leave these behind.
        cleanup_files+=("$_auip")
    done
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"
    cleanup_files+=("$LOGFILE_SYNC")

    # Add arguments from configurations.
    extra_args="${options:-}"

    # Run the rsync. Using eval here so extra_args expands and is used as arguments.
    sync_started=$(date +%s)
    eval "$sync_timeout" "$QFM_BIN" \
            -c "'$conf_path'"           \
            "$extra_args" | tee -a "$LOGFILE_SYNC"
    sync_ended=$(date +%s)

    # Check if run was successful.
    if ! grep -q '^total size is' "$LOGFILE_SYNC"; then
        for module in $modules; do
            rm -f "${docroot}/$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
        done
        post_failed_sync
    fi

    # Count what the sync changed, before the log it is counted from is
    # cleaned up below. Every module quick-fedora-mirror synchronized reports
    # into the one log, so the counts cover them all.
    read -r qfm_transferred qfm_deleted < <(count_rsync_changes "$LOGFILE_SYNC")
    set_sync_counts "$qfm_transferred" "$qfm_deleted"

    # At this point we are successful.
    post_successful_sync

    # Run any hooks.
    if [[ $post_hook ]]; then
        echo "Executing post hook:"
        eval "$post_hook"
    fi

    # Save trace information. Each sub-module gets its own trace, so repo is
    # pointed at each in turn and then restored, as the configured repo is what
    # the post-successful-sync hook expects to be given.
    if [[ $save_trace_enabled ]]; then
        module_repo=$repo
        for module in $modules; do
            repo="${docroot}/$(module_dir "$module")"
            save_trace_file
        done
        repo=$module_repo
    fi
    rm -f "$LOGFILE_SYNC"

    # Remove archive update file.
    for module in $modules; do
        rm -f "${docroot}/$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
    done

    # If report mirror configuration file provided, run report mirror.
    if [[ $report_mirror ]]; then
        echo
        echo "Reporting mirror update:"
        /bin/report_mirror -c "${report_mirror:?}"
    fi

    run_post_successful_sync_hook
    log_end_header
}

# If no arguments are provided, we can print help.
if (( $# < 1 )); then
    print_help
fi

# Parse arguments.
while (( $# > 0 )); do
    case "$1" in
        # Installs utilities used by this script which are not available in the standard repositories.
        -u|--update-support-utilities)
            update_support_utilities
            exit 0
        ;;
        # If help is requested, print it.
        -h|h|help|--help)
            print_help
        ;;
        # Print version.
        -v|--version)
            echo "Mirror Sync (${VERSION})"
            exit 0
        ;;
        # Default to rsync if module has no special options, otherwise if no module is found give help.
        *)
            for MODULE in ${MODULES:?}; do
                if [[ "$1" == "$MODULE" ]]; then
                    eval sync_method="\${${MODULE}_sync_method:-rsync}"
                    if [[ "${sync_method:?}" == "git" ]]; then
                        git_sync "$@"
                    elif [[ "${sync_method:?}" == "aws" ]]; then
                        aws_sync "$@"
                    elif [[ "${sync_method:?}" == "s3cmd" ]]; then
                        s3cmd_sync "$@"
                    elif [[ "${sync_method:?}" == "s5cmd" ]]; then
                        s5cmd_sync "$@"
                    elif [[ "${sync_method:?}" == "repo-sync" ]] || [[ "${sync_method:?}" == "repo_sync" ]]; then
                        repo_sync_sync "$@"
                    elif [[ "${sync_method:?}" == "ftp" ]]; then
                        ftp_sync "$@"
                    elif [[ "${sync_method:?}" == "wget" ]]; then
                        wget_sync "$@"
                    elif [[ "${sync_method:?}" == "qfm" ]]; then
                        quick_fedora_mirror_sync "$@"
                    else
                        rsync_sync "$@"
                    fi
                    exit 0
                fi
            done
            # No module was found, so give help.
            echo "Unknown module '$1'"
            echo
            print_help 1
        ;;
    esac
done
