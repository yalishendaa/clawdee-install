#!/usr/bin/env bash
# clawdee-install -- installer
#
# Installs on a fresh Ubuntu 22.04 / 24.04 VPS:
#   - clawdee user (dedicated, non-login-privileged)
#   - Node.js 22 + Python 3.12 + Claude Code CLI
#   - CLAWDEE: yalishendaa/clawdee-telegram-gateway -> systemd unit claude-gateway
#
# Operator runs `sudo -u clawdee claude login` once after install finishes.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yalishendaa/clawdee/main/install.sh | sudo bash
#   # or
#   sudo ./install.sh
#
# Env overrides (non-interactive):
#   CLAWDEE_BOT_TOKEN   CLAWDEE Telegram bot token
#   CLAWDEE_BOT_USER    CLAWDEE bot @username (no @)
#   CLAWDEE_TG_USER_ID  Operator Telegram numeric ID
#   CLAWDEE_USER_NAME   Operator display name (for CLAWDEE CLAUDE.md)
#   CLAWDEE_LANGUAGE    Operator language (default: Russian)
#   CLAWDEE_TIMEZONE    Operator timezone (default: Europe/Moscow)

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly CLAWDEE_REPO="https://github.com/yalishendaa/clawdee-telegram-gateway.git"
readonly CLAWDEE_DIR_NAME="claude-gateway"
readonly NODE_MAJOR="22"
readonly CLAWDEE_USER="clawdee"
readonly CLAWDEE_HOME="/home/clawdee"

# Template bundle (pinned SHAs).
readonly TEMPLATE_REPO="https://github.com/yalishendaa/clawdee-architecture.git"
readonly TEMPLATE_SHA="deba073228a144ab8c0291082ddef05031c1be58"
readonly SUPERPOWERS_REPO="https://github.com/yalishendaa/clawdee-superpowers.git"
readonly SUPERPOWERS_SHA="4372379c9b061b4d183ec1b6cd4cc19a25b99191"

# 6 skills from template + 4 bundled with installer = 10 total.
readonly SKILLS_FROM_TEMPLATE=(groq-voice markdown-new perplexity-research datawrapper excalidraw youtube-transcript)
readonly SKILLS_FROM_INSTALLER=(onboarding self-compiler quick-reminders present)

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
readonly TEMPLATES_DIR_DEFAULT="${_SCRIPT_DIR}/templates"
readonly INSTALLER_ROOT_DEFAULT="${_SCRIPT_DIR}"
unset _SCRIPT_DIR
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

TEMPLATES_DIR="${CLAWDEE_TEMPLATES_DIR:-$TEMPLATES_DIR_DEFAULT}"
INSTALLER_ROOT="${CLAWDEE_INSTALLER_ROOT:-$INSTALLER_ROOT_DEFAULT}"
TEMPLATE_CLONE_DIR=""
INSTALLER_SKILLS_DIR=""

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

