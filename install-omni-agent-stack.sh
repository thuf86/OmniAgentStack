#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Omni Agent Stack - Instalador Interativo para Linux
#
# Este script NÃO baixa os repositórios.
#
# Estrutura esperada:
#
# OmniAgentStack/
# ├── components/
# ├── skills/
# ├── claude-agents/
# ├── AGENTS.md
# └── install-interactive.sh
#
# Menu principal:
#   1. Instalar apenas no Codex
#   2. Instalar apenas no Claude
#   3. Instalar ambos Codex/Claude
#   4. Instalar separados
#   0. Sair
# ==============================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENTS_ROOT="$ROOT/components"
SKILLS_ROOT="$ROOT/skills"
CLAUDE_AGENTS_ROOT="$ROOT/claude-agents"
AGENTS_FILE="$ROOT/AGENTS.md"

RUNTIME_ROOT="$ROOT/.omni"
VENV_ROOT="$RUNTIME_ROOT/venvs"
LOGS_ROOT="$RUNTIME_ROOT/logs"
STATE_FILE="$RUNTIME_ROOT/install-state.tsv"
LOG_FILE="$LOGS_ROOT/install-$(date +%Y%m%d-%H%M%S).log"

COMPONENT_IDS=(
  "anything-llm"
  "autogen"
  "browser-use"
  "crawl4ai"
  "crewai"
  "firecrawl"
  "langflow"
  "localai"
  "mem0"
  "ragflow"
)

COMPONENT_NAMES=(
  "AnythingLLM"
  "AutoGen"
  "Browser Use"
  "Crawl4AI"
  "CrewAI"
  "Firecrawl"
  "Langflow"
  "LocalAI"
  "Mem0"
  "RAGFlow"
)

COMPONENT_METHODS=(
  "node"
  "python"
  "python"
  "python"
  "python"
  "compose"
  "python"
  "docker-image"
  "python"
  "compose"
)

# ==============================================================================
# Cores
# ==============================================================================

if [[ -t 1 ]]; then
  C_CYAN=$'\033[1;36m'
  C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'
  C_RED=$'\033[1;31m'
  C_GRAY=$'\033[0;37m'
  C_RESET=$'\033[0m'
else
  C_CYAN=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_GRAY=""
  C_RESET=""
fi

# ==============================================================================
# Utilitários
# ==============================================================================

initialize_installer() {
  mkdir -p "$VENV_ROOT" "$LOGS_ROOT"

  if [[ ! -d "$COMPONENTS_ROOT" ]]; then
    echo "ERRO: pasta de componentes não encontrada:"
    echo "$COMPONENTS_ROOT"
    echo
    echo "Execute primeiro o script de download dos repositórios."
    exit 1
  fi

  touch "$STATE_FILE" "$LOG_FILE"
}

log() {
  local level="$1"
  shift
  local message="$*"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

  printf '[%s][%s] %s\n' "$timestamp" "$level" "$message" >> "$LOG_FILE"

  case "$level" in
    OK)    printf '%s%s%s\n' "$C_GREEN" "$message" "$C_RESET" ;;
    WARN)  printf '%s%s%s\n' "$C_YELLOW" "$message" "$C_RESET" ;;
    ERROR) printf '%s%s%s\n' "$C_RED" "$message" "$C_RESET" ;;
    STEP)  printf '%s%s%s\n' "$C_CYAN" "$message" "$C_RESET" ;;
    *)     printf '%s%s%s\n' "$C_GRAY" "$message" "$C_RESET" ;;
  esac
}

