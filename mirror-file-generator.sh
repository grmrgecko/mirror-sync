#!/bin/bash
# This script is designed to generate some files at the top level of every mirror.
#
# The files generated are:
# index.html
# footer.txt
# DIRECTORY_SIZES.TXT
#
PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:$HOME/.local/bin:$HOME/bin"

# Variables about this program.
PROGRAM="mirror-file-generator"
VERSION="20260602"
PIDPATH="/tmp"
PIDFILE="${PIDPATH}/${PROGRAM}.pid"
LOGFILE="/var/log/mirror-sync/$PROGRAM.log"

# Default variables
SECTIONS="official unofficial"
section_default="unofficial"
template_dir="/usr/local/share/mirror-file-generator/templates"
index_generate=1
index_file_name="index.html"
footer_generate=1
footer_file_name="footer.txt"
dir_sizes_generate=1
dir_sizes_file_name="DIRECTORY_SIZES.TXT"
dir_sizes_unknown_path="$HOME/dusum/unknown_dirs"
dir_sizes_human_readable=1
icons_dir_name="img"
icons_local_repo="$HOME/dashboard-icons"
icons_repo_url="https://github.com/walkxcode/dashboard-icons.git"
icons_repo_refresh=604800
icons_default_source="https://raw.githubusercontent.com/walkxcode/dashboard-icons/main/png"
icons_default_img="tux.png"

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
    echo "Mirror File Generator (${VERSION})"
    echo
    echo "Usage:"
    echo "$0 [--help|--version|--update-unknown-dir-size] [{mirror}]"
    echo
    echo "Available mirrors:"
    for MIRROR in ${MIRRORS:?}; do
        echo "$MIRROR"
    done
    echo
    echo "Note: Defaults to generating files for all mirrors."
    exit
}

# Output message in log format and to logger.
log() {
    msg="$1"
    echo "$(date --rfc-3339=seconds) $(hostname -s) ${PROGRAM}[$$]: $msg"
}

