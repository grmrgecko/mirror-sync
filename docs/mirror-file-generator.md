# mirror-file-generator

A tool to generate common mirror info files at the mirror document root.

It reads the same `/etc/mirror-sync.conf` file as [mirror-sync](../README.md), and follows the same two configuration rules: `MODULES` lists your modules, and every module setting is written as `<module>_<setting>`. See [How the configuration file works](../README.md#how-the-configuration-file-works) if you have not read it yet. `MIRROR_SYNC_CONF` in the environment names a different file to read, the same as it does for mirror-sync.

## Contents

- [Module settings](#module-settings)
- [Custom modules](#custom-modules)
- [Mirrors](#mirrors)
- [Sections](#sections)
- [Templates](#templates)
- [General defaults](#general-defaults)

## Module settings

These settings are shared with mirror-sync and are read straight from its configuration:

| Setting | Description |
| --- | --- |
| `repo` | Used to verify a module is the same repo under the mirror. |
| `sync_method` | Used to determine if the module is a qfm mirror. |
| `timestamp` | Used for sync time. |
| `dusum` | Used for the disk usage summary. |

These settings are added by this tool:

| Setting | Default | Description |
| --- | --- | --- |
| `section` | `section_default` | What section to associate the repo with. |
| `repo_title` | directory name | A title for the repo to show instead of the directory name. |
| `repo_icon` | tux | The repo icon. May be an http(s) link, a file path, a file stored in the template directory, or a png image name from [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png). The script automatically copies or downloads the icon into the image folder. |
| `repo_icon_dark` | *(none)* | The dark-mode variant of the repo icon, accepting the same sources as `repo_icon`. When set, browsers detecting a dark OS theme display this instead. If omitted, the light icon is used in all themes. |
| `repo_description` | *(none)* | A description to show at the bottom of the repo card. |
| `repo_skip` | *(unset)* | This repo should not be put in generated files. |
| `disable_size_calc` | *(unset)* | Set to `1` if you do not want a size to be calculated. |
| `timestamp_file_stat` | *(none)* | Path to a file or folder that is updated when changes are made, stat'd to determine the last sync time. Use this when you have no timestamp file containing a UNIX timestamp. |

## Custom modules

If you have a repo that is not synced via mirror-sync, but you still want to customize how it looks on the generated `index.html`, list it in `CUSTOM_MODULES` and then configure it with any of the settings below.

`CUSTOM_MODULES` is separate from `MODULES` — a repo goes in one list or the other, never both.

Available settings, all behaving exactly as they do for a regular module:

`repo`, `timestamp`, `dusum`, `section`, `repo_title`, `repo_icon`, `repo_icon_dark`, `repo_description`, `repo_skip`, `disable_size_calc`, `timestamp_file_stat`

### Example

```bash
CUSTOM_MODULES="example example2"

example_repo="/home/mirror/http/"
example_section="official"
example_repo_title="Test repo"
example_repo_icon="terminal.png"
example_repo_description="Test, this is a test."

example2_repo="/home/mirror/windows/"
example2_repo_icon="windows.png"
```

## Mirrors

You can define multiple mirrors for this tool to generate files for. Each mirror can have its own templates and repos, and they are configured the same way modules are — listed in a variable, then configured by prefix. Because mirror names share the same flat namespace, it is worth prefixing your mirror names with `mirror_`.

| Setting | Default | Description |
| --- | --- | --- |
| `path` | *(required)* | The path to the mirror under which repos are stored. |
| `title` | the mirror name | A title for the mirror. |
| `logo` | tux | The logo. May be an http(s) link, a file path, a file stored in the template directory, or a png image name from [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png). The script automatically copies or downloads it into the image folder. |
| `logo_dark` | *(none)* | The dark-mode variant of the mirror logo, accepting the same sources as `logo`. When set, browsers detecting a dark OS theme display this instead. If omitted, the light logo is used in all themes. |
| `description` | *(none)* | A description to place below the logo. May be HTML formatted. |
| `provider_site` | *(none)* | A site for the global footer generation. |
| `provider_name` | *(none)* | A name for the global footer generation. |

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

Define the sections used in `index.html` with the `SECTIONS` variable, which defaults to `official unofficial`. Set a default section with `section_default`, which defaults to `unofficial`. A title is auto generated as `{SECTION} Mirrors`, which you can customize with a variable named `section_{SECTION}_title`.

## Templates

Where templates are stored is configured by `template_dir`, which defaults to `/usr/local/share/mirror-file-generator/templates`. Default files are stored under the `default` sub directory, and customizations for individual mirrors go under a sub directory named after that mirror. You can add icons and logos into these template directories as well.

Default templates:

| File | Purpose |
| --- | --- |
| `header.html` | The main index header. |
| `section.html` | Template for a section. |
| `repo.html` | The repo card template. |
| `footer.html` | The footer of the index. |
| `footer.txt` | Template for the global footer file. |

The default `header.html` includes a `@media (prefers-color-scheme: dark)` CSS block that automatically switches the page to a dark theme when the OS reports a dark preference. The logo and repo icon templates use the HTML `<picture>` element, so a dark variant image is served to dark-mode browsers when `logo_dark` or `repo_icon_dark` is configured.

## General defaults

| Setting | Default | Description |
| --- | --- | --- |
| `index_generate` | `1` | Whether to generate the `index.html` file. `1` enabled, `0` disabled. |
| `index_file_name` | `index.html` | Alternative name for the index file. |
| `footer_generate` | `1` | Whether to generate a footer file that can be configured as the mirror's global footer. `1` enabled, `0` disabled. |
| `footer_file_name` | `footer.txt` | Alternative file name for the footer file. |
| `dir_sizes_generate` | `1` | Whether to generate the directory sizes file. `1` enabled, `0` disabled. |
| `dir_sizes_file_name` | `DIRECTORY_SIZES.TXT` | Alternative file name for the directory sizes file. |
| `dir_sizes_unknown_path` | `$HOME/dusum/unknown_dirs` | Path to store directory size summaries for unknown repos. |
| `dir_sizes_human_readable` | `1` | `1` for human readable, `0` for kbytes. |
| `icons_dir_name` | `img` | Where to store logos and icons, relative to the mirror path. |
| `icons_default_source` | [Dashboard Icons](https://github.com/homarr-labs/dashboard-icons/tree/main/png) | The default URL to pull icons from. |
| `icons_default_img` | `tux.png` | A default file to use if the icon or logo is either undefined or inaccessible. |
| `icons_local_repo` | `$HOME/dashboard-icons` | Local path to a cloned copy of the dashboard-icons git repository. When this directory exists, icons are served from it instead of being fetched over HTTP, avoiding per-icon network requests. |
| `icons_repo_url` | `https://github.com/homarr-labs/dashboard-icons.git` | Git URL used to clone the dashboard-icons repository into `icons_local_repo` if it does not already exist. Set to an empty string to disable automatic cloning. |
| `icons_repo_refresh` | `604800` (7 days) | How often, in seconds, the local dashboard-icons clone is pulled for updates. |