pause_menu() {
  read -r -p $'\nPressione ENTER para continuar' _
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

confirm_yes() {
  local prompt="$1"
  local answer

  read -r -p "$prompt [S/n] " answer
  answer="${answer:-s}"

  [[ "$answer" =~ ^[sSyY]$ ]]
}

run_checked() {
  local working_directory="$1"
  shift

  log INFO "Executando em $working_directory: $*"

  (
    cd "$working_directory"
    "$@"
  ) 2>&1 | tee -a "$LOG_FILE"

  local status=${PIPESTATUS[0]}

  if [[ $status -ne 0 ]]; then
    return "$status"
  fi
}

run_capture() {
  local working_directory="$1"
  shift

  log INFO "Executando em $working_directory: $*"

  local output
  local status

  set +e
  output="$(
    cd "$working_directory" &&
    "$@" 2>&1
  )"
  status=$?
  set -e

  printf '%s\n' "$output" >> "$LOG_FILE"
  printf '%s' "$output"

  return "$status"
}

save_state() {
  local id="$1"
  local status="$2"
  local detail="$3"
  local temp_file

  temp_file="$(mktemp)"

  if [[ -f "$STATE_FILE" ]]; then
    awk -F '\t' -v id="$id" '$1 != id' "$STATE_FILE" > "$temp_file" || true
  fi

  printf '%s\t%s\t%s\t%s\n' \
    "$id" \
    "$status" \
    "$(date -Iseconds)" \
    "$detail" >> "$temp_file"

  mv "$temp_file" "$STATE_FILE"
}

component_path() {
  local index="$1"
  printf '%s/%s' "$COMPONENTS_ROOT" "${COMPONENT_IDS[$index]}"
}

copy_tree_idempotent() {
  local source="$1"
  local destination="$2"

  if [[ ! -d "$source" ]]; then
    log ERROR "Diretório de origem não encontrado: $source"
    return 1
  fi

  mkdir -p "$destination"

  if command_exists rsync; then
    rsync -a --ignore-existing "$source/" "$destination/"
    rsync -a --update "$source/" "$destination/"
  else
    cp -a "$source/." "$destination/"
  fi
}

# ==============================================================================
# Integrações Claude Code e Codex
# ==============================================================================

validate_integration_assets() {
  [[ -d "$SKILLS_ROOT" ]] || {
    log ERROR "Pasta de skills não encontrada: $SKILLS_ROOT"
    return 1
  }

  [[ -d "$CLAUDE_AGENTS_ROOT" ]] || {
    log ERROR "Pasta de agentes não encontrada: $CLAUDE_AGENTS_ROOT"
    return 1
  }

  [[ -f "$AGENTS_FILE" ]] || {
    log ERROR "Arquivo AGENTS.md não encontrado: $AGENTS_FILE"
    return 1
  }
}

install_codex_integration() {
  validate_integration_assets

  local codex_root="$HOME/.codex"
  local skills_target="$codex_root/skills"
  local agents_target="$codex_root/AGENTS.md"

  log STEP "Configurando Omni Agent Stack no Codex..."

  mkdir -p "$codex_root"
  copy_tree_idempotent "$SKILLS_ROOT" "$skills_target"

  if [[ -f "$agents_target" ]] && ! cmp -s "$AGENTS_FILE" "$agents_target"; then
    local backup="$agents_target.backup-$(date +%Y%m%d-%H%M%S)"
    cp -a "$agents_target" "$backup"
    log WARN "Backup criado: $backup"
  fi

  cp -a "$AGENTS_FILE" "$agents_target"

  local skills_count
  skills_count="$(find "$skills_target" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

  if [[ "$skills_count" -lt 1 || ! -f "$agents_target" ]]; then
    save_state "integration-codex" "failed" "Falha na validação"
    log ERROR "A validação da integração com o Codex falhou."
    return 1
  fi

  save_state "integration-codex" "installed" "$skills_count skills instaladas"
  log OK "Codex configurado e validado com $skills_count skill(s)."
}

