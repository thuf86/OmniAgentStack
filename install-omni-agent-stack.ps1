#requires -Version 5.1
<#
.SYNOPSIS
    Instalador oficial interativo do Omni Agent Stack.

.DESCRIPTION
    Este script instala os componentes já baixados do Omni Agent Stack.

    Ele NÃO baixa os repositórios. A estrutura esperada é:

        OmniAgentStack\
        ├── components\
        ├── skills\
        ├── claude-agents\
        ├── AGENTS.md
        └── install-omni-agent-stack.ps1

    Menu principal:
        1. Instalar apenas no Codex
        2. Instalar apenas no Claude
        3. Instalar em ambos Codex/Claude
        4. Instalar separados
        0. Sair

    As opções 1, 2 e 3 instalam todos os dez componentes e configuram
    as skills/agentes no destino escolhido.

    A opção 4 permite escolher e instalar um componente por vez.
#>

[CmdletBinding()]
param(
    [string]$Root = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================================================================
# CONFIGURAÇÃO
# =============================================================================

$Script:Root = [IO.Path]::GetFullPath($Root)
$Script:ComponentsRoot = Join-Path $Script:Root "components"
$Script:SkillsRoot = Join-Path $Script:Root "skills"
$Script:ClaudeAgentsRoot = Join-Path $Script:Root "claude-agents"
$Script:AgentsFile = Join-Path $Script:Root "AGENTS.md"

$Script:RuntimeRoot = Join-Path $Script:Root ".omni"
$Script:VenvRoot = Join-Path $Script:RuntimeRoot "venvs"
$Script:LogsRoot = Join-Path $Script:RuntimeRoot "logs"
$Script:StateFile = Join-Path $Script:RuntimeRoot "install-state.json"
$Script:LogFile = Join-Path $Script:LogsRoot ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

$Script:Components = @(
    [ordered]@{
        Id = "anything-llm"
        Name = "AnythingLLM"
        Method = "node"
        WorkingDirectories = @("server")
    },
    [ordered]@{
        Id = "autogen"
        Name = "AutoGen"
        Method = "python"
        MinPython = "3.10"
        Packages = @(
            "autogen-agentchat",
            "autogen-ext[openai]",
            "autogenstudio"
        )
        Imports = @(
            "autogen_agentchat",
            "autogen_ext",
            "autogenstudio"
        )
    },
    [ordered]@{
        Id = "browser-use"
        Name = "Browser Use"
        Method = "python"
        MinPython = "3.11"
        Packages = @("browser-use")
        Imports = @("browser_use")
        PostInstall = "playwright"
    },
    [ordered]@{
        Id = "crawl4ai"
        Name = "Crawl4AI"
        Method = "python"
        MinPython = "3.10"
        Packages = @("crawl4ai")
        Imports = @("crawl4ai")
        PostInstall = "crawl4ai"
    },
    [ordered]@{
        Id = "crewai"
        Name = "CrewAI"
        Method = "python"
        MinPython = "3.10"
        Packages = @("crewai")
        Imports = @("crewai")
    },
    [ordered]@{
        Id = "firecrawl"
        Name = "Firecrawl"
        Method = "compose"
        ComposeHints = @(
            "apps\api\docker-compose.yml",
            "apps\api\docker-compose.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml"
        )
    },
    [ordered]@{
        Id = "langflow"
        Name = "Langflow"
        Method = "python"
        MinPython = "3.10"
        Packages = @("langflow")
        Imports = @("langflow")
    },
    [ordered]@{
        Id = "localai"
        Name = "LocalAI"
        Method = "docker-image"
        DockerImage = "localai/localai:latest-aio-cpu"
    },
    [ordered]@{
        Id = "mem0"
        Name = "Mem0"
        Method = "python"
        MinPython = "3.10"
        Packages = @("mem0ai")
        Imports = @("mem0")
    },
    [ordered]@{
        Id = "ragflow"
        Name = "RAGFlow"
        Method = "compose"
        ComposeHints = @(
            "docker\docker-compose.yml",
            "docker\docker-compose.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml"
        )
    }
)

# =============================================================================
# INFRAESTRUTURA
# =============================================================================

function Initialize-Installer {
    foreach ($directory in @(
        $Script:RuntimeRoot,
        $Script:VenvRoot,
        $Script:LogsRoot
    )) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    if (-not (Test-Path $Script:ComponentsRoot)) {
        throw @"
A pasta de componentes não foi encontrada:

$Script:ComponentsRoot

Execute primeiro o script responsável pelo download dos repositórios.
"@
    }

    if (-not (Test-Path $Script:StateFile)) {
        [ordered]@{
            schema = 1
            updatedAt = (Get-Date).ToString("o")
            integrations = [ordered]@{}
            components = [ordered]@{}
        } |
            ConvertTo-Json -Depth 20 |
            Set-Content -Encoding UTF8 $Script:StateFile
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","STEP")][string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Encoding UTF8 -Path $Script:LogFile -Value "[$timestamp][$Level] $Message"

    $color = switch ($Level) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "STEP"  { "Cyan" }
        default { "Gray" }
    }

    Write-Host $Message -ForegroundColor $color
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)

    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Pause-Menu {
    [void](Read-Host "`nPressione ENTER para continuar")
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultYes = $true
    )

    $suffix = if ($DefaultYes) { "[S/n]" } else { "[s/N]" }
    $answer = Read-Host "$Message $suffix"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return $answer -match "^[sSyY]"
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $Script:Root,
        [switch]$AllowFailure,
        [switch]$Capture
    )

    Write-Log ("Executando: {0} {1}" -f $Command, ($Arguments -join " ")) "INFO"

    Push-Location $WorkingDirectory

    try {
        if ($Capture) {
            $output = & $Command @Arguments 2>&1 | ForEach-Object { "$_" }
            $exitCode = $LASTEXITCODE

            foreach ($line in $output) {
                Add-Content -Encoding UTF8 -Path $Script:LogFile -Value $line
            }

            if ($exitCode -ne 0 -and -not $AllowFailure) {
                throw "O comando retornou o código $exitCode."
            }

            return [pscustomobject]@{
                ExitCode = $exitCode
                Output = $output
            }
        }

        & $Command @Arguments 2>&1 |
            Tee-Object -FilePath $Script:LogFile -Append

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "O comando retornou o código $exitCode."
        }

        return $exitCode
    }
    finally {
        Pop-Location
    }
}

