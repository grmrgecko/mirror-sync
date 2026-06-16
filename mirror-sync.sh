#!/bin/bash
# This script is designed to handle mirror syncing tasks from external mirrors.
# Each mirror is handled within a module which can be configured via the configuration file /etc/mirror-sync.conf.
PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$HOME/.local/bin:$HOME/bin"

# Variables for trace generation.
PROGRAM="mirror-sync"
VERSION="20260616"
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

# Prevent run as root.
if (( EUID == 0 )); then
  echo "Do not mirror as root."
  exit 1
fi

# Load the required configuration file or quit.
if [[ -f /etc/mirror-sync.conf ]]; then
    # shellcheck source=/dev/null
    source /etc/mirror-sync.conf
else
    echo "No configuration file defined, please setup a proper configuration file."
    exit 1
fi

# Print the help for this command.
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
    exit
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

# Updates the mirror support utilties on server with upstream.
update_support_utilities() {
    quick_fedora_mirror_install -u
    jigdo_install -u
    s5cmd_install -u
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
    if (( total_time != 0 )); then
        rate=$(( total / total_time ))
        echo "Average rate: ${rate} B/s"
    fi
}

# For modules that are repositories (with RPM, DEB, ISOs, or source code),
# build a project trace file with information about the repo.
# Mainly works with rsync based modules.
save_trace_file() {
    # Trace file/dir paths.
    TRACE_DIR="${repo}/project/trace"
    mkdir -p "$TRACE_DIR"
    TRACE_FILE="${TRACE_DIR}/${mirror_hostname:?}"
    TRACE_MASTER_FILE="${TRACE_DIR}/master"
    TRACE_HIERARCHY="${TRACE_DIR}/_hierarchy"

    # Parse the rsync host from the source.
    RSYNC_HOST=${source:-}
    RSYNC_HOST=${RSYNC_HOST/rsync:\/\//}
    RSYNC_HOST=${RSYNC_HOST%%:*}
    RSYNC_HOST=${RSYNC_HOST%%/*}

    # Build trace and save to file.
    build_trace_content > "${TRACE_FILE}.new"
    mv "${TRACE_FILE}.new" "$TRACE_FILE"

    # Build heirarchy file.
    {
        if [[ -e "${TRACE_HIERARCHY}.mirror" ]]; then
            cat "${TRACE_HIERARCHY}.mirror"
        fi
        echo "$(basename "$TRACE_FILE") $mirror_hostname $TRACEHOST ${RSYNC_HOST:-unknown}"
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
                    du -s "$docroot$(module_dir "$module")/"
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
    log_start_header
}

# Sync git based mirrors.
git_sync() {
    # Start the module.
    module_config "$1"

    # Read git specific configuration.
    eval source="\$${MODULE}_source"
    eval bare="\$${MODULE}_bare"

    # Normalize the bare flag to either "true" or empty.
    case "${bare,,}" in
        1|true|yes|bare) bare="true" ;;
        *) bare="" ;;
    esac

    # If the destination does not yet contain a git repository, clone it from
    # the configured source. Bare repositories are cloned with --mirror so the
    # configured fetch refspec mirrors all refs from upstream.
    if [[ ! -e "${repo:?}/.git" ]] && [[ ! -e "${repo:?}/HEAD" ]]; then
        if [[ ! $source ]]; then
            echo "No git repository at '${repo:?}' and no source defined to clone from."
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
            post_successful_sync
        else
            post_failed_sync
        fi
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
    # `git pull` is not possible; instead use `git remote update` which honors the
    # configured fetch refspec (e.g. a mirror clone created with --mirror).
    if [[ ! $bare ]] && [[ $(git rev-parse --is-bare-repository 2>/dev/null) == "true" ]]; then
        bare="true"
    fi
    if [[ $bare ]]; then
        eval git remote update --prune ${options:+$options}
    else
        eval git pull ${options:+$options}
    fi
    RT=$?
    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

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
}

# Sync AWS S3 bucket based mirrors.
aws_sync() {
    # Start the module.
    module_config "$1"
    read_aws_config

    if [[ -n $AWS_ENDPOINT_URL ]]; then
        options="$options --endpoint-url='$AWS_ENDPOINT_URL'"
    fi

    # Run AWS client to sync the S3 bucket.
    eval "$sync_timeout" aws s3 sync \
        --no-follow-symlinks \
        --delete \
        "$options" \
        "'${bucket:?}'" "'${repo:?}'"
    RT=${PIPESTATUS[0]}
    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    log_end_header
}

# Sync AWS S3 bucket based mirrors using s3cmd.
s3cmd_sync() {
    # Start the module.
    module_config "$1"
    read_aws_config

    if [[ -n $AWS_ENDPOINT_URL ]]; then
        options="$options --host='$AWS_ENDPOINT_URL'"
    fi

    # Run AWS client to sync the S3 bucket.
    eval "$sync_timeout" s3cmd sync \
        -v --progress \
        --skip-existing \
        --delete-removed \
        --delete-after \
        "$options" \
        "'${bucket:?}'" "'${repo:?}'"
    RT=${PIPESTATUS[0]}
    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

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

    # Run AWS client to sync the S3 bucket.
    eval "$sync_timeout" "$S5CMD_BIN" "$options" \
        sync ${sync_options:+$sync_options} \
        --no-follow-symlinks \
        --delete \
        "'${bucket:?}'" "'${repo:?}'"
    RT=${PIPESTATUS[0]}
    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

    log_end_header
}

# Sync using FTP.
ftp_sync() {
    # Start the module.
    module_config "$1"
    eval source="\$${MODULE}_source"

    # Run AWS client to sync the S3 bucket.
    $sync_timeout lftp <<< "mirror -v --delete --no-perms $options '${source:?}' '${repo:?}'"
    RT=${PIPESTATUS[0]}
    if (( RT == 0 )); then
        post_successful_sync
    else
        post_failed_sync
    fi

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

        # Run wget with configured options.
        eval "$sync_timeout" wget "$options" "'${source:?}'"
        RT=${PIPESTATUS[0]}
        if (( RT == 0 )); then
            post_successful_sync
        else
            post_failed_sync
        fi
    )
    RT=$?
    if (( RT != 0 )); then
        exit "$RT"
    fi

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
            print_help "$@"
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
                    last_modified_unix=$(date -u +%s -d "$last_modified")

                    # If last modified is greater than our max age, it wasn't modified recently and we should not rsync.
                    if (( now-last_modified_unix > ${upstream_max_age:-0} )); then
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
    
    # At this point we are successful.
    post_successful_sync

    # Run any hooks.
    if [[ $post_hook ]]; then
        echo "Executing post hook:"
        eval "$post_hook"
    fi

    # Save trace information.
    if [[ $repo_type ]]; then
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

    # Create archive update file.
    docroot=$repo
    for module in $modules; do
        touch "$docroot$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
    done
    LOGFILE_SYNC="${LOGFILE}.sync"
    echo -n > "$LOGFILE_SYNC"

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
            rm -f "$docroot$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
        done
        post_failed_sync
    fi

    # At this point we are successful.
    post_successful_sync

    # Run any hooks.
    if [[ $post_hook ]]; then
        echo "Executing post hook:"
        eval "$post_hook"
    fi

    # Save trace information.
    if [[ $repo_type ]]; then
        for module in $modules; do
            repo="$docroot$(module_dir "$module")"
            save_trace_file
        done
    fi
    rm -f "$LOGFILE_SYNC"

    # Remove archive update file.
    for module in $modules; do
        rm -f "$docroot$(module_dir "$module")/Archive-Update-in-Progress-${mirror_hostname:?}"
    done

    # If report mirror configuration file provided, run report mirror.
    if [[ $report_mirror ]]; then
        echo
        echo "Reporting mirror update:"
        /bin/report_mirror -c "${report_mirror:?}"
    fi

    log_end_header
}

# If no arugments are provided, we can print help.
if (( $# < 1 )); then
    print_help "$@"
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
            print_help "$@"
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
            print_help "$@"
        ;;
    esac
done
