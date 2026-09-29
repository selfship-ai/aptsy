#!/usr/bin/env bash
# Install Aptsy from a GitHub release and run first-time config.
#
#   curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash
#
# Optional:
#   APTSY_VERSION=v0.1.0   pin a release instead of the latest
#   --non-interactive        no questions: install to a writable bin dir,
#                            start the daemon, then configure every tool
#   --uninstall              remove Aptsy from this machine

set -euo pipefail

REPO="selfship-ai/aptsy"
NON_INTERACTIVE=false
UNINSTALL=false
LOG="${HOME}/.aptsy/install.log"
PIDFILE="${HOME}/.aptsy/aptsy.pid"

usage() {
  cat <<'EOF'
Usage: install.sh [--non-interactive] [--uninstall]

  Detects macOS or Linux and amd64 or arm64, downloads the matching
  Aptsy release, installs the CLI and the hook bridge, then configures
  the coding tools found on this machine.

  --non-interactive   skip questions. Uses /usr/local/bin when writable,
                      otherwise ~/.local/bin. Starts the daemon, then
                      configures every discovered tool.
  --uninstall         remove the boot service, hooks, ~/.aptsy, and
                      the aptsy command. Does not download a release.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --uninstall) UNINSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

info() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
die() {
  printf 'install: %s\n' "$*" >&2
  if [[ -d "$(dirname "$LOG")" ]]; then
    printf 'install: %s\n' "$*" >>"$LOG"
  fi
  exit 1
}

# Opening /dev/tty is the real test. The device node can exist in a container
# and still fail with ENXIO. Under curl | bash, stdin is the script.
has_terminal() { (: </dev/tty) >/dev/null 2>&1; }

tty_read() {
  local prompt="$1" reply=""
  if has_terminal; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r reply </dev/tty || reply=""
  else
    printf '%s' "$prompt"
    IFS= read -r reply || reply=""
  fi
  printf '%s' "$reply"
}

refuse_root() {
  local uid="${EUID:-$(id -u)}"
  if [[ "$uid" -eq 0 ]]; then
    die "run this as your user, not root. It writes hooks and config under \$HOME. sudo is used only to install or remove the command in /usr/local/bin and the boot service."
  fi
}

detect_target() {
  local kernel arch
  if [[ -n "${TERMUX_VERSION:-}" ]] || [[ "${PREFIX:-}" == *com.termux/files/usr* ]]; then
    die "Termux is not supported. This installer ships macOS and Linux binaries."
  fi
  kernel="$(uname -s)"
  arch="$(uname -m)"
  case "$kernel" in
    Darwin) OS="darwin" ;;
    Linux) OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "Windows is not installed by this script. Download aptsy_*_windows_*.zip from https://github.com/selfship-ai/aptsy/releases"
      ;;
    *) die "unsupported operating system: ${kernel}" ;;
  esac
  case "$arch" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
    *) die "unsupported CPU architecture: ${arch}" ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"
  info "Detected ${OS}/${ARCH}."
}

public_latest_tag() {
  local body tag
  body="$(curl -fsSL --retry 2 --max-time 20 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: aptsy-install" \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null)" || return 1
  tag="$(printf '%s\n' "$body" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [[ -n "$tag" ]] || return 1
  printf '%s' "$tag"
}

have_auth() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    AUTH="gh"
    return 0
  fi
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  if [[ -n "$token" ]]; then
    command -v python3 >/dev/null 2>&1 || die "python3 is required to read a private GitHub release when gh is not logged in"
    AUTH="curl"
    export GITHUB_TOKEN="$token"
    return 0
  fi
  return 1
}

