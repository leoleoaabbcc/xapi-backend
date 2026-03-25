#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
CONFIG_TEMPLATE="${REPO_ROOT}/config.example.yaml"
CONFIG_FILE="${REPO_ROOT}/config.yaml"
SERVICE_NAME="cli-proxy-api"

usage() {
  cat <<'EOF'
Usage:
  scripts/setup.sh <command> [options]

Commands:
  install      Copy config.yaml and start the Docker service
  set-admin-password
               Update remote-management.secret-key in config.yaml
  start        Start the Docker service
  stop         Stop the Docker service
  restart      Restart the Docker service
  status       Show service status
  logs         Show service logs
  down         Remove the service container
  help         Show this help message

Install options:
  --mode <prebuilt|source>   Use remote image or build from source
  --force                    Overwrite existing config.yaml

Password options:
  --password <value>         New admin password
  --config <path>            Target config file path (default: ./config.yaml)
  --restart                  Restart service after updating password

Log options:
  --follow                   Follow logs output
  --tail <N>                 Show last N log lines (default: 100)

Examples:
  scripts/setup.sh install --mode prebuilt
  scripts/setup.sh install --mode source --force
  scripts/setup.sh set-admin-password --password 'change-me' --restart
  scripts/setup.sh status
  scripts/setup.sh logs --follow
EOF
}

require_command() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: '${cmd}' is required but not installed."
    exit 1
  fi
}

require_option_value() {
  local option="$1"
  local value="${2-}"

  if [[ -z "${value}" ]]; then
    echo "Error: option '${option}' requires a value."
    exit 1
  fi
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

get_public_ip() {
  local ip=""

  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true)"
  fi

  if [[ -z "${ip}" ]] && command -v wget >/dev/null 2>&1; then
    ip="$(wget -4qO- --timeout=3 https://api.ipify.org 2>/dev/null || true)"
  fi

  printf '%s' "${ip}"
}

ensure_prerequisites() {
  require_command docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "Error: 'docker compose' is required."
    exit 1
  fi
}

copy_config() {
  local target="$1"
  local force="$2"
  local generated_password=""

  if [[ ! -f "${CONFIG_TEMPLATE}" ]]; then
    echo "Error: config template not found at ${CONFIG_TEMPLATE}"
    exit 1
  fi

  if [[ -f "${target}" && "${force}" != "true" ]]; then
    echo "Config already exists at ${target}. Skipping copy."
    return
  fi

  mkdir -p "$(dirname "${target}")"
  cp "${CONFIG_TEMPLATE}" "${target}"
  generated_password="$(generate_random_password)"
  set_admin_password "${target}" "${generated_password}" >/dev/null
  echo "Config created at ${target}"
  echo "Generated admin password: ${generated_password}"
}

build_and_start() {
  local mode="$1"

  case "${mode}" in
    prebuilt)
      echo "Starting service from pre-built image..."
      compose up -d --remove-orphans --no-build
      ;;
    source)
      echo "Building image from source..."
      local version commit build_date
      version="$(git -C "${REPO_ROOT}" describe --tags --always --dirty 2>/dev/null || echo dev)"
      commit="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo none)"
      build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

      export CLI_PROXY_IMAGE="cli-proxy-api:local"
      compose build \
        --build-arg VERSION="${version}" \
        --build-arg COMMIT="${commit}" \
        --build-arg BUILD_DATE="${build_date}"
      compose up -d --remove-orphans --pull never
      ;;
    *)
      echo "Error: unsupported install mode '${mode}'"
      exit 1
      ;;
  esac
}

show_status() {
  local port_output=""
  local public_ip=""
  local public_port=""

  compose ps

  if port_output="$(compose port "${SERVICE_NAME}" 8317 2>/dev/null)"; then
    echo
    echo "Service port:"
    echo "  ${port_output}"

    public_port="${port_output##*:}"
    public_ip="$(get_public_ip)"

    echo "Public access:"
    if [[ -n "${public_ip}" && -n "${public_port}" ]]; then
      echo "  ${public_ip}:${public_port}"
    else
      echo "  unavailable"
    fi
  else
    echo
    echo "Service port:"
    echo "  unavailable"
    echo "Public access:"
    echo "  unavailable"
  fi
}

show_logs() {
  local follow="$1"
  local tail_lines="$2"

  if [[ ! "${tail_lines}" =~ ^[0-9]+$ ]]; then
    echo "Error: --tail must be a non-negative integer."
    exit 1
  fi

  if [[ "${follow}" == "true" ]]; then
    compose logs -f --tail "${tail_lines}" "${SERVICE_NAME}"
  else
    compose logs --tail "${tail_lines}" "${SERVICE_NAME}"
  fi
}

generate_random_password() {
  local password=""

  if command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -base64 24 | tr -d '\n' | tr -d '/+=' | cut -c1-20)"
  fi

  if [[ -z "${password}" ]] && [[ -r /dev/urandom ]]; then
    password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  fi

  if [[ -z "${password}" ]]; then
    password="$(date +%s)Setup$(printf '%06d' "$((RANDOM % 1000000))")"
  fi

  printf '%s' "${password}"
}

prompt_password() {
  local password=""
  local confirm=""

  while true; do
    read -r -s -p "Enter new admin password: " password
    echo >&2
    if [[ -z "${password}" ]]; then
      echo "Error: password cannot be empty." >&2
      continue
    fi

    read -r -s -p "Confirm new admin password: " confirm
    echo >&2
    if [[ "${password}" != "${confirm}" ]]; then
      echo "Error: passwords do not match." >&2
      continue
    fi

    printf '%s' "${password}"
    return
  done
}

