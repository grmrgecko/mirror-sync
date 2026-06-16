# mirror-sync
A tool to mirror repositories for Linux and other similar tools. This tool is designed to help follow upstream mirror instructions, and implement the features they expect from a downstream official mirror. It also includes features to help keep you in the loop in case of situations that need manual intervention.

## Configuration
It is suggested that you mirror using a sub user account, this tool prevents execution as root to protect you. Once you have an user account dedicated to mirror activities, you can make the log directory, configure logrotate, and add a configuration file to define configurations.

### Making log directory
```bash
mkdir -p /var/log/mirror-sync/
chown mirror: /var/log/mirror-sync/
```

### Configuration for logrotate
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

### Configuring mirror-sync
The configuration file is in `/etc/mirror-sync.conf` and is formatted in bash.

## Main configurations
### MODULES
The available modules separated by space. Each module is a separate repository to sync, and this list allows the script to know how to find their configs.

### TRACEHOST
The hostname to show in trace project files, it defaults to the FQDN hostname of the server.

### mirror_hostname
The hostname of this mirror server, it defaults to the FQDN hostname of the server. If you have a public domain for your mirror, you may wish to adjust this configurtion to that.

### PIDPATH
If you wish to override where pid files are stored to prevent duplicate module syncs, the default is `/tmp` and the directory must have write access for the mirror user.

### LOGPATH
If you wish to override where logs are stored, the default is `/var/log/mirror-sync` and the directory must have write access for the mirror user.

### sync_timeout
Timeout before a sync is cancelled, defaults to `timeout 1d` which should work for most mirrors.

### max_errors
How many errors before an email is sent regarding the issue. This allows you to ignore anomalies.

### upstream_max_age
If the upstream last modified date is older than the defined number of seconds, the upstream check will skip syncing. Default is 5 hours.

### upstream_timestamp_min
If an upstream check is configured, this defines the minimum age in seconds of the last successful sync before the next sync will skip the upstream check. Default is 24 hours.

### QFM_PATH
Path to where quick-fedora-mirror is located and configurations are saved. If you already have QFM installed, but want configurations stored separately. You can use the `QFM_BIN` configuration to set the QFM binary path.

### QFM_BIN
The binary path for quick-fedora-mirror. If you override `QFM_PATH`, you will likely also have to override this path. Default:
```bash
QFM_BIN="$QFM_PATH/quick-fedora-mirror"
```

### JIGDO_FILE_BIN
If you installed jigdo outside of the home directory, you need to manually configure the `jigdo-file` binary path here.

### JIGDO_MIRROR_BIN
If you installed jigdo outside of the home directory, you need to manually configure the `jigdo-mirror` binary path here.

### jigdoConf
If you use jigdo to build ISO images, this is the base configuration file name. The jigdo hook saves configurations in `${jigdoConf:?}.${arch}.${s}` format.

### MAILTO
The email address of which to mail errors to.

### INFO_MAINTAINER
The maintainer of this repository, should be defined in `name <email>` format.

### INFO_SPONSOR
If this repo is sponsored, you may define the sponsors here.

### INFO_COUNTRY
The country of which this server resides.

### INFO_LOCATION
The region of which this server resides (state/providence).

### INFO_THROUGHPUT
How fast are the pipes to your repository.

### INFO_TRIGGER
How did the sync occur, cron job or manually via ssh? This is auto detected and you do not need to define this configuration.

### dusum_human_readable_total_file
Path to save a grand total of each disk usage sum in human readable form.

### dusum_kbytes_total_file
Path to save a grand total of each disk usage sum in kilobytes.

## Module specific configurations
Each module is configured via configurations prefixed by the module name. The one configuration used by all modules is the `_sync_method` configuration which defines what sync method to use. Each sync method has different configurations available. The default sync method is rsync.

Each repo has at bare minimum the following configurations:

