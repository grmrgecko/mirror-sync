# mirror-sync

A tool to mirror repositories for Linux and other similar tools. This tool is designed to help follow upstream mirror instructions, and implement the features they expect from a downstream official mirror. It also includes features to help keep you in the loop in case of situations that need manual intervention.

Companion tool: [mirror-file-generator](docs/mirror-file-generator.md) generates index pages and mirror info files from the same configuration file.

## Contents

- [Quick start](#quick-start)
- [How the configuration file works](#how-the-configuration-file-works)
- [Global settings](#global-settings)
- [Module settings](#module-settings)
- [Change counts in hooks](#change-counts-in-hooks)
- [Sync methods](#sync-methods)
- [Trace files](#trace-files)
- [CLI options](#cli-options)
- [Requirements](#requirements)

## Quick start

Mirror using a dedicated user account rather than root; the script refuses to run as root.

**1. Create the log directory**

```bash
mkdir -p /var/log/mirror-sync/
chown mirror: /var/log/mirror-sync/
```

**2. Write `/etc/mirror-sync.conf`**

This is a complete, working configuration. Copy it and change the values:

```bash
# --- Global settings, shared by every module ---
MAILTO="admin@example.com"
INFO_MAINTAINER="Your Name <you@example.com>"
INFO_COUNTRY="US"
INFO_LOCATION="Texas"

# --- List every module you want to sync, separated by spaces ---
MODULES="epel debian"

# --- Settings for the "epel" module. Every line starts with "epel_" ---
epel_sync_method="rsync"
epel_repo="/home/mirror/http/epel"
epel_timestamp="/home/mirror/timestamp/epel"
epel_source="rsync://rsync.example.org/epel/"
epel_type="rpm"

# --- Settings for the "debian" module. Same settings, "debian_" prefix ---
debian_sync_method="rsync"
debian_repo="/home/mirror/http/debian"
debian_timestamp="/home/mirror/timestamp/debian"
debian_source="rsync://rsync.example.org/debian/"
debian_type="deb"
```

**3. Sync a module**

One module per invocation:

```bash
mirror-sync epel
```

**4. Schedule it**

```
0 */6 * * * /usr/local/bin/mirror-sync epel
30 */6 * * * /usr/local/bin/mirror-sync debian
```

**5. Rotate the logs**

```
/var/log/mirror-sync/*.log {
    rotate 7
    create 644 mirror mirror
    daily
    missingok
    notifempty
    sharedscripts
    copytruncate
    compress
}
```

## How the configuration file works

The configuration file is `/etc/mirror-sync.conf` and is **formatted in bash**. It is required; the script exits if it is missing.

Set `MIRROR_SYNC_CONF` to read a different file, which is what testing a change or running a mirror entirely out of a home directory needs, as neither can write to `/etc`. Both `mirror-sync` and `mirror-file-generator` read the variable and share the file.

```bash
MIRROR_SYNC_CONF=~/mirror-sync.conf mirror-sync epel
```

Two rules cover everything:

**Rule 1 — `MODULES` lists your modules.** Each module is one repository to sync. The script only knows about modules named here.

```bash
MODULES="epel debian alpine"
```

**Rule 2 — every module setting is the module name, an underscore, then the setting name.** Throughout this document settings are documented by their bare name (`repo`, `source`, `options`). What you actually write in the file is that name with the module's prefix:

| Setting documented as | For module `epel`, you write | For module `debian`, you write |
| --- | --- | --- |
| `repo` | `epel_repo` | `debian_repo` |
| `sync_method` | `epel_sync_method` | `debian_sync_method` |
| `source` | `epel_source` | `debian_source` |
| `options` | `epel_options` | `debian_options` |

There is no separate section or block syntax. A module is simply the set of variables sharing its prefix.

### Things that commonly go wrong

- **A module name must be a valid bash variable name** — letters, digits and underscores only, not starting with a digit. `my-repo` and `centos.9` cannot work, because the script builds variable names by joining the module name to the setting name. Use `my_repo` or `centos9`.
- **`MODULES` is easy to forget.** If you paste an example from this document without adding its module name to `MODULES`, the script reports `MODULES: parameter null or not set`, or `Unknown module`.
- **The prefix must match the name in `MODULES` exactly**, including case. A module listed as `epel` with settings written as `EPEL_repo` has no configuration, and the script reports `No configuration exists for epel`.
- **It is bash, so quoting matters.** Values containing spaces, globs or `#` need quotes: `epel_options="--exclude '.~tmp~'"`.
- **Booleans accept `true`, `false`, `1` or `0`** in any capitalization. Anything else is a hard error naming the setting, so `prune="yes"` stops the run rather than being quietly read as its opposite.

## Global settings

These are written without any prefix and apply to every module.

### Core

| Setting | Default | Description |
| --- | --- | --- |
| `MODULES` | *(required)* | The modules to sync, separated by spaces. |
| `MAILTO` | *(none)* | Email address errors are mailed to. |
| `PIDPATH` | `/tmp` | Where pid files are stored to prevent duplicate module syncs. Must be writable by the mirror user. |
| `LOGPATH` | `/var/log/mirror-sync` | Where logs are stored. Must be writable by the mirror user. |
| `sync_timeout` | `timeout 1d` | Timeout before a sync is cancelled. Works for most mirrors as-is. |
| `max_errors` | `3` | How many consecutive errors before an email is sent, so anomalies can be ignored. |
| `upstream_max_age` | `18000` (5 hours) | If the upstream last modified date is older than this many seconds, the upstream check skips syncing. |
| `upstream_timestamp_min` | `86400` (24 hours) | Minimum age in seconds of the last successful sync before the next sync will skip the upstream check. |
| `dusum_human_readable_total_file` | *(none)* | Path to save a grand total of each disk usage sum in human readable form. |
| `dusum_kbytes_total_file` | *(none)* | Path to save a grand total of each disk usage sum in kilobytes. |

### Mirror identity

These fill in the [trace files](#trace-files) and are set once for the whole server.

| Setting | Default | Description |
| --- | --- | --- |
| `save_trace` | `true` | Whether to publish a trace file after each successful sync. Every method except git honors it. Override per module with `save_trace`. |
| `mirror_hostname` | FQDN hostname | The hostname of this mirror server. Set this to your public mirror domain if you have one. |
| `TRACEHOST` | FQDN hostname | The hostname to show in trace project files. |
| `INFO_MAINTAINER` | *(none)* | The maintainer of this repository, in `name <email>` format. |
| `INFO_SPONSOR` | *(none)* | The sponsors of this repo, if it is sponsored. |
| `INFO_COUNTRY` | *(none)* | The country this server resides in. |
| `INFO_LOCATION` | *(none)* | The region this server resides in (state/province). |
| `INFO_THROUGHPUT` | *(none)* | How fast the pipes to your repository are. |
| `INFO_TRIGGER` | auto detected | How the sync occurred, cron or ssh. Detected automatically; you do not need to set this. |

### Tool paths

Only needed when a tool is installed somewhere other than the default.

| Setting | Default | Description |
| --- | --- | --- |
| `QFM_PATH` | `$HOME/quick-fedora-mirror` | Where quick-fedora-mirror is located and its configurations are saved. |
| `QFM_BIN` | `$QFM_PATH/quick-fedora-mirror` | The quick-fedora-mirror binary. If you override `QFM_PATH` you will likely need to override this too. |
| `S5CMD_BIN` | `$HOME/bin/s5cmd` | The s5cmd binary, which this tool auto installs. |
| `REPO_SYNC_BIN` | `$HOME/bin/repo-sync` | The repo-sync binary, which this tool auto installs. |
| `JIGDO_FILE_BIN` | `$HOME/bin/jigdo-file` | The `jigdo-file` binary, if jigdo is installed outside the home directory. |
| `JIGDO_MIRROR_BIN` | `$HOME/bin/jigdo-mirror` | The `jigdo-mirror` binary, if jigdo is installed outside the home directory. |
| `jigdoConf` | `$HOME/etc/jigdo/jigdo-mirror.conf` | Base configuration file name used when building ISO images. The jigdo hook saves configurations as `${jigdoConf}.${arch}.${s}`. |

## Module settings

Remember the prefix: a setting shown as `repo` is written `<module>_repo`.

Every module supports these, whatever its sync method:

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `repo` | **yes** | — | The destination directory of the repository. The script exits with `No configuration exists for <module>` if this is unset. |
| `sync_method` | no | `rsync` | One of `rsync`, `git`, `aws`, `s3cmd`, `s5cmd`, `repo-sync`, `ftp`, `wget`, `qfm`. |
| `timestamp` | no | *(none)* | Path to a file storing the last successful sync unix timestamp. Useful for monitoring that each repo is syncing. Required if you use `upstream_check`. |
| `dusum` | no | *(none)* | Path to a file storing the disk usage summary of the repository directory. |
| `save_trace` | no | global `save_trace` | Whether this module publishes a trace file. A module setting always beats the global one. Not used by git, which never writes one. |
| `post_successful_sync_hook` | no | *(none)* | A hook to run at the very end of any sync method, after all cleanup has completed and the sync has been confirmed successful. Unlike the rsync/qfm `post_hook`, this runs after trace files, log cleanup and mirror reporting are finished, and it is available for every sync method. See [change counts in hooks](#change-counts-in-hooks). |

## Change counts in hooks

Most syncs find nothing new. Every sync method counts what it changed and hands the result to the hooks, so a hook can stay idle on a run that brought nothing down:

```bash
epel_post_successful_sync_hook='[[ $SYNC_CHANGED ]] && systemctl reload nginx'
```

| Variable | Description |
| --- | --- |
| `SYNC_CHANGED` | `true` when the sync changed something, empty when it did not. Test it with `[[ $SYNC_CHANGED ]]`. |
| `SYNC_FILES_CHANGED` | Transferred plus deleted. |
| `SYNC_FILES_TRANSFERRED` | Files received from upstream, whether new or updated. |
| `SYNC_FILES_DELETED` | Files removed because upstream no longer publishes them. |
| `SYNC_REFS_UPDATED` | The git method only: refs that moved, appeared or were deleted. `0` everywhere else. |

The variables are exported, so a hook that calls a script of its own gets them too. They are set before every hook that runs after a sync: `post_successful_sync_hook` for every method, and the rsync and qfm `post_hook`.

Each method counts what its own tool reports, so the counts are a statement of what that method moved rather than a number to compare between methods. `SYNC_CHANGED` is the dependable part.

| Method | Counted from |
| --- | --- |
| `rsync`, `qfm` | The itemized change lines rsync prints, one per item it acted on. Both rsync stages count toward one total, as does each module qfm synchronized. Directories are left out, since one is restamped whenever anything inside it changes, and so are the trace files this script rewrites after every sync — without that, a mirror publishing a trace would report a change on every run. |
| `git` | The refs that differ from before the sync, and for a working tree the files that differ between the commit checked out before and the one checked out now. A bare mirror has no working tree, so its file counts stay `0` and `SYNC_REFS_UPDATED` carries the change. A first clone counts its whole tree. |
| `repo-sync` | Its run summary, which states outright whether the repository changed. |
| `aws`, `s3cmd`, `s5cmd` | The line the client prints for each object it downloads or removes. |
| `ftp` | The commands lftp logged, one per file it transferred or removed. Removed directories are not counted. |
| `wget` | The count wget reports having downloaded. wget never deletes, so `SYNC_FILES_DELETED` is always `0`, and a mirror run that re-fetches an unchanged index does not descend into it, so a change behind an unchanged index is not seen until the index changes. |

## Sync methods

Pick the method that matches how upstream publishes:

| Method | Use when |
| --- | --- |
| [`rsync`](#rsync) | Upstream runs an rsync daemon. **The most common choice**, and the default. |
| [`qfm`](#qfm) | Upstream is a Fedora tier 1 mirror, or another rsync server following the Fedora module layout. |
| [`repo-sync`](#repo-sync) | Upstream publishes over http(s) only, and it is an rpm, deb, arch or apk repository. |
| [`git`](#git) | Mirroring a git repository. |
| [`aws`](#aws) / [`s3cmd`](#s3cmd) / [`s5cmd`](#s5cmd) | Upstream is an S3 bucket. |
| [`ftp`](#ftp) | Upstream is FTP, or http with no repository metadata. |
| [`wget`](#wget) | Simple recursive http(s) copy. |

### rsync

By far the most common mirror method is rsync. It, while not perfect, is more efficient than using wget or ftp mirroring. You will need the rsync package installed.

This method supports an extra CLI argument, `--force`, which bypasses upstream checks and synchronizes immediately.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | **yes** | — | The rsync server or ssh server URL. |
| `options` | no | *(none)* | Synchronization options for the first rsync stage. |
| `options_stage2` | no | *(none)* | Options for a second rsync stage, if your repo needs one. The most basic value, if you just want to force stage 2 to occur, is `--exclude '.~tmp~'`. |
| `type` | no | *(none)* | What type of repo is being synced, for the trace file. One of `deb`, `rpm`, `iso`, `source`. |
| `arch_configurations` | no | *(none)* | Which architectures are synchronized to this mirror, for the trace file. |
| `upstream_check` | no | *(none)* | An http URL whose last modified date indicates whether upstream changed recently, to lower the impact on upstream mirrors. Needs `timestamp` set. See the global `upstream_timestamp_min` and `upstream_max_age`. |
| `time_file_check` | no | *(none)* | Name of a time file to check before syncing all files, to reduce load on upstream. |
| `rsync_password` | no | *(none)* | Password for authenticating with an rsync server. |
| `report_mirror` | no | *(none)* | Path to a `report_mirror` configuration, run after a successful sync if you need to report status back to Fedora. |
| `pre_hook` | no | *(none)* | A hook to run prior to the first stage sync. |
| `pre_stage2_hook` | no | *(none)* | A hook to run prior to the second stage sync. |
| `post_hook` | no | *(none)* | A hook to call after a successful sync. If you are using jigdo, the hook is `jigdo_hook`. See [change counts in hooks](#change-counts-in-hooks). |
| `jigdo_pkg_repo` | no | *(none)* | Path to the repo of packages, if you are using jigdo to build ISO images. |

#### Examples

RPM based mirror:

```bash
MODULES="example"

example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://rsync.example.org/module/"
example_options="--exclude '.~tmp~' --exclude 'repodata/*'"
example_options_stage2="--exclude '.~tmp~'"
example_type="rpm"
```

<details>
<summary>DEB based mirror</summary>

```bash
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://rsync.example.org/module/"
example_options="--exclude '.~tmp~' --include=*.diff/ --exclude=*.diff/Index --exclude=Packages* --exclude=Sources* --exclude=Release* --exclude=InRelease --include=i18n/by-hash --exclude=i18n/* --exclude=ls-lR*"
example_options_stage2="--exclude '.~tmp~'"
example_type="deb"
```

</details>

<details>
<summary>Mirror with jigdo ISO building</summary>

```bash
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://rsync.example.org/module/"
example_options="--exclude '.~tmp~' --exclude '*.iso'"
example_pre_stage2_hook="jigdo_hook"
example_jigdo_pkg_repo="/home/mirror/http/debian/"
example_options_stage2="--exclude '.~tmp~'"
example_type="iso"
```

</details>

### qfm

Quick Fedora Mirror helps Fedora mirrors distribute changes faster and save resources discovering what needs to be synced. You must have both the rsync and zsh packages installed. This tool automatically downloads QFM if you do not already have it.

The upstream mirror must offer a module with sub modules designed for quick-fedora-mirror. You can use this with non-Fedora mirrors, but they must follow the Fedora module layout. For Fedora, use a [tier 1 mirror](https://fedoraproject.org/wiki/Infrastructure/Mirroring/Tiering#Tier_1_mirrors).

List the modules available on an rsync server with:

```bash
rsync --list-only rsync://SERVER
```

And list the files in a module with:

```bash
rsync --list-only rsync://SERVER/MODULE
```

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `repo` | **yes** | — | **Differs from other methods**: QFM requires this to be the `$DOCROOT`, into which it copies modules. |
| `source` | **yes** | — | The source rsync server, without any modules appended. |
| `modules` | **yes** | — | The sub modules to sync. Only one sub module is recommended. Defaults available upstream are `fedora-alt`, `fedora-archive`, `fedora-enchilada`, `fedora-epel`, `fedora-secondary`. |
| `master_module` | no | `fedora-buffet` | The main rsync module under which the Fedora sub module directories exist. |
| `module_mapping` | no | *(none)* | A custom sub module mapping, for use with non-Fedora mirrors. |
| `mirror_manager_mapping` | no | *(none)* | The names for a custom module mapping. |
| `filterexp` | no | *(none)* | Regular expression filtering out particular directories/files. |
| `options` | no | *(none)* | Extra options to pass to quick-fedora-mirror. |
| `rsync_options` | no | *(none)* | Extra options to pass to rsync during sync. |
| `type` | no | *(none)* | What type of repo is being synced, for the trace file. One of `deb`, `rpm`, `iso`, `source`. |
| `arch_configurations` | no | *(none)* | Which architectures are synchronized to this mirror, for the trace file. |
| `rsync_password` | no | *(none)* | Password for authenticating with an rsync server. |
| `report_mirror` | no | *(none)* | Path to a `report_mirror` configuration, run after a successful sync. |
| `pre_hook` | no | *(none)* | A hook to run prior to running QFM. |
| `post_hook` | no | *(none)* | A hook to call after a successful sync. See [change counts in hooks](#change-counts-in-hooks). |

#### Example

```bash
MODULES="example"

example_sync_method="qfm"
example_repo="/home/mirror/http/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://mirrors.example.com"
example_modules="fedora-enchilada"
example_report_mirror="/home/mirror/report_mirror.conf"
example_type="rpm"
```

### repo-sync

Synchronize a Linux package repository over http(s) using [repo-sync](https://github.com/grmrgecko/repo-sync). The repo-sync binary auto installs if not present.

Unlike `wget` or `ftp`, which copy whatever files they find, repo-sync reads the repository's own metadata (`repodata/repomd.xml`, `dists/<suite>/Release`, `<name>.db`, `APKINDEX.tar.gz`) and downloads only the files that metadata references, verifying their checksums. The upstream layout is preserved so the destination can be served directly to package managers. This makes it a good fit for upstreams that publish over http only, with no rsync daemon available.

Each repository is identified by its own metadata, so no format has to be stated: an upstream publishing both yum and apt repositories is mirrored by one module in one run.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | **yes** | — | The repository or mirrorlist URL to mirror from. Multiple URLs may be given separated by spaces, and are synchronized one after another into the same destination. |
| `type` | no | *(every format)* | Limit the run to these repository formats: `rpm`, `deb`, `arch`, `apk`. Several may be listed, separated by spaces or commas. A module limited to a single format synchronizes every URL as that format rather than identifying it, which is what a mirrorlist or metalink URL needs. |
| `prune` | no | `true` | Delete files upstream no longer publishes, matching the delete behavior of other methods. Set `false` for repositories where old packages should stay available. |
| `save_trace` | no | global `save_trace` | Traces follow the global setting as with every method, but repo-sync publishes them itself. See below. |
| `options` | no | *(none)* | Extra options passed to `repo-sync` ahead of the sub command, for options applying to every command: `--config-path`, `--log-level`, `--user-agent`, `--request-timeout`. |
| `sync_options` | no | *(none)* | Extra options passed to `repo-sync sync`. See the list below. |

**`type` values**

- `rpm` — yum/dnf repositories, including plain-text mirrorlist and metalink URLs with failover between mirrors.
- `deb` — apt repositories, both standard (`dists/<suite>` with a shared `pool/`) and flat layouts, including `Acquire-By-Hash` population.
- `arch` — pacman repositories, including detached package signatures and companion metadata.
- `apk` — Alpine Linux repositories.

**Common `sync_options`**

- `--trim N` — drop this many leading URL path components when building the destination path.
- `--flat` — place the repository directly in the destination without copying the URL path. Useful with metalink URLs, where each mirror's path differs.
- `--discover` — treat each URL as a directory index and crawl it for repositories.
- `--depth N` — maximum directory depth crawled in discovery mode. Defaults to 5.
- `--exclude GLOB` — keep part of a discovery crawl out of the mirror. Matched against the entry name wherever it appears in the tree, or against the path below the crawled URL when the pattern contains a slash. Repeatable, and an excluded directory is never listed, so nothing below it is mirrored either.
- `--include-file GLOB` — mirror loose files the crawl passes that no repository's metadata lists, such as signing keys or packages published outside a repository. Matched against the file name, repeatable, and only files in directories that are not repositories are considered. These are revalidated against their modification time rather than a checksum, and `--prune` never removes them.
- `--workers N` — number of concurrent download workers.
- `--verify` — re-verify checksums of files that already exist locally.
- `--prune-grace` — keep files that left the repository for this long before pruning them, for example `72h`.
- `--dry-run` — report what would be downloaded or pruned without changing the repository.
- `--component` and `--arch` — limit an apt mirror to specific components and architectures. Include `source` as an architecture to keep source indexes. Applies to `deb` repositories only.

**Trace files**

Traces land inside each repository synchronized, at `project/trace/<mirror_hostname>`, or at the archive root for apt. The details recorded come from `mirror_hostname` and the `INFO_*` settings, so they are configured once globally and passed through to repo-sync rather than repeated in a repo-sync config file. Unset values are omitted from the trace, and the setting is passed either way so a repo-sync config file cannot contradict it.

Because repo-sync writes the trace, it records the mirror it actually fetched from, which for a mirrorlist or metalink is the mirror that answered rather than the configured URL.

#### Examples

By default the URL path is copied below the destination, so this produces `/home/mirror/http/example/repos/CentOS/7/EA4/`. The repository identifies itself, so no `type` is needed:

```bash
MODULES="example"

example_sync_method="repo-sync"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_source="https://repos.example.com/repos/CentOS/7/EA4/"
```

<details>
<summary>Metalink URL, where mirrors' paths differ</summary>

Nothing can be identified through a metalink, so the `type` is stated, and `--flat` keeps the destination stable regardless of which mirror answers:

```bash
example_sync_method="repo-sync"
example_type="rpm"
example_repo="/home/mirror/http/epel9"
example_timestamp="/home/mirror/timestamp/epel9"
example_source="https://mirrors.fedoraproject.org/metalink?repo=epel-9&arch=x86_64"
example_sync_options="--flat"
```

</details>

<details>
<summary>apt suite limited to one component and architecture</summary>

Mirroring two suites in one run. A trace is published at `/home/mirror/http/debian/project/trace/` without configuring anything, as tracing is on by default:

```bash
example_sync_method="repo-sync"
example_repo="/home/mirror/http/debian"
example_timestamp="/home/mirror/timestamp/debian"
example_source="https://deb.example.com/debian/dists/bookworm https://deb.example.com/debian/dists/trixie"
example_sync_options="--component main --arch amd64,source"
```

</details>

<details>
<summary>Alpine repository, discovering every architecture</summary>

Discovers a whole release/repo tree in one run and keeps old packages:

```bash
example_sync_method="repo-sync"
example_repo="/home/mirror/http/alpine"
example_timestamp="/home/mirror/timestamp/alpine"
example_source="https://dl-cdn.alpinelinux.org/alpine/v3.24/community/"
example_sync_options="--discover --depth 1"
example_prune="false"
```

</details>

<details>
<summary>A vendor archive of mixed formats, crawled in one run</summary>

Mirrors the yum and apt repositories one upstream publishes, skipping the distributions this mirror does not serve, and keeping the signing keys and loose packages published outside the repositories:

```bash
example_sync_method="repo-sync"
example_repo="/home/mirror/http/mysql"
example_timestamp="/home/mirror/timestamp/mysql"
example_source="http://repo.mysql.com/"
example_sync_options="--discover --depth 6 --exclude sles --exclude 'fc*' --exclude docker --include-file '*.rpm' --include-file '*.deb' --include-file 'RPM-GPG-KEY-mysql*'"
```

</details>

### git

Synchronizes a git repository. You need the git package installed.

If the destination (`repo`) does not yet contain a git repository, it is cloned from the configured `source`. Otherwise it is updated in place. Bare repositories have no working tree, so they cannot be updated with `git pull`; instead the script clones them with `git clone --mirror` and updates them with `git remote update --prune`, which honors the repository's configured fetch refspec.

Bare repositories are usually served to clients over "dumb" HTTP (a plain file server). After each successful sync (and after the initial clone) the script runs `git update-server-info` so the `info/refs` and `objects/info/packs` files clients need stay up to date. This runs every time rather than being detected, as it is cheap; the packaged `post-update` hook cannot be relied on because it only fires on push, never on the fetch a mirror performs.

This is the one method that never publishes a trace file, so `save_trace` does not apply to it.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | **yes**, when cloning | — | The git URL to clone from. Required when the destination does not already contain a git repository. |
| `bare` | no | auto-detected | Set `true` to treat the repository as bare, which clones with `git clone --mirror` and updates with `git remote update --prune` (or a direct fetch when `hide_remote` is set). If unset, existing repositories are auto-detected. `false` forces treatment as a working tree. |
| `hide_remote` | no | `false` | Set `true` (requires `bare` and `source`) to keep the upstream URL out of the served repository. See below. |
| `options` | no | *(none)* | Extra options appended to the git command: `git clone` when cloning, `git pull` when updating a working tree, or `git remote update --prune` / `git fetch` when updating a bare repository. |

**`hide_remote`** keeps the upstream URL out of the served repository so clients cannot probe the dumb-HTTP files to discover where the mirror pulls from. When enabled, the stored remote is removed from the repository's `config` and the `FETCH_HEAD` file (which records the URL on every fetch) is deleted after each sync. Because there is no stored remote to update, the sync fetches directly from `source` with a mirror refspec (`+refs/*:refs/*`) on each run.

#### Examples

Working tree:

```bash
MODULES="example"

example_sync_method="git"
example_source="https://github.com/example/example.git"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
```

<details>
<summary>Bare repository</summary>

```bash
example_sync_method="git"
example_source="https://github.com/example/example.git"
example_repo="/home/mirror/git/example.git"
example_bare="true"
example_timestamp="/home/mirror/timestamp/example"
# Optional: keep the upstream URL out of the served files.
example_hide_remote="true"
```

</details>

### aws

Synchronize with an S3 bucket using the aws cli. You need the aws cli package installed.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `aws_bucket` | **yes** | — | The bucket URL to sync with. |
| `aws_access_key` | no | *(none)* | The access key for the S3 bucket. |
| `aws_secret_key` | no | *(none)* | The secret for the S3 bucket. |
| `aws_endpoint_url` | no | *(none)* | Endpoint URL, if you are using a third party S3 compatible service. |
| `options` | no | *(none)* | Extra options to append to `aws s3 sync`. |

#### Example

```bash
MODULES="example"

example_sync_method="aws"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

### s3cmd

Synchronize with an S3 bucket using s3cmd. You need the s3cmd package installed.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `aws_bucket` | **yes** | — | The bucket URL to sync with. |
| `aws_access_key` | no | *(none)* | The access key for the S3 bucket. |
| `aws_secret_key` | no | *(none)* | The secret for the S3 bucket. |
| `aws_endpoint_url` | no | *(none)* | Endpoint URL for a third party S3 compatible service, in `HOSTNAME:PORT` format. |
| `options` | no | *(none)* | Extra options to append to `s3cmd`. |

#### Examples

```bash
MODULES="example"

example_sync_method="s3cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

<details>
<summary>Third party bucket</summary>

```bash
example_sync_method="s3cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
example_options="--host='objects.example.com' --host-bucket='%(bucket).objects.example.com'"
```

</details>

### s5cmd

Synchronize with an S3 bucket using s5cmd. The s5cmd binary auto installs if not present.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `aws_bucket` | **yes** | — | The bucket URL to sync with. **Must end with `*`** for s5cmd to work. |
| `aws_access_key` | no | *(none)* | The access key for the S3 bucket. |
| `aws_secret_key` | no | *(none)* | The secret for the S3 bucket. |
| `aws_endpoint_url` | no | *(none)* | Endpoint URL, if you are using a third party S3 compatible service. |
| `options` | no | *(none)* | Extra options to append to `s5cmd`. |
| `sync_options` | no | *(none)* | Extra options to append to the `sync` command of s5cmd. |

#### Example

```bash
MODULES="example"

example_sync_method="s5cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory/*"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

### ftp

Synchronize both http and ftp sources to a repo. Requires the lftp package.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | **yes** | — | The source URL to mirror from. |
| `options` | no | *(none)* | Extra options to append to the mirror command of lftp. |

#### Example

```bash
MODULES="example"

example_sync_method="ftp"
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="https://repos.example.com/rhel/7/x86_64/stable"
```

### wget

Synchronizes using wget. You need the wget package installed.

| Setting | Required | Default | Description |
| --- | --- | --- | --- |
| `source` | **yes** | — | The source URL to mirror from. |
| `options` | no | `--mirror --no-host-directories --no-parent` | The options passed to wget. Setting this replaces the default entirely. |

#### Example

```bash
MODULES="example"

example_sync_method="wget"
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="https://repos.example.com/rhel/7/x86_64/stable"
example_options="--mirror --no-host-directories --no-parent --cut-dirs=4"
```

## Trace files

Every sync method except git publishes a trace file at `<repo>/project/trace/<mirror_hostname>` after a successful sync, following the convention Debian archives established. Downstream mirrors and mirror checkers read it to learn who runs a mirror, where it is, and when it last synchronized. Alongside it, `_hierarchy` lists every mirror the content passed through and `_traces` lists the trace files present.

The contents come from the [`INFO_*` settings](#mirror-identity), `mirror_hostname` and `TRACEHOST`, so they are set once and apply to every module. The `Architectures` line is filled in for rsync and qfm modules that set `type`, and `Upstream-mirror` names the host the module syncs from.

Traces are on by default. Turn them off globally with `save_trace="false"`, or per module with `<module>_save_trace="false"`; a module setting always wins over the global one.

Methods that delete files upstream no longer has are told to leave this mirror's own trace alone, since it exists only locally and would otherwise be treated as removed. Two methods differ from the rest:

- **git** publishes no trace at all, and `save_trace` does not apply to it. A trace is an ordinary file inside the repository: in a checked-out working tree it is untracked and leaves the tree permanently dirty, and in a bare repository it means dropping a directory that is not part of the object store into the repository root. Naming the upstream would also work against `hide_remote`.
- **repo-sync** writes its own traces rather than having this script write them, so each records the mirror it actually fetched from, which for a mirrorlist or metalink is the one that answered. The `INFO_*` values are passed through to it, and `save_trace` switches it on or off the same way.

## CLI options

```
mirror-sync [--help|--update-support-utilities|--version] {module} [--force]
```

One module per invocation. `--force` applies to the rsync method only, where it bypasses the upstream check. Running with no arguments, or with an unknown module, prints the help along with the list of modules found in your configuration.

`MIRROR_SYNC_CONF` in the environment names the configuration file to read, in place of `/etc/mirror-sync.conf`.

## Requirements

- bash
- zsh
- sendmail
- git
- awscli
- s3cmd
- lftp
- wget
- curl
- rsync
- jq
- tar
- jigdo — this tool auto installs.
- quick-fedora-mirror — this tool auto installs.
- s5cmd — this tool auto installs.
- repo-sync — this tool auto installs.

### Install on RPM based servers

```bash
yum install bash zsh sendmail git awscli s3cmd lftp wget curl rsync jq tar
```

### Install on DEB based servers

```bash
apt install bash zsh sendmail git awscli s3cmd lftp wget curl rsync jq tar
```

### Install on Arch

```bash
yay -S bash zsh sendmail git aws-cli-git s3cmd lftp wget curl rsync jq tar
```