resolve_release() {
  if [[ -n "${APTSY_VERSION:-}" ]]; then
    TAG="$APTSY_VERSION"
    [[ "$TAG" == v* ]] || TAG="v${TAG}"
  elif TAG="$(public_latest_tag)"; then
    :
  elif have_auth; then
    if [[ "$AUTH" == "gh" ]]; then
      TAG="$(gh release view --repo "$REPO" --json tagName --jq .tagName)"
    else
      TAG="$(curl -fsSL \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: aptsy-install" \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    fi
  else
    die "could not read the latest release. If it is private, run 'gh auth login' or export GITHUB_TOKEN."
  fi
  [[ -n "$TAG" ]] || die "could not determine the release tag"
  VERSION="${TAG#v}"
  ASSET="aptsy_${VERSION}_${OS}_${ARCH}.tar.gz"
  info "Release ${TAG} (${ASSET})."
}

# curl_download [--progress] URL DEST TIMEOUT [curl args...]
# --progress draws a bar on a terminal. TIMEOUT 0 means no limit.
# Extra arguments are curl flags, such as request headers.
curl_download() {
  local progress=false
  if [[ "${1:-}" == "--progress" ]]; then
    progress=true
    shift
  fi
  local url="$1" dest="$2" timeout="$3"
  shift 3
  local -a limit=()
  if [[ "$timeout" != "0" ]]; then
    limit=(--max-time "$timeout")
  fi
  if [[ "$progress" == true && -t 2 ]]; then
    info "Downloading $(basename "$dest")"
    if ! curl -fL --retry 3 "${limit[@]}" --progress-bar "$@" -o "$dest" "$url"; then
      printf 'download failed: %s\n' "$(basename "$dest")" >>"$LOG"
      return 1
    fi
    return 0
  fi
  curl -fL --retry 3 "${limit[@]}" -sS "$@" -o "$dest" "$url" 2>>"$LOG"
}

download_public() {
  local base="https://github.com/${REPO}/releases/download/${TAG}"
  rm -f "$WORK/$ASSET" "$WORK/checksums.txt"
  curl_download --progress "${base}/${ASSET}" "$WORK/$ASSET" 180 && \
    curl_download "${base}/checksums.txt" "$WORK/checksums.txt" 60
}

download_authenticated() {
  have_auth || return 1
  if [[ "$AUTH" == "gh" ]]; then
    gh release download "$TAG" --repo "$REPO" --dir "$WORK" --clobber \
      --pattern "$ASSET" --pattern checksums.txt
    return
  fi
  local asset_url sums_url
  asset_url="$(release_asset_url "$ASSET")"
  sums_url="$(release_asset_url checksums.txt)"
  # curl drops Authorization when the GitHub API redirects to the storage host.
  curl_download --progress "$asset_url" "$WORK/$ASSET" 0 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -H "User-Agent: aptsy-install"
  curl_download "$sums_url" "$WORK/checksums.txt" 0 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -H "User-Agent: aptsy-install"
}

download_release() {
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  if download_public; then
    info "Downloaded the public release."
  else
    info "Public download failed. Trying an authenticated download."
    if ! have_auth || ! download_authenticated; then
      die "could not download ${ASSET}. If the release is private, run 'gh auth login' or export GITHUB_TOKEN."
    fi
  fi
  [[ -f "$WORK/$ASSET" ]] || die "download did not produce ${ASSET}"
  [[ -f "$WORK/checksums.txt" ]] || die "download did not produce checksums.txt"
  verify_checksum "$WORK/$ASSET" "$WORK/checksums.txt"
  tar -xzf "$WORK/$ASSET" -C "$WORK"
  [[ -f "$WORK/aptsy" ]] || die "archive has no aptsy binary"
  [[ -f "$WORK/aptsy-bridge" ]] || die "archive has no aptsy-bridge binary"
  chmod 755 "$WORK/aptsy" "$WORK/aptsy-bridge"
}

release_asset_url() {
  local name="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: aptsy-install" \
    "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" \
    | python3 -c 'import json,sys; name=sys.argv[1]; rel=json.load(sys.stdin)
for asset in rel.get("assets", []):
    if asset["name"] == name:
        print(asset["url"]); break
else:
    sys.exit("missing asset " + name)' "$name"
}