- sync_method - rsync, git, aws, s3cmd, ftp, wget, or qfm.
- repo - The destination directory of the repository.
- timestamp - Path to a file to store the last successful sync unix time stamp. Can be used by a monitoring system to confirm each repo is syncing successfully.
- dusum - Path to a file to store disk usage summary results of the repository directory.

### git
Synchronizes a git repository. To use this method, you need to have the git package installed.

If the destination (`repo`) does not yet contain a git repository, it is cloned from the configured `source`. Otherwise it is updated in place. Bare repositories have no working tree, so they cannot be updated with `git pull`; instead the script clones them with `git clone --mirror` and updates them with `git remote update --prune`, which honors the repository's configured fetch refspec.

Whether a repository is bare can be set explicitly with the `bare` configuration, otherwise existing repositories are auto-detected.

#### source
The git URL to clone the repository from. Required when the destination does not already contain a git repository.

#### bare
Set to `true` to treat the repository as bare. When cloning, this clones with `git clone --mirror`. When updating, this forces use of `git remote update --prune`. If unset, existing repositories are auto-detected.

#### options
Extra options appended to the git command (`git clone` when cloning, `git pull` when updating a working-tree repository, or `git remote update --prune` when updating a bare repository).

#### Example
```bash
example_sync_method="git"
example_source="https://github.com/example/example.git"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
```

#### Bare repository example
```bash
example_sync_method="git"
example_source="https://github.com/example/example.git"
example_repo="/home/mirror/git/example.git"
example_bare="true"
example_timestamp="/home/mirror/timestamp/example"
```

### aws
Synchronize with an s3 bucket using aws cli. To use this, you need the aws cli package installed.

#### aws_bucket
The bucket URL to sync with.

#### aws_access_key
The access key for the s3 bucket.

#### aws_secret_key
The secret for the s3 bucket.

#### aws_endpoint_url
If you are using a third party S3 compatible service, you can enter their endpoint URL here.

#### options
Extra options to append to `aws s3 sync`.

#### Example
```bash
example_sync_method="aws"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

### s3cmd
Synchronize with an s3 bucket using s3cmd. To use this, you need the s3cmd package installed.

#### aws_bucket
The bucket URL to sync with.

#### aws_access_key
The access key for the s3 bucket.

#### aws_secret_key
The secret for the s3 bucket.

#### aws_endpoint_url
If you are using a third party S3 compatible service, you can enter their endpoint URL here in format of HOSTNAME:PORT.

#### options
Extra options to append to `s3cmd`.

#### Example
```bash
example_sync_method="s3cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

Example of using third party bucket:
```bash
example_sync_method="s3cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
example_options="--host='objects.example.com' --host-bucket='%(bucket).objects.example.com'"
```

### s5cmd
Synchronize with an s3 bucket using s5cmd. The s5cmd will auto install if not existing.

#### aws_bucket
The bucket URL to sync with. You must end the bucket url with `*` for s5cmd to work.

#### aws_access_key
The access key for the s3 bucket.

#### aws_secret_key
The secret for the s3 bucket.

#### aws_endpoint_url
If you are using a third party S3 compatible service, you can enter their endpoint URL here.

#### options
Extra options to append to `s5cmd`.

#### sync_options
Extra options to append to the `sync` command of s5cmd.

#### Example
```bash
example_sync_method="s5cmd"
example_repo="/home/mirror/http/example"
example_timestamp="/home/mirror/timestamp/example"
example_aws_bucket="s3://bucket/directory/*"
example_aws_access_key="RANDOM_KEY_FROM_PROVIDER"
example_aws_secret_key="RANDOM_SECRET_FROM_PROVIDER"
```

### ftp
Synchronize both http and ftp sources to a repo. This sync method requires the lftp package to be installed.

#### source
The source url to mirror from.

#### options
Extra options to append to the mirror command of lftp.

#### Example
```bash
example_sync_method="ftp"
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="https://repos.example.com/rhel/7/x86_64/stable"
```

### wget
Synchronizes using wget to a repository. To use this, you need the wget package installed.

#### source
The source url to mirror from.

#### options
The options passed to wget. Defaults to `--mirror --no-host-directories --no-parent`.

