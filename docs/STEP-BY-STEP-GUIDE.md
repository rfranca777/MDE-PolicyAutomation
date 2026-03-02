# 📖 MDE Policy Automation — Guia Completo Passo-a-Passo

<div align="center">

**Documentação Detalhada para Implementação e Validação**  
*Com referências visuais do Portal Azure, Portal MDE e execução de scripts*

[![Version](https://img.shields.io/badge/Version-1.0.4-00ff88?style=for-the-badge)](../CHANGELOG.md)
[![Author](https://img.shields.io/badge/Author-Rafael_França-0078D4?style=for-the-badge)](https://github.com/rfranca777)

</div>

---

## 📋 Índice

1. [Visão Geral da Solução](#1-visão-geral-da-solução)
2. [Pré-Requisitos](#2-pré-requisitos)
3. [Etapa 1 — Autenticação e Seleção de Subscription](#3-etapa-1--autenticação)
4. [Etapa 2 — Nomenclatura Inteligente](#4-etapa-2--nomenclatura-inteligente)
5. [Etapa 3 — Resource Group](#5-etapa-3--resource-group)
6. [Etapa 4 — Grupo Entra ID](#6-etapa-4--grupo-entra-id)
7. [Etapa 5 — Automation Account](#7-etapa-5--automation-account)
8. [Etapa 6 — Managed Identity](#8-etapa-6--managed-identity)
9. [Etapa 7 — RBAC Reader](#9-etapa-7--rbac-reader)
10. [Etapa 8 — Permissões Graph API](#10-etapa-8--permissões-graph-api)
11. [Etapa 9 — Módulo Az.Accounts](#11-etapa-9--módulo-azaccounts)
12. [Etapa 10 — Runbook PowerShell](#12-etapa-10--runbook-powershell)
13. [Etapa 11 — Schedule e Job Schedule](#13-etapa-11--schedule-e-job-schedule)
14. [Etapa 12 — Azure Policy](#14-etapa-12--azure-policy)
15. [Etapa 13 — MDE Device Groups](#15-etapa-13--mde-device-groups)
16. [Etapa 14 — MDE Machine Tags via API](#16-etapa-14--mde-machine-tags-via-api)
17. [Validação Completa](#17-validação-completa)
18. [Troubleshooting](#18-troubleshooting)
19. [Referências de Portal](#19-referências-de-portal)

---

## 1. Visão Geral da Solução

### O Problema

Em ambientes com **múltiplas subscriptions Azure**, as VMs Windows aparecem no portal MDE (Microsoft Defender for Endpoint) como uma lista única, sem organização:

```
❌ ANTES (sem automação):
┌──────────────────────────────────────────────────────────────┐
│  MDE Portal → Device Inventory                               │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  srv-prod-01      Windows Server 2022    No Tag        │  │
│  │  srv-dev-03       Windows Server 2019    No Tag        │  │
│  │  vm-staging-02    Windows 11             No Tag        │  │
│  │  sql-prod-01      Windows Server 2022    No Tag        │  │
│  │  ... (centenas de VMs misturadas)                      │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
│  ⚠️ Problemas:                                               │
│  • Impossível aplicar políticas AV/ASR diferenciadas         │
│  • Novas VMs ficam sem tag por dias/semanas                  │
│  • Grupos Intune desatualizados                              │
│  • Trabalho manual a cada subscription nova                  │
└──────────────────────────────────────────────────────────────┘
```

### A Solução

```
✅ DEPOIS (com MDE Policy Automation):
┌──────────────────────────────────────────────────────────────┐
│  MDE Portal → Device Groups (organizados por subscription)   │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  📁 mde-policy-production                              │  │
│  │    ├── srv-prod-01    Tag: mde-policy-production       │  │
│  │    └── sql-prod-01    Tag: mde-policy-production       │  │
│  │                                                        │  │
│  │  📁 mde-policy-development                             │  │
│  │    └── srv-dev-03     Tag: mde-policy-development      │  │
│  │                                                        │  │
│  │  📁 mde-policy-staging                                 │  │
│  │    └── vm-staging-02  Tag: mde-policy-staging          │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                               │
│  ✅ Cada grupo tem políticas AV/ASR específicas              │
│  ✅ Novas VMs são tagueadas automaticamente pela Policy      │
│  ✅ Runbook sincroniza Entra ID a cada hora                  │
│  ✅ Zero intervenção manual                                  │
└──────────────────────────────────────────────────────────────┘
```

### Arquitetura em 3 Camadas

```
┌───────────────────────────────────────────────────────────────────────────┐
│                                                                           │
│  CAMADA 1 — AZURE POLICY (Infraestrutura)                                │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  Azure Policy (DeployIfNotExists)                                   │  │
│  │  ↓ Detecta VM Windows sem tag                                       │  │
│  │  ↓ Deploy Custom Script Extension automaticamente                   │  │
│  │  ↓ Set-MDEDeviceTag.ps1 configura registro Windows:                 │  │
│  │                                                                     │  │
│  │  HKLM:\SOFTWARE\Policies\Microsoft\                                 │  │
│  │    Windows Advanced Threat Protection\DeviceTagging                  │  │
│  │      Group = "mde-policy-{subscription}"                            │  │
│  │                                                                     │  │
│  │  ↓ MDE Agent lê a tag e sincroniza com a nuvem (15-30 min)         │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  CAMADA 2 — AZURE AUTOMATION (Operacional)                               │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  Automation Account com Managed Identity                            │  │
│  │  ↓ Runbook PowerShell executa a cada hora                           │  │
│  │  ↓ Descobre VMs Azure + Azure Arc machines                          │  │
│  │  ↓ Busca devices correspondentes no Entra ID                       │  │
│  │  ↓ Adiciona ao Security Group do Entra ID                          │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
│  CAMADA 3 — MDE INTEGRATION (Segurança)                                  │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │  MDE Device Groups baseados no Entra ID Security Group             │  │
│  │  ↓ Políticas AV/ASR diferenciadas por grupo                        │  │
│  │  ↓ Cada subscription = um Device Group = políticas específicas     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                           │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Pré-Requisitos

### Software Necessário

| Requisito | Como Verificar | Onde Baixar |
|-----------|---------------|-------------|
| **Azure CLI 2.0+** | `az version` | [aka.ms/installazurecli](https://aka.ms/installazurecli) |
| **PowerShell 5.1+** | `$PSVersionTable.PSVersion` | Incluso no Windows 10/11 |
| **Git** | `git --version` | [git-scm.com](https://git-scm.com) |
| **Navegador moderno** | Chrome, Edge, Firefox | Para acesso ao portal Azure |

### Permissões Azure Necessárias

| Permissão | Onde É Usada | Como Verificar |
|-----------|-------------|----------------|
| **Contributor** na Subscription | Criar RG, Automation Account, Policy | Portal → Subscriptions → IAM |
| **Policy Contributor** | Criar e atribuir Azure Policy | Portal → Subscriptions → IAM |
| **User Access Administrator** | Atribuir RBAC para Managed Identity | Portal → Subscriptions → IAM |
| **Global Admin ou Cloud Application Admin** | Graph API permissions | Entra Admin Center → Roles |

### Verificação Rápida

```powershell
# Verificar Azure CLI
az version

# Verificar PowerShell
$PSVersionTable.PSVersion

# Verificar login Azure
az login
az account show

# Verificar permissões
az role assignment list --assignee $(az account show --query user.name -o tsv) --query "[].roleDefinitionName" -o table
```

> **📸 O que você verá no terminal:**
> ```
> PS C:\> az account show --query "{user:user.name, tenant:tenantId, sub:name}" -o table
> User                                    Tenant                                Subscription
> --------------------------------------  ------------------------------------  ----------------------------------------
> admin@contoso.onmicrosoft.com           xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  Production-Subscription
> ```

---

## 3. Etapa 1 — Autenticação

### O Que Acontece

O script verifica se o Azure CLI está autenticado e lista todas as subscriptions disponíveis para seleção.

### No Terminal (Execução do Script)

```
============================================================
  MICROSOFT DEFENDER FOR ENDPOINT
  Deployment Completo - 14 Stages - AUTOMACAO TOTAL
  v1.0.4 - Full Automation Edition
============================================================

[1/14] AUTENTICACAO E SUBSCRICAO
========================================================

  [OK] Autenticado: admin@contoso.onmicrosoft.com

  Subscriptions disponiveis:
  [1] Production-Subscription
  [2] Development-Subscription
  [3] Staging-Subscription

  Selecione (1-3): 1
  [OK] Subscription: Production-Subscription
```

### No Portal Azure — Onde Verificar

**Caminho:** `Portal Azure` → `Subscriptions`

```
📸 Azure Portal → Subscriptions
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Home > Subscriptions                                         │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name                            Status    Subscription ID  │ │
│  │  ────────────────────────────────────────────────────────── │ │
│  │  ✅ Production-Subscription       Active    fbb41bf3-...    │ │
│  │  ✅ Development-Subscription      Active    abc12345-...    │ │
│  │  ✅ Staging-Subscription          Active    def67890-...    │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  💡 O script lista TODAS as subscriptions ativas e pede para     │
│     selecionar qual deseja configurar.                            │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://portal.azure.com/#view/Microsoft_Azure_Billing/SubscriptionsBlade`

---

## 4. Etapa 2 — Nomenclatura Inteligente

### O Que Acontece

O script pega o nome da subscription selecionada e gera nomes padronizados para **todos** os recursos que serão criados. Isso garante consistência e rastreabilidade.

### Lógica de Geração

```powershell
# Exemplo: Subscription "Production-Subscription"
$subNameClean = "Production-Subscription" -replace '[^a-zA-Z0-9-]', '-'  # Remove caracteres especiais
$subNameShort = $subNameClean.Substring(0, 40).ToLower()                  # Trunca em 40 chars, lowercase
# Resultado: "production-subscription"
```

### Tabela de Nomenclatura

| Recurso | Padrão | Exemplo Real |
|---------|--------|-------------|
| **Resource Group** | `rg-mde-{sub}` | `rg-mde-production-subscription` |
| **Automation Account** | `aa-mde-{sub}` | `aa-mde-production-subscription` |
| **Entra ID Group** | `grp-mde-{sub}` | `grp-mde-production-subscription` |
| **MDE Device Group** | `mde-policy-{sub}` | `mde-policy-production-subscription` |
| **Runbook** | `rb-mde-sync-{sub}` | `rb-mde-sync-production-subscription` |
| **Schedule** | `sch-mde-{sub}` | `sch-mde-production-subscription` |
| **Azure Policy** | `pol-mde-tag-{sub}` | `pol-mde-tag-production-subscription` |

> **⚠️ IMPORTANTE:** O `TagValue` aplicado no registro Windows segue a mesma nomenclatura do `mde-policy-{sub}`. Esta é a chave que conecta todo o pipeline.

### No Terminal

```
[2/14] NOMENCLATURA INTELIGENTE
========================================================

  [INFO] Resource Group: rg-mde-production-subscription
  [INFO] Automation Account: aa-mde-production-subscription
  [INFO] Entra ID Group: grp-mde-production-subscription
  [INFO] MDE Device Group: mde-policy-production-subscription
  [INFO] Schedule: sch-mde-production-subscription
  [INFO] Runbook: rb-mde-sync-production-subscription
  [INFO] Policy: pol-mde-tag-production-subscription

  Location:
  Sugestao: eastus
  [ENTER aceitar | Digite outra]: ↵
  [OK] Location: eastus

  Incluir Azure Arc machines?
  [ENTER para SIM | N para nao]: ↵
  [OK] Azure Arc: SIM
```

---

## 5. Etapa 3 — Resource Group

### O Que Acontece

Cria um Resource Group dedicado para os recursos de automação MDE, com **8 tags corporativas** para governança.

### Tags Aplicadas

| Tag | Valor | Propósito |
|-----|-------|-----------|
| `Project` | `MDE-Device-Management` | Identificação do projeto |
| `Environment` | `Production` | Classificação do ambiente |
| `Owner` | `Security-Team` | Equipe responsável |
| `CostCenter` | `SecOps-001` | Centro de custo |
| `Criticality` | `High` | Criticidade do recurso |
| `Compliance` | `SOC2` | Framework de compliance |
| `ManagedBy` | `Azure-Automation` | Forma de gerenciamento |
| `DataClassification` | `Internal` | Classificação de dados |

### No Portal Azure — Onde Verificar

**Caminho:** `Portal Azure` → `Resource Groups` → `rg-mde-{sub}`

```
📸 Azure Portal → Resource Groups
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Home > Resource groups > rg-mde-production-subscription      │
│                                                                   │
│  Overview  │  Tags  │  IAM  │  Deployments                       │
│                                                                   │
│  ┌─ Tags ─────────────────────────────────────────────────────┐  │
│  │  Project              MDE-Device-Management                │  │
│  │  Environment          Production                           │  │
│  │  Owner                Security-Team                        │  │
│  │  CostCenter           SecOps-001                           │  │
│  │  Criticality          High                                 │  │
│  │  Compliance           SOC2                                 │  │
│  │  ManagedBy            Azure-Automation                     │  │
│  │  DataClassification   Internal                             │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups`

### No Terminal

```
[3/14] RESOURCE GROUP
========================================================

  [WAIT] Criando Resource Group...
  [OK] Resource Group criado com sucesso
  [OK] Validacao: Resource Group confirmado
```

---

## 6. Etapa 4 — Grupo Entra ID

### O Que Acontece

Cria um **Security Group** no Microsoft Entra ID (antigo Azure AD). Este grupo será preenchido automaticamente pelo Runbook com os devices (VMs) da subscription.

### No Portal — Microsoft Entra Admin Center

**Caminho:** `Entra Admin Center` → `Groups` → `All groups`

```
📸 Entra Admin Center → Groups → All groups
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Microsoft Entra admin center > Groups > All groups           │
│                                                                   │
│  + New group    🔄 Refresh    🗑️ Delete                          │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Display Name                    Type       Source          │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  grp-mde-production-subscription Security  Cloud           │ │
│  │  grp-mde-development-subscription Security  Cloud          │ │
│  │                                                             │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique no grupo para ver:                                        │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Members (8 devices)                                        │ │
│  │  ├── LAB-AGENCIA4         Windows    Entra ID joined       │ │
│  │  ├── SecLab-DC            Windows    Hybrid joined         │ │
│  │  ├── srv-prod-01          Windows    Entra ID joined       │ │
│  │  └── ... (preenchido automaticamente pelo Runbook)         │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupsManagementMenuBlade/~/AllGroups`

### No Terminal

```
[4/14] GRUPO ENTRA ID (SECURITY GROUP)
========================================================

  [WAIT] Criando novo Security Group...
  [OK] Security Group criado: grp-mde-production-subscription
  [OK] Group ID: c6e6bfee-9e19-4495-97b0-0d5a6ca30e45
```

> **💡 Dica:** O script verifica se o grupo já existe antes de criar. Se existir, reutiliza automaticamente.

---

## 7. Etapa 5 — Automation Account

### O Que Acontece

Cria um Azure Automation Account que será o "motor" da sincronização automática entre VMs Azure e o grupo Entra ID.

### No Portal Azure

**Caminho:** `Portal Azure` → `Automation Accounts` → `aa-mde-{sub}`

```
📸 Azure Portal → Automation Accounts
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Home > Automation Accounts > aa-mde-production-subscription  │
│                                                                   │
│  Overview  │  Runbooks  │  Schedules  │  Identity  │  Modules    │
│                                                                   │
│  ┌─ Essentials ───────────────────────────────────────────────┐  │
│  │  Status:           Running                                 │  │
│  │  Location:         East US                                 │  │
│  │  SKU:              Basic                                   │  │
│  │  Resource Group:   rg-mde-production-subscription          │  │
│  │  Subscription:     Production-Subscription                 │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌─ Identity ─────────────────────────────────────────────────┐  │
│  │  Type:             System assigned                         │  │
│  │  Status:           ✅ On                                   │  │
│  │  Object ID:        df4baebf-4b2f-453d-b4f4-e4708db2aaed   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.Automation%2FAutomationAccounts`

### No Terminal

```
[5/14] AUTOMATION ACCOUNT
========================================================

  [WAIT] Criando Automation Account...
  [OK] Automation Account criado: aa-mde-production-subscription
  [OK] SKU: Basic
```

---

## 8. Etapa 6 — Managed Identity

### O Que Acontece

Habilita a **System Assigned Managed Identity** no Automation Account. Esta identidade permite que o Runbook se autentique automaticamente sem credenciais armazenadas (Zero Trust).

### Conceito Visual

```
┌──────────────────────────────────────────────────────────────┐
│  🔐 ZERO TRUST — Managed Identity                            │
│                                                               │
│  ❌ Forma ANTIGA (insegura):                                  │
│  ├── Service Principal com client_secret no código           │
│  ├── Credenciais rotacionam e expiram                        │
│  └── Risco de vazamento de secrets                           │
│                                                               │
│  ✅ Forma ATUAL (Managed Identity):                           │
│  ├── Azure gera e gerencia a identidade automaticamente      │
│  ├── Sem credenciais no código                               │
│  ├── Rotação automática de tokens                            │
│  └── Princípio de menor privilégio                           │
└──────────────────────────────────────────────────────────────┘
```

### No Portal Azure

**Caminho:** `Automation Account` → `Identity` → `System assigned`

```
📸 Automation Account → Identity
┌──────────────────────────────────────────────────────────────────┐
│  aa-mde-production-subscription │ Identity                        │
│                                                                   │
│  ┌─ System assigned ──────────────────────────────────────────┐  │
│  │                                                             │  │
│  │  Status:  ● On  ○ Off                                      │  │
│  │                                                             │  │
│  │  Object (principal) ID:                                     │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  df4baebf-4b2f-453d-b4f4-e4708db2aaed              │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  ℹ️ This managed identity is used to access Azure           │  │
│  │     resources. You can assign Azure roles to it.           │  │
│  │                                                             │  │
│  │  [ Azure role assignments ]                                │  │
│  └─────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### No Terminal

```
[6/14] MANAGED IDENTITY (ZERO TRUST)
========================================================

  [WAIT] Habilitando System Assigned Managed Identity...
  [OK] Managed Identity habilitada
  [OK] Principal ID: df4baebf-4b2f-453d-b4f4-e4708db2aaed
  [INFO] Aguardando propagacao AAD (30 segundos)...
  [OK] Identity propagada com sucesso
```

> **⚠️ NOTA:** O Azure AD pode levar até 30 segundos para propagar a identidade. O script tem retry logic com 3 tentativas e delays de 20 segundos.

---

## 9. Etapa 7 — RBAC Reader

### O Que Acontece

Atribui a role **Reader** à Managed Identity no escopo da subscription. Isso permite que o Runbook liste as VMs Azure sem poder modificá-las.

### No Portal Azure

**Caminho:** `Subscription` → `Access control (IAM)` → `Role assignments`

```
📸 Subscription → IAM → Role assignments
┌──────────────────────────────────────────────────────────────────┐
│  Production-Subscription │ Access control (IAM)                   │
│                                                                   │
│  ✓ Check access  │  Role assignments  │  Roles  │  Deny          │
│                                                                   │
│  + Add  │  🔄 Refresh  │  📥 Download                            │
│                                                                   │
│  ┌─ Role assignments ─────────────────────────────────────────┐  │
│  │  Name                               Role       Scope      │  │
│  │  ──────────────────────────────────────────────────────────│  │
│  │  aa-mde-production-subscription     Reader     Subscription│  │
│  │  (System Assigned MI)                                      │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  💡 "Reader" permite listar VMs mas NÃO modificá-las.           │
│     Princípio de menor privilégio (Least Privilege).             │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://portal.azure.com/#view/Microsoft_Azure_Billing/SubscriptionsBlade` → IAM

---

## 10. Etapa 8 — Permissões Graph API

### O Que Acontece

Atribui permissões **Graph API** à Managed Identity para que o Runbook possa:
- `Group.ReadWrite.All` — Adicionar/remover membros no grupo Entra ID
- `Device.Read.All` — Ler devices registrados no Entra ID

### Conceito Visual

```
┌──────────────────────────────────────────────────────────────┐
│  📡 Permissões Graph API                                      │
│                                                               │
│  Managed Identity ─────► Microsoft Graph                      │
│  (aa-mde-{sub})         ├── Group.ReadWrite.All              │
│                          │    └── Adicionar VMs ao grupo     │
│                          └── Device.Read.All                  │
│                               └── Buscar devices no Entra ID │
└──────────────────────────────────────────────────────────────┘
```

### No Portal — Entra Admin Center

**Caminho:** `Entra Admin Center` → `Enterprise Applications` → `aa-mde-{sub}` → `Permissions`

```
📸 Entra Admin Center → Enterprise Applications → Permissions
┌──────────────────────────────────────────────────────────────────┐
│  aa-mde-production-subscription │ API permissions                 │
│                                                                   │
│  ┌─ Admin consent granted ─────────────────────────────────────┐ │
│  │  API                Permission           Type     Status    │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  Microsoft Graph    Group.ReadWrite.All   Application  ✅   │ │
│  │  Microsoft Graph    Device.Read.All       Application  ✅   │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://entra.microsoft.com/#view/Microsoft_AAD_IAM/StartboardApplicationsMenuBlade/~/AppAppsPreview`

---

## 11. Etapa 9 — Módulo Az.Accounts

### O Que Acontece

Instala o módulo PowerShell `Az.Accounts` no Automation Account. Este módulo é necessário para que o Runbook use `Connect-AzAccount -Identity` (autenticação via Managed Identity).

### No Portal Azure

**Caminho:** `Automation Account` → `Modules`

```
📸 Automation Account → Modules
┌──────────────────────────────────────────────────────────────────┐
│  aa-mde-production-subscription │ Modules                         │
│                                                                   │
│  + Add a module  │  🔄 Refresh                                   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name           Version   Status                            │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  Az.Accounts    3.x.x    ✅ Available                      │ │
│  │  ... (módulos padrão)                                       │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### No Terminal

```
[9/14] MODULO Az.Accounts
========================================================

  [WAIT] Instalando Az.Accounts no Automation Account...
  [OK] Modulo instalado com sucesso
```

---

## 12. Etapa 10 — Runbook PowerShell

### O Que Acontece

Cria e publica um **Runbook PowerShell** que executa a sincronização entre VMs Azure e o grupo Entra ID:

1. Conecta via Managed Identity
2. Lista todas as VMs Azure na subscription
3. Lista Azure Arc machines (se habilitado)
4. Para cada VM, busca o device correspondente no Entra ID
5. Adiciona devices encontrados ao grupo Entra ID

### Fluxo do Runbook

```
┌─────────────┐    ┌─────────────────┐    ┌──────────────────┐
│ Connect-Az  │    │  Get-AzVM       │    │  Get-AzConnected │
│  Account    │───▶│  (lista VMs)    │───▶│  Machine (Arc)   │
│ -Identity   │    │                 │    │  (opcional)       │
└─────────────┘    └────────┬────────┘    └────────┬─────────┘
                            │                       │
                            ▼                       │
                   ┌─────────────────────┐         │
                   │  Combina nomes:     │◀────────┘
                   │  vm1, vm2, arc1...  │
                   └────────┬────────────┘
                            │
                            ▼
                   ┌─────────────────────┐
                   │  Graph API:         │
                   │  GET /devices       │
                   │  Match por nome     │
                   └────────┬────────────┘
                            │
                            ▼
                   ┌─────────────────────┐
                   │  Graph API:         │
                   │  POST /groups/      │
                   │  {id}/members/$ref  │
                   │  (adiciona device)  │
                   └─────────────────────┘
```

### No Portal Azure

**Caminho:** `Automation Account` → `Runbooks` → `rb-mde-sync-{sub}`

```
📸 Automation Account → Runbooks
┌──────────────────────────────────────────────────────────────────┐
│  aa-mde-production-subscription │ Runbooks                        │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name                              Type       Status       │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  rb-mde-sync-production-subscription PowerShell Published  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique no Runbook → Overview:                                    │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Last run:   2026-03-01 22:00:00 UTC                       │ │
│  │  Status:     Completed                                     │ │
│  │  Duration:   45 seconds                                    │ │
│  │                                                             │ │
│  │  [ Start ]  [ Edit ]  [ View logs ]                        │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### Output do Runbook (exemplo)

```
=== MDE Device Sync Started ===
Subscription: fbb41bf3-dc95-4c71-8e14-396d3ed38b91
Target Group: c6e6bfee-9e19-4495-97b0-0d5a6ca30e45
Include Arc: True
Connected with Managed Identity
Azure VMs found: 5
Arc Machines found: 2
Total devices to sync: 7
Getting all Entra ID devices for matching...
Total Entra ID devices available: 12
Searching VM: srv-prod-01
  MATCHED: srv-prod-01 -> SRV-PROD-01 (DeviceId: 12d7dfc1-...)
Searching VM: sql-prod-01
  MATCHED: sql-prod-01 -> SQL-PROD-01 (DeviceId: 283c4256-...)
...
Entra ID devices found: 5
Current group members: 3
Devices to add: 2
Added device: 283c4256-fde1-4119-...
Added device: a40c50e8-5b2e-4c11-...
=== Sync Complete: 2 devices added ===
```

---

## 13. Etapa 11 — Schedule e Job Schedule

### O Que Acontece

Cria um **Schedule** que executa o Runbook automaticamente a cada hora, e vincula o Runbook ao Schedule.

### No Portal Azure

**Caminho:** `Automation Account` → `Schedules`

```
📸 Automation Account → Schedules
┌──────────────────────────────────────────────────────────────────┐
│  aa-mde-production-subscription │ Schedules                       │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name                              Frequency   Status      │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  sch-mde-production-subscription   Every 1 hour  Enabled  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique no Schedule → Details:                                    │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Start time:     2026-03-01 00:00:00 UTC                   │ │
│  │  Recurrence:     Every 1 hour                              │ │
│  │  Expiration:     Never                                     │ │
│  │  Timezone:       UTC                                       │ │
│  │                                                             │ │
│  │  Linked Runbooks:                                          │ │
│  │  └── rb-mde-sync-production-subscription                   │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

---

## 14. Etapa 12 — Azure Policy

### O Que Acontece

Esta é a etapa mais importante para a **automação de tags**. Cria uma Azure Policy do tipo `DeployIfNotExists` que:

1. **Detecta** VMs Windows sem a Custom Script Extension `MDEDeviceTagExtension`
2. **Deploya automaticamente** a extensão com o script `Set-MDEDeviceTag.ps1`
3. O script **configura o registro Windows** com o tag value

### Como a Policy Funciona (Fluxo Visual)

```
┌───────────────────────────────────────────────────────────────────┐
│                                                                    │
│  VM Windows criada    Azure Policy avalia     Compliance check     │
│  no Azure          ──► a cada 15-30 min   ──► é "Non-Compliant"?  │
│                                                                    │
│                              │ SIM                                  │
│                              ▼                                      │
│                    ┌─────────────────────────────────┐              │
│                    │  DeployIfNotExists triggered     │              │
│                    │  ↓                               │              │
│                    │  Cria sub-resource:              │              │
│                    │  CustomScriptExtension           │              │
│                    │  Name: MDEDeviceTagExtension     │              │
│                    │  Script: Set-MDEDeviceTag.ps1    │              │
│                    │  Args: -TagValue "mde-policy-x"  │              │
│                    └─────────────┬───────────────────┘              │
│                                  │                                  │
│                                  ▼                                  │
│                    ┌─────────────────────────────────┐              │
│                    │  Dentro da VM:                   │              │
│                    │  HKLM:\SOFTWARE\Policies\        │              │
│                    │    Microsoft\Windows Advanced    │              │
│                    │    Threat Protection\            │              │
│                    │    DeviceTagging                 │              │
│                    │      Group = "mde-policy-{sub}"  │              │
│                    └─────────────┬───────────────────┘              │
│                                  │                                  │
│                                  ▼                                  │
│                    ┌─────────────────────────────────┐              │
│                    │  MDE Sense Agent lê o registry  │              │
│                    │  ↓ Sync com MDE Cloud (15-30m)  │              │
│                    │  ↓ Tag aparece no MDE Portal    │              │
│                    └─────────────────────────────────┘              │
│                                                                    │
└───────────────────────────────────────────────────────────────────┘
```

### No Portal Azure — Policy Definitions

**Caminho:** `Portal Azure` → `Policy` → `Definitions` → Buscar `mde-device-tag`

```
📸 Azure Portal → Policy → Definitions
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Policy │ Definitions                                         │
│                                                                   │
│  🔍 Search: "mde-device-tag"                                    │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name                                      Type    Mode    │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  Deploy MDE Device Tag to Windows VMs      Custom  Indexed│ │
│  │  (mde-device-tag-windows-vms)                              │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique para ver detalhes:                                        │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Policy rule (JSON):                                        │ │
│  │  IF:                                                        │ │
│  │    type == "Microsoft.Compute/virtualMachines"              │ │
│  │    AND osType == "Windows"                                  │ │
│  │  THEN:                                                      │ │
│  │    effect = DeployIfNotExists                               │ │
│  │    → Deploy CustomScriptExtension with Set-MDEDeviceTag.ps1│ │
│  │                                                             │ │
│  │  Parameters:                                                │ │
│  │    tagValue: string (required)                              │ │
│  │    scriptUri: string (required)                             │ │
│  │    effect: string (default: DeployIfNotExists)              │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://portal.azure.com/#view/Microsoft_Azure_Policy/PolicyMenuBlade/~/Definitions`

### No Portal Azure — Policy Compliance

**Caminho:** `Portal Azure` → `Policy` → `Compliance`

```
📸 Azure Portal → Policy → Compliance
┌──────────────────────────────────────────────────────────────────┐
│  🏠 Policy │ Compliance                                          │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Assignment Name                   Compliance   Resources  │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  MDE Device Tag | SecurityLab      85%          2 VMs      │ │
│  │  (mde-tag-securitylab)                                     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique na assignment → Resource compliance:                      │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Resource                  Compliance State  Last Evaluated │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  lab-agencia4              ✅ Compliant      2026-03-01    │ │
│  │  lab-mde-policy-tag-mng    ✅ Compliant      2026-03-01    │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

### No Portal Azure — VM Extensions

**Caminho:** `Portal Azure` → `Virtual Machine` → `Extensions + applications`

```
📸 VM → Extensions + applications
┌──────────────────────────────────────────────────────────────────┐
│  lab-agencia4 │ Extensions + applications                         │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Name                         Publisher          Status     │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  MDEDeviceTagExtension        Microsoft.Compute   ✅ OK    │ │
│  │  AzurePolicyForWindows        Microsoft.GuestConf ✅ OK    │ │
│  │  BGInfo                       Microsoft.Compute   ✅ OK    │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  💡 A extensão "MDEDeviceTagExtension" foi criada                │
│     AUTOMATICAMENTE pela Azure Policy. Não precisa instalar      │
│     manualmente.                                                  │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `Portal Azure` → `Virtual machines` → Selecione a VM → `Extensions + applications`

### Verificação do Registry na VM

Para verificar se o tag foi configurado corretamente na VM:

```powershell
# Via Azure CLI (remotamente, sem precisar acessar a VM):
az vm run-command invoke `
    --resource-group SecurityLab `
    --name lab-agencia4 `
    --command-id RunPowerShellScript `
    --scripts "Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'"
```

> **📸 Resultado esperado:**
> ```
> Group        : mde-policy-me-mngenvmcap186458-rafaelluizf-1
> PSPath       : ...DeviceTagging
> ```

---

## 15. Etapa 13 — MDE Device Groups

### O Que Acontece

O script **gera um arquivo HTML** com instruções detalhadas para criar o MDE Device Group no portal security.microsoft.com. Esta é a **única etapa manual** — a API do MDE não suporta criação programática de Device Groups.

### No Portal MDE — Device Groups

**Caminho:** `security.microsoft.com` → `Settings` → `Endpoints` → `Device groups`

```
📸 MDE Portal → Settings → Endpoints → Device groups
┌──────────────────────────────────────────────────────────────────┐
│  🛡️ Microsoft Defender XDR                                       │
│                                                                   │
│  Settings > Endpoints > Device groups                             │
│                                                                   │
│  + Add device group                                               │
│                                                                   │
│  ┌─ Step 1: General ──────────────────────────────────────────┐  │
│  │                                                             │  │
│  │  Device group name:                                        │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  mde-policy-production-subscription                 │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  Description:                                              │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  Managed device group for subscription              │   │  │
│  │  │  Production-Subscription                            │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  Automation level:                                         │  │
│  │  ⚫ Full - remediate threats automatically                 │  │
│  │  ○  Semi - require approval for all folders               │  │
│  │  ○  No automated response                                 │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌─ Step 2: Devices ──────────────────────────────────────────┐  │
│  │                                                             │  │
│  │  Filter by: Tag                                            │  │
│  │  ┌─────────────────────────────────────────────────────┐   │  │
│  │  │  Operator: Equals                                   │   │  │
│  │  │  Value:    mde-policy-production-subscription       │   │  │
│  │  └─────────────────────────────────────────────────────┘   │  │
│  │                                                             │  │
│  │  Preview (3 devices):                                      │  │
│  │  ├── srv-prod-01                                           │  │
│  │  ├── sql-prod-01                                           │  │
│  │  └── app-prod-01                                           │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                   │
│  ┌─ Step 3: User access ─────────────────────────────────────┐   │
│  │  Assign user groups with access to this device group       │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                   │
│  [ Done ]                                                         │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://security.microsoft.com/securitysettings/endpoints/device_groups`

> **⚠️ IMPORTANTE:** O nome do Device Group (`mde-policy-{sub}`) deve corresponder **exatamente** ao valor da tag configurada no registry. Assim, todos os devices com essa tag serão automaticamente incluídos no grupo.

---

## 16. Etapa 14 — MDE Machine Tags via API

### O Que Acontece (Opcional)

Para organizações que querem tags **adicionais** além do registry, o script pode:
1. Criar um App Registration no Entra ID
2. Solicitar permissão `Machine.ReadWrite.All` no MDE API
3. Aplicar tags diretamente via MDE API a todos os devices

### No Portal — App Registrations

**Caminho:** `Entra Admin Center` → `App registrations` → `MDE-Automation-{sub}`

```
📸 Entra Admin Center → App registrations
┌──────────────────────────────────────────────────────────────────┐
│  MDE-Automation-production-subscription │ API permissions          │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  API                      Permission              Status   │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  WindowsDefenderATP       Machine.ReadWrite.All    ✅      │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ℹ️ Esta permissão é necessária SOMENTE para Stage 14.           │
│     Os Stages 1-13 funcionam sem esta permissão.                  │
└──────────────────────────────────────────────────────────────────┘
```

---

## 17. Validação Completa

### Checklist de Verificação

Após a execução do script, verifique cada componente:

```
┌──────────────────────────────────────────────────────────────────┐
│  ✅ CHECKLIST DE VALIDAÇÃO                                       │
│                                                                   │
│  □ 1. Resource Group existe com 8 tags                           │
│       Portal → Resource Groups → rg-mde-{sub} → Tags            │
│                                                                   │
│  □ 2. Entra ID Group existe                                      │
│       Entra Admin Center → Groups → grp-mde-{sub}               │
│                                                                   │
│  □ 3. Entra ID Group tem membros (devices)                       │
│       Entra Admin Center → Groups → grp-mde-{sub} → Members     │
│                                                                   │
│  □ 4. Automation Account existe com Managed Identity             │
│       Portal → Automation Accounts → aa-mde-{sub} → Identity    │
│                                                                   │
│  □ 5. Runbook está Published                                     │
│       Portal → Automation Accounts → aa-mde-{sub} → Runbooks    │
│                                                                   │
│  □ 6. Schedule está Enabled (hourly)                             │
│       Portal → Automation Accounts → aa-mde-{sub} → Schedules   │
│                                                                   │
│  □ 7. Azure Policy está Assigned                                 │
│       Portal → Policy → Assignments → mde-tag-{sub}             │
│                                                                   │
│  □ 8. VMs têm o registry tag configurado                        │
│       VM → Run Command → Get-ItemProperty DeviceTagging          │
│                                                                   │
│  □ 9. MDE Portal mostra tag nos devices                          │
│       security.microsoft.com → Device Inventory → Device → Tags  │
│                                                                   │
│  □ 10. MDE Device Group criado (manual)                          │
│        security.microsoft.com → Settings → Device groups          │
└──────────────────────────────────────────────────────────────────┘
```

### Comandos de Validação

```powershell
# 1. Verificar Resource Group
az group show --name "rg-mde-{sub}" --query "{name:name,tags:tags}" -o json

# 2. Verificar Automation Account
az automation account show --name "aa-mde-{sub}" --resource-group "rg-mde-{sub}" --query "{name:name,state:state}" -o table

# 3. Verificar Runbook
az automation runbook show --name "rb-mde-sync-{sub}" --automation-account-name "aa-mde-{sub}" --resource-group "rg-mde-{sub}" --query "{name:name,state:state}" -o table

# 4. Verificar Azure Policy
az policy definition show --name "pol-mde-tag-{sub}" --query "{name:name,mode:mode}" -o table

# 5. Verificar Tag no Registry da VM (remoto)
az vm run-command invoke -g "rg-mde-{sub}" -n "vm-name" --command-id RunPowerShellScript --scripts "Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection\DeviceTagging'"

# 6. Verificar MDE Sense Agent
az vm run-command invoke -g "rg-mde-{sub}" -n "vm-name" --command-id RunPowerShellScript --scripts "Get-Service -Name Sense | Select-Object Name,Status,StartType"
```

> **📸 Resultado esperado da validação de tag:**
> ```
> PS> az vm run-command invoke -g SecurityLab -n lab-agencia4 --command-id RunPowerShellScript --scripts "..." -o tsv
> SENSE: Running
> TAG: mde-policy-me-mngenvmcap186458-rafaelluizf-1
> ```

### No Portal MDE — Device Inventory com Tags

**Caminho:** `security.microsoft.com` → `Assets` → `Devices`

```
📸 MDE Portal → Device Inventory
┌──────────────────────────────────────────────────────────────────┐
│  🛡️ Microsoft Defender XDR │ Assets > Devices                    │
│                                                                   │
│  🔍 Filter: Tag contains "mde-policy"                            │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Device Name      OS             Tags                       │ │
│  │  ──────────────────────────────────────────────────────────│ │
│  │  LAB-AGENCIA4     Windows 10     mde-policy-me-mngenv...  │ │
│  │  LAB-MDE-POLI...  Windows 10     mde-policy-me-mngenv...  │ │
│  │  SecLab-DC        Windows Server mde-policy-me-mngenv...  │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  Clique no device → Device page → Tags section:                   │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │  Tags:                                                      │ │
│  │  ┌───────────────────────────────────────────────────────┐ │ │
│  │  │  🏷️ mde-policy-me-mngenvmcap186458-rafaelluizf-1     │ │ │
│  │  └───────────────────────────────────────────────────────┘ │ │
│  │                                                             │ │
│  │  ℹ️ Tag definida via registro Windows (Azure Policy)        │ │
│  └─────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

**URL direta:** `https://security.microsoft.com/machines`

---

## 18. Troubleshooting

### Problema: Tag não aparece no MDE Portal

```
Diagnóstico:
┌──────────────────────────────────────────────────────────────┐
│  1. Verificar MDE Sense Agent na VM                          │
│     Get-Service -Name Sense                                  │
│     → Deve estar "Running" com StartType "Automatic"        │
│                                                               │
│  2. Verificar registry key                                    │
│     Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\     │
│       Windows Advanced Threat Protection\DeviceTagging"      │
│     → Group deve ter o valor correto                         │
│                                                               │
│  3. Aguardar sincronização                                   │
│     O MDE Agent sincroniza tags a cada 15-30 minutos.        │
│     Em alguns casos pode levar até 4 horas na primeira vez.  │
│                                                               │
│  4. Verificar conectividade                                  │
│     A VM precisa acessar *.securitycenter.windows.com        │
└──────────────────────────────────────────────────────────────┘
```

### Problema: Policy mostra "Non-Compliant"

```
Diagnóstico:
┌──────────────────────────────────────────────────────────────┐
│  1. Verificar se a VM é Windows                              │
│     A policy só se aplica a VMs Windows (osType == Windows)  │
│                                                               │
│  2. Verificar Managed Identity da Policy Assignment          │
│     A assignment precisa de uma Managed Identity com role    │
│     "Virtual Machine Contributor" para deployer extensões    │
│                                                               │
│  3. Verificar acesso ao script                               │
│     O scriptUri deve ser acessível publicamente ou via SAS   │
│     Teste: Invoke-WebRequest -Uri $ScriptUri                 │
│                                                               │
│  4. Forçar avaliação                                         │
│     az policy state trigger-scan --resource-group "rg-mde-*" │
│     Aguardar 15-30 minutos                                   │
└──────────────────────────────────────────────────────────────┘
```

### Problema: Runbook falha com erro de permissão

```
Diagnóstico:
┌──────────────────────────────────────────────────────────────┐
│  1. Verificar Managed Identity está ativada                  │
│     Automation Account → Identity → System assigned → On    │
│                                                               │
│  2. Verificar RBAC Reader                                    │
│     Subscription → IAM → Role assignments                    │
│     A MI deve ter "Reader" na subscription                   │
│                                                               │
│  3. Verificar Graph API permissions                          │
│     Entra Admin Center → Enterprise Apps → aa-mde-* →       │
│     API permissions → Group.ReadWrite.All + Device.Read.All  │
│                                                               │
│  4. Verificar módulo Az.Accounts                             │
│     Automation Account → Modules → Az.Accounts              │
│     Status deve ser "Available"                              │
└──────────────────────────────────────────────────────────────┘
```

---

## 19. Referências de Portal

### URLs Importantes

| Portal | URL | O Que Ver |
|--------|-----|-----------|
| **Azure Policy** - Definitions | [portal.azure.com/#...PolicyMenuBlade/~/Definitions](https://portal.azure.com/#view/Microsoft_Azure_Policy/PolicyMenuBlade/~/Definitions) | Definição da policy `mde-device-tag` |
| **Azure Policy** - Compliance | [portal.azure.com/#...PolicyComplianceBlade](https://portal.azure.com/#view/Microsoft_Azure_Policy/PolicyComplianceBlade) | Status de compliance das VMs |
| **Resource Groups** | [portal.azure.com/#...BrowseResourceGroups](https://portal.azure.com/#view/HubsExtension/BrowseResourceGroups) | Resource Group `rg-mde-{sub}` |
| **Automation Accounts** | [portal.azure.com/#...AutomationAccounts](https://portal.azure.com/#view/HubsExtension/BrowseResource/resourceType/Microsoft.Automation%2FAutomationAccounts) | Runbooks, Schedules, Identity |
| **VM Extensions** | Portal → VM → Extensions | Custom Script Extension `MDEDeviceTagExtension` |
| **Entra ID Groups** | [entra.microsoft.com/#...AllGroups](https://entra.microsoft.com/#view/Microsoft_AAD_IAM/GroupsManagementMenuBlade/~/AllGroups) | Grupo `grp-mde-{sub}` e membros |
| **MDE Device Inventory** | [security.microsoft.com/machines](https://security.microsoft.com/machines) | Tags nos devices |
| **MDE Device Groups** | [security.microsoft.com/...device_groups](https://security.microsoft.com/securitysettings/endpoints/device_groups) | Criar/gerenciar Device Groups |
| **MDE Machine Tags** | [learn.microsoft.com/...machine-tags](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/machine-tags) | Documentação oficial Microsoft |

### Documentação Oficial Microsoft

- [Azure Policy Overview](https://learn.microsoft.com/azure/governance/policy/overview)
- [DeployIfNotExists Effect](https://learn.microsoft.com/azure/governance/policy/concepts/effects#deployifnotexists)
- [Managed Identities](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview)
- [MDE Machine Tags](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/machine-tags)
- [MDE Device Groups](https://learn.microsoft.com/microsoft-365/security/defender-endpoint/machine-groups)
- [Azure Automation Runbooks](https://learn.microsoft.com/azure/automation/automation-runbook-types)
- [Custom Script Extension](https://learn.microsoft.com/azure/virtual-machines/extensions/custom-script-windows)

---

## 📊 Resumo Final do Pipeline

```
┌─────────────────────────────────────────────────────────────────────────┐
│                                                                         │
│  ✅ PIPELINE MDE POLICY AUTOMATION — RESUMO VISUAL                     │
│                                                                         │
│  EXECUÇÃO ÚNICA (14 Stages):                                           │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │ [1] Auth → [2] Naming → [3] RG → [4] Entra Group                 │ │
│  │   ↓                                                                │ │
│  │ [5] Automation → [6] MI → [7] RBAC → [8] Graph                   │ │
│  │   ↓                                                                │ │
│  │ [9] Module → [10] Runbook → [11] Schedule                        │ │
│  │   ↓                                                                │ │
│  │ [12] Azure Policy → [13] MDE Device Group → [14] MDE API Tags    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  EXECUÇÃO CONTÍNUA (automática, sem intervenção):                      │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │                                                                    │ │
│  │  A cada hora:  Runbook → Azure VMs → Entra ID Group → MDE        │ │
│  │  A cada VM:    Azure Policy → Custom Script → Registry → MDE Tag │ │
│  │                                                                    │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
│  RESULTADO:                                                             │
│  ┌────────────────────────────────────────────────────────────────────┐ │
│  │  • VMs automaticamente tagueadas pela subscription                │ │
│  │  • Entra ID Group sempre em sync com Azure VMs                    │ │
│  │  • MDE Device Groups com políticas diferenciadas                  │ │
│  │  • Zero trabalho manual após deploy inicial                       │ │
│  └────────────────────────────────────────────────────────────────────┘ │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

<div align="center">

**MDE Policy Automation v1.0.4** — *From manual chaos to automated governance*

[![GitHub](https://img.shields.io/badge/GitHub-rfranca777/MDE--PolicyAutomation-181717?style=for-the-badge&logo=github)](https://github.com/rfranca777/MDE-PolicyAutomation)
[![ODefender](https://img.shields.io/badge/ODefender-Community-FF6F00?style=for-the-badge)](https://github.com/rfranca777/odefender-community)

**Autor:** Rafael França — Customer Success Architect, Cyber Security @ Microsoft

</div>