# Escape characters that are not HTML safe to ensure accidental
# code injection does not occur.
html_encode() {
    local s
    s=${1//&/\&amp;}
    s=${s//</\&lt;}
    s=${s//>/\&gt;}
    s=${s//'"'/\&quot;}
    printf -- %s "$s"
}

# Find the template file path.
template_file() {
    local file=$1
    # If the mirror has an override, provide it. Otherwise, provide default path.
    if [[ -e "$template_dir/$mirror/$file" ]]; then
        echo "$template_dir/$mirror/$file"
    else
        echo "$template_dir/default/$file"
    fi
}

# Copy an image and return the path to the copied image.
image_copy() {
    # Get the requested file.
    local file=$1
    if [[ -z $file ]]; then
        return
    fi
    # Get the file name in which to save the file as.
    # Would typically be logo or the directory name of the repo.
    local file_name=$2
    if [[ -z $file_name ]]; then
        return
    fi
    ## Extract the extension to make a proper save path with the file name and extension.
    local extension="${file##*.}"
    extension="${extension%\?*}"
    local save_path="$path/$icons_dir_name/$file_name.$extension"
    local http_code

    # Determine if the saved file needs to be updated.
    local needs_update=0
    if [[ ! -e "$save_path" ]]; then
        needs_update=1
    elif [[ "$file" =~ ^http(s|)\:\/\/ ]]; then
        # Re-download remote files if older than the refresh interval.
        if (( $(date +%s) - $(stat --format='%Y' "$save_path") > icons_repo_refresh )); then
            needs_update=1
        fi
    elif [[ -f $file ]]; then
        # Re-copy local files if the source mtime differs.
        if (( $(stat --format='%Y' "$file") != $(stat --format='%Y' "$save_path") )); then
            needs_update=1
        fi
    fi

    if (( needs_update )); then
        # If http, use curl to grab the image.
        if [[ "$file" =~ ^http(s|)\:\/\/ ]]; then
            # If failure, and is not the default image, attempt to grab the default file.
            # --fail suppresses writing the response body on HTTP errors; rm -f cleans up
            # any partial file so the fallback recursion isn't blocked by the needs_update check.
            if ! http_code=$(curl -sf --write-out "%{http_code}" -o "$save_path" "$file") \
                || ( ((http_code!=200)) && [[ "$file" != "$icons_default_img" ]] \
                && [[ "$file" != "$icons_default_source/$icons_default_img" ]] ); then
                rm -f "$save_path"
                image_copy "$icons_default_img" "$file_name"
                return
            fi
        # If the file exists, copy it preserving mtime.
        elif [[ -f $file ]]; then
            cp -p "$file" "$save_path"
        else
            # Check to see if a template file exists with the file name.
            local t_file
            t_file=$(template_file "$file")
            # If the file exists, copy it preserving mtime.
            if [[ -f $t_file ]]; then
                cp -p "$t_file" "$save_path"
            elif [[ "$file" != /* ]] && [[ "$file" != "$icons_default_source/$file" ]]; then
                # If nothing else exists, try grabbing from the default source.
                image_copy "$icons_default_source/$file" "$file_name"
                return
            fi
        fi
    fi
    # Return the save relative path.
    echo "$icons_dir_name/$file_name.$extension"
}

# Read the module's configuration.
read_config() {
    eval timestamp="\${${MODULE}_timestamp:-}"
    eval dusum="\${${MODULE}_dusum:-}"
    eval section="\${${MODULE}_section:-}"
    eval repo_title="\${${MODULE}_repo_title:-}"
    eval icon="\${${MODULE}_repo_icon:-}"
    eval repo_description="\${${MODULE}_repo_description:-}"
    eval disable_size_calc="\${${MODULE}_disable_size_calc:-0}"
    eval repo_skip="\${${MODULE}_repo_skip:-0}"
    eval timestamp_file_stat="\${${MODULE}_timestamp_file_stat:-}"
}

# Cli options.
update_unknown_dir_size=0
selected_mirrors=()

# Parse arguments.
while (( $# > 0 )); do
    case "$1" in
        # If we should update directory size summaries for unknown repos.
        -u|--update-unknown-dir-size)
            update_unknown_dir_size=1
            shift
        ;;
        # If help is requested, print it.
        -h|h|help|--help)
            print_help "$@"
        ;;
        # Print version.
        -v|--version)
            echo "Mirror File Generator (${VERSION})"
            exit 0
        ;;
        # Check what mirror is requested.
        *)
            mirror="$1"
            shift

            # Verify that the mirror exists.
            foundMirror=""
            for MIRROR in ${MIRRORS:?}; do
                if [[ "$mirror" == "$MIRROR" ]]; then
                    # Verify the path is configured for this mirror.
                    eval path="\${${MIRROR}_path:-}"
                    if [[ -z $path ]] || [[ ! -e $path ]]; then
                        echo "The mirror $MIRROR is missing the path"
                        exit 1
                    fi
                    foundMirror="$MIRROR"
                fi
            done

            # If the mirror wasn't found, quit.
            if [[ -z $foundMirror ]]; then
                echo "Unknown mirror '$mirror'"
                echo
                print_help "$@"
            fi

            # Add mirror to list.
            # We are purposely adding quotes to match the space.
            # shellcheck disable=SC2076
            if [[ ! " ${selected_mirrors[*]} " =~ " ${foundMirror} " ]]; then
                selected_mirrors+=("$foundMirror")
            fi
        ;;
    esac
done

# Redirect stdout to both stdout and log file.
exec 1> >(tee -a "$LOGFILE")
# Redirect errors to stdout so they also are logged.
exec 2>&1

# Check existing pid file.
if [[ -f $PIDFILE ]]; then
    PID=$(cat "$PIDFILE")
    # Prevent double locks.
    if [[ $PID == "$BASHPID" ]]; then
        log "Double lock detected."
        exit 1
    fi

    # Check if PID is active.
    if ps -p "$PID" >/dev/null; then
        log "A sync is already in progress (pid ${PID})."
        exit 1
    fi
fi

# Create a new pid file for this process.
echo "$BASHPID" >"$PIDFILE"

# On exit, remove pid file.
trap 'rm -f "$PIDFILE"' EXIT

# If no mirrors were selected, default to all.
if (( ${#selected_mirrors[@]} == 0 )); then
    for MIRROR in ${MIRRORS:?}; do
        # Verify the path is configured for this mirror.
        eval path="\${${MIRROR}_path:-}"
        if [[ -z $path ]] || [[ ! -e $path ]]; then
            log "The mirror $MIRROR is missing the path"
            exit 1
        fi
        # Add mirror to the list.
        # We are purposely adding quotes to match the space.
        # shellcheck disable=SC2076
        if [[ ! " ${selected_mirrors[*]} " =~ " ${MIRROR} " ]]; then
            selected_mirrors+=("$MIRROR")
        fi
    done
fi

# Ensure the local dashboard-icons repo is present and fresh (pulled at most weekly).
if [[ -n $icons_local_repo ]]; then
    if [[ -n $icons_repo_url ]] && [[ ! -d "$icons_local_repo/.git" ]]; then
        log "Cloning dashboard-icons to $icons_local_repo"
        git clone --depth=1 "$icons_repo_url" "$icons_local_repo" \
            || log "Warning: failed to clone dashboard-icons, falling back to remote URLs"
    elif [[ -n $icons_repo_url ]] && [[ -d "$icons_local_repo/.git" ]]; then
        fetch_head="$icons_local_repo/.git/FETCH_HEAD"
        if [[ ! -f "$fetch_head" ]] \
            || (( $(date +%s) - $(stat --format='%Y' "$fetch_head") > icons_repo_refresh )); then
            log "Updating dashboard-icons at $icons_local_repo"
            git -C "$icons_local_repo" pull --ff-only \
                || log "Warning: failed to update dashboard-icons"
        fi
    fi

    # Prefer the local clone over the remote URL.
    if [[ -d "$icons_local_repo/png" ]]; then
        icons_default_source="$icons_local_repo/png"
    fi
fi

# Keep track of repos which sizes were updated for to
# avoid updating sizes in multi mirror situations.
repo_sizes_updated=()

# Scan each mirror and build files.
for ((i=0; i<${#selected_mirrors[@]}; i++)); do
    mirror=${selected_mirrors[i]}
    # Read all mirror configs.
    eval path="\${${mirror}_path:-}"
    eval title="\${${mirror}_title:-$mirror}"
    title=$(html_encode "$title")
    export title
    eval logo="\${${mirror}_logo:-}"
    eval description="\${${mirror}_description:-}"
    export description
    eval provider_site="\${${mirror}_provider_site:-}"
    provider_site=$(html_encode "$provider_site")
    export provider_site
    eval provider_name="\${${mirror}_provider_name:-}"
    provider_name=$(html_encode "$provider_name")
    export provider_name

    # If the image directory isn't there, make it.
    if [[ ! -d "$path/$icons_dir_name" ]]; then
        mkdir -p "$path/$icons_dir_name"
    fi

    # Grab the image and export the relative path for templates.
    logo_relative=$(html_encode "$(image_copy "${logo:-$icons_default_img}" logo)")
    export logo_relative

    # Default index file path.
    index_file_path="$path/$index_file_name"
    index_file_temp="$index_file_path.build"
    
    # If the index file should be generated, add the header and start sections.
    if ((index_generate)); then
        # Make temp file with the header templated filled out with exported variables.
        log "Generating index for $mirror at $index_file_path"
        envsubst < "$(template_file header.html)" > "$index_file_temp"

        # With each section, make a new section temporary file to build section lists.
        for SECTION in $SECTIONS; do
            eval section_title="\${section_${SECTION}_title:-${SECTION^} Mirrors}"
            section_title=$(html_encode "$section_title")
            export section_title
            envsubst < "$(template_file section.html)" > "$index_file_temp.$SECTION"
        done
    fi

    # If directory sizes should generate, start the file with current date.
    dir_sizes_file_path="$path/$dir_sizes_file_name"
    if ((dir_sizes_generate)); then
        log "Generating directory sizes file for $mirror at $dir_sizes_file_path"
        date > "$dir_sizes_file_path"
    fi

    # Keep record of total kbytes of repo sizes.
    totalKBytes=0

    # For each directory under the mirror, generate repo data.
    for dir in "$path"/*; do
        # Some repos may be built with symbolic links, so get the real path.
        real_dir=$(realpath "$dir")
        # If the real path isn't a directory, ignore this path.
        if ! [[ -d $real_dir ]]; then
            continue
        fi
        # Get the directory name.
        dir_name=$(basename "$dir")
        # If this directory is the images directory, we should ignore it.
        if [[ "$dir_name" == "$icons_dir_name" ]]; then
            continue
        fi
        log "Checking repo $dir_name"


        # If a module was found, we do not need to look further.
        found_repo=0

        # Check each module to see if this directory is a module's repo.
        for MODULE in ${MODULES:?}; do
            # Get the repo with the trailing slash removed.
            eval repo="\${${MODULE}_repo%/}"
            # Get the sync method for QFM detection.
            eval sync_method="\${${MODULE}_sync_method:-rsync}"

            # If is this module.
            if [[ -n $repo ]] && [[ "$repo" == "$real_dir" ]]; then
                found_repo=1
            # If QFM module, we need to determine sub path using QFM logic.
            elif [[ "${sync_method:?}" == "qfm" ]]; then
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

                # Get what modules this module defines to get with QFM.
                eval modules="\$${MODULE}_modules"
                
                # Determine if any of the modules match this repo directory.
                docroot=$repo
                for module in ${modules:?}; do
                    if [[ "$docroot/$(module_dir "$module")" == "$real_dir" ]]; then
                        found_repo=1
                        break
                    fi
                done
            fi

            # If this module was identified as this repo, grab configs.
            if ((found_repo)); then
                log "Found repo configurations"
                read_config

                # If a timestamp file exists, grab and format the date.
                if [[ -n $timestamp ]] && [[ -f $timestamp ]]; then
                    repo_sync_time=$(date -d "@$(cat "$timestamp")" '+%c')
                fi

                # If a directory usage summary exists and we're not skipping, parse the size.
                if [[ -n $dusum ]] && [[ -f $dusum ]] && ((${repo_skip:-0} == 0)); then
                    repo_size_kb=$(grep "$real_dir" "$dusum" | awk '{print $1}')
                    if [[ -n $repo_size_kb ]]; then
                        totalKBytes=$((totalKBytes+repo_size_kb))
                        repo_size=$(echo "$repo_size_kb*1024" | bc | numfmt --to=iec)
                    fi
                fi
                break
            fi
        done

        if ((found_repo == 0)); then
            # To allow customization of non synced modules, check each module.
            for MODULE in ${CUSTOM_MODULES:-}; do
                # Get the repo with trailing slash removed.
                eval repo="\${${MODULE}_repo%/}"

                # Confirm if this custom module is this repo, and parse configs if it is.
                if [[ -n $repo ]] && [[ "$repo" == "$real_dir" ]]; then
                    log "Found custom configurations"
                    read_config
                    # Stage/prod tiers populated by mirror-promote.sh land here,
                    # so timestamp/dusum are read below for both MODULES and CUSTOM_MODULES.
                    break
                fi
            done

            # Read the per-tier timestamp/dusum sidecars that mirror-promote.sh
            # copies for promoted CUSTOM_MODULES (e.g. stage_almalinux, prod_*).
            if [[ -n ${timestamp:-} ]] && [[ -f $timestamp ]]; then
                repo_sync_time=$(date -d "@$(cat "$timestamp")" '+%c')
            fi
            if [[ -n ${dusum:-} ]] && [[ -f $dusum ]] && ((${repo_skip:-0} == 0)); then
                repo_size_kb=$(grep "$real_dir" "$dusum" | awk '{print $1}')
                if [[ -n $repo_size_kb ]]; then
                    totalKBytes=$((totalKBytes+repo_size_kb))
                    repo_size=$(echo "$repo_size_kb*1024" | bc | numfmt --to=iec)
                fi
            fi
        fi

        # If we should skip this repo, continue to the next.
        if ((${repo_skip:-0})); then
            # Unset all vars for next repo.
            unset repo_path repo_icon repo_title repo_size repo_size_kb \
                    repo_sync_time repo_description timestamp dusum section \
                    icon repo_skip disable_size_calc timestamp_file_stat
            continue
        fi

        # If a timstamp file stat is configured and the path exists, get the timestamp via stat.
        if [[ -e ${timestamp_file_stat:-} ]]; then
            # Get all timestamps, sort, and get the latest entry.
            latest_unix_stat=$(stat --format='%W %X %Y %Z' "$timestamp_file_stat" | tr ' ' '\n' | sort -nr | head -n1)
            # Format the timestamp.
            repo_sync_time=$(date -d "@$latest_unix_stat" '+%c')
        fi

        # Fallback to the .last-synced sidecar mtime that mirror-promote.sh writes
        # into each promoted repo. Lets stage/prod proxy-cache repos render a
        # meaningful date even when no other timestamp source is configured.
        if [[ -z ${repo_sync_time:-} ]] && [[ -f "$real_dir/.last-synced" ]]; then
            last_synced_unix=$(stat --format='%Y' "$real_dir/.last-synced")
            repo_sync_time=$(date -d "@$last_synced_unix" '+%c')
        fi

        # HTML encode and export variables for subsitution.
        repo_path="$dir_name/"
        export repo_path
        repo_title=$(html_encode "${repo_title:-$dir_name}")
        export repo_title
        repo_description=$(html_encode "${repo_description:-}")
        export repo_description
        repo_sync_time=$(html_encode "${repo_sync_time:-Unknown}")
        export repo_sync_time

        # Grab the icon and get its relative path.
        repo_icon=$(html_encode "$(image_copy "${icon:-$icons_default_img}" "$dir_name")")
        export repo_icon

        # If repo size is undefined, check if an unknown repo directory size exists.
        if [[ -z ${repo_size:-} ]] && ((${disable_size_calc:-0} == 0)); then
            unknown_path="$dir_sizes_unknown_path/$mirror/$dir_name"

            # If we should update the directory usage sizes, do so.
            # shellcheck disable=SC2076
            if ((update_unknown_dir_size)) \
                && [[ ! " ${repo_sizes_updated[*]} " =~ " ${real_dir} " ]]; then
                # Add to list of repos with updated sizes.
                repo_sizes_updated+=("$real_dir")

                log "Generating sum file for $dir_name"
                # If the mirror dir under the unknown repo path doesn't exist, create it.
                if [[ ! -e "$dir_sizes_unknown_path/$mirror" ]]; then
                    mkdir -p "$dir_sizes_unknown_path/$mirror"
                fi

                # Get a sum, store to variable first to avoid having an empty file when another cron finishes.
                SUM=$({
                    du -s "$real_dir"
                } 2>/dev/null)

                # Save sum to file.
                echo "$SUM" > "$unknown_path"
            fi

            # If the unknown repo size path exists, grab it.
            if [[ -f $unknown_path ]]; then
                repo_size_kb=$(grep "$real_dir" "$unknown_path" | awk '{print $1}')
                if [[ -n $repo_size_kb ]]; then
                    totalKBytes=$((totalKBytes+repo_size_kb))
                    repo_size=$(echo "$repo_size_kb*1024" | bc | numfmt --to=iec)
                fi
            fi
        fi

        # Export the repo size.
        repo_size=$(html_encode "${repo_size:-Unknown}")
        export repo_size

        # If we're generating the index.html, do so.
        if ((index_generate)); then
            section=${section:-$section_default}
            envsubst < "$(template_file repo.html)" >> "$index_file_temp.$section"
        fi

        # If we're generating the repo size file, add to it.
        if ((dir_sizes_generate)); then
            if ((dir_sizes_human_readable)); then
                printf "%-5s %s\n" "$repo_size" "$dir_name" >> "$dir_sizes_file_path"
            else
                printf "%-12s %s\n" "${repo_size_kb:-0}" "$dir_name" >> "$dir_sizes_file_path"
            fi
        fi

        # Unset all vars for next repo.
        unset repo_path repo_icon repo_title repo_size repo_size_kb \
                repo_sync_time repo_description timestamp dusum section \
                icon repo_skip disable_size_calc timestamp_file_stat
    done

    # If the index should be generated, add each section and footer.
    if ((index_generate)); then
        # Add all sections and remove the temp file.
        for SECTION in $SECTIONS; do
            cat "$index_file_temp.$SECTION" >> "$index_file_temp"
            rm -f "$index_file_temp.$SECTION"
        done

        # Add footer subsituting environment variables.
        envsubst < "$(template_file footer.html)" >> "$index_file_temp"

        # Verify the index temp contains a repo before moving into place.
        if grep -q "Last Sync:" "$index_file_temp"; then
            [[ -f $index_file_path ]] && rm -f "$index_file_path"
            mv "$index_file_temp" "$index_file_path"
        else
            rm -f "$index_file_temp"
        fi
    fi

    # If we are generating the directory sizes file, add the total.
    if ((dir_sizes_generate)); then
        if ((dir_sizes_human_readable)); then
            printf "%-5s %s\n" "$(echo "$totalKBytes*1024" | bc | numfmt --to=iec)" "total" >> "$dir_sizes_file_path"
        else
            printf "%-12s %s\n" "$totalKBytes" "total" >> "$dir_sizes_file_path"
        fi
    fi

    # If we should generate the global footer, do so.
    if ((footer_generate)); then
        log "Generating footer for $mirror at $path/$footer_file_name"
        envsubst < "$(template_file footer.txt)" > "$path/$footer_file_name"
    fi
done