set_admin_password() {
  local config_path="$1"
  local password="$2"
  local config_dir tmp_file

  if [[ ! -f "${config_path}" ]]; then
    echo "Error: config file not found at ${config_path}"
    exit 1
  fi

  config_dir="$(dirname "${config_path}")"
  tmp_file="$(mktemp "${config_dir}/.setup-config.XXXXXX")"

  SETUP_ADMIN_PASSWORD="${password}" awk '
    BEGIN {
      secret = ENVIRON["SETUP_ADMIN_PASSWORD"]
      gsub(/\\/, "\\\\", secret)
      gsub(/"/, "\\\"", secret)
      in_remote = 0
      found_remote = 0
      updated = 0
      indent = "  "
    }
    /^remote-management:[[:space:]]*$/ {
      print
      in_remote = 1
      found_remote = 1
      next
    }
    in_remote && /^[^[:space:]]/ {
      if (!updated) {
        print indent "secret-key: \"" secret "\""
        updated = 1
      }
      in_remote = 0
    }
    in_remote && /^[[:space:]]+secret-key:[[:space:]]*/ {
      match($0, /^[[:space:]]+/)
      indent = substr($0, RSTART, RLENGTH)
      print indent "secret-key: \"" secret "\""
      updated = 1
      next
    }
    {
      print
    }
    END {
      if (in_remote && !updated) {
        print indent "secret-key: \"" secret "\""
      } else if (!found_remote) {
        print ""
        print "remote-management:"
        print indent "secret-key: \"" secret "\""
      }
    }
  ' "${config_path}" > "${tmp_file}"

  mv "${tmp_file}" "${config_path}"
  chmod 600 "${config_path}" 2>/dev/null || true
  echo "Admin password updated in ${config_path}"
}

prompt_main_command() {
  cat >&2 <<'EOF'
Select an action:
  1) install
  2) set-admin-password
  3) start
  4) stop
  5) restart
  6) status
  7) logs
  8) down
  9) help
EOF
  read -r -p "Enter choice [1-9]: " choice

  case "${choice}" in
    1) echo "install" ;;
    2) echo "set-admin-password" ;;
    3) echo "start" ;;
    4) echo "stop" ;;
    5) echo "restart" ;;
    6) echo "status" ;;
    7) echo "logs" ;;
    8) echo "down" ;;
    9) echo "help" ;;
    *) echo "Error: invalid choice" >&2; exit 1 ;;
  esac
}

prompt_install_mode() {
  cat >&2 <<'EOF'
Select install mode:
  1) prebuilt
  2) source
EOF
  read -r -p "Enter choice [1-2]: " choice

  case "${choice}" in
    1) echo "prebuilt" ;;
    2) echo "source" ;;
    *) echo "Error: invalid choice" >&2; exit 1 ;;
  esac
}

run_install() {
  local mode="$1"
  local force="$2"

  ensure_prerequisites
  copy_config "${CONFIG_FILE}" "${force}"
  build_and_start "${mode}"
  show_status
}

main() {
  local command="${1:-}"
  local install_mode=""
  local force="false"
  local config_path="${CONFIG_FILE}"
  local log_follow="false"
  local log_tail="100"
  local admin_password=""
  local restart_after_password_change="false"

  if [[ -z "${command}" ]]; then
    command="$(prompt_main_command)"
  else
    shift
  fi

  case "${command}" in
    install)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --mode)
            require_option_value "$1" "${2-}"
            install_mode="${2:-}"
            shift 2
            ;;
          --force)
            force="true"
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            echo "Error: unknown option '$1'"
            usage
            exit 1
            ;;
        esac
      done

      if [[ -z "${install_mode}" ]]; then
        install_mode="$(prompt_install_mode)"
      fi

      run_install "${install_mode}" "${force}"
      ;;
    set-admin-password)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --password)
            require_option_value "$1" "${2-}"
            admin_password="${2:-}"
            shift 2
            ;;
          --config)
            require_option_value "$1" "${2-}"
            config_path="${2:-}"
            shift 2
            ;;
          --restart)
            restart_after_password_change="true"
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            echo "Error: unknown option '$1'"
            usage
            exit 1
            ;;
        esac
      done

      if [[ -z "${admin_password}" ]]; then
        admin_password="$(prompt_password)"
      fi

      set_admin_password "${config_path}" "${admin_password}"

      if [[ "${restart_after_password_change}" == "true" ]]; then
        ensure_prerequisites
        compose restart "${SERVICE_NAME}"
        show_status
      else
        echo "Restart the service to apply the new password."
      fi
      ;;
    start)
      ensure_prerequisites
      compose up -d --remove-orphans --no-build
      show_status
      ;;
    stop)
      ensure_prerequisites
      compose stop
      show_status
      ;;
    restart)
      ensure_prerequisites
      compose restart
      show_status
      ;;
    status)
      ensure_prerequisites
      show_status
      ;;
    logs)
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --follow)
            log_follow="true"
            shift
            ;;
          --tail)
            require_option_value "$1" "${2-}"
            log_tail="${2:-}"
            shift 2
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            echo "Error: unknown option '$1'"
            usage
            exit 1
            ;;
        esac
      done

      ensure_prerequisites
      show_logs "${log_follow}" "${log_tail}"
      ;;
    down)
      ensure_prerequisites
      compose down
      ;;
    help|-h|--help)
      usage
      ;;
    *)
      echo "Error: unknown command '${command}'"
      usage
      exit 1
      ;;
  esac
}

main "$@"