function Get-ComponentPath {
    param([hashtable]$Component)

    return Join-Path $Script:ComponentsRoot $Component.Id
}

function Read-State {
    try {
        return Get-Content -Raw -Encoding UTF8 $Script:StateFile |
            ConvertFrom-Json
    }
    catch {
        Write-Log "O arquivo de estado estava inválido e será recriado." "WARN"

        if (Test-Path $Script:StateFile) {
            Copy-Item `
                $Script:StateFile `
                "$($Script:StateFile).backup-$(Get-Date -Format yyyyMMdd-HHmmss)" `
                -Force
        }

        [ordered]@{
            schema = 1
            updatedAt = (Get-Date).ToString("o")
            integrations = [ordered]@{}
            components = [ordered]@{}
        } |
            ConvertTo-Json -Depth 20 |
            Set-Content -Encoding UTF8 $Script:StateFile

        return Get-Content -Raw -Encoding UTF8 $Script:StateFile |
            ConvertFrom-Json
    }
}

function Save-ComponentState {
    param(
        [Parameter(Mandatory)][string]$ComponentId,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ""
    )

    $state = Read-State

    $components = [ordered]@{}

    if ($state.components) {
        foreach ($property in $state.components.PSObject.Properties) {
            $components[$property.Name] = $property.Value
        }
    }

    $components[$ComponentId] = [ordered]@{
        status = $Status
        detail = $Detail
        updatedAt = (Get-Date).ToString("o")
    }

    $integrations = [ordered]@{}

    if ($state.integrations) {
        foreach ($property in $state.integrations.PSObject.Properties) {
            $integrations[$property.Name] = $property.Value
        }
    }

    [ordered]@{
        schema = 1
        updatedAt = (Get-Date).ToString("o")
        integrations = $integrations
        components = $components
    } |
        ConvertTo-Json -Depth 30 |
        Set-Content -Encoding UTF8 $Script:StateFile
}

function Save-IntegrationState {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Status,
        [string]$Detail = ""
    )

    $state = Read-State

    $components = [ordered]@{}

    if ($state.components) {
        foreach ($property in $state.components.PSObject.Properties) {
            $components[$property.Name] = $property.Value
        }
    }

    $integrations = [ordered]@{}

    if ($state.integrations) {
        foreach ($property in $state.integrations.PSObject.Properties) {
            $integrations[$property.Name] = $property.Value
        }
    }

    $integrations[$Target] = [ordered]@{
        status = $Status
        detail = $Detail
        updatedAt = (Get-Date).ToString("o")
    }

    [ordered]@{
        schema = 1
        updatedAt = (Get-Date).ToString("o")
        integrations = $integrations
        components = $components
    } |
        ConvertTo-Json -Depth 30 |
        Set-Content -Encoding UTF8 $Script:StateFile
}

function Copy-DirectoryIdempotent {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path $Source)) {
        throw "Diretório de origem não encontrado: $Source"
    }

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    if (Test-Command "robocopy") {
        & robocopy `
            $Source `
            $Destination `
            /E `
            /XO `
            /FFT `
            /R:2 `
            /W:1 `
            /NFL `
            /NDL `
            /NJH `
            /NJS `
            /NP |
            Out-Null

        if ($LASTEXITCODE -gt 7) {
            throw "Falha na cópia com Robocopy. Código: $LASTEXITCODE"
        }
    }
    else {
        Copy-Item `
            (Join-Path $Source "*") `
            $Destination `
            -Recurse `
            -Force
    }
}

# =============================================================================
# INTEGRAÇÕES CODEX E CLAUDE
# =============================================================================

function Test-IntegrationAssets {
    if (-not (Test-Path $Script:SkillsRoot)) {
        throw "A pasta de skills não foi encontrada: $Script:SkillsRoot"
    }

    if (-not (Test-Path $Script:ClaudeAgentsRoot)) {
        throw "A pasta de agentes não foi encontrada: $Script:ClaudeAgentsRoot"
    }

    if (-not (Test-Path $Script:AgentsFile)) {
        throw "O arquivo AGENTS.md não foi encontrado: $Script:AgentsFile"
    }
}

function Install-CodexIntegration {
    Test-IntegrationAssets

    Write-Log "Configurando Omni Agent Stack no Codex..." "STEP"

    $codexRoot = Join-Path $HOME ".codex"
    $skillsTarget = Join-Path $codexRoot "skills"
    $agentsTarget = Join-Path $codexRoot "AGENTS.md"

    New-Item -ItemType Directory -Force -Path $codexRoot | Out-Null

    Copy-DirectoryIdempotent `
        -Source $Script:SkillsRoot `
        -Destination $skillsTarget

    if (Test-Path $agentsTarget) {
        $sourceHash = (Get-FileHash $Script:AgentsFile -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash $agentsTarget -Algorithm SHA256).Hash

        if ($sourceHash -ne $targetHash) {
            $backup = "$agentsTarget.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
            Copy-Item $agentsTarget $backup -Force
            Write-Log "Backup criado: $backup" "WARN"
        }
    }

    Copy-Item $Script:AgentsFile $agentsTarget -Force

    $skillsCount = (
        Get-ChildItem $skillsTarget -Directory -ErrorAction SilentlyContinue |
        Measure-Object
    ).Count

    if ($skillsCount -lt 1 -or -not (Test-Path $agentsTarget)) {
        Save-IntegrationState "codex" "failed" "Falha na validação"
        throw "A validação da integração com o Codex falhou."
    }

    Save-IntegrationState `
        "codex" `
        "installed" `
        "$skillsCount skills instaladas"

    Write-Log "Codex configurado e validado com $skillsCount skill(s)." "OK"
}

function Install-ClaudeIntegration {
    Test-IntegrationAssets

    Write-Log "Configurando Omni Agent Stack no Claude Code..." "STEP"

    $claudeRoot = Join-Path $HOME ".claude"
    $skillsTarget = Join-Path $claudeRoot "skills"
    $agentsTarget = Join-Path $claudeRoot "agents"

    Copy-DirectoryIdempotent `
        -Source $Script:SkillsRoot `
        -Destination $skillsTarget

    Copy-DirectoryIdempotent `
        -Source $Script:ClaudeAgentsRoot `
        -Destination $agentsTarget

    $skillsCount = (
        Get-ChildItem $skillsTarget -Directory -ErrorAction SilentlyContinue |
        Measure-Object
    ).Count

    $agentsCount = (
        Get-ChildItem $agentsTarget -Filter "*.md" -ErrorAction SilentlyContinue |
        Measure-Object
    ).Count

    if ($skillsCount -lt 1 -or $agentsCount -lt 1) {
        Save-IntegrationState "claude" "failed" "Falha na validação"
        throw "A validação da integração com o Claude Code falhou."
    }

    Save-IntegrationState `
        "claude" `
        "installed" `
        "$skillsCount skills e $agentsCount agentes instalados"

    Write-Log `
        "Claude Code configurado e validado com $skillsCount skill(s) e $agentsCount agente(s)." `
        "OK"
}

function Install-TargetIntegration {
    param(
        [ValidateSet("codex","claude","both")]
        [string]$Target
    )

    switch ($Target) {
        "codex" {
            Install-CodexIntegration
        }

        "claude" {
            Install-ClaudeIntegration
        }

        "both" {
            Install-CodexIntegration
            Install-ClaudeIntegration
        }
    }
}

# =============================================================================
# INSTALAÇÃO PYTHON
# =============================================================================

function Get-Python {
    $candidates = @(
        @{ Exe = "py"; Prefix = @("-3") },
        @{ Exe = "python"; Prefix = @() },
        @{ Exe = "python3"; Prefix = @() }
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-Command $candidate.Exe)) {
            continue
        }

        $result = Invoke-Checked `
            -Command $candidate.Exe `
            -Arguments (
                $candidate.Prefix +
                @(
                    "-c",
                    "import sys; print('.'.join(map(str, sys.version_info[:3])))"
                )
            ) `
            -Capture `
            -AllowFailure

        if ($result.ExitCode -eq 0) {
            return [pscustomobject]@{
                Exe = $candidate.Exe
                Prefix = $candidate.Prefix
                Version = ($result.Output | Select-Object -Last 1).Trim()
            }
        }
    }

    return $null
}

function Test-MinimumVersion {
    param(
        [string]$Actual,
        [string]$Minimum
    )

    try {
        return ([version]$Actual -ge [version]$Minimum)
    }
    catch {
        return $false
    }
}

function Get-VenvInfo {
    param([hashtable]$Component)

    $root = Join-Path $Script:VenvRoot $Component.Id

    return [pscustomobject]@{
        Root = $root
        Python = Join-Path $root "Scripts\python.exe"
    }
}

function Test-PythonInstallation {
    param([hashtable]$Component)

    $venv = Get-VenvInfo $Component

    if (-not (Test-Path $venv.Python)) {
        return $false
    }

    foreach ($module in $Component.Imports) {
        $result = Invoke-Checked `
            -Command $venv.Python `
            -Arguments @(
                "-c",
                "import $module; print('OK')"
            ) `
            -Capture `
            -AllowFailure

        if ($result.ExitCode -ne 0) {
            return $false
        }
    }

    return $true
}

function Install-PythonComponent {
    param([hashtable]$Component)

    if (Test-PythonInstallation $Component) {
        Write-Log `
            "$($Component.Name) já está instalado e validado. Reinstalação evitada." `
            "OK"

        Save-ComponentState `
            $Component.Id `
            "installed" `
            "Importações Python validadas"

        return
    }

    $python = Get-Python

    if (-not $python) {
        throw "Python não encontrado. Instale Python $($Component.MinPython) ou superior."
    }

    if (-not (Test-MinimumVersion $python.Version $Component.MinPython)) {
        throw @"
$($Component.Name) requer Python $($Component.MinPython) ou superior.
Versão encontrada: $($python.Version)
"@
    }

    $venv = Get-VenvInfo $Component

    if (-not (Test-Path $venv.Python)) {
        Write-Log "Criando ambiente Python isolado: $($venv.Root)" "STEP"

        Invoke-Checked `
            -Command $python.Exe `
            -Arguments (
                $python.Prefix +
                @(
                    "-m",
                    "venv",
                    $venv.Root
                )
            )
    }
    else {
        Write-Log "Ambiente Python existente será reparado e validado." "WARN"
    }

    Invoke-Checked `
        -Command $venv.Python `
        -Arguments @(
            "-m",
            "pip",
            "install",
            "--disable-pip-version-check",
            "--upgrade",
            "pip",
            "setuptools",
            "wheel"
        )

    foreach ($package in $Component.Packages) {
        Invoke-Checked `
            -Command $venv.Python `
            -Arguments @(
                "-m",
                "pip",
                "install",
                "--upgrade",
                $package
            )
    }

    if ($Component.Contains("PostInstall")) {
        switch ($Component.PostInstall) {
            "playwright" {
                Invoke-Checked `
                    -Command $venv.Python `
                    -Arguments @(
                        "-m",
                        "playwright",
                        "install",
                        "chromium"
                    )
            }

            "crawl4ai" {
                $scriptsDirectory = Split-Path $venv.Python -Parent
                $setup = Join-Path $scriptsDirectory "crawl4ai-setup.exe"

                if (Test-Path $setup) {
                    Invoke-Checked -Command $setup
                }
                else {
                    Write-Log `
                        "crawl4ai-setup.exe não foi localizado; será usada a validação por importação." `
                        "WARN"
                }
            }
        }
    }

    if (-not (Test-PythonInstallation $Component)) {
        throw "A instalação terminou, mas a validação por importação falhou."
    }

    $lockFile = Join-Path `
        $Script:RuntimeRoot `
        "$($Component.Id)-requirements.lock.txt"

    $freeze = Invoke-Checked `
        -Command $venv.Python `
        -Arguments @(
            "-m",
            "pip",
            "freeze"
        ) `
        -Capture

    $freeze.Output |
        Set-Content -Encoding UTF8 $lockFile

    Save-ComponentState `
        $Component.Id `
        "installed" `
        "Ambiente Python validado"

    Write-Log "$($Component.Name) instalado e validado." "OK"
}

# =============================================================================
# INSTALAÇÃO NODE.JS
# =============================================================================

function Resolve-NodeWorkingDirectory {
    param([hashtable]$Component)

    $componentPath = Get-ComponentPath $Component

    foreach ($relativePath in $Component.WorkingDirectories) {
        $candidate = Join-Path $componentPath $relativePath

        if (Test-Path (Join-Path $candidate "package.json")) {
            return $candidate
        }
    }

    if (Test-Path (Join-Path $componentPath "package.json")) {
        return $componentPath
    }

    return $null
}

function Test-NodeInstallation {
    param([hashtable]$Component)

    $workingDirectory = Resolve-NodeWorkingDirectory $Component

    if (-not $workingDirectory) {
        return $false
    }

    if (-not (Test-Path (Join-Path $workingDirectory "node_modules"))) {
        return $false
    }

    if (-not (Test-Command "npm")) {
        return $false
    }

    $result = Invoke-Checked `
        -Command "npm" `
        -Arguments @(
            "ls",
            "--depth=0",
            "--silent"
        ) `
        -WorkingDirectory $workingDirectory `
        -Capture `
        -AllowFailure

    # npm ls pode retornar 1 por dependências peer/opcionais.
    return $result.ExitCode -in @(0,1)
}

function Install-NodeComponent {
    param([hashtable]$Component)

    $workingDirectory = Resolve-NodeWorkingDirectory $Component

    if (-not $workingDirectory) {
        throw "Nenhum package.json foi encontrado para $($Component.Name)."
    }

    if (Test-NodeInstallation $Component) {
        Write-Log `
            "$($Component.Name) já possui dependências Node válidas. Reinstalação evitada." `
            "OK"

        Save-ComponentState `
            $Component.Id `
            "installed" `
            "Dependências Node validadas"

        return
    }

    if (-not (Test-Command "node") -or -not (Test-Command "npm")) {
        throw "Node.js e npm são obrigatórios para instalar $($Component.Name)."
    }

    if (
        (Test-Path (Join-Path $workingDirectory "pnpm-lock.yaml")) -and
        (Test-Command "pnpm")
    ) {
        Invoke-Checked `
            -Command "pnpm" `
            -Arguments @(
                "install",
                "--frozen-lockfile"
            ) `
            -WorkingDirectory $workingDirectory
    }
    elseif (
        (Test-Path (Join-Path $workingDirectory "yarn.lock")) -and
        (Test-Command "yarn")
    ) {
        Invoke-Checked `
            -Command "yarn" `
            -Arguments @(
                "install",
                "--frozen-lockfile"
            ) `
            -WorkingDirectory $workingDirectory
    }
    elseif (Test-Path (Join-Path $workingDirectory "package-lock.json")) {
        Invoke-Checked `
            -Command "npm" `
            -Arguments @("ci") `
            -WorkingDirectory $workingDirectory
    }
    else {
        Invoke-Checked `
            -Command "npm" `
            -Arguments @("install") `
            -WorkingDirectory $workingDirectory
    }

    if (-not (Test-NodeInstallation $Component)) {
        throw "As dependências foram processadas, mas a validação Node falhou."
    }

    Save-ComponentState `
        $Component.Id `
        "installed" `
        "Dependências Node validadas"

    Write-Log "$($Component.Name) instalado e validado." "OK"
}

# =============================================================================
# INSTALAÇÃO DOCKER
# =============================================================================

function Test-DockerReady {
    if (-not (Test-Command "docker")) {
        return $false
    }

    $result = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "info",
            "--format",
            "{{.ServerVersion}}"
        ) `
        -Capture `
        -AllowFailure

    return $result.ExitCode -eq 0
}

function Find-ComposeFile {
    param([hashtable]$Component)

    $componentPath = Get-ComponentPath $Component

    foreach ($relativePath in $Component.ComposeHints) {
        $candidate = Join-Path $componentPath $relativePath

        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $fallback = Get-ChildItem `
        -Path $componentPath `
        -Recurse `
        -File `
        -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @(
                "docker-compose.yml",
                "docker-compose.yaml",
                "compose.yml",
                "compose.yaml"
            )
        } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1

    if ($fallback) {
        return $fallback.FullName
    }

    return $null
}

function Ensure-ComposeEnv {
    param([string]$ComposeFile)

    $workingDirectory = Split-Path $ComposeFile -Parent
    $envFile = Join-Path $workingDirectory ".env"

    if (Test-Path $envFile) {
        return
    }

    foreach ($templateName in @(
        ".env.example",
        "env.example",
        ".env.template"
    )) {
        $source = Join-Path $workingDirectory $templateName

        if (Test-Path $source) {
            Copy-Item $source $envFile -Force
            Write-Log ".env criado a partir de $templateName." "OK"
            return
        }
    }
}

function Test-ComposeInstallation {
    param([hashtable]$Component)

    if (-not (Test-DockerReady)) {
        return $false
    }

    $composeFile = Find-ComposeFile $Component

    if (-not $composeFile) {
        return $false
    }

    $workingDirectory = Split-Path $composeFile -Parent

    $config = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "config",
            "--services"
        ) `
        -WorkingDirectory $workingDirectory `
        -Capture `
        -AllowFailure

    if ($config.ExitCode -ne 0) {
        return $false
    }

    $services = @(
        $config.Output |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    return $services.Count -gt 0
}

function Install-ComposeComponent {
    param([hashtable]$Component)

    if (-not (Test-DockerReady)) {
        throw "Docker Desktop não está instalado, não foi iniciado ou não respondeu."
    }

    $composeFile = Find-ComposeFile $Component

    if (-not $composeFile) {
        throw "Nenhum arquivo Docker Compose foi localizado para $($Component.Name)."
    }

    Ensure-ComposeEnv $composeFile

    $workingDirectory = Split-Path $composeFile -Parent

    $config = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "config",
            "--services"
        ) `
        -WorkingDirectory $workingDirectory `
        -Capture

    $declaredServices = @(
        $config.Output |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    if ($declaredServices.Count -eq 0) {
        throw "Nenhum serviço válido foi encontrado no arquivo Compose."
    }

    $running = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "ps",
            "--status",
            "running",
            "--services"
        ) `
        -WorkingDirectory $workingDirectory `
        -Capture `
        -AllowFailure

    $runningServices = @(
        $running.Output |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    if ($runningServices.Count -gt 0) {
        Write-Log `
            "$($Component.Name) já possui serviços em execução. Duplicação evitada." `
            "OK"

        Save-ComponentState `
            $Component.Id `
            "installed" `
            "$($runningServices.Count) serviço(s) Docker em execução"

        return
    }

    Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "pull",
            "--ignore-pull-failures"
        ) `
        -WorkingDirectory $workingDirectory `
        -AllowFailure

    Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "build"
        ) `
        -WorkingDirectory $workingDirectory `
        -AllowFailure

    Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "up",
            "-d",
            "--remove-orphans"
        ) `
        -WorkingDirectory $workingDirectory

    Start-Sleep -Seconds 5

    $runningAfterStart = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "compose",
            "-f",
            $composeFile,
            "ps",
            "--status",
            "running",
            "--services"
        ) `
        -WorkingDirectory $workingDirectory `
        -Capture `
        -AllowFailure

    $activeServices = @(
        $runningAfterStart.Output |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }
    )

    if ($activeServices.Count -eq 0) {
        throw "Nenhum serviço permaneceu em execução após docker compose up."
    }

    if (-not (Test-ComposeInstallation $Component)) {
        throw "A configuração Docker Compose não passou na validação final."
    }

    Save-ComponentState `
        $Component.Id `
        "installed" `
        "$($activeServices.Count) serviço(s) Docker em execução"

    Write-Log "$($Component.Name) instalado e validado." "OK"
}

function Test-DockerImageInstallation {
    param([hashtable]$Component)

    if (-not (Test-DockerReady)) {
        return $false
    }

    $result = Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "image",
            "inspect",
            $Component.DockerImage
        ) `
        -Capture `
        -AllowFailure

    return $result.ExitCode -eq 0
}

function Install-DockerImageComponent {
    param([hashtable]$Component)

    if (-not (Test-DockerReady)) {
        throw "Docker Desktop não está disponível."
    }

    if (Test-DockerImageInstallation $Component) {
        Write-Log `
            "$($Component.Name) já possui a imagem $($Component.DockerImage). Download duplicado evitado." `
            "OK"

        Save-ComponentState `
            $Component.Id `
            "installed" `
            "Imagem Docker validada"

        return
    }

    Invoke-Checked `
        -Command "docker" `
        -Arguments @(
            "pull",
            $Component.DockerImage
        )

    if (-not (Test-DockerImageInstallation $Component)) {
        throw "A imagem Docker foi baixada, mas não passou na validação."
    }

    Save-ComponentState `
        $Component.Id `
        "installed" `
        "Imagem Docker validada"

    Write-Log "$($Component.Name) instalado e validado." "OK"
}

# =============================================================================
# ORQUESTRAÇÃO DOS COMPONENTES
# =============================================================================

function Test-Component {
    param([hashtable]$Component)

    switch ($Component.Method) {
        "python" {
            return Test-PythonInstallation $Component
        }

        "node" {
            return Test-NodeInstallation $Component
        }

        "compose" {
            return Test-ComposeInstallation $Component
        }

        "docker-image" {
            return Test-DockerImageInstallation $Component
        }

        default {
            return $false
        }
    }
}

function Install-Component {
    param([hashtable]$Component)

    $componentPath = Get-ComponentPath $Component

    if (-not (Test-Path $componentPath)) {
        Write-Log `
            "$($Component.Name): repositório não encontrado em $componentPath." `
            "ERROR"

        Save-ComponentState `
            $Component.Id `
            "missing" `
            "Repositório não encontrado"

        return $false
    }

    Write-Log "`nPreparando $($Component.Name)..." "STEP"

    try {
        switch ($Component.Method) {
            "python" {
                Install-PythonComponent $Component
            }

            "node" {
                Install-NodeComponent $Component
            }

            "compose" {
                Install-ComposeComponent $Component
            }

            "docker-image" {
                Install-DockerImageComponent $Component
            }

            default {
                throw "Método de instalação desconhecido: $($Component.Method)"
            }
        }

        if (-not (Test-Component $Component)) {
            throw "A validação final não confirmou a instalação."
        }

        Save-ComponentState `
            $Component.Id `
            "installed" `
            "Instalação validada"

        Write-Log "$($Component.Name): INSTALADO E VALIDADO." "OK"

        return $true
    }
    catch {
        Save-ComponentState `
            $Component.Id `
            "failed" `
            $_.Exception.Message

        Write-Log `
            "$($Component.Name): FALHA - $($_.Exception.Message)" `
            "ERROR"

        Write-Log "Consulte o log: $Script:LogFile" "WARN"

        return $false
    }
}

