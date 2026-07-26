#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="3.0.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPONENTS="$ROOT/components"
SKILLS="$ROOT/skills"
CLAUDE_AGENTS="$ROOT/claude-agents"
AGENTS_FILE="$ROOT/AGENTS.md"
RUNTIME="$ROOT/.omni-v3"
VENVS="$RUNTIME/venvs"
LOGS="$RUNTIME/logs"
MARKERS="$RUNTIME/markers"
LOG="$LOGS/install-$(date +%Y%m%d-%H%M%S).log"

IDS=(anything-llm autogen browser-use crawl4ai crewai firecrawl langflow localai mem0 ragflow)
NAMES=(AnythingLLM AutoGen "Browser Use" Crawl4AI CrewAI Firecrawl Langflow LocalAI Mem0 RAGFlow)
METHODS=(node python python python python compose python docker-image python compose)

mkdir -p "$VENVS" "$LOGS" "$MARKERS"
[[ -d "$COMPONENTS" ]] || { echo "Pasta components não encontrada: $COMPONENTS"; exit 1; }

C=$'\033[1;36m'; G=$'\033[1;32m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; Z=$'\033[0m'

log(){ local level="$1";shift; echo "[$(date '+%F %T')][$level] $*" >>"$LOG"; case "$level" in OK)echo "${G}$*${Z}";;WARN)echo "${Y}$*${Z}";;ERROR)echo "${R}$*${Z}";;STEP)echo "${C}$*${Z}";;*)echo "$*";;esac; }
pause_menu(){ read -r -p $'\nPressione ENTER para continuar' _; }
has(){ command -v "$1" >/dev/null 2>&1; }
marker(){ echo "$MARKERS/$1.ok"; }
has_marker(){ [[ -f "$(marker "$1")" ]]; }
set_marker(){ date -Iseconds >"$(marker "$1")"; }
copy_tree(){ mkdir -p "$2"; if has rsync;then rsync -a --update "$1/" "$2/";else cp -a "$1/." "$2/";fi; }

install_codex(){
  has_marker codex&&{ log OK "Codex já está configurado por esta versão.";return; }
  [[ -d "$SKILLS"&&-f "$AGENTS_FILE" ]]||return 1
  log STEP "Configurando Omni Agent Stack no Codex..."
  mkdir -p "$HOME/.codex";copy_tree "$SKILLS" "$HOME/.codex/skills"
  [[ -f "$HOME/.codex/AGENTS.md" ]]&&! cmp -s "$AGENTS_FILE" "$HOME/.codex/AGENTS.md"&&cp "$HOME/.codex/AGENTS.md" "$HOME/.codex/AGENTS.md.backup-$(date +%Y%m%d-%H%M%S)"
  cp "$AGENTS_FILE" "$HOME/.codex/AGENTS.md";set_marker codex;log OK "Codex configurado e validado."
}
install_claude(){
  has_marker claude&&{ log OK "Claude Code já está configurado por esta versão.";return; }
  [[ -d "$SKILLS"&&-d "$CLAUDE_AGENTS" ]]||return 1
  log STEP "Configurando Omni Agent Stack no Claude Code..."
  copy_tree "$SKILLS" "$HOME/.claude/skills";copy_tree "$CLAUDE_AGENTS" "$HOME/.claude/agents"
  set_marker claude;log OK "Claude Code configurado e validado."
}
destination(){ case "$1" in codex)install_codex;;claude)install_claude;;both)install_codex;install_claude;;esac; }

pycfg(){ case "$1" in
autogen)echo "3.10|autogen-agentchat;autogen-ext[openai];autogenstudio|autogen_agentchat;autogen_ext;autogenstudio|";;
browser-use)echo "3.11|browser-use|browser_use|playwright";;
crawl4ai)echo "3.10|crawl4ai|crawl4ai|crawl4ai";;
crewai)echo "3.10|crewai|crewai|";;
langflow)echo "3.10|langflow|langflow|";;
mem0)echo "3.10|mem0ai|mem0|";;esac; }