install_claude_integration() {
  validate_integration_assets

  local claude_root="$HOME/.claude"
  local skills_target="$claude_root/skills"
  local agents_target="$claude_root/agents"

  log STEP "Configurando Omni Agent Stack no Claude Code..."

  mkdir -p "$claude_root"
  copy_tree_idempotent "$SKILLS_ROOT" "$skills_target"
  copy_tree_idempotent "$CLAUDE_AGENTS_ROOT" "$agents_target"

  local skills_count
  local agents_count

  skills_count="$(find "$skills_target" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  agents_count="$(find "$agents_target" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"

  if [[ "$skills_count" -lt 1 || "$agents_count" -lt 1 ]]; then
    save_state "integration-claude" "failed" "Falha na validação"
    log ERROR "A validação da integração com o Claude Code falhou."
    return 1
  fi

  save_state \
    "integration-claude" \
    "installed" \
    "$skills_count skills e $agents_count agentes instalados"

  log OK "Claude Code configurado e validado com $skills_count skill(s) e $agents_count agente(s)."
}

install_target_integration() {
  local target="$1"

  case "$target" in
    codex)
      install_codex_integration
      ;;
    claude)
      install_claude_integration
      ;;
    both)
      install_codex_integration
      install_claude_integration
      ;;
    *)
      log ERROR "Destino desconhecido: $target"
      return 1
      ;;
  esac
}

# ==============================================================================
# Python
# ==============================================================================

get_python_command() {
  local candidate

  for candidate in python3 python; do
    if command_exists "$candidate"; then
      local version
      version="$("$candidate" -c 'import sys; print(".".join(map(str, sys.version_info[:3])))' 2>/dev/null || true)"

      if [[ -n "$version" ]]; then
        printf '%s|%s' "$candidate" "$version"
        return 0
      fi
    fi
  done

  return 1
}

version_ge() {
  local current="$1"
  local minimum="$2"

  printf '%s\n%s\n' "$minimum" "$current" |
    sort -V -C
}

venv_python() {
  local id="$1"
  printf '%s/%s/bin/python' "$VENV_ROOT" "$id"
}

python_component_config() {
  local id="$1"

  case "$id" in
    autogen)
      printf '%s\n' \
        "3.10" \
        "autogen-agentchat|autogen-ext[openai]|autogenstudio" \
        "autogen_agentchat|autogen_ext|autogenstudio" \
        ""
      ;;
    browser-use)
      printf '%s\n' \
        "3.11" \
        "browser-use" \
        "browser_use" \
        "playwright"
      ;;
    crawl4ai)
      printf '%s\n' \
        "3.10" \
        "crawl4ai" \
        "crawl4ai" \
        "crawl4ai"
      ;;
    crewai)
      printf '%s\n' \
        "3.10" \
        "crewai" \
        "crewai" \
        ""
      ;;
    langflow)
      printf '%s\n' \
        "3.10" \
        "langflow" \
        "langflow" \
        ""
      ;;
    mem0)
      printf '%s\n' \
        "3.10" \
        "mem0ai" \
        "mem0" \
        ""
      ;;
    *)
      return 1
      ;;
  esac
}

test_python_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local python_bin

  python_bin="$(venv_python "$id")"

  [[ -x "$python_bin" ]] || return 1

  mapfile -t config < <(python_component_config "$id")
  local imports="${config[2]}"

  IFS='|' read -r -a import_list <<< "$imports"

  local module
  for module in "${import_list[@]}"; do
    "$python_bin" -c "import $module" >/dev/null 2>&1 || return 1
  done

  return 0
}