#### Example
```bash
example_sync_method="wget"
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="https://repos.example.com/rhel/7/x86_64/stable"
example_options="--mirror --no-host-directories --no-parent --cut-dirs=4"
```

### rsync
By far, the most common mirror method is to use rsync. It, while not perfect, is more efficent than using wget or ftp mirroring. You will need the rsync package installed for this to function. There is an extra CLI argument available for this sync method, `--force` which allows you to by-pass upstream checks and synchronize immediately.

#### pre_hook
A hook to run prior to the first stage sync.

#### source
The rsync server or ssh server URL.

#### options
Synchronization options for the first rsync stage.

#### options_stage2
If your repo needs a 2 stage rsync, define some options here. The most basic option you can use, if you want to force stage 2 to occur, would be `--exclude '.~tmp~'`.

#### pre_stage2_hook
A hook to run prior to the second stage sync.

#### upstream_check
An http URL to check the last modified date as a reference for if the upstream mirror was possibly modified recently. This option is mainly here to lower the impact on upstream mirrors so that mirroring happens less often. See `upstream_timestamp_min` and `upstream_max_age` for global configuration options of this check.

#### time_file_check
Name of a time file to check if the upstream has updated before syncing all files to reduce load on upstream mirrors.

#### report_mirror
If you have Fedora report mirror installed, and need to report back to Fedora about the status of your repository, you can provide this option a configuration path for the `report_mirror` utility to run the report after a successful sync.

#### rsync_password
If you have an rsync password and need to authenticate with an rsync server, this is where you define the password.

#### post_hook
Any hooks to call after a successful sync, define here. If you are using jigdo, the hook is `jigdo_hook`.

#### jigdo_pkg_repo
If you are using jigdo to build ISO images, you need to define the path to the repo of packages.

#### arch_configurations
Information for trace files on what architectures are synchronized to this mirror.

#### type
For the trace file saving, this defines what type of repo is being synced. Options are deb, rpm, iso, or source.

#### Example
Example for RPM based mirror:
```bash
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://rsync.example.org/module/"
example_options="--exclude '.~tmp~' --exclude 'repodata/*'"
example_options_stage2="--exclude '.~tmp~'"
example_type="rpm"
```

Example for DEB based mirror:
```bash
example_repo="/home/mirror/http/example/"
example_timestamp="/home/mirror/timestamp/example"
example_source="rsync://rsync.example.org/module/"
example_options="--exclude '.~tmp~' --include=*.diff/ --exclude=*.diff/Index --exclude=Packages* --exclude=Sources* --exclude=Release* --exclude=InRelease --include=i18n/by-hash --exclude=i18n/* --exclude=ls-lR*"
example_options_stage2="--exclude '.~tmp~'"
example_type="deb"
```

Example with jigdo:
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

### qfm
Quick Fedora Mirror is a tool to help Fedora mirrors distribute changes faster and save on resources when trying to discover what needs to be synced. To use this method, you must have both the rsync and zsh package installed. This tool automatically downloads QFM if you do not already have it installed.

