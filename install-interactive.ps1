[CmdletBinding()]
param(
    [string]$Raiz = $PSScriptRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Raiz = [IO.Path]::GetFullPath($Raiz)

$Componentes = @(
    @{ Id="anything-llm"; Nome="AnythingLLM" },
    @{ Id="autogen"; Nome="AutoGen" },
    @{ Id="browser-use"; Nome="Browser Use" },
    @{ Id="crawl4ai"; Nome="Crawl4AI" },
    @{ Id="crewai"; Nome="CrewAI" },
    @{ Id="firecrawl"; Nome="Firecrawl" },
    @{ Id="langflow"; Nome="Langflow" },
    @{ Id="localai"; Nome="LocalAI" },
    @{ Id="mem0"; Nome="Mem0" },
    @{ Id="ragflow"; Nome="RAGFlow" }
)

function Pause-Menu {
    [void](Read-Host "`nPressione ENTER para continuar")
}

function Copy-DirectorySafe {
    param([string]$Origem,[string]$Destino)
    if (-not (Test-Path $Origem)) { throw "Origem não encontrada: $Origem" }
    New-Item -ItemType Directory -Force -Path $Destino | Out-Null
    Copy-Item -Path (Join-Path $Origem "*") -Destination $Destino -Recurse -Force
}

function Install-Claude {
    $homeClaude = Join-Path $HOME ".claude"
    $skillsDestino = Join-Path $homeClaude "skills"
    $agentsDestino = Join-Path $homeClaude "agents"
    New-Item -ItemType Directory -Force -Path $skillsDestino,$agentsDestino | Out-Null

    Get-ChildItem (Join-Path $Raiz "skills") -Directory | ForEach-Object {
        Copy-DirectorySafe $_.FullName (Join-Path $skillsDestino $_.Name)
    }
    Copy-Item (Join-Path $Raiz "claude-agents\*.md") $agentsDestino -Force
    Write-Host "Claude Code configurado em $homeClaude" -ForegroundColor Green
}

function Install-Codex {
    $homeCodex = Join-Path $HOME ".codex"
    $skillsDestino = Join-Path $homeCodex "skills"
    New-Item -ItemType Directory -Force -Path $skillsDestino | Out-Null

    Get-ChildItem (Join-Path $Raiz "skills") -Directory | ForEach-Object {
        Copy-DirectorySafe $_.FullName (Join-Path $skillsDestino $_.Name)
    }

    $agentsOrigem = Join-Path $Raiz "AGENTS.md"
    $agentsDestino = Join-Path $homeCodex "AGENTS.md"
    if (Test-Path $agentsDestino) {
        $backup = "$agentsDestino.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Copy-Item $agentsDestino $backup
        Write-Host "Backup criado: $backup" -ForegroundColor DarkYellow
    }
    Copy-Item $agentsOrigem $agentsDestino -Force
    Write-Host "Codex configurado em $homeCodex" -ForegroundColor Green
}

function Invoke-Checked {
    param([string]$Comando,[string[]]$Argumentos,[string]$Diretorio)
    Push-Location $Diretorio
    try {
        & $Comando @Argumentos
        if ($LASTEXITCODE -ne 0) { throw "Comando falhou ($LASTEXITCODE): $Comando $($Argumentos -join ' ')" }
    } finally { Pop-Location }
}

function Install-Component {
    param([hashtable]$Componente)
    $dir = Join-Path $Raiz "components\$($Componente.Id)"
    if (-not (Test-Path $dir)) {
        Write-Host "Componente não encontrado: $dir" -ForegroundColor Red
        return
    }

    Write-Host "`nPreparando $($Componente.Nome)..." -ForegroundColor Cyan

    # Preferência: Compose, pois isola stacks heterogêneas.
    $composeCandidates = @(
        (Join-Path $dir "docker-compose.yml"),
        (Join-Path $dir "docker-compose.yaml"),
        (Join-Path $dir "compose.yml"),
        (Join-Path $dir "compose.yaml"),
        (Join-Path $dir "docker\docker-compose.yml"),
        (Join-Path $dir "docker\docker-compose.yaml")
    )
    $compose = $composeCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

    if ($compose -and (Get-Command docker -ErrorAction SilentlyContinue)) {
        $resposta = Read-Host "Foi encontrado Docker Compose. Deseja executar 'docker compose build'? [S/n]"
        if ($resposta -notmatch '^(n|N)$') {
            Invoke-Checked "docker" @("compose","-f",$compose,"build") $dir
            Write-Host "$($Componente.Nome) preparado via Docker." -ForegroundColor Green
            return
        }
    }

    # Python: ambiente virtual isolado por componente.
    if ((Test-Path (Join-Path $dir "pyproject.toml")) -or (Test-Path (Join-Path $dir "requirements.txt"))) {
        $python = if (Get-Command py -ErrorAction SilentlyContinue) { "py" }
                  elseif (Get-Command python -ErrorAction SilentlyContinue) { "python" }
                  else { $null }
        if ($python) {
            $venv = Join-Path $dir ".venv"
            if ($python -eq "py") { Invoke-Checked "py" @("-3","-m","venv",$venv) $dir }
            else { Invoke-Checked $python @("-m","venv",$venv) $dir }
            $pip = Join-Path $venv "Scripts\python.exe"
            if (-not (Test-Path $pip)) { $pip = Join-Path $venv "bin\python" }
            Invoke-Checked $pip @("-m","pip","install","--upgrade","pip") $dir
            if (Test-Path (Join-Path $dir "pyproject.toml")) {
                Invoke-Checked $pip @("-m","pip","install","-e",".") $dir
            } else {
                Invoke-Checked $pip @("-m","pip","install","-r","requirements.txt") $dir
            }
            Write-Host "$($Componente.Nome) preparado em ambiente virtual isolado." -ForegroundColor Green
            return
        }
    }

    # Node: respeita o lockfile detectado.
    if (Test-Path (Join-Path $dir "package.json")) {
        if ((Test-Path (Join-Path $dir "pnpm-lock.yaml")) -and (Get-Command pnpm -ErrorAction SilentlyContinue)) {
            Invoke-Checked "pnpm" @("install","--frozen-lockfile") $dir
        } elseif ((Test-Path (Join-Path $dir "yarn.lock")) -and (Get-Command yarn -ErrorAction SilentlyContinue)) {
            Invoke-Checked "yarn" @("install","--frozen-lockfile") $dir
        } elseif (Get-Command npm -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $dir "package-lock.json")) { Invoke-Checked "npm" @("ci") $dir }
            else { Invoke-Checked "npm" @("install") $dir }
        } else {
            Write-Host "Node.js/npm não encontrado." -ForegroundColor Red
            return
        }
        Write-Host "$($Componente.Nome) teve dependências Node instaladas." -ForegroundColor Green
        return
    }

    Write-Host "Nenhum instalador automático seguro foi identificado. Consulte o README do componente." -ForegroundColor Yellow
}