verify_checksum() {
  local file="$1" sums="$2" base want got
  base="$(basename "$file")"
  want="$(grep -F "$base" "$sums" | awk 'NR==1 { print $1 }')"
  [[ -n "$want" ]] || die "checksums.txt has no entry for ${base}"
  if command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$file" | awk '{ print $1 }')"
  else
    got="$(shasum -a 256 "$file" | awk '{ print $1 }')"
  fi
  [[ "$got" == "$want" ]] || die "checksum mismatch for ${base}"
  info "Checksum ok."
}

choose_bindir() {
  local system_dir="/usr/local/bin" user_dir="${HOME}/.local/bin" choice
  if [[ "$NON_INTERACTIVE" == true ]] || ! has_terminal; then
    if [[ -w "$system_dir" ]]; then
      BINDIR="$system_dir"
    else
      BINDIR="$user_dir"
    fi
    info "Installing the aptsy command to ${BINDIR}."
    return
  fi
  info ""
  info "Where should the aptsy command be installed?"
  info "  [1] ${system_dir}  (default; uses sudo when that directory is not writable)"
  info "  [2] ${user_dir}  (also adds it to your shell startup file)"
  choice="$(tty_read "Choice [1]: ")"
  case "${choice:-1}" in
    2) BINDIR="$user_dir" ;;
    1|"") BINDIR="$system_dir" ;;
    *) die "unknown choice: ${choice}" ;;
  esac
}

install_file() {
  local src="$1" dest_dir="$2" name="$3"
  mkdir -p "$dest_dir"
  if [[ -w "$dest_dir" ]]; then
    install -m 755 "$src" "${dest_dir}/${name}"
  elif ! has_terminal || [[ "$NON_INTERACTIVE" == true ]]; then
    die "${dest_dir} is not writable. Re-run without --non-interactive to allow sudo, or choose ~/.local/bin."
  else
    info "Writing ${dest_dir}/${name} requires sudo."
    sudo install -m 755 "$src" "${dest_dir}/${name}"
  fi
}

# A login shell that sources both rc files must not prepend the directory twice.
SHELL_PATH_LINE='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
SHELL_PATH_RE='^[[:space:]]*([^#[:space:]].*)?PATH=.*\.local/bin'

append_shell_path() {
  local rc="$1" line="$2" pattern="$3"
  if [[ -f "$rc" ]] && grep -E "$pattern" "$rc" >/dev/null 2>&1; then
    return 0
  fi
  mkdir -p "$(dirname "$rc")"
  printf '\n# aptsy command\n%s\n' "$line" >>"$rc" || die "cannot update PATH in ${rc}"
  info "Added ~/.local/bin to PATH in ${rc}."
}

wire_shell_path() {
  [[ "$BINDIR" == "${HOME}/.local/bin" ]] || return 0
  local login_shell="${SHELL:-/bin/bash}"
  case "${login_shell##*/}" in
    zsh)
      append_shell_path "${HOME}/.zshrc" "$SHELL_PATH_LINE" "$SHELL_PATH_RE"
      append_shell_path "${HOME}/.zprofile" "$SHELL_PATH_LINE" "$SHELL_PATH_RE"
      ;;
    fish)
      append_shell_path "${HOME}/.config/fish/config.fish" \
        'fish_add_path "$HOME/.local/bin"' \
        '^[[:space:]]*fish_add_path.*\.local/bin'
      ;;
    *)
      append_shell_path "${HOME}/.bashrc" "$SHELL_PATH_LINE" "$SHELL_PATH_RE"
      append_shell_path "${HOME}/.profile" "$SHELL_PATH_LINE" "$SHELL_PATH_RE"
      if [[ -f "${HOME}/.bash_profile" ]]; then
        append_shell_path "${HOME}/.bash_profile" "$SHELL_PATH_LINE" "$SHELL_PATH_RE"
      fi
      ;;
  esac
  case ":${PATH}:" in
    *":${BINDIR}:"*) ;;
    *)
      info "Open a new terminal before typing aptsy. This installer cannot change the shell that launched it."
      ;;
  esac
}

