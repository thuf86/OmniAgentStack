#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$Version = "1.1.0"
$Root = [IO.Path]::GetFullPath($Root)
$ComponentsRoot = Join-Path $Root "components"
$SkillsRoot = Join-Path $Root "skills"
$ClaudeAgentsRoot = Join-Path $Root "claude-agents"

$RuntimeFolders = @(
    ".omni",
    ".omni-v3",
    ".omni-v4"
)

$Components = @(
    [ordered]@{
        Id = "anything-llm"
        Name = "AnythingLLM"
        NodePaths = @("server\node_modules","node_modules")
    },
    [ordered]@{ Id="autogen"; Name="AutoGen" },
    [ordered]@{ Id="browser-use"; Name="Browser Use" },
    [ordered]@{ Id="crawl4ai"; Name="Crawl4AI" },
    [ordered]@{ Id="crewai"; Name="CrewAI" },
    [ordered]@{
        Id = "firecrawl"
        Name = "Firecrawl"
        ComposeHints = @(
            "apps\api\docker-compose.yml",
            "apps\api\docker-compose.yaml",
            "docker-compose.yml",
            "docker-compose.yaml",
            "compose.yml",
            "compose.yaml"
        )
    },
    [ordered]@{ Id="langflow"; Name="Langflow" },
    [ordered]@{
        Id = "localai"
        Name = "LocalAI"
        DockerImage = "localai/localai:latest-aio-cpu"
    },
    [ordered]@{ Id="mem0"; Name="Mem0" },
    [ordered]@{
        Id = "ragflow"
        Name = "RAGFlow"
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

function Write-Status {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO","OK","WARN","ERROR","STEP")][string]$Level = "INFO"
    )

    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "STEP" { "Cyan" }
        default { "Gray" }
    }

    Write-Host $Message -ForegroundColor $color
}

function Test-Command {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[S/n]" } else { "[s/N]" }
    $answer = Read-Host "$Message $suffix"

    if ([string]::IsNullOrWhiteSpace($answer)) {
        return $DefaultYes
    }

    return $answer -match "^[sSyY]$"
}