install_python_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local name="${COMPONENT_NAMES[$index]}"

  if test_python_component "$index"; then
    log OK "$name já está instalado e validado. Reinstalação evitada."
    save_state "$id" "installed" "Importações Python validadas"
    return 0
  fi

  local python_info
  python_info="$(get_python_command)" || {
    log ERROR "Python não encontrado."
    return 1
  }

  local python_cmd="${python_info%%|*}"
  local python_version="${python_info##*|}"

  mapfile -t config < <(python_component_config "$id")
  local minimum="${config[0]}"
  local packages="${config[1]}"
  local post_install="${config[3]}"

  if ! version_ge "$python_version" "$minimum"; then
    log ERROR "$name requer Python $minimum ou superior. Encontrado: $python_version"
    return 1
  fi

  local venv_dir="$VENV_ROOT/$id"
  local python_bin="$venv_dir/bin/python"

  if [[ ! -x "$python_bin" ]]; then
    log STEP "Criando ambiente Python isolado: $venv_dir"
    "$python_cmd" -m venv "$venv_dir" 2>&1 | tee -a "$LOG_FILE"
  else
    log WARN "Ambiente Python existente será reparado e validado."
  fi

  "$python_bin" -m pip install \
    --disable-pip-version-check \
    --upgrade \
    pip \
    setuptools \
    wheel 2>&1 | tee -a "$LOG_FILE"

  IFS='|' read -r -a package_list <<< "$packages"

  local package
  for package in "${package_list[@]}"; do
    "$python_bin" -m pip install \
      --upgrade \
      "$package" 2>&1 | tee -a "$LOG_FILE"
  done

  case "$post_install" in
    playwright)
      "$python_bin" -m playwright install chromium 2>&1 | tee -a "$LOG_FILE"
      ;;
    crawl4ai)
      local setup_command="$venv_dir/bin/crawl4ai-setup"

      if [[ -x "$setup_command" ]]; then
        "$setup_command" 2>&1 | tee -a "$LOG_FILE"
      else
        log WARN "crawl4ai-setup não foi localizado; a validação seguirá por importação."
      fi
      ;;
  esac

  if ! test_python_component "$index"; then
    log ERROR "$name foi processado, mas a validação por importação falhou."
    save_state "$id" "failed" "Validação Python falhou"
    return 1
  fi

  "$python_bin" -m pip freeze > "$RUNTIME_ROOT/$id-requirements.lock.txt"

  save_state "$id" "installed" "Ambiente Python validado"
  log OK "$name instalado e validado."
}

# ==============================================================================
# Node.js
# ==============================================================================

resolve_node_directory() {
  local index="$1"
  local component_dir
  component_dir="$(component_path "$index")"

  if [[ -f "$component_dir/server/package.json" ]]; then
    printf '%s/server' "$component_dir"
    return 0
  fi

  if [[ -f "$component_dir/package.json" ]]; then
    printf '%s' "$component_dir"
    return 0
  fi

  return 1
}

test_node_component() {
  local index="$1"
  local directory

  directory="$(resolve_node_directory "$index")" || return 1

  [[ -d "$directory/node_modules" ]] || return 1
  command_exists npm || return 1

  (
    cd "$directory"
    npm ls --depth=0 --silent >/dev/null 2>&1
  )

  local status=$?

  [[ $status -eq 0 || $status -eq 1 ]]
}

install_node_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local name="${COMPONENT_NAMES[$index]}"
  local directory

  directory="$(resolve_node_directory "$index")" || {
    log ERROR "Nenhum package.json foi encontrado para $name."
    return 1
  }

  if test_node_component "$index"; then
    log OK "$name já possui dependências Node válidas. Reinstalação evitada."
    save_state "$id" "installed" "Dependências Node validadas"
    return 0
  fi

  command_exists node || {
    log ERROR "Node.js não encontrado."
    return 1
  }

  command_exists npm || {
    log ERROR "npm não encontrado."
    return 1
  }

  if [[ -f "$directory/pnpm-lock.yaml" ]] && command_exists pnpm; then
    run_checked "$directory" pnpm install --frozen-lockfile
  elif [[ -f "$directory/yarn.lock" ]] && command_exists yarn; then
    run_checked "$directory" yarn install --frozen-lockfile
  elif [[ -f "$directory/package-lock.json" ]]; then
    run_checked "$directory" npm ci
  else
    run_checked "$directory" npm install
  fi

  if ! test_node_component "$index"; then
    log ERROR "A validação Node de $name falhou."
    save_state "$id" "failed" "Validação Node falhou"
    return 1
  fi

  save_state "$id" "installed" "Dependências Node validadas"
  log OK "$name instalado e validado."
}

# ==============================================================================
# Docker
# ==============================================================================

test_docker_ready() {
  command_exists docker || return 1
  docker info >/dev/null 2>&1
}