listener_pid() {
  local pid=""
  if [[ -f "$PIDFILE" ]]; then
    pid="$(tr -d '[:space:]' <"$PIDFILE" || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  if command -v lsof >/dev/null 2>&1; then
    pid="$(lsof -nP -iTCP:45117 -sTCP:LISTEN -t 2>/dev/null | awk 'NR==1 { print; exit }')"
    if [[ -z "$pid" ]]; then
      pid="$(lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | awk 'NR==1 { print; exit }')"
    fi
    if [[ -n "$pid" ]]; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  return 1
}

web_up() { curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:45117/health"; }
mcp_up() { curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:45118/health"; }
legacy_up() { curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:8787/health"; }

run_init() {
  local config="${HOME}/.aptsy/config.yml" answer
  info ""
  if [[ -f "$config" ]]; then
    if [[ "$NON_INTERACTIVE" == true ]] || ! has_terminal; then
      info "Config already exists at ${config}. Leaving it in place."
      return 0
    fi
    answer="$(tty_read "Config already exists. Re-run setup and update hooks? [y/N]: ")"
    case "${answer:-N}" in
      y|Y) ;;
      *) info "Keeping ${config}."; return 0 ;;
    esac
  fi
  info "Configuring hooks and ${config}."
  info "aptsy will list the coding tools it found on this machine."
  # Close or replace stdin. Under curl | bash it is the script itself.
  if has_terminal && [[ "$NON_INTERACTIVE" != true ]]; then
    "$APTSY" init </dev/tty
  else
    info "Configuring every discovered tool."
    printf 'Y\n' | "$APTSY" init
  fi
}

start_daemon() {
  # aptsy start registers the boot service and returns. sudo may prompt.
  if has_terminal; then
    "$APTSY" start </dev/tty
  else
    "$APTSY" start </dev/null
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if web_up && mcp_up; then
      info "Stop it with: aptsy stop"
      return 0
    fi
    sleep 0.5
  done
  die "aptsy did not become healthy on 127.0.0.1:45117 and 127.0.0.1:45118."
}

stop_daemon() {
  if has_terminal; then
    "$APTSY" stop </dev/tty
  else
    "$APTSY" stop </dev/null
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if ! web_up && ! legacy_up; then
      return 0
    fi
    sleep 0.5
  done
  die "aptsy is still listening"
}

maybe_start() {
  local answer was_running=false
  if web_up || legacy_up; then
    was_running=true
  fi
  if [[ "$was_running" == true ]]; then
    info "aptsy is already running. The new binary is used after a restart."
    if [[ "$NON_INTERACTIVE" == true ]] || ! has_terminal; then
      info "Stop the current process and run '${APTSY} start'."
      return 0
    fi
    answer="$(tty_read "Restart it with the new binary? [Y/n]: ")"
    case "${answer:-Y}" in
      n|N) info "Left the current process running."; return 0 ;;
      y|Y|"") stop_daemon; start_daemon ;;
      *) die "unknown choice: ${answer}" ;;
    esac
    return 0
  fi
  if [[ "$NON_INTERACTIVE" == true ]] || ! has_terminal; then
    info "Starting aptsy."
    start_daemon
    return 0
  fi
  info ""
  info "Aptsy starts before tool setup, so MCP clients connect to a server that is already running."
  answer="$(tty_read "Start aptsy in the background? [Y/n]: ")"
  case "${answer:-Y}" in
    n|N) info "Run 'aptsy start' when you want the daemon. MCP entries are added then, after the server is up. Stop it with 'aptsy stop'." ;;
    y|Y|"") start_daemon ;;
    *) die "unknown choice: ${answer}" ;;
  esac
}

find_aptsy() {
  local candidate
  for candidate in /usr/local/bin/aptsy "${HOME}/.local/bin/aptsy"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  if command -v aptsy >/dev/null 2>&1; then
    command -v aptsy
    return 0
  fi
  return 1
}

