#!/usr/bin/env bash
# Install Aptsy from a GitHub release and run first-time config.
#
#   curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash
#
# Optional:
#   SSLEARN_VERSION=v0.1.0   pin a release instead of the latest
#   --non-interactive        no questions: install to a writable bin dir,
#                            configure every discovered tool, do not start

set -euo pipefail

REPO="selfship-ai/aptsy"
NON_INTERACTIVE=false
LOG="${HOME}/.selfship/learn/install.log"
PIDFILE="${HOME}/.selfship/learn/sslearn.pid"

usage() {
  cat <<'EOF'
Usage: install.sh [--non-interactive]

  Detects macOS or Linux and amd64 or arm64, downloads the matching
  Aptsy release, installs the CLI and the hook bridge, then configures
  the coding tools found on this machine.

  --non-interactive   skip questions. Uses /usr/local/bin when writable,
                      otherwise ~/.local/bin. Configures every discovered
                      tool. Does not start the daemon.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install: unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

mkdir -p "${HOME}/.selfship/learn"
touch "$LOG"

info() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
die() { printf 'install: %s\n' "$*" | tee -a "$LOG" >&2; exit 1; }

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
    die "run this as your user, not root. It writes hooks and config under \$HOME. sudo is used only to copy sslearn into /usr/local/bin when you choose that directory."
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
      die "Windows is not installed by this script. Download sslearn_*_windows_*.zip from https://github.com/selfship-ai/aptsy/releases"
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
    -H "User-Agent: sslearn-install" \
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
  if [[ -n "${SSLEARN_VERSION:-}" ]]; then
    TAG="$SSLEARN_VERSION"
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
        -H "User-Agent: sslearn-install" \
        "https://api.github.com/repos/${REPO}/releases/latest" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    fi
  else
    die "could not read the latest release. If it is private, run 'gh auth login' or export GITHUB_TOKEN."
  fi
  [[ -n "$TAG" ]] || die "could not determine the release tag"
  VERSION="${TAG#v}"
  ASSET="sslearn_${VERSION}_${OS}_${ARCH}.tar.gz"
  info "Release ${TAG} (${ASSET})."
}

download_public() {
  local base="https://github.com/${REPO}/releases/download/${TAG}"
  rm -f "$WORK/$ASSET" "$WORK/checksums.txt"
  curl -fL --retry 3 --max-time 180 -o "$WORK/$ASSET" "${base}/${ASSET}" 2>>"$LOG" && \
    curl -fL --retry 3 --max-time 60 -o "$WORK/checksums.txt" "${base}/checksums.txt" 2>>"$LOG"
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
  curl -fL --retry 3 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -H "User-Agent: sslearn-install" \
    -o "$WORK/$ASSET" "$asset_url"
  curl -fL --retry 3 \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/octet-stream" \
    -H "User-Agent: sslearn-install" \
    -o "$WORK/checksums.txt" "$sums_url"
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
  [[ -f "$WORK/sslearn" ]] || die "archive has no sslearn binary"
  [[ -f "$WORK/sslearn-bridge" ]] || die "archive has no sslearn-bridge binary"
  chmod 755 "$WORK/sslearn" "$WORK/sslearn-bridge"
}

release_asset_url() {
  local name="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: sslearn-install" \
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
    info "Installing the sslearn command to ${BINDIR}."
    return
  fi
  info ""
  info "Where should the sslearn command be installed?"
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
  printf '\n# sslearn command\n%s\n' "$line" >>"$rc" || die "cannot update PATH in ${rc}"
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
      info "Open a new terminal before typing sslearn. This installer cannot change the shell that launched it."
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
    pid="$(lsof -nP -iTCP:8787 -sTCP:LISTEN -t 2>/dev/null | awk 'NR==1 { print; exit }')"
    if [[ -n "$pid" ]]; then
      printf '%s' "$pid"
      return 0
    fi
  fi
  return 1
}

daemon_up() { curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:8787/health"; }

run_init() {
  local config="${HOME}/.selfship/learn/config.yml" answer
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
  info "sslearn will list the coding tools it found on this machine."
  # Close or replace stdin. Under curl | bash it is the script itself.
  if has_terminal && [[ "$NON_INTERACTIVE" != true ]]; then
    "$SSLEARN" init </dev/tty
  else
    info "Configuring every discovered tool."
    printf 'Y\n' | "$SSLEARN" init
  fi
}

start_daemon() {
  local log="${HOME}/.selfship/learn/sslearn.log"
  mkdir -p "${HOME}/.selfship/learn"
  # stdin must not be the installer script.
  nohup "$SSLEARN" start </dev/null >>"$log" 2>&1 &
  echo $! >"$PIDFILE"
  sleep 1
  if daemon_up; then
    info "Started pid $(cat "$PIDFILE"). Log: ${log}"
    info "Stop with: sslearn stop"
  else
    die "sslearn did not become healthy. See ${log}"
  fi
}

stop_daemon() {
  local pid
  if pid="$(listener_pid)"; then
    kill "$pid" || die "could not stop pid ${pid}"
    local i
    for i in 1 2 3 4 5; do
      daemon_up || return 0
      sleep 1
    done
    die "sslearn pid ${pid} is still listening on 127.0.0.1:8787"
  fi
  die "sslearn is listening on 127.0.0.1:8787 but its pid was not found. Stop it, then rerun."
}

maybe_start() {
  local answer was_running=false
  if daemon_up; then
    was_running=true
  fi
  if [[ "$was_running" == true ]]; then
    info "sslearn is already running. The new binary is used after a restart."
    if [[ "$NON_INTERACTIVE" == true ]] || ! has_terminal; then
      info "Stop the current process and run '${SSLEARN} start'."
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
    info "Run '${SSLEARN} start' when you want the daemon."
    return 0
  fi
  info ""
  answer="$(tty_read "Start sslearn in the background? [Y/n]: ")"
  case "${answer:-Y}" in
    n|N) info "Run '${SSLEARN} start' when you want the daemon. Stop a background daemon with 'sslearn stop', or press Ctrl+C if it is in this terminal." ;;
    y|Y|"") start_daemon ;;
    *) die "unknown choice: ${answer}" ;;
  esac
}

main() {
  refuse_root
  detect_target
  resolve_release
  download_release
  choose_bindir
  install_file "$WORK/sslearn" "$BINDIR" sslearn
  install_file "$WORK/sslearn-bridge" "${HOME}/.selfship/hooks" sslearn-bridge
  SSLEARN="${BINDIR}/sslearn"
  info "Installed ${SSLEARN}"
  info "Installed ${HOME}/.selfship/hooks/sslearn-bridge"
  wire_shell_path
  "$SSLEARN" version </dev/null || true
  run_init
  maybe_start
  info "Done. Install log: ${LOG}"
}

main "$@"