compose_hints() {
  local id="$1"

  case "$id" in
    firecrawl)
      printf '%s\n' \
        "apps/api/docker-compose.yml" \
        "apps/api/docker-compose.yaml" \
        "docker-compose.yml" \
        "docker-compose.yaml" \
        "compose.yml" \
        "compose.yaml"
      ;;
    ragflow)
      printf '%s\n' \
        "docker/docker-compose.yml" \
        "docker/docker-compose.yaml" \
        "docker-compose.yml" \
        "docker-compose.yaml" \
        "compose.yml" \
        "compose.yaml"
      ;;
  esac
}

find_compose_file() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local component_dir
  component_dir="$(component_path "$index")"

  local relative
  while IFS= read -r relative; do
    [[ -n "$relative" ]] || continue

    if [[ -f "$component_dir/$relative" ]]; then
      printf '%s/%s' "$component_dir" "$relative"
      return 0
    fi
  done < <(compose_hints "$id")

  find "$component_dir" \
    -type f \
    \( \
      -name 'docker-compose.yml' -o \
      -name 'docker-compose.yaml' -o \
      -name 'compose.yml' -o \
      -name 'compose.yaml' \
    \) \
    -print |
    awk '{ print length($0), $0 }' |
    sort -n |
    cut -d' ' -f2- |
    head -n 1
}

ensure_compose_env() {
  local compose_file="$1"
  local directory
  directory="$(dirname "$compose_file")"

  [[ -f "$directory/.env" ]] && return 0

  local template

  for template in ".env.example" "env.example" ".env.template"; do
    if [[ -f "$directory/$template" ]]; then
      cp -a "$directory/$template" "$directory/.env"
      log OK ".env criado a partir de $template."
      return 0
    fi
  done
}

test_compose_component() {
  local index="$1"

  test_docker_ready || return 1

  local compose_file
  compose_file="$(find_compose_file "$index")"

  [[ -n "$compose_file" && -f "$compose_file" ]] || return 1

  local directory
  directory="$(dirname "$compose_file")"

  local services
  services="$(
    cd "$directory" &&
    docker compose -f "$compose_file" config --services 2>/dev/null
  )" || return 1

  [[ -n "$services" ]]
}

install_compose_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local name="${COMPONENT_NAMES[$index]}"

  test_docker_ready || {
    log ERROR "Docker não está instalado, não está em execução ou não respondeu."
    return 1
  }

  local compose_file
  compose_file="$(find_compose_file "$index")"

  if [[ -z "$compose_file" || ! -f "$compose_file" ]]; then
    log ERROR "Nenhum arquivo Docker Compose foi localizado para $name."
    return 1
  fi

  ensure_compose_env "$compose_file"

  local directory
  directory="$(dirname "$compose_file")"

  local running_services
  running_services="$(
    cd "$directory" &&
    docker compose -f "$compose_file" ps --status running --services 2>/dev/null || true
  )"

  if [[ -n "$running_services" ]]; then
    local running_count
    running_count="$(printf '%s\n' "$running_services" | sed '/^$/d' | wc -l | tr -d ' ')"

    log OK "$name já possui $running_count serviço(s) em execução. Duplicação evitada."
    save_state "$id" "installed" "$running_count serviços Docker ativos"
    return 0
  fi

  (
    cd "$directory"
    docker compose -f "$compose_file" pull --ignore-pull-failures || true
    docker compose -f "$compose_file" build || true
    docker compose -f "$compose_file" up -d --remove-orphans
  ) 2>&1 | tee -a "$LOG_FILE"

  sleep 5

  running_services="$(
    cd "$directory" &&
    docker compose -f "$compose_file" ps --status running --services 2>/dev/null || true
  )"

  if [[ -z "$running_services" ]]; then
    log ERROR "Nenhum serviço de $name permaneceu em execução."
    save_state "$id" "failed" "Nenhum serviço Docker ativo"
    return 1
  fi

  if ! test_compose_component "$index"; then
    log ERROR "A configuração Docker Compose de $name não passou na validação."
    save_state "$id" "failed" "Compose inválido"
    return 1
  fi

  local active_count
  active_count="$(printf '%s\n' "$running_services" | sed '/^$/d' | wc -l | tr -d ' ')"

  save_state "$id" "installed" "$active_count serviços Docker ativos"
  log OK "$name instalado e validado."
}

