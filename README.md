# Omni Agent Stack

<p align="center">
  <img src="docs/logo.png" width="180">
</p>

<p align="center">

**Uma plataforma unificada para Agentes de IA, Automação, Memória, RAG, Fluxos Inteligentes e Navegação Autônoma.**

[![License](https://img.shields.io/badge/License-Multiple-blue.svg)](#licensing)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%7C%20Linux-success.svg)]
[![Claude Code](https://img.shields.io/badge/Claude-Code-orange.svg)]
[![Codex](https://img.shields.io/badge/OpenAI-Codex-green.svg)]

</p>

---

# Visão Geral

O **Omni Agent Stack** é um **monorepositório agregador** que reúne algumas das principais tecnologias open source para desenvolvimento de Agentes de IA em uma única plataforma.

O objetivo é simplificar a instalação, integração e utilização dessas ferramentas, oferecendo uma experiência única para pesquisadores, desenvolvedores e empresas.

O projeto **não substitui** nenhum dos projetos originais.

Ele atua como uma camada de integração, organização e automação.

---

# Componentes

| Projeto | Finalidade |
|----------|------------|
| AnythingLLM | Plataforma de IA privada com suporte a múltiplos LLMs |
| AutoGen | Framework para agentes colaborativos |
| Browser Use | Navegação inteligente baseada em IA |
| Crawl4AI | Crawling otimizado para aplicações de IA |
| CrewAI | Orquestração de múltiplos agentes |
| Firecrawl | Extração inteligente de conteúdo Web |
| Langflow | Construção visual de pipelines LLM |
| LocalAI | Execução local de modelos compatíveis com OpenAI |
| Mem0 | Memória persistente para agentes |
| RAGFlow | Plataforma completa para sistemas RAG |

---

# Recursos

- Instalação automática
- Integração entre frameworks
- Estrutura única
- Atualização simplificada
- Compatível com Claude Code
- Compatível com OpenAI Codex
- Skills compartilhadas
- Agentes especializados
- Organização em monorepositório
- Scripts para Windows e Linux
- Docker Compose quando disponível
- Ambientes Python isolados
- Instalação automática de dependências Node
- Estrutura preparada para expansão

---

# Estrutura

```
OmniAgentStack/

├── components/
│
├── integrations/
│
├── orchestrator/
│
├── skills/
│
├── claude-agents/
│
├── docs/
│
├── scripts/
│
├── install.ps1
├── install.sh
├── download-and-merge.ps1
├── download-and-merge.sh
│
├── AGENTS.md
├── CLAUDE.md
│
└── README.md
```

---

# Instalação

## Windows

```powershell
Set-ExecutionPolicy Bypass -Scope Process

.\download-and-merge.ps1

.\install-interactive.ps1
```

---

## Linux

```bash
chmod +x download-and-merge.sh

chmod +x install-interactive.sh

./download-and-merge.sh

./install-interactive.sh
```

---

# Instalação Interativa

O instalador permite:

```
1 - Instalar os componentes

2 - Instalar apenas Claude Code

3 - Instalar apenas Codex

4 - Instalar Claude Code + Codex

5 - Instalar tudo
```

Também é possível instalar apenas um framework específico.

---

# Compatibilidade

- Windows 10+
- Windows Server
- Ubuntu
- Debian
- Fedora
- Arch
- WSL2
- Docker

---

# Objetivo

Este projeto busca facilitar a criação de soluções utilizando múltiplos frameworks de IA em conjunto.

Ao invés de instalar e configurar diversas ferramentas manualmente, o Omni Agent Stack oferece um ambiente centralizado, organizado e preparado para evolução.

---

# Licenciamento

Este repositório **não altera a licença dos projetos incorporados**.

Cada componente permanece sob sua licença original.

Consulte a pasta:

```
components/<projeto>/LICENSE
```

para verificar a licença específica.

---

# Créditos

Este projeto somente é possível graças ao excelente trabalho das equipes responsáveis pelos projetos abaixo.

## AnythingLLM

https://github.com/Mintplex-Labs/anything-llm

Copyright © Mintplex Labs

---

## AutoGen

https://github.com/microsoft/autogen

Copyright © Microsoft

---

## Browser Use

https://github.com/browser-use/browser-use

Copyright © Browser Use Contributors

---

## Crawl4AI

https://github.com/unclecode/crawl4ai

Copyright © Crawl4AI Contributors

---

## CrewAI

https://github.com/crewAIInc/crewAI

Copyright © CrewAI Contributors

---

## Firecrawl

https://github.com/firecrawl/firecrawl

Copyright © Firecrawl Contributors

---

## Langflow

https://github.com/langflow-ai/langflow

Copyright © Langflow Contributors

---

## LocalAI

https://github.com/mudler/LocalAI

Copyright © LocalAI Contributors

---

## Mem0

https://github.com/mem0ai/mem0

Copyright © Mem0 Contributors

---

## RAGFlow

https://github.com/infiniflow/ragflow

Copyright © InfiniFlow Contributors

---

# Aviso Importante

Este projeto é um **agregador e integrador**.

Ele **não é afiliado, patrocinado ou mantido** pelos autores dos projetos listados acima.

Todos os direitos sobre cada componente pertencem aos seus respectivos autores.

Caso algum mantenedor deseje qualquer alteração referente aos créditos, estrutura ou distribuição de seu projeto neste repositório, será um prazer atender à solicitação.

---

# Contribuindo

Pull Requests são bem-vindos.

Para mudanças maiores, abra primeiro uma Issue para discutirmos a proposta.

---

# Roadmap

- Interface Web única
- Orquestrador Universal
- Atualizações automáticas
- Marketplace de Skills
- Marketplace de Agentes
- Plugins
- Observabilidade
- Dashboard
- API REST
- API MCP
- Integração com OpenAI
- Integração com Anthropic
- Integração com Ollama
- Integração com LocalAI
- Integração com LM Studio

---

# Desenvolvido com ❤️ pela comunidade Open Source.
