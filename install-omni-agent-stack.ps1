#requires -Version 5.1
[CmdletBinding()]
param([string]$Root = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$InstallerVersion = "3.0.0"
$Root = [IO.Path]::GetFullPath($Root)
$ComponentsRoot = Join-Path $Root "components"
$SkillsRoot = Join-Path $Root "skills"
$ClaudeAgentsRoot = Join-Path $Root "claude-agents"
$AgentsFile = Join-Path $Root "AGENTS.md"
$RuntimeRoot = Join-Path $Root ".omni-v3"
$VenvRoot = Join-Path $RuntimeRoot "venvs"
$LogRoot = Join-Path $RuntimeRoot "logs"
$MarkerRoot = Join-Path $RuntimeRoot "markers"
$LogFile = Join-Path $LogRoot ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))

$Components = @(
    [ordered]@{ Id="anything-llm"; Name="AnythingLLM"; Method="node"; NodePaths=@("server",".") },
    [ordered]@{ Id="autogen"; Name="AutoGen"; Method="python"; MinPython="3.10"; Packages=@("autogen-agentchat","autogen-ext[openai]","autogenstudio"); Imports=@("autogen_agentchat","autogen_ext","autogenstudio") },
    [ordered]@{ Id="browser-use"; Name="Browser Use"; Method="python"; MinPython="3.11"; Packages=@("browser-use"); Imports=@("browser_use"); PostInstall="playwright" },
    [ordered]@{ Id="crawl4ai"; Name="Crawl4AI"; Method="python"; MinPython="3.10"; Packages=@("crawl4ai"); Imports=@("crawl4ai"); PostInstall="crawl4ai" },
    [ordered]@{ Id="crewai"; Name="CrewAI"; Method="python"; MinPython="3.10"; Packages=@("crewai"); Imports=@("crewai") },
    [ordered]@{ Id="firecrawl"; Name="Firecrawl"; Method="compose"; ComposeHints=@("apps\api\docker-compose.yml","apps\api\docker-compose.yaml","docker-compose.yml","docker-compose.yaml","compose.yml","compose.yaml") },
    [ordered]@{ Id="langflow"; Name="Langflow"; Method="python"; MinPython="3.10"; Packages=@("langflow"); Imports=@("langflow") },
    [ordered]@{ Id="localai"; Name="LocalAI"; Method="docker-image"; DockerImage="localai/localai:latest-aio-cpu" },
    [ordered]@{ Id="mem0"; Name="Mem0"; Method="python"; MinPython="3.10"; Packages=@("mem0ai"); Imports=@("mem0") },
    [ordered]@{ Id="ragflow"; Name="RAGFlow"; Method="compose"; ComposeHints=@("docker\docker-compose.yml","docker\docker-compose.yaml","docker-compose.yml","docker-compose.yaml","compose.yml","compose.yaml") }
)

function Initialize-Installer {
    New-Item -ItemType Directory -Force -Path $RuntimeRoot,$VenvRoot,$LogRoot,$MarkerRoot | Out-Null
    if (-not (Test-Path $ComponentsRoot)) {
        throw "Pasta components não encontrada: $ComponentsRoot"
    }
}

function Write-Log {
    param([string]$Message,[ValidateSet("INFO","OK","WARN","ERROR","STEP")][string]$Level="INFO")
    Add-Content -Encoding UTF8 -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')][$Level] $Message"
    $color = switch($Level){"OK"{"Green"}"WARN"{"Yellow"}"ERROR"{"Red"}"STEP"{"Cyan"}default{"Gray"}}
    Write-Host $Message -ForegroundColor $color
}