test_docker_image_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"

  [[ "$id" == "localai" ]] || return 1

  test_docker_ready || return 1
  docker image inspect "localai/localai:latest-aio-cpu" >/dev/null 2>&1
}

install_docker_image_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local name="${COMPONENT_NAMES[$index]}"
  local image="localai/localai:latest-aio-cpu"

  test_docker_ready || {
    log ERROR "Docker não está disponível."
    return 1
  }

  if test_docker_image_component "$index"; then
    log OK "$name já possui a imagem $image. Download duplicado evitado."
    save_state "$id" "installed" "Imagem Docker validada"
    return 0
  fi

  docker pull "$image" 2>&1 | tee -a "$LOG_FILE"

  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log ERROR "A imagem Docker de $name não passou na validação."
    save_state "$id" "failed" "Imagem Docker inválida"
    return 1
  fi

  save_state "$id" "installed" "Imagem Docker validada"
  log OK "$name instalado e validado."
}

# ==============================================================================
# Orquestração
# ==============================================================================

test_component() {
  local index="$1"
  local method="${COMPONENT_METHODS[$index]}"

  case "$method" in
    python)
      test_python_component "$index"
      ;;
    node)
      test_node_component "$index"
      ;;
    compose)
      test_compose_component "$index"
      ;;
    docker-image)
      test_docker_image_component "$index"
      ;;
    *)
      return 1
      ;;
  esac
}

install_component() {
  local index="$1"
  local id="${COMPONENT_IDS[$index]}"
  local name="${COMPONENT_NAMES[$index]}"
  local method="${COMPONENT_METHODS[$index]}"
  local directory

  directory="$(component_path "$index")"

  if [[ ! -d "$directory" ]]; then
    log ERROR "$name: repositório não encontrado em $directory."
    save_state "$id" "missing" "Repositório não encontrado"
    return 1
  fi

  log STEP "Preparando $name..."

  local status=0

  case "$method" in
    python)
      install_python_component "$index" || status=$?
      ;;
    node)
      install_node_component "$index" || status=$?
      ;;
    compose)
      install_compose_component "$index" || status=$?
      ;;
    docker-image)
      install_docker_image_component "$index" || status=$?
      ;;
    *)
      log ERROR "Método desconhecido para $name: $method"
      status=1
      ;;
  esac

  if [[ $status -ne 0 ]]; then
    save_state "$id" "failed" "Falha durante a instalação"
    log ERROR "$name: FALHA."
    log WARN "Consulte o log: $LOG_FILE"
    return 1
  fi

  if ! test_component "$index"; then
    save_state "$id" "failed" "Validação final falhou"
    log ERROR "$name: a validação final não confirmou a instalação."
    return 1
  fi

  save_state "$id" "installed" "Instalação validada"
  log OK "$name: INSTALADO E VALIDADO."
}

install_all_components() {
  local success=0
  local failed=0
  local index

  for index in "${!COMPONENT_IDS[@]}"; do
    if install_component "$index"; then
      ((success += 1))
    else
      ((failed += 1))
    fi
  done

  if [[ $failed -eq 0 ]]; then
    log OK "Instalação concluída: $success componente(s) válido(s), nenhuma falha."
    return 0
  fi

  log WARN "Instalação concluída: $success componente(s) válido(s), $failed falha(s)."
  return 1
}