test_python(){
 local i="$1" id="${IDS[$i]}" py="$VENVS/$id/bin/python";[[ -x "$py" ]]||return 1
 IFS='|' read -r min pkgs imports post<<<"$(pycfg "$id")";IFS=';' read -ra mods<<<"$imports"
 for m in "${mods[@]}";do "$py" -c "import $m" >/dev/null 2>&1||return 1;done
}
install_python(){
 local i="$1" id="${IDS[$i]}" name="${NAMES[$i]}";test_python "$i"&&{ log OK "$name já está instalado e validado.";return; }
 local base;base="$(command -v python3||command -v python||true)";[[ -n "$base" ]]||return 1
 IFS='|' read -r min pkgs imports post<<<"$(pycfg "$id")";local ver;ver="$($base -c 'import sys;print(".".join(map(str,sys.version_info[:3])))')"
 [[ "$(printf '%s\n%s\n' "$min" "$ver"|sort -V|head -1)" == "$min" ]]||{ log ERROR "$name requer Python $min+; encontrado $ver.";return 1; }
 local v="$VENVS/$id" py="$v/bin/python";[[ -x "$py" ]]||"$base" -m venv "$v"
 "$py" -m pip install --upgrade pip setuptools wheel|tee -a "$LOG"
 IFS=';' read -ra arr<<<"$pkgs";for p in "${arr[@]}";do "$py" -m pip install --upgrade "$p"|tee -a "$LOG";done
 [[ "$post" == playwright ]]&&"$py" -m playwright install chromium|tee -a "$LOG"
 [[ "$post" == crawl4ai&&-x "$v/bin/crawl4ai-setup" ]]&&"$v/bin/crawl4ai-setup"|tee -a "$LOG"
 test_python "$i"
}
node_dir(){ local b="$COMPONENTS/${IDS[$1]}";[[ -f "$b/server/package.json" ]]&&echo "$b/server"||{ [[ -f "$b/package.json" ]]&&echo "$b"; }; }
test_node(){ local d;d="$(node_dir "$1")"||return 1;[[ -d "$d/node_modules" ]]; }
install_node(){ local i="$1" d;test_node "$i"&&{ log OK "${NAMES[$i]} já está instalado.";return; };d="$(node_dir "$i")"||return 1;has npm||return 1;if [[ -f "$d/pnpm-lock.yaml" ]]&&has pnpm;then(cd "$d"&&pnpm install --frozen-lockfile);elif [[ -f "$d/package-lock.json" ]];then(cd "$d"&&npm ci);else(cd "$d"&&npm install);fi|tee -a "$LOG";test_node "$i"; }
docker_ready(){ has docker&&docker info >/dev/null 2>&1; }
compose_file(){ local i="$1" b="$COMPONENTS/${IDS[$i]}";local arr;if [[ "${IDS[$i]}" == firecrawl ]];then arr=(apps/api/docker-compose.yml apps/api/docker-compose.yaml docker-compose.yml docker-compose.yaml compose.yml compose.yaml);else arr=(docker/docker-compose.yml docker/docker-compose.yaml docker-compose.yml docker-compose.yaml compose.yml compose.yaml);fi;for f in "${arr[@]}";do [[ -f "$b/$f" ]]&&{ echo "$b/$f";return;};done;return 1; }
test_compose(){ docker_ready||return 1;local f;f="$(compose_file "$1")"||return 1;(cd "$(dirname "$f")"&&docker compose -f "$f" config --services >/dev/null 2>&1); }
install_compose(){ local i="$1" f;docker_ready||return 1;f="$(compose_file "$i")"||return 1;local d;d="$(dirname "$f")";local running;running="$(cd "$d"&&docker compose -f "$f" ps --status running --services 2>/dev/null||true)";[[ -n "$running" ]]&&{ log OK "${NAMES[$i]} já está em execução.";return; };(cd "$d"&&docker compose -f "$f" pull --ignore-pull-failures||true;docker compose -f "$f" build||true;docker compose -f "$f" up -d --remove-orphans)|tee -a "$LOG";test_compose "$i"; }
test_image(){ docker_ready&&docker image inspect localai/localai:latest-aio-cpu >/dev/null 2>&1; }
install_image(){ test_image&&{ log OK "LocalAI já está instalado.";return;};docker_ready||return 1;docker pull localai/localai:latest-aio-cpu|tee -a "$LOG";test_image; }
test_component(){ case "${METHODS[$1]}" in python)test_python "$1";;node)test_node "$1";;compose)test_compose "$1";;docker-image)test_image;;esac; }
install_component(){ local i="$1" id="${IDS[$i]}" n="${NAMES[$i]}";[[ -d "$COMPONENTS/$id" ]]||{ log ERROR "$n: repositório ausente.";return 1;};log STEP "Preparando $n...";case "${METHODS[$i]}" in python)install_python "$i";;node)install_node "$i";;compose)install_compose "$i";;docker-image)install_image;;esac||{ log ERROR "$n: FALHA.";return 1;};test_component "$i"||return 1;set_marker "component-$id";log OK "$n: INSTALADO E VALIDADO."; }
install_all(){ destination "$1"||{ log ERROR "Falha ao configurar o destino.";pause_menu;return;};local ok=0 fail=0;for i in "${!IDS[@]}";do if install_component "$i";then((ok+=1));else((fail+=1));fi;done;log INFO "Resumo: $ok instalado(s), $fail falha(s).";pause_menu; }
select_dest(){ while true;do clear;echo "${C}=== DESTINO DO COMPONENTE ===${Z}";echo "1. Instalar integração apenas no Codex";echo "2. Instalar integração apenas no Claude";echo "3. Instalar integração em ambos Codex/Claude";echo "0. Cancelar";read -r -p "Escolha: " x;case "$x" in 1)echo codex;return;;2)echo claude;return;;3)echo both;return;;0)return 1;;esac;done; }
separate(){ while true;do clear;echo "${C}=== INSTALAÇÃO DOS REPOSITÓRIOS ===${Z}";for i in "${!IDS[@]}";do printf "%2d. %s\n" "$((i+1))" "${NAMES[$i]}";done;echo " 0. Voltar";read -r -p "Escolha: " x;[[ "$x" == 0 ]]&&return;[[ "$x" =~ ^([1-9]|10)$ ]]||continue;t="$(select_dest)"||continue;destination "$t"&&install_component "$((x-1))"||true;pause_menu;done; }
main(){ while true;do clear;echo "${C}==============================================";echo " OMNI AGENT STACK INSTALLER v$VERSION";echo "==============================================${Z}";echo;echo "1. Instalar apenas no Codex";echo "2. Instalar apenas no Claude";echo "3. Instalar ambos Codex/Claude";echo "4. Instalar separados";echo "0. Sair";read -r -p "Escolha: " x;case "$x" in 1)install_all codex;;2)install_all claude;;3)install_all both;;4)separate;;0)return;;esac;done; }
main