This tool requires that the upstream mirror has a module with sub modules designed for use with quick-fedora-mirror. You can use this tool with non-fedora mirrors, however they must follow the fedora module configurations. For fedora mirrors, you can utilize [tier 1 mirrors](https://fedoraproject.org/wiki/Infrastructure/Mirroring/Tiering#Tier_1_mirrors).

You can list modules available on an rsync server with:
```bash
rsync --list-only rsync://SERVER
```

And to check a module out, you can list the files with:
```bash
rsync --list-only rsync://SERVER/MODULE
```

#### repo
For the repo config, QFM requires the directory to be `$DOCROOT` which it'll then copy modules into. This is different from all other sync methods.

#### pre_hook
A hook to run prior to running QFM.

#### source
The source rsync server, without any modules appended.

#### master_module
The main rsync module under which the fedora sub module directories exist. Defaults to `fedora-buffet`.

#### module_mapping
If you are using this with a non-fedora mirror, you can define your own custom sub module mapping.

#### mirror_manager_mapping
The names for custom module mapping.

#### modules
The sub modules to sync. It is recommended that you only do one sub module, the modules available by default are fedora-alt, fedora-archive, fedora-enchilada, fedora-epel, and fedora-secondary.

#### options
Extra options to pass to quick-fedora-mirror.

#### filterexp
If you wish to filter out particular directories/files, define regular expression here.

#### rsync_options
Extra options to pass to rsync during sync.

#### report_mirror
If you have Fedora report mirror installed, and need to report back to Fedora about the status of your repository, you can provide this option a configuration path for the `report_mirror` utility to run the report after a successful sync.

#### rsync_password
If you have an rsync password and need to authenticate with an rsync server, this is where you define the password.

#### post_hook
Any hooks to call after a successful sync, define here.

#### arch_configurations
Information for trace files on what architectures are synchronized to this mirror.

#### type
For the trace file saving, this defines what type of repo is being synced. Options are deb, rpm, iso, or source.

#### Example
```bash
example_sync_method=qfm
example_repo='/home/mirror/http/'
example_timestamp='/home/mirror/timestamp/example'
example_source='rsync://mirrors.example.com'
example_modules=fedora-enchilada
example_report_mirror='/home/mirror/report_mirror.conf'
example_type=rpm
```

## CLI Options
There are not that many cli options available, usage is as follows:
```
[--help|--update-support-utilities|--version] {module} [--force]
```

## Requirements list

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
- jigdo - this tool auto installs.
- quick-fedora-mirror - this tool auto installs.

### Install on RPM based servers
```bash
yum install bash zsh sendmail git awscli s3cmd lftp wget curl rsync
```

### Install on DEB based servers
```bash
apt install bash zsh sendmail git awscli s3cmd lftp wget curl rsync
```

### Install on Arch 
```bash
yay -S bash zsh sendmail git aws-cli-git s3cmd lftp wget curl rsync
```

# mirror-file-generator
A tool to generate common mirror info files at the mirror document root.

## Configuration of modules
This tool utilizes the same config file as mirror-sync, and shares the following configurations.

* repo - Used to verify a module is the same repo under the mirror.
* sync_method - Used to determine if qfm mirror.
* timestamp - Used for sync time.
* dusum - Used for disk usage summary.

The tool also adds the following repo-specific configurations:

### section
What section to associate the repo with.

### repo_title
A title for the repo to show instead of the directory name.

### repo_icon
The repo icon, will default to tux if not defined. The icon can be defined as an http(s) link, file path, a file stored in the template directory, or png image name from [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png). The script will automatically make a copy or download the icon to the image folder.

### repo_icon_dark
The dark-mode variant of the repo icon. Accepts the same sources as `repo_icon`. When defined, browsers that detect a dark OS theme will display this icon instead. If omitted, the light icon is used in all themes.

### repo_description
A description to show at the bottom of the repo card.

### repo_skip
This repo should not be put in generated files.

### disable_size_calc
Should be set to a 1 if you do not want a size to be calculated.

### timestamp_file_stat
If you do not have a timestamp file with the UNIX timestamp of the last sync, but there is a file or folder that is updated when changes are made. You can specify the path to that file or folder here and the script will stat it to determine the last sync time.

## Configuration of custom modules
If you have a repo that is not synced via the mirror-sync, but want to customize its look on the generated index.html. You can define a list of custom modules with the `CUSTOM_MODULES` variable, then define any of the following configurations.

* repo
* timestamp
* dusum
* section
* repo_title
* repo_icon
* repo_icon_dark
* repo_description
* repo_skip
* disable_size_calc
* timestamp_file_stat

All of the above configurations behave the same way a regular module behaves.

### Example
```bash
CUSTOM_MODULES="example example2"

example_repo='/home/mirror/http/'
example_section="official"
example_repo_title="Test repo"
example_repo_icon="terminal.png"
example_repo_description="Test, this is a test."

example2_repo='/home/mirror/windows/'
example2_repo_icon="windows.png"
```

## Mirrors
You can define multiple mirrors for this tool to generate files for. Each mirror can have their own templates and repos, and are configured similar to how modules are configured. As such, it is worth maybe pre-pending `mirror_` to your mirror name.

### path
The path to the mirror under which repos are stored.

### title
A title for the mirror, defaults to the name if unset.

### logo
The logo, will default to tux if not defined. The logo can be defined as an http(s) link, file path, a file stored in the template directory, or png image name from [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png). The script will automatically make a copy or download the icon to the image folder.

### logo_dark
The dark-mode variant of the mirror logo. Accepts the same sources as `logo`. When defined, browsers that detect a dark OS theme will display this logo instead. If omitted, the light logo is used in all themes.

### description
A description to place below the logo that can be HTML formatted.

### provider_site
A site for the global footer generation.

### provider_name
A name for the global footer generation.

### Example
```bash
MIRRORS="mirror_example"

mirror_example_path="/home/mirror/mirror_docroot"
mirror_example_title="My company"
mirror_example_logo="http://example.com/logo.png"
mirror_example_logo_dark="http://example.com/logo-dark.png"
mirror_example_description="A public mirror provided by this cool company."
mirror_example_provider_site="http://www.example.com/"
mirror_example_provider_name="Company"
```

## Sections
You can define multiple sections for the index.html with `SECTIONS` variable, it defaults to `official unofficial`. You can then set a default section with `section_default`, which defaults to `unofficial`. A title is auto generated as `{SECTION} Mirrors`, which you can customize with a variable named `section_{SECTION}_title`.

## Templates
Where templates are stored is configured by `template_dir` which defaults to `/usr/local/share/mirror-file-generator/templates`. Default files should be stored under the `default` sub directory, and any customizations to individual mirrors should be saved under a sub directory with that mirror's name. You can add icons/logos into these template directories as well.

Default templates:
* header.html - The main index header.
* section.html - Template for a section.
* repo.html - The repo card template.
* footer.html - The footer of the index.
* footer.txt - Template for the global footer file.

The default `header.html` template includes a `@media (prefers-color-scheme: dark)` CSS block that automatically switches the page to a dark theme when the OS reports a dark preference. The logo and repo icon templates use the HTML `<picture>` element so that a dark variant image is served to dark-mode browsers when `logo_dark` or `repo_icon_dark` is configured.

## Configurations of general defaults.

### index_generate
Whether or not to generate the index.html file.

* 1 Enabled
* 0 Disabled

### index_file_name
If your index file name is different, you can adjust here.

### footer_generate
Whether or not to generate a footer file that can be configured as the mirror's global footer.

* 1 Enabled
* 0 Disabled

### footer_file_name
Alternative file name for the footer file.

### dir_sizes_generate
Whether or not to generate directory sizes file.

* 1 Enabled
* 0 Disabled

### dir_sizes_file_name
Alternative file name for directory sizes file.

### dir_sizes_unknown_path
Path to store directory size summaries for unknown repos.

### dir_sizes_human_readable
Should make human readable or output in kbytes.

* 1 Human readable
* 0 Kbytes

### icons_dir_name
Where to store logos and icons.

### icons_default_source
The default URL to pull icons from, defaults to [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png).

### icons_default_img
A default file to use if icon or logo defined either isn't defined or isn't accessible.

### icons_local_repo
Local path to a cloned copy of the dashboard-icons git repository. When this directory exists, the script serves icons from it instead of fetching them over HTTP, which avoids per-icon network requests. Defaults to `$HOME/dashboard-icons`.

### icons_repo_url
Git URL used to clone the dashboard-icons repository into `icons_local_repo` if it does not already exist. Set to an empty string to disable automatic cloning. Defaults to `https://github.com/homarr-labs/dashboard-icons.git`.

### icons_repo_refresh
How often (in seconds) the local dashboard-icons clone is pulled for updates. Defaults to `604800` (7 days).