strip_shell_path() {
  local rc="$1" tmp
  [[ -f "$rc" ]] || return 0
  grep -q '^[[:space:]]*# aptsy command[[:space:]]*$' "$rc" || return 0
  tmp="$(mktemp)"
  awk '
    $0 ~ /^[[:space:]]*# aptsy command[[:space:]]*$/ { skip = 1; next }
    skip { skip = 0; next }
    { print }
  ' "$rc" >"$tmp"
  if ! cmp -s "$rc" "$tmp"; then
    mv "$tmp" "$rc"
  else
    rm -f "$tmp"
  fi
}

uninstall_without_cli() {
  printf '%s\n' "Removing the boot service, the aptsy command, and ~/.aptsy."
  printf '%s\n' "Hook entries in other tools are removed when aptsy uninstall is available."
  case "$(uname -s)" in
    Darwin)
      if [[ -f /Library/LaunchDaemons/ai.aptsy.daemon.plist ]]; then
        if launchctl print system/ai.aptsy.daemon >/dev/null 2>&1; then
          sudo launchctl bootout system/ai.aptsy.daemon || true
        fi
        sudo rm -f /Library/LaunchDaemons/ai.aptsy.daemon.plist
      fi
      rm -f "${HOME}/Library/Logs/aptsy.log"
      ;;
    Linux)
      if [[ -f /etc/systemd/system/aptsy.service || -d /var/log/aptsy ]]; then
        sudo systemctl disable --now aptsy || true
        sudo rm -f /etc/systemd/system/aptsy.service
        sudo systemctl daemon-reload || true
        sudo rm -rf /var/log/aptsy
      fi
      if [[ -f "${HOME}/.config/systemd/user/aptsy.service" ]]; then
        systemctl --user disable --now aptsy || true
        rm -f "${HOME}/.config/systemd/user/aptsy.service"
        systemctl --user daemon-reload || true
      fi
      rm -rf "${HOME}/.local/state/aptsy"
      ;;
  esac
  rm -f "${HOME}/.local/bin/aptsy"
  if [[ -f /usr/local/bin/aptsy ]]; then
    sudo rm -f /usr/local/bin/aptsy
  fi
  rm -rf "${HOME}/.aptsy"
  strip_shell_path "${HOME}/.zshrc"
  strip_shell_path "${HOME}/.zprofile"
  strip_shell_path "${HOME}/.bashrc"
  strip_shell_path "${HOME}/.profile"
  strip_shell_path "${HOME}/.bash_profile"
  strip_shell_path "${HOME}/.config/fish/config.fish"
  printf '%s\n' "Aptsy has been uninstalled."
}

run_uninstall() {
  local bin="" status=0
  if ! bin="$(find_aptsy)"; then
    uninstall_without_cli
    return
  fi
  if has_terminal; then
    "$bin" uninstall --yes </dev/tty || status=$?
  else
    "$bin" uninstall --yes </dev/null || status=$?
  fi
  if [[ "$status" -eq 0 ]]; then
    return
  fi
  # Older releases do not have this command. They exit 2 for an unknown command.
  if [[ "$status" -eq 2 ]]; then
    printf '%s\n' "This copy of aptsy has no uninstall command. Removing the files it left behind."
    uninstall_without_cli
    return
  fi
  exit "$status"
}

main() {
  refuse_root
  if [[ "$UNINSTALL" == true ]]; then
    run_uninstall
    return
  fi
  mkdir -p "${HOME}/.aptsy"
  touch "$LOG"
  detect_target
  resolve_release
  download_release
  choose_bindir
  install_file "$WORK/aptsy" "$BINDIR" aptsy
  install_file "$WORK/aptsy-bridge" "${HOME}/.aptsy/hooks" aptsy-bridge
  APTSY="${BINDIR}/aptsy"
  info "Installed ${APTSY}"
  info "Installed ${HOME}/.aptsy/hooks/aptsy-bridge"
  wire_shell_path
  "$APTSY" version </dev/null || true
  maybe_start
  run_init
  info "Done. Install log: ${LOG}"
}

main "$@"