function Pause-Menu { [void](Read-Host "`nPressione ENTER para continuar") }
function Test-Command([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
function Marker-Path([string]$Name) { return Join-Path $MarkerRoot "$Name.ok" }
function Test-Marker([string]$Name) { return Test-Path (Marker-Path $Name) }
function Set-Marker([string]$Name) { Set-Content -Encoding UTF8 -Path (Marker-Path $Name) -Value (Get-Date -Format o) }

function Invoke-External {
    param([string]$Command,[string[]]$Arguments=@(),[string]$WorkingDirectory=$Root,[switch]$AllowFailure,[switch]$Capture)
    Write-Log "Executando: $Command $($Arguments -join ' ')" INFO
    Push-Location $WorkingDirectory
    try {
        if ($Capture) {
            $output = & $Command @Arguments 2>&1 | ForEach-Object { "$_" }
            $code = $LASTEXITCODE
            $output | Add-Content -Encoding UTF8 -Path $LogFile
            if ($code -ne 0 -and -not $AllowFailure) { throw "Comando falhou com código $code." }
            return [pscustomobject]@{ ExitCode=$code; Output=$output }
        }
        & $Command @Arguments 2>&1 | Tee-Object -FilePath $LogFile -Append
        $code = $LASTEXITCODE
        if ($code -ne 0 -and -not $AllowFailure) { throw "Comando falhou com código $code." }
    } finally {
        Pop-Location
    }
}

function Copy-Tree {
    param([string]$Source,[string]$Destination)
    if (-not (Test-Path $Source)) { throw "Origem não encontrada: $Source" }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    if (Test-Command "robocopy") {
        & robocopy $Source $Destination /E /XO /FFT /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -gt 7) { throw "Robocopy falhou com código $LASTEXITCODE." }
    } else {
        Copy-Item (Join-Path $Source "*") $Destination -Recurse -Force
    }
}

function Install-Codex {
    if (Test-Marker "codex") {
        Write-Log "Codex já está configurado por esta versão do instalador." OK
        return
    }
    if (-not (Test-Path $SkillsRoot)) { throw "Pasta skills não encontrada." }
    if (-not (Test-Path $AgentsFile)) { throw "AGENTS.md não encontrado." }

    Write-Log "Configurando Omni Agent Stack no Codex..." STEP
    $base = Join-Path $HOME ".codex"
    New-Item -ItemType Directory -Force -Path $base | Out-Null
    Copy-Tree $SkillsRoot (Join-Path $base "skills")

    $target = Join-Path $base "AGENTS.md"
    if (Test-Path $target) {
        if ((Get-FileHash $target -Algorithm SHA256).Hash -ne (Get-FileHash $AgentsFile -Algorithm SHA256).Hash) {
            Copy-Item $target "$target.backup-$(Get-Date -Format yyyyMMdd-HHmmss)" -Force
        }
    }
    Copy-Item $AgentsFile $target -Force
    if (-not (Test-Path $target)) { throw "AGENTS.md não foi copiado para o Codex." }

    Set-Marker "codex"
    Write-Log "Codex configurado e validado." OK
}

function Install-Claude {
    if (Test-Marker "claude") {
        Write-Log "Claude Code já está configurado por esta versão do instalador." OK
        return
    }
    if (-not (Test-Path $SkillsRoot)) { throw "Pasta skills não encontrada." }
    if (-not (Test-Path $ClaudeAgentsRoot)) { throw "Pasta claude-agents não encontrada." }

    Write-Log "Configurando Omni Agent Stack no Claude Code..." STEP
    $base = Join-Path $HOME ".claude"
    Copy-Tree $SkillsRoot (Join-Path $base "skills")
    Copy-Tree $ClaudeAgentsRoot (Join-Path $base "agents")

    Set-Marker "claude"
    Write-Log "Claude Code configurado e validado." OK
}

function Install-Destination([ValidateSet("codex","claude","both")][string]$Target) {
    switch($Target) {
        "codex" { Install-Codex }
        "claude" { Install-Claude }
        "both" { Install-Codex; Install-Claude }
    }
}

function Get-Python {
    foreach($candidate in @(
        @{Exe="py";Prefix=@("-3")},
        @{Exe="python";Prefix=@()},
        @{Exe="python3";Prefix=@()}
    )) {
        if (Test-Command $candidate.Exe) {
            $r = Invoke-External $candidate.Exe ($candidate.Prefix + @("-c","import sys;print('.'.join(map(str,sys.version_info[:3])))")) -Capture -AllowFailure
            if ($r.ExitCode -eq 0) {
                return [pscustomobject]@{ Exe=$candidate.Exe; Prefix=$candidate.Prefix; Version=($r.Output|Select-Object -Last 1).Trim() }
            }
        }
    }
    return $null
}

function Venv-Python($Component) { return Join-Path $VenvRoot "$($Component.Id)\Scripts\python.exe" }

function Test-PythonComponent($Component) {
    $python = Venv-Python $Component
    if (-not (Test-Path $python)) { return $false }
    foreach($module in $Component.Imports) {
        if ((Invoke-External $python @("-c","import $module") -Capture -AllowFailure).ExitCode -ne 0) { return $false }
    }
    return $true
}

function Install-PythonComponent($Component) {
    if (Test-PythonComponent $Component) {
        Write-Log "$($Component.Name) já está instalado e validado." OK
        return
    }
    $base = Get-Python
    if (-not $base) { throw "Python não encontrado." }
    if ([version]$base.Version -lt [version]$Component.MinPython) {
        throw "$($Component.Name) requer Python $($Component.MinPython)+. Encontrado: $($base.Version)."
    }

    $venv = Join-Path $VenvRoot $Component.Id
    $python = Venv-Python $Component
    if (-not (Test-Path $python)) {
        Invoke-External $base.Exe ($base.Prefix + @("-m","venv",$venv))
    }

    Invoke-External $python @("-m","pip","install","--upgrade","pip","setuptools","wheel")
    foreach($package in $Component.Packages) {
        Invoke-External $python @("-m","pip","install","--upgrade",$package)
    }

    if ($Component.Contains("PostInstall") -and $Component.PostInstall -eq "playwright") {
        Invoke-External $python @("-m","playwright","install","chromium")
    }
    if ($Component.Contains("PostInstall") -and $Component.PostInstall -eq "crawl4ai") {
        $setup = Join-Path (Split-Path $python -Parent) "crawl4ai-setup.exe"
        if (Test-Path $setup) { Invoke-External $setup }
    }

    if (-not (Test-PythonComponent $Component)) { throw "Validação Python falhou." }
}

function Resolve-NodeDirectory($Component) {
    $base = Join-Path $ComponentsRoot $Component.Id
    foreach($relative in $Component.NodePaths) {
        $candidate = if ($relative -eq ".") { $base } else { Join-Path $base $relative }
        if (Test-Path (Join-Path $candidate "package.json")) { return $candidate }
    }
    return $null
}

function Test-NodeComponent($Component) {
    $directory = Resolve-NodeDirectory $Component
    return $directory -and (Test-Path (Join-Path $directory "node_modules"))
}

function Install-NodeComponent($Component) {
    if (Test-NodeComponent $Component) {
        Write-Log "$($Component.Name) já está instalado." OK
        return
    }
    $directory = Resolve-NodeDirectory $Component
    if (-not $directory) { throw "package.json não encontrado." }
    if (-not (Test-Command "npm")) { throw "npm não encontrado." }

    if ((Test-Path (Join-Path $directory "pnpm-lock.yaml")) -and (Test-Command "pnpm")) {
        Invoke-External "pnpm" @("install","--frozen-lockfile") $directory
    } elseif (Test-Path (Join-Path $directory "package-lock.json")) {
        Invoke-External "npm" @("ci") $directory
    } else {
        Invoke-External "npm" @("install") $directory
    }

    if (-not (Test-NodeComponent $Component)) { throw "Validação Node falhou." }
}

function Test-DockerReady {
    if (-not (Test-Command "docker")) { return $false }
    return (Invoke-External "docker" @("info") -Capture -AllowFailure).ExitCode -eq 0
}

function Find-ComposeFile($Component) {
    $base = Join-Path $ComponentsRoot $Component.Id
    foreach($relative in $Component.ComposeHints) {
        $candidate = Join-Path $base $relative
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}

function Test-ComposeComponent($Component) {
    if (-not (Test-DockerReady)) { return $false }
    $compose = Find-ComposeFile $Component
    if (-not $compose) { return $false }
    return (Invoke-External "docker" @("compose","-f",$compose,"config","--services") (Split-Path $compose -Parent) -Capture -AllowFailure).ExitCode -eq 0
}

function Install-ComposeComponent($Component) {
    if (-not (Test-DockerReady)) { throw "Docker não está disponível." }
    $compose = Find-ComposeFile $Component
    if (-not $compose) { throw "Arquivo Docker Compose não encontrado." }
    $directory = Split-Path $compose -Parent

    $running = Invoke-External "docker" @("compose","-f",$compose,"ps","--status","running","--services") $directory -Capture -AllowFailure
    if (@($running.Output | Where-Object { $_ }).Count -gt 0) {
        Write-Log "$($Component.Name) já está em execução." OK
        return
    }

    Invoke-External "docker" @("compose","-f",$compose,"pull","--ignore-pull-failures") $directory -AllowFailure
    Invoke-External "docker" @("compose","-f",$compose,"build") $directory -AllowFailure
    Invoke-External "docker" @("compose","-f",$compose,"up","-d","--remove-orphans") $directory

    if (-not (Test-ComposeComponent $Component)) { throw "Validação Docker Compose falhou." }
}

function Test-DockerImageComponent($Component) {
    if (-not (Test-DockerReady)) { return $false }
    return (Invoke-External "docker" @("image","inspect",$Component.DockerImage) -Capture -AllowFailure).ExitCode -eq 0
}

function Install-DockerImageComponent($Component) {
    if (Test-DockerImageComponent $Component) {
        Write-Log "$($Component.Name) já está instalado." OK
        return
    }
    if (-not (Test-DockerReady)) { throw "Docker não está disponível." }
    Invoke-External "docker" @("pull",$Component.DockerImage)
    if (-not (Test-DockerImageComponent $Component)) { throw "Validação da imagem Docker falhou." }
}

function Test-Component($Component) {
    switch($Component.Method) {
        "python" { return Test-PythonComponent $Component }
        "node" { return Test-NodeComponent $Component }
        "compose" { return Test-ComposeComponent $Component }
        "docker-image" { return Test-DockerImageComponent $Component }
    }
}

function Install-Component($Component) {
    if (-not (Test-Path (Join-Path $ComponentsRoot $Component.Id))) {
        Write-Log "$($Component.Name): repositório ausente." ERROR
        return $false
    }

    try {
        Write-Log "Preparando $($Component.Name)..." STEP
        switch($Component.Method) {
            "python" { Install-PythonComponent $Component }
            "node" { Install-NodeComponent $Component }
            "compose" { Install-ComposeComponent $Component }
            "docker-image" { Install-DockerImageComponent $Component }
        }
        if (-not (Test-Component $Component)) { throw "Validação final falhou." }
        Set-Marker "component-$($Component.Id)"
        Write-Log "$($Component.Name): INSTALADO E VALIDADO." OK
        return $true
    } catch {
        Write-Log "$($Component.Name): FALHA - $($_.Exception.Message)" ERROR
        return $false
    }
}

function Install-All([ValidateSet("codex","claude","both")][string]$Target) {
    try {
        Install-Destination $Target
    } catch {
        Write-Log "Falha ao configurar o destino: $($_.Exception.Message)" ERROR
        Pause-Menu
        return
    }

    $success = 0
    $failed = 0
    foreach($component in $Components) {
        if (Install-Component $component) { $success++ } else { $failed++ }
    }

    Write-Log "Resumo: $success instalado(s), $failed falha(s)." $(if($failed -eq 0){"OK"}else{"WARN"})
    Pause-Menu
}

function Select-Destination {
    while($true) {
        Clear-Host
        Write-Host "=== DESTINO DO COMPONENTE ===" -ForegroundColor Cyan
        Write-Host "1. Instalar integração apenas no Codex"
        Write-Host "2. Instalar integração apenas no Claude"
        Write-Host "3. Instalar integração em ambos Codex/Claude"
        Write-Host "0. Cancelar"

        switch(Read-Host "`nEscolha") {
            "1" { return "codex" }
            "2" { return "claude" }
            "3" { return "both" }
            "0" { return $null }
            default { Start-Sleep 1 }
        }
    }
}

function Show-SeparateMenu {
    while($true) {
        Clear-Host
        Write-Host "=== INSTALAÇÃO DOS REPOSITÓRIOS ===" -ForegroundColor Cyan
        for($i=0;$i -lt $Components.Count;$i++) {
            Write-Host ("{0,2}. {1}" -f ($i+1),$Components[$i].Name)
        }
        Write-Host " 0. Voltar"

        $choice = Read-Host "`nEscolha"
        if ($choice -eq "0") { return }

        $number = 0
        if ([int]::TryParse($choice,[ref]$number) -and $number -ge 1 -and $number -le 10) {
            $target = Select-Destination
            if ($target) {
                try {
                    Install-Destination $target
                    [void](Install-Component $Components[$number-1])
                } catch {
                    Write-Log "Falha: $($_.Exception.Message)" ERROR
                }
                Pause-Menu
            }
        }
    }
}

function Show-MainMenu {
    while($true) {
        Clear-Host
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host " OMNI AGENT STACK INSTALLER v$InstallerVersion" -ForegroundColor Cyan
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "1. Instalar apenas no Codex"
        Write-Host "2. Instalar apenas no Claude"
        Write-Host "3. Instalar ambos Codex/Claude"
        Write-Host "4. Instalar separados"
        Write-Host "0. Sair"

        switch(Read-Host "`nEscolha") {
            "1" { Install-All "codex" }
            "2" { Install-All "claude" }
            "3" { Install-All "both" }
            "4" { Show-SeparateMenu }
            "0" { return }
            default { Start-Sleep 1 }
        }
    }
}

try {
    Initialize-Installer
    Write-Log "Omni Agent Stack Installer v$InstallerVersion iniciado em $Root." INFO
    Show-MainMenu
} catch {
    Write-Host "ERRO FATAL: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log: $LogFile" -ForegroundColor Yellow
    exit 1
}