log()  { printf '%b[%s]%b %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_NC" "$*"; }
ok()   { printf '%b✓%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b!%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    local n="$1"; shift
    printf '\n%b== Step %s: %s ==%b\n' "$C_BOLD" "$n" "$*" "$C_NC"
}

banner() {
    printf '\n%b' "$C_YELLOW"
    cat <<'EOF'

                                                                                                          █╗ █╗
██████╗ ██╗    ██╗██████╗ ██████╗     ██████╗ ██╗   ██╗    ████████╗██╗  ██╗███████╗    ██╗   ██╗███████╗███████╗
██╔══██╗██║    ██║██╔══██╗██╔══██╗    ██╔══██╗╚██╗ ██╔╝    ╚══██╔══╝██║  ██║██╔════╝    ██║   ██║██╔════╝██╔════╝
██████╔╝██║ █╗ ██║██████╔╝██║  ██║    ██████╔╝ ╚████╔╝        ██║   ███████║█████╗      ██║   ██║███████╗█████╗  
██╔═══╝ ██║███╗██║██╔══██╗██║  ██║    ██╔══██╗  ╚██╔╝         ██║   ██╔══██║██╔══╝      ╚██╗ ██╔╝╚════██║██╔══╝  
██║     ╚███╔███╔╝██║  ██║██████╔╝    ██████╔╝   ██║          ██║   ██║  ██║███████╗     ╚████╔╝ ███████║███████╗
╚═╝      ╚══╝╚══╝ ╚═╝  ╚═╝╚═════╝     ╚═════╝    ╚═╝          ╚═╝   ╚═╝  ╚═╝╚══════╝      ╚═══╝  ╚══════╝╚══════╝

EOF
    printf '%b\n' "$C_NC"
}

# =============================================================================
# HELPERS
# =============================================================================

apt_get() {
    # Stop unattended-upgrades on first call s  o it doesn't hold the lock for
    # the entire install. Safe to call multiple times (systemctl is idempotent).
    systemctl stop unattended-upgrades 2>/dev/null || true
    systemctl stop apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    local tries=0
    local max_tries=100  # 5 minutes
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null || \
          fuser /var/lib/apt/lists/lock &>/dev/null || \
          fuser /var/lib/dpkg/lock &>/dev/null; do
        ((tries++))
        if (( tries > max_tries )); then
            die "dpkg lock held for >5 min. Run: sudo kill \$(fuser /var/lib/dpkg/lock-frontend) && sudo dpkg --configure -a"
        fi
        if (( tries % 10 == 0 )); then
            log "Waiting for dpkg lock... (${tries}/${max_tries})"
        fi
        sleep 3
    done
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# Tmp tracking.
TMPFILES=()
TMPDIRS=()
_cleanup() {
    local f d
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
    for d in "${TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
}
trap _cleanup EXIT

is_noninteractive() {
    [[ "${CLAWDEE_NONINTERACTIVE:-0}" == "1" ]] || ! (exec </dev/tty) 2>/dev/null
}

# prompt_or_env VAR ENV_NAME "prompt" [default] [--secret]
# shellcheck disable=SC2034  # out_ref is a nameref, writes propagate to caller
prompt_or_env() {
    local -n out_ref=$1
    local env_name=$2
    local prompt=$3
    local default=${4:-}
    local secret=${5:-}
    local env_val="${!env_name:-}"

    if [[ -n "$env_val" ]]; then
        out_ref="$env_val"
        return 0
    fi

    if is_noninteractive; then
        if [[ -n "$default" ]]; then
            out_ref="$default"
            return 0
        fi
        die "Non-interactive mode: required value ${env_name} is missing (prompt was: ${prompt})."
    fi

    local answer=""
    if [[ -n "$default" ]]; then
        prompt="${prompt} [${default}]"
    fi
    prompt="${prompt}: "

    if [[ "$secret" == "--secret" ]]; then
        read -r -s -p "$prompt" answer </dev/tty
        echo ""
    else
        read -r -p "$prompt" answer </dev/tty
    fi

    if [[ -z "$answer" && -n "$default" ]]; then
        answer="$default"
    fi
    out_ref="$answer"
}

# Simple {{KEY}} -> VALUE substitution from template file into dst.
# Usage: render_template src dst KEY1 VAL1 [KEY2 VAL2 ...]
render_template() {
    local src=$1 dst=$2; shift 2
    [[ -f "$src" ]] || die "Template not found: $src"

    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"

    while (($# >= 2)); do
        local key="$1" val="$2"; shift 2
        # Use python for safe literal replace (no regex surprises in values).
        python3 - "$tmp" "{{${key}}}" "$val" <<'PY'
import sys, pathlib
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.write_text(p.read_text().replace(needle, repl))
PY
    done

    mv "$tmp" "$dst"
}

as_clawdee() {
    sudo -u "$CLAWDEE_USER" -H -- env -C "$CLAWDEE_HOME" "$@"
}

# Install a file at dst owned by a specific user, 0600 by default.
install_as_user() {
    local src=$1 dst=$2 owner=$3 mode=${4:-0600}
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
}

# write_as_user: copy SRC to DST owned by CLAWDEE_USER. Works even when SRC is
# a root-owned 0600 mktemp file that clawdee cannot read.
write_as_user() {
    local src="$1" dst="$2" mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$dst_dir"
    fi
    install -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" -m "$mode" "$src" "$dst"
}

# fix_owner: recursively chown to clawdee (-h affects symlinks).
fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chown -RhP "${CLAWDEE_USER}:${CLAWDEE_USER}" "$path"
}

# ---------------------------------------------------------------------------
# Template / skill sourcing
# ---------------------------------------------------------------------------

fetch_template() {
    if [[ -n "$TEMPLATE_CLONE_DIR" && -d "$TEMPLATE_CLONE_DIR" ]]; then
        echo "$TEMPLATE_CLONE_DIR"
        return 0
    fi

    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")

    log "Cloning pinned template @ ${TEMPLATE_SHA:0:8}..." >&2
    if ! git clone --quiet "$TEMPLATE_REPO" "$dir" >&2; then
        err "Failed to clone template repo from ${TEMPLATE_REPO}"
        return 1
    fi
    if ! git -C "$dir" checkout --quiet "$TEMPLATE_SHA" 2>/dev/null; then
        err "Failed to checkout SHA ${TEMPLATE_SHA}"
        return 1
    fi

    TEMPLATE_CLONE_DIR="$dir"
    echo "$dir"
}

locate_installer_skills() {
    if [[ -n "$INSTALLER_SKILLS_DIR" && -d "$INSTALLER_SKILLS_DIR" ]]; then
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    if [[ -d "${INSTALLER_ROOT}/skills" ]]; then
        INSTALLER_SKILLS_DIR="${INSTALLER_ROOT}/skills"
        echo "$INSTALLER_SKILLS_DIR"
        return 0
    fi

    # curl | bash path: no local skills/ dir, clone installer repo.
    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    log "Cloning installer bundled skills..." >&2
    if ! git clone --quiet --depth 1 "https://github.com/yalishendaa/clawdee-install.git" "$dir" >&2; then
        err "Failed to clone installer repo for bundled skills."
        return 1
    fi
    if [[ ! -d "${dir}/skills" ]]; then
        err "Installer repo has no skills/ subtree."
        return 1
    fi
    INSTALLER_SKILLS_DIR="${dir}/skills"
    echo "$INSTALLER_SKILLS_DIR"
}

# install_skill_bundle SRC DST_PARENT NAME -- atomic same-fs rsync+mv.
install_skill_bundle() {
    local src="$1" dst_parent="$2" skill_name="$3"

    if [[ ! -d "$src" ]]; then
        err "install_skill_bundle: source '${src}' not found."
        return 1
    fi

    local dst="${dst_parent}/${skill_name}"
    mkdir -p "$dst_parent"

    local stage="${dst_parent}/.${skill_name}.staging.$$"
    rm -rf "$stage" 2>/dev/null || true
    mkdir -p "$stage"
    TMPDIRS+=("$stage")

    if ! rsync -a --delete "${src}/" "${stage}/${skill_name}/"; then
        rm -rf "$stage"
        err "install_skill_bundle: rsync failed for '${skill_name}'."
        return 1
    fi

    if [[ -d "$dst" ]]; then
        rm -rf "${dst}.prev" 2>/dev/null || true
        mv "$dst" "${dst}.prev"
    fi

    if ! mv "${stage}/${skill_name}" "$dst"; then
        err "install_skill_bundle: mv of staged '${skill_name}' failed."
        if [[ -d "${dst}.prev" ]]; then
            mv "${dst}.prev" "$dst" || true
            warn "Restored previous version of '${skill_name}'."
        fi
        rm -rf "$stage"
        return 1
    fi

    rm -rf "${dst}.prev" 2>/dev/null || true
    rm -rf "$stage" 2>/dev/null || true

    # Always fix ownership on the installed skill -- this guards against
    # partial-failure paths where the outer fix_owner is skipped.
    fix_owner "$dst"
    return 0
}

validate_tg_token() {
    local token=$1
    # Format: <digits>:<alphanum-dash-underscore>, at least 8:30 chars.
    [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]
}

tg_get_me() {
    local token=$1
    curl "${CURL_OPTS[@]}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true
}

# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step 0 "Preflight checks"

    if [[ $EUID -ne 0 ]]; then
        die "Run as root: sudo $0"
    fi

    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release -- unsupported OS."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ID=${ID:-unknown}. Ubuntu 22.04 or 24.04 required."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            ok "Ubuntu ${VERSION_ID} detected."
            ;;
        *)
            if [[ "${CLAWDEE_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
                warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (CLAWDEE_ALLOW_UNTESTED_UBUNTU=1)."
            else
                die "Ubuntu ${VERSION_ID:-?} is untested. Require 22.04 or 24.04, or set CLAWDEE_ALLOW_UNTESTED_UBUNTU=1."
            fi
            ;;
    esac

    if ! command -v curl &>/dev/null; then
        log "Bootstrapping curl..."
        apt_get update -qq
        apt_get install -y -qq curl
    fi

    if ! curl "${CURL_OPTS[@]}" -o /dev/null https://api.github.com/ 2>/dev/null; then
        warn "Network check to api.github.com failed. Installer may fail later."
    fi

    # When run via `curl | bash`, the script lives in /tmp and has no sibling
    # templates/ or skills/ dirs. Clone the installer repo into a tmp dir and
    # re-point TEMPLATES_DIR / INSTALLER_ROOT to that clone.
    if [[ ! -d "$TEMPLATES_DIR" ]]; then
        if ! command -v git &>/dev/null; then
            apt_get update -qq
            apt_get install -y -qq git
        fi
        local clone_dir
        clone_dir=$(mktemp -d)
        TMPDIRS+=("$clone_dir")
        log "Templates not found at ${TEMPLATES_DIR}; cloning installer repo..."
        if ! git clone --quiet --depth 1 --branch "${CLAWDEE_INSTALL_REF:-main}" \
                https://github.com/yalishendaa/clawdee-install.git "$clone_dir"; then
            warn "Clone of branch ${CLAWDEE_INSTALL_REF:-main} failed; falling back to default branch."
            rm -rf "$clone_dir"
            clone_dir=$(mktemp -d)
            TMPDIRS+=("$clone_dir")
            git clone --quiet --depth 1 \
                https://github.com/yalishendaa/clawdee-install.git "$clone_dir" \
                || die "Failed to clone installer repo for templates/skills."
        fi
        TEMPLATES_DIR="${clone_dir}/templates"
        INSTALLER_ROOT="$clone_dir"
        [[ -d "$TEMPLATES_DIR" ]] || die "Cloned repo has no templates/ dir."
    fi

    ok "Preflight passed."
}

# =============================================================================
# STEP 1: APT DEPENDENCIES
# =============================================================================

install_apt_deps() {
    step 1 "Installing apt dependencies"

    apt_get update -qq
    apt_get install -y -qq \
        ca-certificates gnupg lsb-release software-properties-common \
        sudo \
        curl wget git jq rsync \
        build-essential \
        systemd \
        logrotate \
        cron

    # Python 3.12: native on Ubuntu 24.04. On 22.04 we need deadsnakes PPA
    # because the default python3 is 3.10 and this installer requires 3.12+.
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${VERSION_ID:-}" in
        22.04)
            if ! command -v python3.12 >/dev/null 2>&1; then
                log "Adding deadsnakes PPA for Python 3.12 (Ubuntu 22.04)."
                add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
                apt_get update -qq
            fi
            apt_get install -y -qq python3.12 python3.12-venv python3.12-dev python3-pip
            # Point /usr/bin/python3 -> python3.12 so `python3 --version` shows 3.12.
            update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 100 >/dev/null 2>&1 || true
            update-alternatives --set python3 /usr/bin/python3.12 >/dev/null 2>&1 || true
            ;;
        24.04|*)
            apt_get install -y -qq python3 python3-venv python3-pip python3-dev
            ;;
    esac

    local py_ver
    py_ver=$(python3 --version 2>&1 | awk '{print $2}')
    ok "Base packages installed (python3=${py_ver})."
}

# =============================================================================
# STEP 2: NODE.JS 22
# =============================================================================

install_node() {
    step 2 "Installing Node.js ${NODE_MAJOR}"

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
        if [[ "$current_major" == "$NODE_MAJOR" ]]; then
            ok "Node.js $(node -v) already installed."
            return 0
        fi
        warn "Node.js $(node -v) present but not v${NODE_MAJOR}; replacing."
    fi

    curl "${CURL_OPTS[@]}" "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt_get install -y -qq nodejs
    ok "Node.js $(node -v) installed."
}

# =============================================================================
# STEP 3: CLAUDE CODE CLI
# =============================================================================

install_claude_cli() {
    step 3 "Installing Claude Code CLI (per-user for ${CLAWDEE_USER})"

    local claude_bin="${CLAWDEE_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        ok "Claude CLI already installed at ${claude_bin}."
        # Best-effort update; never block install on update failure.
        as_clawdee "$claude_bin" update >/dev/null 2>&1 || warn "claude update non-zero; continuing."
        _ensure_path_export
        return 0
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl "${CURL_OPTS[@]}" https://claude.ai/install.sh -o "$installer_tmp" \
        || die "Failed to download Claude Code installer."
    chmod 644 "$installer_tmp"

    # Run Anthropic's installer as clawdee so binary lands at ~/.local/bin/claude.
    as_clawdee bash "$installer_tmp"

    if [[ ! -x "$claude_bin" ]]; then
        die "Claude CLI install failed -- ${claude_bin} not found."
    fi

    local ver
    ver=$(as_clawdee "$claude_bin" --version 2>/dev/null || echo "unknown")
    ok "Claude CLI v${ver} installed at ${claude_bin}."

    _ensure_path_export
}

# Expose ~/.local/bin on clawdee's PATH for non-interactive SSH + systemd.
# .bashrc aborts on non-interactive shells, so prepend before the PS1 guard.
# .profile runs in full for login shells -- append is fine.
_ensure_path_export() {
    local marker='# Added by clawdee-install: expose ~/.local/bin'
    local export_line='export PATH="$HOME/.local/bin:$PATH"'

    local rc_entry rc placement
    for rc_entry in "${CLAWDEE_HOME}/.bashrc:prepend" "${CLAWDEE_HOME}/.profile:append"; do
        rc="${rc_entry%:*}"
        placement="${rc_entry##*:}"

        if [[ ! -f "$rc" ]]; then
            as_clawdee touch "$rc"
        fi

        if grep -Fq "$marker" "$rc" 2>/dev/null; then
            continue
        fi

        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        if [[ "$placement" == "prepend" ]]; then
            { echo "$marker"; echo "$export_line"; echo ''; cat "$rc"; } >"$tmp"
        else
            { cat "$rc"; echo ''; echo "$marker"; echo "$export_line"; } >"$tmp"
        fi
        install -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" -m 0644 "$tmp" "$rc"
    done
}

# =============================================================================
# STEP 4: CLAWDEE USER
# =============================================================================

ensure_clawdee_user() {
    step 4 "Ensuring '${CLAWDEE_USER}' system user"

    if id -u "$CLAWDEE_USER" &>/dev/null; then
        ok "User '${CLAWDEE_USER}' already exists."
    else
        useradd --create-home --shell /bin/bash "$CLAWDEE_USER"
        ok "User '${CLAWDEE_USER}' created."
    fi

    # Make sure home is usable.
    if [[ ! -d "$CLAWDEE_HOME" ]]; then
        die "Home dir ${CLAWDEE_HOME} missing after useradd."
    fi
    chown "${CLAWDEE_USER}:${CLAWDEE_USER}" "$CLAWDEE_HOME"
    chmod 0755 "$CLAWDEE_HOME"
}

# =============================================================================
# STEP 5: OPERATOR INPUTS
# =============================================================================

# Globals set by collect_inputs
CLAWDEE_BOT_TOKEN=""
CLAWDEE_BOT_USERNAME=""
TG_USER_ID=""
OPERATOR_NAME=""
OPERATOR_LANGUAGE=""
OPERATOR_TIMEZONE=""

collect_inputs() {
    step 5 "Collecting operator inputs"

    if ! is_noninteractive; then
        cat <<'BRIEF'

The installer will now ask a few questions. You need a Telegram bot ready
(create it in @BotFather beforehand) and your numeric Telegram user ID
(get it from @userinfobot). Token is hidden while typing.

BRIEF
    fi

    prompt_or_env OPERATOR_NAME     CLAWDEE_USER_NAME  "Как к вам обращаться?"                "friend"
    prompt_or_env OPERATOR_LANGUAGE CLAWDEE_LANGUAGE   "Язык общения (English / Russian / ...)" "Russian"
    prompt_or_env OPERATOR_TIMEZONE CLAWDEE_TIMEZONE   "Таймзона (IANA: Europe/Moscow, Asia/Bangkok, ...)" "Europe/Moscow"

    prompt_or_env CLAWDEE_BOT_TOKEN CLAWDEE_BOT_TOKEN \
        "CLAWDEE bot token (from @BotFather, формат 1234567890:ABC...)" \
        "" --secret
    prompt_or_env TG_USER_ID        CLAWDEE_TG_USER_ID \
        "Ваш Telegram numeric user ID (from @userinfobot)" \
        ""

    CLAWDEE_BOT_USERNAME="${CLAWDEE_BOT_USER:-}"

    if [[ -n "$CLAWDEE_BOT_TOKEN" ]]; then
        if ! validate_tg_token "$CLAWDEE_BOT_TOKEN"; then
            die "CLAWDEE token format invalid (expected '<digits>:<30+ chars>')."
        fi
        local jresp
        jresp=$(tg_get_me "$CLAWDEE_BOT_TOKEN")
        if [[ "$(echo "$jresp" | jq -r '.ok // false' 2>/dev/null)" == "true" ]]; then
            [[ -z "$CLAWDEE_BOT_USERNAME" ]] && \
                CLAWDEE_BOT_USERNAME=$(echo "$jresp" | jq -r '.result.username // ""')
            ok "CLAWDEE bot verified: @${CLAWDEE_BOT_USERNAME:-?}"
        else
            warn "Telegram getMe for CLAWDEE failed -- token will be written as-is."
        fi
    else
        log "CLAWDEE token empty (interactive skip / non-interactive no-env)."
    fi

    if [[ -n "$TG_USER_ID" && ! "$TG_USER_ID" =~ ^[0-9]+$ ]]; then
        die "Telegram user ID must be a positive integer (got: ${TG_USER_ID})."
    fi

    ok "Inputs collected: name=${OPERATOR_NAME}, tz=${OPERATOR_TIMEZONE}, lang=${OPERATOR_LANGUAGE}"
}

# =============================================================================
# STEP 6: INSTALL CLAWDEE
# =============================================================================

install_clawdee() {
    step 6 "Installing CLAWDEE (claude-gateway)"

    local dir="${CLAWDEE_HOME}/${CLAWDEE_DIR_NAME}"

    if [[ -d "${dir}/.git" ]]; then
        log "CLAWDEE repo exists -- pulling latest."
        as_clawdee git -C "$dir" pull --ff-only || warn "git pull failed; continuing with existing checkout."
    else
        as_clawdee git clone --depth 1 "$CLAWDEE_REPO" "$dir"
    fi

    # Virtualenv + requirements
    local venv="${dir}/.venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        as_clawdee python3 -m venv "$venv"
    fi
    if [[ -f "${dir}/requirements.txt" ]]; then
        as_clawdee "${venv}/bin/pip" install --upgrade pip --quiet
        as_clawdee "${venv}/bin/pip" install -r "${dir}/requirements.txt" --quiet
    fi

    # gateway config.json. chmod 0600 because it contains a secret.
    local wsroot="${CLAWDEE_HOME}/.claude-lab/clawdee/.claude"
    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" \
        "${CLAWDEE_HOME}/.claude-lab" \
        "${CLAWDEE_HOME}/.claude-lab/clawdee" \
        "$wsroot"

    local config_tmp
    config_tmp=$(mktemp)
    TMPFILES+=("$config_tmp")
    render_template "${TEMPLATES_DIR}/gateway-config.json" "$config_tmp" \
        USER        "$CLAWDEE_USER" \
        AGENT_NAME  "clawdee" \
        USER_NAME   "$OPERATOR_NAME"
    # Inject bot_token and allowed_user_ids via jq. Values may be empty if
    # token was skipped -- edit config.json manually afterwards.
    local patched
    patched=$(mktemp)
    TMPFILES+=("$patched")
    local id_arg="null"
    [[ -n "$TG_USER_ID" ]] && id_arg="[${TG_USER_ID}]"
    jq --arg tok "$CLAWDEE_BOT_TOKEN" --argjson ids "${id_arg}" \
       '.agents.clawdee.bot_token = $tok | .allowed_user_ids = ($ids // [])' \
       "$config_tmp" > "$patched"
    mv "$patched" "$config_tmp"
    install_as_user "$config_tmp" "${dir}/config.json" "$CLAWDEE_USER" 0600

    # Full agent workspace (CLAUDE.md + core/USER.md + stub cold memory).
    _write_agent_workspace "$wsroot"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    TMPFILES+=("$unit_tmp")
    render_template "${TEMPLATES_DIR}/claude-gateway.service" "$unit_tmp" \
        USER "$CLAWDEE_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/claude-gateway.service

    fix_owner "${CLAWDEE_HOME}/.claude-lab"
    ok "CLAWDEE installed at ${dir}"
}

# _write_agent_workspace <wsroot> -- lays down CLAUDE.md + core/ tree for CLAWDEE.
# Lays down CLAUDE.md + core/ tree for CLAWDEE.
_write_agent_workspace() {
    local ws="$1"

    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" \
        "$ws" \
        "${ws}/core" \
        "${ws}/core/hot" \
        "${ws}/core/warm" \
        "${ws}/skills" \
        "${ws}/logs"

    # CLAUDE.md (top-level)
    local claude_md_tmp
    claude_md_tmp=$(mktemp)
    TMPFILES+=("$claude_md_tmp")
    render_template "${TEMPLATES_DIR}/CLAUDE.md" "$claude_md_tmp" \
        AGENT_NAME "CLAWDEE" \
        AGENT_ROLE "operator's daily AI assistant" \
        USER_NAME  "$OPERATOR_NAME" \
        LANGUAGE   "$OPERATOR_LANGUAGE" \
        TIMEZONE   "$OPERATOR_TIMEZONE"
    write_as_user "$claude_md_tmp" "${ws}/CLAUDE.md" 0644

    # core/USER.md -- operator profile
    local user_tmp
    user_tmp=$(mktemp)
    TMPFILES+=("$user_tmp")
    cat > "$user_tmp" <<UEOF
# USER.md -- Operator profile

**Name:** ${OPERATOR_NAME}
**Timezone:** ${OPERATOR_TIMEZONE}
**Preferred language:** ${OPERATOR_LANGUAGE}

## Notes
- Edit this file freely -- the agent reads it on every start.
UEOF
    write_as_user "$user_tmp" "${ws}/core/USER.md" 0644

    # core/rules.md
    local rules_tmp
    rules_tmp=$(mktemp)
    TMPFILES+=("$rules_tmp")
    cat > "$rules_tmp" <<'REOF'
# Rules

- Ask before destructive operations (rm -rf, DROP TABLE, sudo on shared infra).
- Never commit secrets. Never print tokens/keys in plain text.
- On each correction: update LEARNINGS.md so the mistake does not repeat.
- Prefer small, reversible changes.
REOF
    write_as_user "$rules_tmp" "${ws}/core/rules.md" 0644

    # Stub cold memory + hot/warm files so @includes in CLAUDE.md resolve.
    local stub_tmp
    stub_tmp=$(mktemp)
    TMPFILES+=("$stub_tmp")

    printf '# MEMORY.md\n\nLong-term notes.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/MEMORY.md" 0644

    printf '# LEARNINGS.md\n\nOne line per correction.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/LEARNINGS.md" 0644

    printf '# recent.md -- full journal (NOT in @include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/recent.md" 0644

    printf '# handoff.md -- last 10 entries (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/handoff.md" 0644

    printf '# decisions.md -- last 14 days of decisions (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/warm/decisions.md" 0644
}

# =============================================================================
# STEP 7: GLOBAL ~/.claude/ (OAuth creds live here)
# =============================================================================

setup_global_claude() {
    step 8 "Setting up ${CLAWDEE_HOME}/.claude/ (shared OAuth dir)"

    local claude_dir="${CLAWDEE_HOME}/.claude"
    install -d -m 0700 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$claude_dir"
    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "${claude_dir}/plugins"

    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        cat > "$tmp" <<'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  },
  "permissions": {
    "allow": [
      "Bash(npm:*)", "Bash(node:*)", "Bash(git:*)",
      "Bash(python3:*)", "Bash(pip3:*)",
      "Bash(cat:*)", "Bash(ls:*)", "Bash(mkdir:*)",
      "Bash(chmod:*)", "Bash(echo:*)",
      "Read", "Write", "Edit"
    ]
  }
}
SJEOF
        write_as_user "$tmp" "$settings_json" 0644
    fi

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        echo '{"mcpServers": {}}' > "$tmp"
        write_as_user "$tmp" "$mcp_json" 0644
    fi

    # Global CLAUDE.md -- loaded by every Claude Code session under clawdee user.
    # Shared by CLAWDEE (chat agent) and Richard (server-doctor) so Richard is
    # not blind about the owner, language, and safety rules.
    local global_claude_md="${claude_dir}/CLAUDE.md"
    if [[ ! -f "$global_claude_md" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        render_template "${TEMPLATES_DIR}/global-CLAUDE.md" "$tmp" \
            USER       "$CLAWDEE_USER" \
            USER_NAME  "$OPERATOR_NAME" \
            TG_ID      "$TG_USER_ID" \
            LANGUAGE   "$OPERATOR_LANGUAGE" \
            TIMEZONE   "$OPERATOR_TIMEZONE"
        write_as_user "$tmp" "$global_claude_md" 0644
    fi

    fix_owner "$claude_dir"
    ok "${claude_dir} ready."
}

# =============================================================================
# STEP 9: SKILLS (6 from template + 4 bundled = 10)
# =============================================================================

install_skills() {
    step 9 "Installing ${#SKILLS_FROM_TEMPLATE[@]} template + ${#SKILLS_FROM_INSTALLER[@]} bundled skills"

    local dst_parent="${CLAWDEE_HOME}/.claude-lab/clawdee/.claude/skills"
    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$dst_parent"

    local installed=()

    local tpl_dir
    if tpl_dir=$(fetch_template); then
        local tpl_skills_root="${tpl_dir}/skills"
        [[ -d "$tpl_skills_root" ]] || tpl_skills_root="$tpl_dir"

        local name
        for name in "${SKILLS_FROM_TEMPLATE[@]}"; do
            local src="${tpl_skills_root}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Template skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Template fetch failed -- template skills skipped."
    fi

    local skills_src
    if skills_src=$(locate_installer_skills); then
        local name
        for name in "${SKILLS_FROM_INSTALLER[@]}"; do
            local src="${skills_src}/${name}"
            if [[ ! -d "$src" ]]; then
                warn "Bundled skill '${name}' missing -- skipping."
                continue
            fi
            if install_skill_bundle "$src" "$dst_parent" "$name"; then
                installed+=("$name")
            fi
        done
    else
        warn "Installer skills dir not found -- bundled skills skipped."
    fi

    fix_owner "$dst_parent"
    ok "Skills installed: ${installed[*]:-<none>} (${#installed[@]}/10)"
}

# =============================================================================
# STEP 10: SUPERPOWERS PLUGIN
# =============================================================================

install_superpowers() {
    step 10 "Installing Superpowers plugin @ ${SUPERPOWERS_SHA:0:8}"

    local plugins_dir="${CLAWDEE_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$plugins_dir"

    if [[ -d "$sp_dir" ]]; then
        log "Superpowers already present -- pinning SHA."
        as_clawdee git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch failed -- keeping existing checkout."
        as_clawdee git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed."
    else
        as_clawdee git clone --quiet --depth 1 "$SUPERPOWERS_REPO" "$sp_dir" \
            || { warn "Failed to clone Superpowers -- skipping."; return 0; }
        as_clawdee git -C "$sp_dir" fetch --depth=1 origin "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers fetch of pinned SHA failed -- using HEAD."
        as_clawdee git -C "$sp_dir" checkout --quiet "$SUPERPOWERS_SHA" 2>/dev/null \
            || warn "Superpowers checkout of pinned SHA failed -- using HEAD."
    fi

    # Defensive jq merge of plugins config.
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    local abs_path="$sp_dir"

    if [[ -f "$cfg" ]]; then
        if ! jq -e 'type=="object"' "$cfg" >/dev/null 2>&1; then
            local backup
            backup="${cfg}.bak.$(date +%s)"
            cp "$cfg" "$backup" 2>/dev/null || true
            warn "Existing ${cfg} is not a JSON object -- backed up to $(basename "$backup"); skipping merge."
            fix_owner "$plugins_dir"
            return 0
        fi
        if ! jq --arg p "$abs_path" \
                '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
                "$cfg" > "$tmp" 2>/dev/null; then
            warn "jq merge of plugins config failed -- leaving ${cfg} untouched."
            return 0
        fi
        [[ ! -s "$tmp" ]] && { warn "jq empty output -- skipping."; return 0; }
    else
        if ! jq -n --arg p "$abs_path" \
                '{plugins: {superpowers: {enabled: true, path: $p}}}' > "$tmp" 2>/dev/null; then
            warn "Failed to write initial plugins config -- skipping."
            return 0
        fi
    fi
    write_as_user "$tmp" "$cfg" 0644

    fix_owner "$plugins_dir"
    ok "Superpowers installed at ${sp_dir}"
}

# =============================================================================
# STEP 11: SUDOERS (passwordless narrow-scope for agent self-repair)
# =============================================================================

install_sudoers() {
    step 11 "Granting clawdee narrow passwordless sudo"

    local sudoers_file="/etc/sudoers.d/clawdee-agents"
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    cat > "$tmp" <<SUDOERS
# clawdee-install v${CLAWDEE_VERSION} -- passwordless sudo for 'clawdee'.
# Scope: systemctl + journalctl for the agent unit, plus apt package mgmt
# so the agent can self-repair / install packages.

Cmnd_Alias CLAWDEE_SYSTEMCTL = \\
    /usr/bin/systemctl start claude-gateway, \\
    /usr/bin/systemctl stop claude-gateway, \\
    /usr/bin/systemctl restart claude-gateway, \\
    /usr/bin/systemctl status claude-gateway, \\
    /usr/bin/systemctl is-active claude-gateway, \\
    /usr/bin/systemctl enable claude-gateway, \\
    /usr/bin/systemctl disable claude-gateway, \\
    /usr/bin/systemctl start claude-richard, \\
    /usr/bin/systemctl stop claude-richard, \\
    /usr/bin/systemctl restart claude-richard, \\
    /usr/bin/systemctl status claude-richard, \\
    /usr/bin/systemctl is-active claude-richard, \\
    /usr/bin/systemctl enable claude-richard, \\
    /usr/bin/systemctl disable claude-richard, \\
    /usr/bin/systemctl daemon-reload

Cmnd_Alias CLAWDEE_JOURNAL = \\
    /usr/bin/journalctl -u claude-gateway, \\
    /usr/bin/journalctl -u claude-gateway *, \\
    /usr/bin/journalctl -u claude-richard, \\
    /usr/bin/journalctl -u claude-richard *

Cmnd_Alias CLAWDEE_APT = \\
    /usr/bin/apt, /usr/bin/apt *, \\
    /usr/bin/apt-get, /usr/bin/apt-get *

${CLAWDEE_USER} ALL=(root) NOPASSWD: CLAWDEE_SYSTEMCTL, CLAWDEE_JOURNAL, CLAWDEE_APT
SUDOERS

    # Validate syntax before installing -- a broken sudoers can lock out sudo.
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        err "Generated sudoers failed visudo -cf syntax check. Aborting install to avoid lockout."
        return 1
    fi

    install -m 0440 -o root -g root "$tmp" "$sudoers_file"
    ok "Sudoers installed at ${sudoers_file} (0440)."
}

# =============================================================================
# STEP 12: MEMORY ROTATION SCRIPTS + CRON
# =============================================================================

# Install the 5 memory-rotation scripts into the clawdee workspace and register
# them with clawdee's crontab.
install_memory_cron() {
    step 12 "Installing memory-rotation scripts + cron"

    local scripts_src
    if [[ -d "${INSTALLER_ROOT}/scripts" ]]; then
        scripts_src="${INSTALLER_ROOT}/scripts"
    else
        warn "scripts/ directory missing at ${INSTALLER_ROOT} -- memory cron skipped."
        return 0
    fi

    local scripts_dst="${CLAWDEE_HOME}/.claude-lab/clawdee/scripts"
    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$scripts_dst"

    local logs_dst="${CLAWDEE_HOME}/.claude-lab/clawdee/logs"
    install -d -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$logs_dst"

    local name
    local installed=()
    local required=(trim-hot rotate-warm compress-warm ov-session-sync memory-rotate)
    for name in "${required[@]}"; do
        local src="${scripts_src}/${name}.sh"
        if [[ ! -f "$src" ]]; then
            # A partial install would leave dead cron entries pointing at
            # missing files -- fail loud to avoid a broken cron setup.
            err "Memory script '${name}.sh' missing at ${src} -- refusing partial install."
            return 1
        fi
        install -m 0755 -o "$CLAWDEE_USER" -g "$CLAWDEE_USER" "$src" "${scripts_dst}/${name}.sh"
        installed+=("$name")
    done

    # Ensure cron service is enabled + running. On minimal Ubuntu images
    # (LXC, cloud) the cron package is installed but not auto-started.
    systemctl enable --now cron 2>/dev/null \
        || warn "cron service not started -- memory rotation will run after next reboot."

    # Merge cron lines with clawdee's existing crontab without clobbering it.
    # Marker lets us update on reinstall instead of duplicating entries.
    local marker="# clawdee-install v${CLAWDEE_VERSION}: memory rotation"
    local cron_block
    # CRON_TZ pins the schedule to UTC so the Day-2 diagnostic contract
    # (04:30/05:00/06:00/06:30/21:00 UTC) fires at the same wall-clock moment
    # regardless of the host's system timezone. HOME= is set because scripts
    # rely on $HOME under `set -u`; on some minimal images cron does not
    # always export HOME to the user's actual home directory.
    cron_block=$(cat <<CRON
${marker}
CRON_TZ=UTC
HOME=${CLAWDEE_HOME}
30 4 * * * ${scripts_dst}/rotate-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
0 5 * * *  ${scripts_dst}/trim-hot.sh >> ${logs_dst}/memory-cron.log 2>&1
0 6 * * *  ${scripts_dst}/compress-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
30 6 * * * ${scripts_dst}/ov-session-sync.sh >> ${logs_dst}/memory-cron.log 2>&1
0 21 * * * ${scripts_dst}/memory-rotate.sh >> ${logs_dst}/memory-cron.log 2>&1
# clawdee-install memory rotation end
CRON
)

    local current_tmp new_tmp
    current_tmp=$(mktemp)
    new_tmp=$(mktemp)
    TMPFILES+=("$current_tmp" "$new_tmp")

    # Fetch current crontab (empty is fine on first run).
    crontab -u "$CLAWDEE_USER" -l 2>/dev/null > "$current_tmp" || true

    # Strip any previous managed block so we can re-insert the current one.
    python3 - "$current_tmp" "$new_tmp" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    text = f.read()
cleaned = re.sub(
    r'# clawdee-install v[0-9.]+: memory rotation.*?# clawdee-install memory rotation end\n?',
    '',
    text,
    flags=re.DOTALL,
)
open(dst, 'w', encoding='utf-8').write(cleaned.rstrip() + ('\n' if cleaned.strip() else ''))
PY

    # Append new block.
    printf '%s\n' "$cron_block" >> "$new_tmp"

    if ! crontab -u "$CLAWDEE_USER" "$new_tmp" 2>/dev/null; then
        err "Failed to install crontab for ${CLAWDEE_USER} -- memory rotation will not run. Day-2 self-diagnostic will flag this as a failure."
        return 1
    fi

    # Verify the block actually landed so a silent crontab discard doesn't slip through.
    if ! crontab -u "$CLAWDEE_USER" -l 2>/dev/null | grep -q "clawdee-install memory rotation end"; then
        err "crontab accepted the file but memory-rotation block is not visible on read-back."
        return 1
    fi

    ok "Memory cron installed: ${installed[*]}"
}

# =============================================================================
# STEP 13: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 13 "Enabling systemd services (and starting if OAuth is already set up)"

    systemctl daemon-reload

    local oauth_ready="no"
    if [[ -f "${CLAWDEE_HOME}/.claude/.credentials.json" ]]; then
        oauth_ready="yes"
    fi

    # Always enable (on-boot auto-start). If tokens are present we also try
    # start -- but only when OAuth credentials exist, otherwise the unit crashes.
    if [[ -n "$CLAWDEE_BOT_TOKEN" ]]; then
        systemctl enable claude-gateway.service --quiet
        if [[ "$oauth_ready" == "yes" ]]; then
            if systemctl start claude-gateway.service 2>/dev/null; then
                ok "claude-gateway enabled + started."
            else
                warn "claude-gateway enabled, but start failed -- check 'journalctl -u claude-gateway'."
            fi
        else
            log "claude-gateway enabled -- will start after OAuth under clawdee."
        fi
    else
        log "claude-gateway NOT enabled (no token)."
    fi

}

# =============================================================================
# FINAL BANNER
# =============================================================================

final_instructions() {
    local clawdee_label="@${CLAWDEE_BOT_USERNAME:-<fill-in>}"
    local tokens_filled="no"
    if [[ -n "$CLAWDEE_BOT_TOKEN" && -n "$TG_USER_ID" ]]; then
        tokens_filled="yes"
    fi

    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  clawdee-install v${CLAWDEE_VERSION} complete.
================================================================================$(printf '%b' "$C_NC")

Installed on this VPS:
  - User:      ${CLAWDEE_USER} (${CLAWDEE_HOME})
  - Claude:    ${CLAWDEE_HOME}/.local/bin/claude  (per-user, on PATH)
  - CLAWDEE:   ${CLAWDEE_HOME}/${CLAWDEE_DIR_NAME}  (systemd: claude-gateway)
  - Skills:    ${CLAWDEE_HOME}/.claude-lab/clawdee/.claude/skills/  (10 skills)
  - Plugin:    ${CLAWDEE_HOME}/.claude/plugins/superpowers/
  - Sudoers:   /etc/sudoers.d/clawdee-agents  (narrow, 0440)

$(printf '%b' "$C_BOLD")Tokens filled during install:$(printf '%b' "$C_NC") ${tokens_filled}

$(printf '%b' "$C_BOLD")NEXT STEPS:$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") One-time Anthropic OAuth -- requires Claude.ai Pro or Max subscription.
      Run the command below, open the printed URL in your browser and log in:

        sudo -u ${CLAWDEE_USER} -i bash -lc 'claude login'

  $(printf '%b' "$C_YELLOW")2.$(printf '%b' "$C_NC") If token was skipped during install, fill it now and restart:

        # edit ${CLAWDEE_HOME}/${CLAWDEE_DIR_NAME}/config.json --
        # set agents.clawdee.bot_token and allowed_user_ids=[<your id>]

        sudo systemctl restart claude-gateway
        sudo systemctl status  claude-gateway --no-pager

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") Smoke-checks:

        id ${CLAWDEE_USER}                                      # uid >= 1000
        node -v                                                 # v22.x
        python3 --version                                       # 3.12+
        sudo -u ${CLAWDEE_USER} bash -lc 'which claude'         # ${CLAWDEE_HOME}/.local/bin/claude
        ls ${CLAWDEE_HOME}/.claude-lab/clawdee/.claude/          # CLAUDE.md, core/, skills/
        systemctl is-active claude-gateway                      # active (after steps 1+2)
        ls -la /etc/sudoers.d/clawdee-agents                    # exists, 0440
        ls ${CLAWDEE_HOME}/.claude-lab/clawdee/.claude/skills/ | wc -l   # 10

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Пиши CLAWDEE в Telegram: ${clawdee_label}

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    banner
    preflight
    install_apt_deps
    install_node
    ensure_clawdee_user
    install_claude_cli
    collect_inputs
    install_clawdee
    setup_global_claude
    install_skills
    install_superpowers
    install_sudoers
    install_memory_cron
    enable_services
    final_instructions
}

main "$@"