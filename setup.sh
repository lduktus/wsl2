#!/bin/sh

# duktus 2023

# NOTE: -o pipefail will only work with latest shell versions
set -euo pipefail

### variables ###
PACKAGES="bash bash-completion binutils buildah curl ca-certificates coreutils cosign direnv doas fd findutils git make openrc openssh py3-pip podman podman-docker ripgrep shellcheck shfmt skopeo util-linux-misc wslu zoxide"
# NOTE: set a default USERNAME by setting WSL_USER as environment variable
USERNAME="$1"

### functions ##
# die with an error message
_die() {
    printf "\n\033[0;31m[ERROR]:%s\033[0m\n" "$@" >&2
    exit 1
}

# print a warning message
_warn() {
    printf "\n\033[0;33m[WARN]:%s\033[0m\n" "$@" >&2
}

# print a infro message
_info() {
    printf "\n\033[0;32m[INFO]:%s\033[0m\n" "$@" >&2
}

# check if we are using alpine
_is_alpine() {
    grep -xq '^ID=alpine*$' /etc/os-release && return 0
    return 1
}

# check if command exists
_command_exists() {
    command -v "$@" >/dev/null 2>&1 && return 0
    printf "%s\n" "Command does not exist: $@" >&2 && return 1
}

# update all packages
_apk_update() {
    apk update && apk upgrade && return 0
}

# change default repositories to edge
_apk_change_repositories() {
    sed -i -e 's/v[[:digit:]]+\.[[:digit:]]+/edge/g' /etc/apk/repositories && return 0
}

# install man pages
_apk_add_docs() {
    apk add mandoc man-pages mandoc-apropos less less-doc && return 0
}

# install missing packages such as man-pages or bash-completion
_apk_add_missing() {
    suffix="$1"
    apk list -I |
        sed -rn "/-${suffix}/! s/([a-z-]+[a-z]).*/\1/p" |
        awk '{ print system("apk info \""$1"-'${suffix}'\" > /dev/null") == 0 ? $1 "-'${suffix}'" : "" }' |
        xargs apk add && return 0
}

# generates the local wsl.conf file, this will ensure:
# - we use our default user (arg1)
# - mount option should silence podman warnings
# - openrc is started on boot
_generate_wsl_conf() {
    printf '[user]\ndefault=%s\n\n[boot]\ncommand="openrc default; mount --make-rshared /"\n' "$1" > /etc/wsl.conf
}

# generate a doas.conf file, this will ensure:
# - users of the wheel group can use doas
_generate_doas_conf() {
    mkdir -pv /etc/doas.d
    printf 'permit :wheel\n' > /etc/doas.d/doas.conf && return 0
}

# add default user to wheel group
_add_user_to_wheel() {
    adduser "$1" wheel && return 0
}

# enable cgroups service
_enable_cgroups() {
    rc-update add cgroups && return 0
}

# enable podman service
_enable_podman() {
    rc-update add podman && return 0
}

# enable rootless podman mode
_enable_rootless_podman() {
    printf  'tun\n' >> /etc/modules && printf '%s:100000:65536\n' "$1" >> /etc/subuid && printf '%s:100000:65536\n' "$1" >> /etc/subgid && return 0
}

### script ###

# perform some checks
_info 'performing checks'
if [ "$(id -u)" -ne 0 ]; then
    _die "this script must be run as root"
fi

_is_alpine || _die "this script is only for Alpine Linux"
_command_exists apk || _die "something is weird, apk is not installed"

# first ensure our system is up to date
_info 'changing default repositories'
_apk_change_repositories || _warn "could not change repositories"

_info 'updating system'
_apk_update || _warn "could not update packages"

# install packages
_info 'installing packages'
apk add -U ${PACKAGES} || _die "could not install packages"

# install missing bash-completions
_info 'adding missing bash-completion'
_apk_add_missing "bash-completion" || _warn "couldn't add missing bash-completions"

# afterwards add support for man-pages and install all man-pages for the installed packages
_info 'adding missing man-pages'
(_apk_add_docs && _apk_add_missing "doc") || _warn "couldn't add missing docs"

# perform basic system configuration
_info 'generating wsl config'
_generate_wsl_conf "$USERNAME" || _warn "couldn't generate wsl.conf"

_info 'giving wheel group doas permissions'
_generate_doas_conf || _warn "couldn't generate doas.conf"

_info 'enabling crgoups for podman support'
_enable_cgroups || _warn "couldn't enable cgroups"

_info 'enabling poman service'
_enable_podman || _warn "couldn't enable podman service"

if _command_exists pip3; then
    _info 'installing podman-compose via pip3'
    pip3 install podman-compose || _warn "couldn't install podman-compose"
else
    _warn "pip3 is not installed, skipping podman-compose"
fi

# set up our default user
if [ ! "$USERNAME" == 'root' ]; then
    _info 'enabling rootless podman'
    _enable_rootless_podman "$USERNAME" || _warn "couldn't enable rootless podman"
    _info 'set your user password'
    _command_exists passwd && passwd "$USERNAME"
    _info 'setting default user shell'
    _command_exists chsh && [ -x /bin/bash ] && chsh -s /bin/bash "$USERNAME"
fi