install_complete_stack() {
  local target="$1"

  clear

  printf '%s\n' "${C_CYAN}==============================================${C_RESET}"
  printf '%s\n' "${C_CYAN}       INSTALAÇÃO DO OMNI AGENT STACK${C_RESET}"
  printf '%s\n\n' "${C_CYAN}==============================================${C_RESET}"

  if ! install_target_integration "$target"; then
    log ERROR "Falha ao configurar a integração selecionada."
    pause_menu
    return
  fi

  log STEP "Iniciando instalação dos dez componentes..."

  install_all_components || true

  log OK "Processo do Omni Agent Stack concluído."
  pause_menu
}

# ==============================================================================
# Menu de instalação separada
# ==============================================================================

select_individual_target() {
  while true; do
    clear

    printf '%s\n' "${C_CYAN}=== DESTINO DO COMPONENTE ===${C_RESET}"
    echo "1. Instalar integração apenas no Codex"
    echo "2. Instalar integração apenas no Claude"
    echo "3. Instalar integração em ambos Codex/Claude"
    echo "0. Cancelar"
    echo

    read -r -p "Escolha: " choice

    case "$choice" in
      1) printf '%s' "codex"; return 0 ;;
      2) printf '%s' "claude"; return 0 ;;
      3) printf '%s' "both"; return 0 ;;
      0) return 1 ;;
      *)
        printf '%sOpção inválida.%s\n' "$C_RED" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

show_separate_install_menu() {
  while true; do
    clear

    printf '%s\n' "${C_CYAN}=== INSTALAÇÃO DOS REPOSITÓRIOS ===${C_RESET}"
    echo " 1. AnythingLLM"
    echo " 2. AutoGen"
    echo " 3. Browser Use"
    echo " 4. Crawl4AI"
    echo " 5. CrewAI"
    echo " 6. Firecrawl"
    echo " 7. Langflow"
    echo " 8. LocalAI"
    echo " 9. Mem0"
    echo "10. RAGFlow"
    echo " 0. Voltar"
    echo

    read -r -p "Escolha: " choice

    if [[ "$choice" == "0" ]]; then
      return
    fi

    if [[ ! "$choice" =~ ^([1-9]|10)$ ]]; then
      printf '%sOpção inválida.%s\n' "$C_RED" "$C_RESET"
      sleep 1
      continue
    fi

    local index=$((choice - 1))
    local target

    if ! target="$(select_individual_target)"; then
      continue
    fi

    clear

    if install_target_integration "$target"; then
      echo
      install_component "$index" || true
    else
      log ERROR "Falha ao configurar a integração selecionada."
    fi

    pause_menu
  done
}

# ==============================================================================
# Menu principal
# ==============================================================================

show_main_menu() {
  while true; do
    clear

    printf '%s\n' "${C_CYAN}==============================================${C_RESET}"
    printf '%s\n' "${C_CYAN}          OMNI AGENT STACK INSTALLER${C_RESET}"
    printf '%s\n' "${C_CYAN}==============================================${C_RESET}"
    echo
    echo "1. Instalar apenas no Codex"
    echo "2. Instalar apenas no Claude"
    echo "3. Instalar ambos Codex/Claude"
    echo "4. Instalar separados"
    echo "0. Sair"
    echo

    read -r -p "Escolha: " choice

    case "$choice" in
      1)
        install_complete_stack "codex"
        ;;
      2)
        install_complete_stack "claude"
        ;;
      3)
        install_complete_stack "both"
        ;;
      4)
        show_separate_install_menu
        ;;
      0)
        log INFO "Instalador encerrado."
        return
        ;;
      *)
        printf '%sOpção inválida.%s\n' "$C_RED" "$C_RESET"
        sleep 1
        ;;
    esac
  done
}

# ==============================================================================
# Inicialização
# ==============================================================================

on_error() {
  local exit_code=$?
  local line_number="${BASH_LINENO[0]:-desconhecida}"

  log ERROR "Erro inesperado na linha $line_number. Código: $exit_code"
  log WARN "Consulte o log: $LOG_FILE"
}

trap on_error ERR

initialize_installer
log INFO "Omni Agent Stack Installer para Linux iniciado."
log INFO "Diretório raiz: $ROOT"

show_main_menu