function Show-ComponentsMenu {
    while ($true) {
        Clear-Host
        Write-Host "=== INSTALAÇÃO DOS REPOSITÓRIOS ===" -ForegroundColor Cyan
        for ($i=0; $i -lt $Componentes.Count; $i++) {
            Write-Host ("{0,2}. {1}" -f ($i+1), $Componentes[$i].Nome)
        }
        Write-Host "11. Instalar/preparar todos"
        Write-Host " 0. Voltar"
        $op = Read-Host "`nEscolha"

        if ($op -eq "0") { return }
        if ($op -eq "11") {
            foreach ($c in $Componentes) { Install-Component $c }
            Pause-Menu
            continue
        }
        $numero = 0
        if ([int]::TryParse($op, [ref]$numero) -and $numero -ge 1 -and $numero -le 10) {
            Install-Component $Componentes[$numero-1]
            Pause-Menu
        } else {
            Write-Host "Opção inválida." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

while ($true) {
    Clear-Host
    Write-Host "============================================" -ForegroundColor DarkCyan
    Write-Host "       OMNI AGENT STACK - INSTALADOR" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor DarkCyan
    Write-Host "1. Instalar/preparar repositórios"
    Write-Host "2. Instalar agents/skills apenas no Claude Code"
    Write-Host "3. Instalar skills apenas no Codex"
    Write-Host "4. Instalar agents/skills no Claude Code e Codex"
    Write-Host "5. Fazer tudo: repositórios + Claude + Codex"
    Write-Host "0. Sair"
    $opcao = Read-Host "`nEscolha uma opção"

    switch ($opcao) {
        "1" { Show-ComponentsMenu }
        "2" { Install-Claude; Pause-Menu }
        "3" { Install-Codex; Pause-Menu }
        "4" { Install-Claude; Install-Codex; Pause-Menu }
        "5" { Show-ComponentsMenu; Install-Claude; Install-Codex; Pause-Menu }
        "0" { exit 0 }
        default { Write-Host "Opção inválida." -ForegroundColor Red; Start-Sleep 1 }
    }
}