function Remove-PathSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Description = $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Status "${Description}: não encontrado; ignorado." "INFO"
        return
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        Write-Status "${Description}: removido." "OK"
    }
    catch {
        # Fallback para caminhos longos no Windows.
        if (Test-Path -LiteralPath $Path) {
            $normalized = [IO.Path]::GetFullPath($Path)
            & cmd.exe /c "rd /s /q `"\\?\$normalized`"" | Out-Null

            if (Test-Path -LiteralPath $Path) {
                throw "Não foi possível remover: $Path"
            }

            Write-Status "${Description}: removido com suporte a caminho longo." "OK"
        }
    }
}

function Find-ComposeFile {
    param($Component)

    $base = Join-Path $ComponentsRoot $Component.Id

    if (-not (Test-Path $base)) {
        return $null
    }

    foreach ($relative in $Component.ComposeHints) {
        $candidate = Join-Path $base $relative

        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Stop-ComposeStack {
    param(
        $Component,
        [switch]$RemoveVolumes
    )

    if (-not (Test-Command "docker")) {
        Write-Status "$($Component.Name): Docker não encontrado; etapa ignorada." "WARN"
        return
    }

    $compose = Find-ComposeFile $Component

    if (-not $compose) {
        Write-Status "$($Component.Name): arquivo Compose não encontrado; etapa ignorada." "WARN"
        return
    }

    $arguments = @(
        "compose",
        "-f",
        $compose,
        "down",
        "--remove-orphans"
    )

    if ($RemoveVolumes) {
        $arguments += "--volumes"
    }

    Write-Status "Parando serviços de $($Component.Name)..." "STEP"

    Push-Location (Split-Path $compose -Parent)
    try {
        & docker @arguments

        if ($LASTEXITCODE -ne 0) {
            Write-Status "$($Component.Name): Docker Compose retornou código $LASTEXITCODE." "WARN"
        }
        else {
            Write-Status "$($Component.Name): serviços removidos." "OK"
        }
    }
    finally {
        Pop-Location
    }
}

function Remove-IntegrationFiles {
    Write-Status "Removendo integrações do Codex e Claude Code..." "STEP"

    if (Test-Path $SkillsRoot) {
        foreach ($skill in Get-ChildItem $SkillsRoot -Directory -ErrorAction SilentlyContinue) {
            Remove-PathSafe `
                -Path (Join-Path $HOME ".codex\skills\$($skill.Name)") `
                -Description "Codex skill $($skill.Name)"

            Remove-PathSafe `
                -Path (Join-Path $HOME ".claude\skills\$($skill.Name)") `
                -Description "Claude skill $($skill.Name)"
        }
    }

    if (Test-Path $ClaudeAgentsRoot) {
        foreach ($agent in Get-ChildItem $ClaudeAgentsRoot -File -Filter "*.md" -ErrorAction SilentlyContinue) {
            Remove-PathSafe `
                -Path (Join-Path $HOME ".claude\agents\$($agent.Name)") `
                -Description "Claude agent $($agent.Name)"
        }
    }

    $codexAgents = Join-Path $HOME ".codex\AGENTS.md"

    if (Test-Path $codexAgents) {
        $projectAgents = Join-Path $Root "AGENTS.md"
        $removeAgents = $true

        if (Test-Path $projectAgents) {
            try {
                $removeAgents = (Get-FileHash $codexAgents -Algorithm SHA256).Hash -eq
                                (Get-FileHash $projectAgents -Algorithm SHA256).Hash
            }
            catch {
                $removeAgents = $false
            }
        }

        if ($removeAgents) {
            Remove-PathSafe $codexAgents "Codex AGENTS.md do Omni Agent Stack"

            $latestBackup = Get-ChildItem `
                -Path (Join-Path $HOME ".codex") `
                -Filter "AGENTS.md.backup-*" `
                -File `
                -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($latestBackup) {
                Copy-Item $latestBackup.FullName $codexAgents -Force
                Write-Status "Backup anterior do Codex AGENTS.md restaurado." "OK"
            }
        }
        else {
            Write-Status "Codex AGENTS.md foi modificado ou não corresponde ao projeto; preservado." "WARN"
        }
    }
}

function Remove-ProjectInstallations {
    Write-Status "Removendo ambientes e dependências locais..." "STEP"

    foreach ($runtime in $RuntimeFolders) {
        Remove-PathSafe `
            -Path (Join-Path $Root $runtime) `
            -Description "Estado e ambientes $runtime"
    }

    $anything = $Components | Where-Object { $_.Id -eq "anything-llm" }

    foreach ($relative in $anything.NodePaths) {
        Remove-PathSafe `
            -Path (Join-Path (Join-Path $ComponentsRoot "anything-llm") $relative) `
            -Description "AnythingLLM $relative"
    }

    # Ambientes locais eventualmente criados por versões anteriores.
    foreach ($component in $Components) {
        $componentRoot = Join-Path $ComponentsRoot $component.Id

        foreach ($relative in @(".venv","venv")) {
            Remove-PathSafe `
                -Path (Join-Path $componentRoot $relative) `
                -Description "$($component.Name) $relative"
        }
    }
}

function Remove-DockerResources {
    param([switch]$RemoveVolumesAndImages)

    foreach ($id in @("firecrawl","ragflow")) {
        $component = $Components | Where-Object { $_.Id -eq $id }
        Stop-ComposeStack -Component $component -RemoveVolumes:$RemoveVolumesAndImages
    }

    if ($RemoveVolumesAndImages -and (Test-Command "docker")) {
        $localAI = $Components | Where-Object { $_.Id -eq "localai"

        }

        Write-Status "Removendo imagem do LocalAI..." "STEP"
        & docker image rm $localAI.DockerImage

        if ($LASTEXITCODE -eq 0) {
            Write-Status "Imagem do LocalAI removida." "OK"
        }
        else {
            Write-Status "Imagem do LocalAI não foi removida ou não existia." "WARN"
        }
    }
}

function Remove-PlaywrightCache {
    $cache = Join-Path $env:LOCALAPPDATA "ms-playwright"

    if (Test-Path $cache) {
        Remove-PathSafe $cache "Cache global do Playwright"
    }
    else {
        Write-Status "Cache global do Playwright não encontrado." "INFO"
    }
}

function Standard-Cleanup {
    Write-Status "Iniciando limpeza padrão..." "STEP"

    Remove-IntegrationFiles
    Remove-DockerResources
    Remove-ProjectInstallations

    Write-Status "Limpeza padrão concluída. Os repositórios em components foram preservados." "OK"
}

function Full-Cleanup {
    Write-Status "ATENÇÃO: a limpeza completa removerá volumes Docker e dados persistentes." "WARN"

    if (-not (Confirm-Action "Confirma a limpeza completa?" $false)) {
        Write-Status "Limpeza completa cancelada." "INFO"
        return
    }

    Remove-IntegrationFiles
    Remove-DockerResources -RemoveVolumesAndImages
    Remove-ProjectInstallations

    if (Confirm-Action "Remover também o cache global do Playwright? Isso pode afetar outros projetos." $false) {
        Remove-PlaywrightCache
    }

    Write-Status "Limpeza completa concluída. Os repositórios em components foram preservados." "OK"
}

function Show-Menu {
    while ($true) {
        Clear-Host
        Write-Host "==================================================" -ForegroundColor Cyan
        Write-Host " OMNI AGENT STACK UNINSTALLER v$Version" -ForegroundColor Cyan
        Write-Host "==================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Limpeza padrão para reinstalação"
        Write-Host "2. Limpeza completa, incluindo volumes e imagem Docker"
        Write-Host "3. Remover apenas integrações Codex/Claude"
        Write-Host "0. Sair"
        Write-Host ""

        switch (Read-Host "Escolha") {
            "1" {
                if (Confirm-Action "Confirma a limpeza padrão?" $false) {
                    Standard-Cleanup
                }

                [void](Read-Host "`nPressione ENTER para continuar")
            }

            "2" {
                Full-Cleanup
                [void](Read-Host "`nPressione ENTER para continuar")
            }

            "3" {
                if (Confirm-Action "Confirma a remoção das integrações?" $false) {
                    Remove-IntegrationFiles
                    Write-Status "Integrações removidas." "OK"
                }

                [void](Read-Host "`nPressione ENTER para continuar")
            }

            "0" {
                return
            }

            default {
                Start-Sleep -Seconds 1
            }
        }
    }
}

try {
    Show-Menu
}
catch {
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