function Install-AllComponents {
    $success = 0
    $failed = 0

    foreach ($component in $Script:Components) {
        if (Install-Component $component) {
            $success++
        }
        else {
            $failed++
        }
    }

    $level = if ($failed -eq 0) {
        "OK"
    }
    else {
        "WARN"
    }

    Write-Log `
        "Instalação concluída: $success componente(s) válido(s) e $failed falha(s)." `
        $level

    return $failed -eq 0
}

function Install-CompleteStack {
    param(
        [ValidateSet("codex","claude","both")]
        [string]$Target
    )

    Clear-Host

    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host "       INSTALAÇÃO DO OMNI AGENT STACK" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor DarkCyan
    Write-Host ""

    try {
        Install-TargetIntegration $Target

        Write-Host ""
        Write-Log "Iniciando instalação dos dez componentes..." "STEP"

        [void](Install-AllComponents)

        Write-Host ""
        Write-Log "Processo do Omni Agent Stack concluído." "OK"
    }
    catch {
        Write-Log "Falha na instalação: $($_.Exception.Message)" "ERROR"
    }

    Pause-Menu
}

# =============================================================================
# MENU DE INSTALAÇÃO SEPARADA
# =============================================================================

function Select-IndividualTarget {
    while ($true) {
        Clear-Host

        Write-Host "=== DESTINO DO COMPONENTE ===" -ForegroundColor Cyan
        Write-Host "1. Instalar integração apenas no Codex"
        Write-Host "2. Instalar integração apenas no Claude"
        Write-Host "3. Instalar integração em ambos Codex/Claude"
        Write-Host "0. Cancelar"

        $choice = Read-Host "`nEscolha"

        switch ($choice) {
            "1" { return "codex" }
            "2" { return "claude" }
            "3" { return "both" }
            "0" { return $null }

            default {
                Write-Host "Opção inválida." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

function Show-SeparateInstallMenu {
    while ($true) {
        Clear-Host

        Write-Host "=== INSTALAÇÃO DOS REPOSITÓRIOS ===" -ForegroundColor Cyan
        Write-Host " 1. AnythingLLM"
        Write-Host " 2. AutoGen"
        Write-Host " 3. Browser Use"
        Write-Host " 4. Crawl4AI"
        Write-Host " 5. CrewAI"
        Write-Host " 6. Firecrawl"
        Write-Host " 7. Langflow"
        Write-Host " 8. LocalAI"
        Write-Host " 9. Mem0"
        Write-Host "10. RAGFlow"
        Write-Host " 0. Voltar"
        Write-Host ""

        $choice = Read-Host "Escolha"

        if ($choice -eq "0") {
            return
        }

        $number = 0

        if (
            -not [int]::TryParse($choice, [ref]$number) -or
            $number -lt 1 -or
            $number -gt 10
        ) {
            Write-Host "Opção inválida." -ForegroundColor Red
            Start-Sleep -Seconds 1
            continue
        }

        $component = $Script:Components[$number - 1]
        $target = Select-IndividualTarget

        if (-not $target) {
            continue
        }

        Clear-Host

        try {
            Install-TargetIntegration $target

            Write-Host ""
            [void](Install-Component $component)
        }
        catch {
            Write-Log "Falha: $($_.Exception.Message)" "ERROR"
        }

        Pause-Menu
    }
}

# =============================================================================
# MENU PRINCIPAL
# =============================================================================

function Show-MainMenu {
    while ($true) {
        Clear-Host

        Write-Host "==============================================" -ForegroundColor DarkCyan
        Write-Host "          OMNI AGENT STACK INSTALLER" -ForegroundColor Cyan
        Write-Host "==============================================" -ForegroundColor DarkCyan
        Write-Host ""
        Write-Host "1. Instalar apenas no Codex"
        Write-Host "2. Instalar apenas no Claude"
        Write-Host "3. Instalar ambos Codex/Claude"
        Write-Host "4. Instalar separados"
        Write-Host "0. Sair"
        Write-Host ""

        $choice = Read-Host "Escolha"

        switch ($choice) {
            "1" {
                Install-CompleteStack "codex"
            }

            "2" {
                Install-CompleteStack "claude"
            }

            "3" {
                Install-CompleteStack "both"
            }

            "4" {
                Show-SeparateInstallMenu
            }

            "0" {
                Write-Log "Instalador encerrado." "INFO"
                return
            }

            default {
                Write-Host "Opção inválida." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }
}

# =============================================================================
# EXECUÇÃO
# =============================================================================

try {
    Initialize-Installer

    Write-Log "Omni Agent Stack Installer iniciado." "INFO"
    Write-Log "Diretório raiz: $Script:Root" "INFO"

    Show-MainMenu
}
catch {
    Write-Host ""
    Write-Host "ERRO FATAL: $($_.Exception.Message)" -ForegroundColor Red

    if (Test-Path $Script:LogsRoot) {
        Write-Host "Log: $Script:LogFile" -ForegroundColor Yellow
    }

    exit 1
}
