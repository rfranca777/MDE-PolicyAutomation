<#
.SYNOPSIS
    FIX v2: Deep Name Matching + Registar VMs + Popular Grupos Entra ID
.DESCRIPTION
    Versao avancada do fix com 6 camadas de matching para resolver diferencas
    de nomenclatura entre Azure VM names, Entra ID device displayNames e MDE.
    
    Problema original: 15/28 VMs matched, 13 ficaram de fora.
    Causa raiz: Azure VM name != Entra ID device displayName
    
    Camadas de matching (em ordem de confianca):
    L1: physicalIds contem Azure Resource ID da VM (99% exacto)
    L2: Nome exacto case-insensitive (95%)
    L3: Nome normalizado sem dominio/prefixo (90%)
    L4: NetBIOS truncado 15 chars (85% — Windows trunca hostnames)
    L5: Fuzzy match — contains/startsWith/endsWith (70%)
    L6: Azure vmId == Entra deviceId (60% — quando MDE+AAD sincronizados)
    
    Tambem:
    - Diagnostico completo: mostra TODOS os devices Entra com nomes similares
    - Instala extensao AAD nas VMs sem device
    - Adiciona devices aos 4 grupos (main/stale7/stale30/ephemeral)
    - Mapeamento manual para casos impossíveis de automatizar
    
.NOTES
    Version: 2.0.0
    Author:  Rafael Franca — github.com/rfranca777
    Date:    2026-03-09
#>

$ErrorActionPreference = "Continue"

# ============================================================
# CONFIGURACAO — ALTERAR CONFORME NECESSARIO
# ============================================================
$sub       = "fbb41bf3-dc95-4c71-8e14-396d3ed38b91"
$grpMain   = "57290630-2627-4daa-9310-f21947a460f4"
$grpStale7 = "e24ed75b-df91-47e0-8eaf-2520d16531ec"
$grpStale30= "ccbbd400-1ac2-4b59-937e-2bcdcac1e2df"
$grpEph    = "82d42fb0-4ff4-4b1a-a71a-4b39ef6e0239"

# Mapeamento manual — para VMs com nomes completamente diferentes no Entra ID
# Formato: "AzureVmName" = "EntraDeviceDisplayName"
# Preencher APENAS se houver VMs que nem o fuzzy match conseguir resolver
$manualMap = @{
    # "vm-azure-name" = "entra-device-name"
    # "SRVPROD01"     = "srvprod01.corp.contoso.com"
}

# ============================================================
# FUNCOES DE NORMALIZACAO AVANCADA
# ============================================================
function Normalize-Deep {
    <#
    .SYNOPSIS
        Normalizacao profunda de nomes para matching Azure/Entra/MDE
    .DESCRIPTION
        Remove: dominios, prefixos DOMAIN\, sufixos .local/.corp/.com,
        hifens/underscores extras, e converte para lowercase.
    #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    
    $n = $Name.Trim().ToLower()
    
    # 1. Remover prefixo de dominio (DOMAIN\hostname → hostname)
    if ($n -match '^[^\\]+\\(.+)$') { $n = $Matches[1] }
    
    # 2. Remover sufixos de dominio (hostname.domain.local → hostname)
    #    Cuidado: nao remover se o nome todo é o FQDN sem hostname separavel
    if ($n -match '^([^.]+)\.') { $n = $Matches[1] }
    
    # 3. Remover caracteres especiais que podem diferir entre sistemas
    #    Manter hifens e numeros (importantes para identidade)
    $n = $n -replace '[_]', '-'         # normalizar underscore → hifen
    $n = $n -replace '--+', '-'          # colapsar hifens duplos
    $n = $n -replace '^-|-$', ''         # remover hifens nas pontas
    
    return $n
}

function Get-NetBIOSName {
    <#
    .SYNOPSIS
        Simula truncamento NetBIOS (Windows limita hostnames a 15 chars)
    #>
    param([string]$Name)
    $norm = Normalize-Deep $Name
    if ($norm.Length -gt 15) { return $norm.Substring(0, 15) }
    return $norm
}

function Get-SimilarityScore {
    <#
    .SYNOPSIS
        Calcula score de similaridade entre dois nomes (0.0 a 1.0)
    .DESCRIPTION
        Usa metrica simples: longest common substring / max length
    #>
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return 0.0 }
    
    $a1 = $A.ToLower()
    $b1 = $B.ToLower()
    
    if ($a1 -eq $b1) { return 1.0 }
    
    # Longest common substring
    $maxLen = 0
    for ($i = 0; $i -lt $a1.Length; $i++) {
        for ($j = 0; $j -lt $b1.Length; $j++) {
            $len = 0
            while (($i + $len) -lt $a1.Length -and ($j + $len) -lt $b1.Length -and $a1[$i + $len] -eq $b1[$j + $len]) {
                $len++
            }
            if ($len -gt $maxLen) { $maxLen = $len }
        }
    }
    
    return [Math]::Round($maxLen / [Math]::Max($a1.Length, $b1.Length), 2)
}

function Get-AllEntraDevices {
    <#
    .SYNOPSIS
        Fetch paginado de todos os devices Entra ID (suporta >999)
    #>
    $allDevices = @()
    $uri = "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,physicalIds,operatingSystem,operatingSystemVersion,trustType,approximateLastSignInDateTime,accountEnabled"
    do {
        $response = az rest --method GET --uri $uri -o json 2>$null | ConvertFrom-Json
        if ($response -and $response.value) {
            $allDevices += $response.value
        }
        $uri = if ($response -and $response.'@odata.nextLink') { $response.'@odata.nextLink' } else { $null }
    } while ($uri)
    return ,$allDevices
}

# ============================================================
# INICIO
# ============================================================
$tempPath = "C:\temp"
if (-not (Test-Path $tempPath)) { New-Item -ItemType Directory -Path $tempPath -Force | Out-Null }

az account set --subscription $sub 2>$null

Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v2: DEEP MATCHING + REGISTAR + SYNC GRUPOS" -ForegroundColor White
Write-Host "  6 camadas de matching | Diagnostico completo" -ForegroundColor Gray
Write-Host "================================================================`n" -ForegroundColor Magenta

# ============================================================
# FASE 1: INVENTARIO AZURE VMs
# ============================================================
Write-Host "--- FASE 1: INVENTARIO AZURE VMs ---`n" -ForegroundColor Cyan

$vmsRaw = az vm list --subscription $sub --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vms = @()
if ($vmsRaw) { $vms = @($vmsRaw | ConvertFrom-Json) }

# Power state — batch query (MUITO mais rapido que get-instance-view por VM)
$powerMap = @{}
$powerRaw = az vm list --subscription $sub -d --query "[].{name:name, power:powerState}" -o json 2>$null
if ($powerRaw) {
    $powerList = $powerRaw | ConvertFrom-Json
    foreach ($p in $powerList) { $powerMap[$p.name] = $p.power }
}

$vmDetails = @()
foreach ($vm in $vms) {
    $vmDetails += @{
        name   = $vm.name
        rg     = $vm.rg
        os     = $vm.os
        id     = $vm.id
        vmId   = $vm.vmId
        power  = if ($powerMap.ContainsKey($vm.name)) { $powerMap[$vm.name] } else { "Unknown" }
    }
}

Write-Host "  Total VMs: $($vmDetails.Count)" -ForegroundColor White
Write-Host ""
Write-Host ("  {0,-30} {1,-10} {2,-20} {3,-15}" -f "NOME", "OS", "RESOURCE GROUP", "POWER STATE") -ForegroundColor DarkCyan
Write-Host "  $('-' * 80)" -ForegroundColor DarkGray
foreach ($v in $vmDetails) {
    $powerColor = if ($v.power -match "running") { "Green" } elseif ($v.power -match "deallocated|stopped") { "Yellow" } else { "Gray" }
    Write-Host ("  {0,-30} {1,-10} {2,-20} {3,-15}" -f $v.name, $v.os, $v.rg, $v.power) -ForegroundColor $powerColor
}

# ============================================================
# FASE 2: INVENTARIO ENTRA ID DEVICES
# ============================================================
Write-Host "`n--- FASE 2: INVENTARIO ENTRA ID DEVICES ---`n" -ForegroundColor Cyan

$deviceList = Get-AllEntraDevices
Write-Host "  Total devices Entra ID: $($deviceList.Count)" -ForegroundColor White

# Pre-calcular nomes normalizados de todos os devices para performance
$deviceIndex = @()
foreach ($d in $deviceList) {
    $deviceIndex += @{
        raw           = $d
        displayName   = $d.displayName
        normalized    = Normalize-Deep $d.displayName
        netbios       = Get-NetBIOSName $d.displayName
        id            = $d.id
        deviceId      = $d.deviceId
        os            = $d.operatingSystem
        trustType     = $d.trustType
        lastSignIn    = $d.approximateLastSignInDateTime
        enabled       = $d.accountEnabled
        physicalIds   = $d.physicalIds
    }
}

# ============================================================
# FASE 3: DEEP MATCHING (6 CAMADAS)
# ============================================================
Write-Host "`n--- FASE 3: DEEP MATCHING (6 CAMADAS) ---`n" -ForegroundColor Cyan

$matched = @()
$unmatched = @()
$matchLog = @()
$usedDeviceIds = @{}  # Evitar match duplo

foreach ($vm in $vmDetails) {
    $vmName = $vm.name
    $vmNorm = Normalize-Deep $vmName
    $vmNetBIOS = Get-NetBIOSName $vmName
    $vmResourceId = $vm.id.ToLower()
    $vmVmId = if ($vm.vmId) { $vm.vmId.ToLower() } else { "" }
    
    $dev = $null
    $matchLayer = ""
    $matchDetail = ""
    
    # --- L0: Mapeamento Manual ---
    if ($manualMap.ContainsKey($vmName)) {
        $manualTarget = $manualMap[$vmName].ToLower()
        $dev = ($deviceIndex | Where-Object { $_.displayName.ToLower() -eq $manualTarget -and -not $usedDeviceIds.ContainsKey($_.id) }) | Select-Object -First 1
        if ($dev) { $matchLayer = "L0-MANUAL"; $matchDetail = "Manual map: $vmName → $($dev.displayName)" }
    }
    
    # --- L1: physicalIds contem Azure Resource ID ---
    if (-not $dev) {
        $dev = ($deviceIndex | Where-Object {
            -not $usedDeviceIds.ContainsKey($_.id) -and
            $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower() -like "*$vmResourceId*" })
        }) | Select-Object -First 1
        if ($dev) { $matchLayer = "L1-PHYSICAL"; $matchDetail = "physicalIds contem resourceId" }
    }
    
    # --- L2: Nome exacto (case-insensitive) ---
    if (-not $dev) {
        $dev = ($deviceIndex | Where-Object { 
            -not $usedDeviceIds.ContainsKey($_.id) -and
            $_.displayName -and $_.displayName.ToLower() -eq $vmName.ToLower() 
        }) | Select-Object -First 1
        if ($dev) { $matchLayer = "L2-EXACT"; $matchDetail = "Nome exacto: $vmName == $($dev.displayName)" }
    }
    
    # --- L3: Nome normalizado (sem dominio, sem prefixo) ---
    if (-not $dev) {
        $dev = ($deviceIndex | Where-Object { 
            -not $usedDeviceIds.ContainsKey($_.id) -and
            $_.normalized -eq $vmNorm -and $vmNorm.Length -ge 3
        }) | Select-Object -First 1
        if ($dev) { $matchLayer = "L3-NORMALIZED"; $matchDetail = "Normalizado: '$vmNorm' == '$($dev.normalized)' (raw: $($dev.displayName))" }
    }
    
    # --- L4: NetBIOS truncado (primeiros 15 chars) ---
    if (-not $dev) {
        if ($vmNetBIOS.Length -ge 3) {
            $dev = ($deviceIndex | Where-Object { 
                -not $usedDeviceIds.ContainsKey($_.id) -and
                $_.netbios -eq $vmNetBIOS -and $_.netbios.Length -ge 3
            }) | Select-Object -First 1
            if ($dev) { $matchLayer = "L4-NETBIOS"; $matchDetail = "NetBIOS 15ch: '$vmNetBIOS' == '$($dev.netbios)' (raw: $($dev.displayName))" }
        }
    }
    
    # --- L5: Fuzzy — contains / startsWith / endsWith ---
    if (-not $dev) {
        # 5a: Device displayName contem VM name inteiro (ex: "vm-srv-01.contoso.com" contem "vm-srv-01")
        $candidates = @($deviceIndex | Where-Object { 
            -not $usedDeviceIds.ContainsKey($_.id) -and
            $_.normalized -and $vmNorm.Length -ge 4 -and $_.normalized.Contains($vmNorm) 
        })
        
        # 5b: VM name contem device name inteiro (ex: "vm-srv-01-prod" contem "vm-srv-01")
        if ($candidates.Count -eq 0) {
            $candidates = @($deviceIndex | Where-Object { 
                -not $usedDeviceIds.ContainsKey($_.id) -and
                $_.normalized -and $_.normalized.Length -ge 4 -and $vmNorm.Contains($_.normalized) 
            })
        }
        
        # 5c: StartsWith match (nomes que comecam igual — muito comum em Azure VMs)
        if ($candidates.Count -eq 0) {
            $prefix = $vmNorm
            if ($prefix.Length -gt 6) { $prefix = $prefix.Substring(0, [Math]::Min(10, $prefix.Length)) }
            $candidates = @($deviceIndex | Where-Object { 
                -not $usedDeviceIds.ContainsKey($_.id) -and
                $_.normalized -and $_.normalized.StartsWith($prefix) -and $prefix.Length -ge 5
            })
        }
        
        # Se temos exactamente 1 candidato, é match. Se >1, pegar o mais similar
        if ($candidates.Count -eq 1) {
            $dev = $candidates[0]
            $matchLayer = "L5-FUZZY"
            $matchDetail = "Fuzzy: '$vmNorm' ~ '$($dev.normalized)' (raw: $($dev.displayName))"
        } elseif ($candidates.Count -gt 1) {
            # Desempatar por similaridade
            $best = $null; $bestScore = 0
            foreach ($c in $candidates) {
                $score = Get-SimilarityScore $vmNorm $c.normalized
                if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
            }
            if ($best -and $bestScore -ge 0.6) {
                $dev = $best
                $matchLayer = "L5-FUZZY"
                $matchDetail = "Fuzzy best ($bestScore): '$vmNorm' ~ '$($dev.normalized)' (raw: $($dev.displayName), $($candidates.Count) candidates)"
            }
        }
    }
    
    # --- L6: Azure vmId == Entra deviceId ---
    if (-not $dev -and $vmVmId.Length -gt 10) {
        $dev = ($deviceIndex | Where-Object { 
            -not $usedDeviceIds.ContainsKey($_.id) -and
            $_.deviceId -and $_.deviceId.ToLower() -eq $vmVmId 
        }) | Select-Object -First 1
        if ($dev) { $matchLayer = "L6-VMID"; $matchDetail = "vmId == deviceId: $vmVmId" }
    }
    
    # --- Resultado ---
    if ($dev) {
        $usedDeviceIds[$dev.id] = $true
        $matched += @{
            vm         = $vm
            device     = $dev
            layer      = $matchLayer
            detail     = $matchDetail
        }
        $color = switch -Wildcard ($matchLayer) {
            "L0*" { "Magenta" }
            "L1*" { "Green" }
            "L2*" { "Green" }
            "L3*" { "Cyan" }
            "L4*" { "Yellow" }
            "L5*" { "Yellow" }
            "L6*" { "DarkCyan" }
            default { "White" }
        }
        Write-Host "  [MATCH] $vmName" -ForegroundColor $color -NoNewline
        Write-Host " → $($dev.displayName)" -ForegroundColor White -NoNewline
        Write-Host " ($matchLayer)" -ForegroundColor DarkGray
        Write-Host "          $matchDetail" -ForegroundColor DarkGray
    } else {
        $unmatched += $vm
        
        # Mostrar candidatos mais proximos para diagnostico
        Write-Host "  [MISS]  $vmName" -ForegroundColor Red -NoNewline
        Write-Host " → SEM MATCH EM 6 CAMADAS" -ForegroundColor Red
        Write-Host "          Norm: '$vmNorm' | NetBIOS: '$vmNetBIOS'" -ForegroundColor DarkGray
        
        # Top 3 devices mais similares (para ajudar diagnostico manual)
        $topSimilar = @()
        foreach ($d in $deviceIndex) {
            $score = Get-SimilarityScore $vmNorm $d.normalized
            if ($score -gt 0.3) {
                $topSimilar += @{ device = $d; score = $score }
            }
        }
        $topSimilar = $topSimilar | Sort-Object { $_.score } -Descending | Select-Object -First 3
        if ($topSimilar.Count -gt 0) {
            Write-Host "          Candidatos mais proximos:" -ForegroundColor DarkYellow
            foreach ($ts in $topSimilar) {
                Write-Host "            $($ts.score) — $($ts.device.displayName) (norm: $($ts.device.normalized))" -ForegroundColor DarkGray
            }
        }
    }
}

# ============================================================
# SUMARIO DE MATCHING
# ============================================================
Write-Host "`n--- SUMARIO MATCHING ---`n" -ForegroundColor Cyan

$layerStats = @{}
foreach ($m in $matched) {
    $layer = $m.layer
    if (-not $layerStats.ContainsKey($layer)) { $layerStats[$layer] = 0 }
    $layerStats[$layer]++
}

Write-Host "  Total VMs:      $($vmDetails.Count)" -ForegroundColor White
Write-Host "  Matched:        $($matched.Count)" -ForegroundColor Green
Write-Host "  Unmatched:      $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Red'}else{'Green'})
Write-Host ""
Write-Host "  Detalhes por camada:" -ForegroundColor Gray
foreach ($layer in ($layerStats.Keys | Sort-Object)) {
    Write-Host "    $layer : $($layerStats[$layer])" -ForegroundColor DarkGray
}

if ($unmatched.Count -gt 0) {
    Write-Host "`n  VMs SEM MATCH:" -ForegroundColor Red
    foreach ($u in $unmatched) {
        Write-Host "    $($u.name) ($($u.os)) — $($u.power)" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  DICA: Adicione estas VMs ao `$manualMap no topo do script" -ForegroundColor Yellow
    Write-Host "  Exemplo: `$manualMap[`"$($unmatched[0].name)`"] = `"entra-device-name`"" -ForegroundColor DarkYellow
}

# ============================================================
# FASE 4: INSTALAR EXTENSAO AAD NAS VMs SEM DEVICE
# ============================================================
Write-Host "`n--- FASE 4: VERIFICAR/INSTALAR EXTENSAO AAD ---`n" -ForegroundColor Cyan

# VMs sem match podem precisar da extensao AAD para se registar no Entra ID
$needsExtension = @()
foreach ($vm in $unmatched) {
    # Verificar se a extensao ja esta instalada
    $extName = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
    $extInstalled = az vm extension show --resource-group $vm.rg --vm-name $vm.name --name $extName --query "provisioningState" -o tsv 2>$null
    
    if ($extInstalled -eq "Succeeded") {
        Write-Host "  [SKIP] $($vm.name) — extensao $extName ja instalada (device pode estar a propagar)" -ForegroundColor Gray
    } elseif ($vm.power -match "deallocated|stopped") {
        Write-Host "  [SKIP] $($vm.name) — VM desligada ($($vm.power)) — nao e possivel instalar" -ForegroundColor Yellow
    } else {
        $needsExtension += $vm
        Write-Host "  [NEED] $($vm.name) — extensao $extName nao encontrada" -ForegroundColor Yellow
    }
}

if ($needsExtension.Count -gt 0) {
    Write-Host "`n  Instalar extensao AAD em $($needsExtension.Count) VMs? [S/N]: " -NoNewline -ForegroundColor Cyan
    $installChoice = Read-Host
    
    if ($installChoice -match '^[Ss]') {
        # PARALELO — todas as extensoes ao mesmo tempo via Start-Job
        $jobs = @()
        foreach ($vm in $needsExtension) {
            $extType = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
            Write-Host "  [$($vm.os)] $($vm.name) → Queued $extType" -ForegroundColor Yellow
            $jobs += Start-Job -ScriptBlock {
                param($rg,$name,$ext,$subId)
                az account set --subscription $subId 2>$null
                az vm extension set --resource-group $rg --vm-name $name --name $ext --publisher "Microsoft.Azure.ActiveDirectory" --output none 2>$null
                @{ name=$name; ok=($LASTEXITCODE -eq 0) }
            } -ArgumentList $vm.rg, $vm.name, $extType, $sub
        }
        Write-Host "  Aguardando $($jobs.Count) instalacoes em paralelo..." -ForegroundColor Cyan
        $jobs | Wait-Job -Timeout 300 | Out-Null
        foreach ($j in $jobs) {
            $res = Receive-Job -Job $j
            if ($j.State -eq 'Completed' -and $res.ok) { Write-Host "  [OK] $($res.name)" -ForegroundColor Green }
            else { Write-Host "  [FAIL] $($res.name)" -ForegroundColor Red }
        }
        $jobs | Remove-Job -Force
        
        Write-Host "`n  Aguardando propagacao Entra ID (30s)..." -ForegroundColor Gray
        Start-Sleep -Seconds 30
        
        # Re-fetch devices e tentar match novamente
        Write-Host "  Re-carregando devices..." -ForegroundColor Cyan
        $deviceList2 = Get-AllEntraDevices
        $deviceIndex2 = @()
        foreach ($d in $deviceList2) {
            $deviceIndex2 += @{
                raw         = $d; displayName = $d.displayName
                normalized  = Normalize-Deep $d.displayName; netbios = Get-NetBIOSName $d.displayName
                id          = $d.id; deviceId = $d.deviceId; os = $d.operatingSystem
                trustType   = $d.trustType; lastSignIn = $d.approximateLastSignInDateTime
                enabled     = $d.accountEnabled; physicalIds = $d.physicalIds
            }
        }
        
        Write-Host "  Devices apos propagacao: $($deviceIndex2.Count) (antes: $($deviceIndex.Count))" -ForegroundColor White
        
        # Tentar match das VMs que estavam unmatched
        $newMatches = @()
        $stillUnmatched = @()
        foreach ($vm in $unmatched) {
            $vmNorm = Normalize-Deep $vm.name
            $vmResourceId = $vm.id.ToLower()
            $vmVmId = if ($vm.vmId) { $vm.vmId.ToLower() } else { "" }
            
            $dev = $null
            $matchLayer = ""
            
            # Repetir L1-L6 com devices atualizados
            # L1
            $dev = ($deviceIndex2 | Where-Object {
                -not $usedDeviceIds.ContainsKey($_.id) -and
                $_.physicalIds -and ($_.physicalIds | Where-Object { $_.ToLower() -like "*$vmResourceId*" })
            }) | Select-Object -First 1
            if ($dev) { $matchLayer = "L1-PHYSICAL(retry)" }
            
            # L2
            if (-not $dev) {
                $dev = ($deviceIndex2 | Where-Object { 
                    -not $usedDeviceIds.ContainsKey($_.id) -and
                    $_.displayName -and $_.displayName.ToLower() -eq $vm.name.ToLower() 
                }) | Select-Object -First 1
                if ($dev) { $matchLayer = "L2-EXACT(retry)" }
            }
            
            # L3
            if (-not $dev) {
                $dev = ($deviceIndex2 | Where-Object { 
                    -not $usedDeviceIds.ContainsKey($_.id) -and
                    $_.normalized -eq $vmNorm -and $vmNorm.Length -ge 3
                }) | Select-Object -First 1
                if ($dev) { $matchLayer = "L3-NORM(retry)" }
            }
            
            # L4
            if (-not $dev) {
                $vmNetBIOS = Get-NetBIOSName $vm.name
                $dev = ($deviceIndex2 | Where-Object { 
                    -not $usedDeviceIds.ContainsKey($_.id) -and
                    $_.netbios -eq $vmNetBIOS -and $_.netbios.Length -ge 3
                }) | Select-Object -First 1
                if ($dev) { $matchLayer = "L4-NETBIOS(retry)" }
            }
            
            # L5 fuzzy
            if (-not $dev) {
                $candidates = @($deviceIndex2 | Where-Object { 
                    -not $usedDeviceIds.ContainsKey($_.id) -and
                    $_.normalized -and $vmNorm.Length -ge 4 -and (
                        $_.normalized.Contains($vmNorm) -or 
                        $vmNorm.Contains($_.normalized) -or
                        ($_.normalized.Length -ge 5 -and $vmNorm.StartsWith($_.normalized.Substring(0, [Math]::Min(5, $_.normalized.Length))))
                    )
                })
                if ($candidates.Count -eq 1) { 
                    $dev = $candidates[0]; $matchLayer = "L5-FUZZY(retry)" 
                } elseif ($candidates.Count -gt 1) {
                    $best = $null; $bestScore = 0
                    foreach ($c in $candidates) {
                        $score = Get-SimilarityScore $vmNorm $c.normalized
                        if ($score -gt $bestScore) { $bestScore = $score; $best = $c }
                    }
                    if ($best -and $bestScore -ge 0.5) { $dev = $best; $matchLayer = "L5-FUZZY(retry,$bestScore)" }
                }
            }
            
            # L6
            if (-not $dev -and $vmVmId.Length -gt 10) {
                $dev = ($deviceIndex2 | Where-Object { 
                    -not $usedDeviceIds.ContainsKey($_.id) -and
                    $_.deviceId -and $_.deviceId.ToLower() -eq $vmVmId 
                }) | Select-Object -First 1
                if ($dev) { $matchLayer = "L6-VMID(retry)" }
            }
            
            if ($dev) {
                $usedDeviceIds[$dev.id] = $true
                $newMatches += @{ vm = $vm; device = $dev; layer = $matchLayer; detail = "Retry apos extensao AAD" }
                Write-Host "  [NOVO] $($vm.name) → $($dev.displayName) ($matchLayer)" -ForegroundColor Green
            } else {
                $stillUnmatched += $vm
            }
        }
        
        # Adicionar novos matches ao array principal
        $matched += $newMatches
        $unmatched = $stillUnmatched
        
        Write-Host "`n  Novos matches: $($newMatches.Count) | Ainda pendentes: $($stillUnmatched.Count)" -ForegroundColor White
    }
} else {
    Write-Host "  Todas as VMs unmatched ja tem extensao ou estao desligadas." -ForegroundColor Gray
}

# ============================================================
# FASE 5: ADICIONAR DEVICES AOS GRUPOS
# ============================================================
Write-Host "`n--- FASE 5: ADICIONAR AOS GRUPOS ---`n" -ForegroundColor Cyan

# Pre-carregar membros existentes de todos os grupos (evitar chamadas desnecessarias)
$existingMembers = @{}
foreach ($gDef in @(
    @{id=$grpMain;    tag="Main"},
    @{id=$grpStale7;  tag="Stale-7d"},
    @{id=$grpStale30; tag="Stale-30d"},
    @{id=$grpEph;     tag="Ephemeral"}
)) {
    $membersRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($gDef.id)/members?`$select=id,displayName" -o json 2>$null | ConvertFrom-Json
    $existingMembers[$gDef.id] = @()
    if ($membersRaw -and $membersRaw.value) { $existingMembers[$gDef.id] = $membersRaw.value }
    Write-Host "  $($gDef.tag): $($existingMembers[$gDef.id].Count) membros actuais" -ForegroundColor DarkGray
}

$addedMain = 0; $addedStale7 = 0; $addedStale30 = 0; $addedEph = 0; $skipped = 0

foreach ($m in $matched) {
    $devId = $m.device.id
    $devName = $m.device.displayName
    $lastSign = $m.device.lastSignIn
    $vmPower = $m.vm.power
    
    # Determinar grupo alvo baseado em lastSignIn e power state
    $targetGroup = $grpMain
    $targetLabel = "Main"
    
    if ($lastSign) {
        try {
            $daysAgo = ((Get-Date) - [DateTime]::Parse($lastSign)).Days
            if ($daysAgo -gt 30) { $targetGroup = $grpStale30; $targetLabel = "Stale-30d" }
            elseif ($daysAgo -gt 7) { $targetGroup = $grpStale7; $targetLabel = "Stale-7d" }
        } catch { }
    } else {
        # Sem lastSignIn — basear no power state
        if ($vmPower -match "deallocated|stopped") {
            $targetGroup = $grpStale7; $targetLabel = "Stale-7d (desligada)"
        } else {
            $targetGroup = $grpMain; $targetLabel = "Main (sem sign-in mas ligada)"
        }
    }
    
    # Verificar se ja e membro (usando cache pre-carregado)
    $alreadyMember = $existingMembers[$targetGroup] | Where-Object { $_.id -eq $devId }
    if ($alreadyMember) {
        Write-Host "  [=] $devName → ja no $targetLabel" -ForegroundColor Gray
        $skipped++
        continue
    }
    
    # Tambem verificar nos OUTROS grupos (remover de grupo antigo se necessario)
    $inOtherGroup = $false
    foreach ($otherId in @($grpMain, $grpStale7, $grpStale30, $grpEph)) {
        if ($otherId -eq $targetGroup) { continue }
        $otherMember = $existingMembers[$otherId] | Where-Object { $_.id -eq $devId }
        if ($otherMember) {
            Write-Host "  [~] $devName → movendo de outro grupo para $targetLabel" -ForegroundColor Yellow
            # Remover do grupo antigo
            az rest --method DELETE --uri "https://graph.microsoft.com/v1.0/groups/$otherId/members/$devId/`$ref" --output none 2>&1 | Out-Null
            $inOtherGroup = $true
            break
        }
    }
    
    # Adicionar ao grupo correto
    $addBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" } | ConvertTo-Json
    $bodyFile = Join-Path $tempPath "add-member-fix.json"
    $addBody | Out-File $bodyFile -Encoding UTF8 -Force -NoNewline
    
    az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members/`$ref" --headers "Content-Type=application/json" --body "@$bodyFile" --output none 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [+] $devName → $targetLabel" -ForegroundColor Green
        switch ($targetGroup) {
            $grpMain    { $addedMain++ }
            $grpStale7  { $addedStale7++ }
            $grpStale30 { $addedStale30++ }
            $grpEph     { $addedEph++ }
        }
    } else {
        Write-Host "  [!] $devName → erro ao adicionar (pode ja estar)" -ForegroundColor DarkYellow
    }
}

# ============================================================
# FASE 6: VERIFICACAO FINAL
# ============================================================
Write-Host "`n--- FASE 6: VERIFICACAO FINAL ---`n" -ForegroundColor Cyan

$totalInGroups = 0
foreach ($gDef in @(
    @{id=$grpMain;    tag="Main"},
    @{id=$grpStale7;  tag="Stale-7d"},
    @{id=$grpStale30; tag="Stale-30d"},
    @{id=$grpEph;     tag="Ephemeral"}
)) {
    $membersRaw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($gDef.id)/members?`$select=displayName" -o json 2>$null | ConvertFrom-Json
    $members = @()
    if ($membersRaw -and $membersRaw.value) { $members = $membersRaw.value }
    $totalInGroups += $members.Count
    
    $color = if ($members.Count -gt 0) { "Green" } else { "Yellow" }
    Write-Host "  $($gDef.tag): $($members.Count) devices" -ForegroundColor $color
    foreach ($member in $members) {
        Write-Host "    - $($member.displayName)" -ForegroundColor DarkGray
    }
}

# ============================================================
# RELATORIO FINAL
# ============================================================
Write-Host "`n================================================================" -ForegroundColor Magenta
Write-Host "  FIX v2 — RELATORIO FINAL" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host ""
Write-Host "  INVENTARIO:" -ForegroundColor Cyan
Write-Host "    Azure VMs:          $($vmDetails.Count)" -ForegroundColor White
Write-Host "    Entra ID Devices:   $($deviceList.Count)" -ForegroundColor White
Write-Host ""
Write-Host "  MATCHING:" -ForegroundColor Cyan
Write-Host "    Matched total:      $($matched.Count)" -ForegroundColor Green
Write-Host "    Unmatched:          $($unmatched.Count)" -ForegroundColor $(if($unmatched.Count -gt 0){'Red'}else{'Green'})
Write-Host ""
Write-Host "  Por camada:" -ForegroundColor Gray
$allLayers = @{}
foreach ($m in $matched) { 
    $l = $m.layer -replace '\(retry.*\)', '(retry)'
    if (-not $allLayers.ContainsKey($l)) { $allLayers[$l] = 0 }
    $allLayers[$l]++
}
foreach ($l in ($allLayers.Keys | Sort-Object)) { Write-Host "    $l : $($allLayers[$l])" -ForegroundColor DarkGray }
Write-Host ""
Write-Host "  GRUPOS:" -ForegroundColor Cyan
Write-Host "    Adicionados Main:    $addedMain" -ForegroundColor White
Write-Host "    Adicionados Stale7:  $addedStale7" -ForegroundColor White
Write-Host "    Adicionados Stale30: $addedStale30" -ForegroundColor White
Write-Host "    Adicionados Ephemeral: $addedEph" -ForegroundColor White
Write-Host "    Ja no grupo:         $skipped" -ForegroundColor Gray
Write-Host "    Total em grupos:     $totalInGroups" -ForegroundColor White
Write-Host ""

if ($unmatched.Count -gt 0) {
    Write-Host "  ⚠ ACAO NECESSARIA PARA $($unmatched.Count) VMs:" -ForegroundColor Yellow
    Write-Host "" 
    Write-Host "  Opcao A — Adicionar ao `$manualMap e reexecutar:" -ForegroundColor Yellow
    Write-Host ""
    foreach ($u in $unmatched) {
        Write-Host "    `$manualMap[`"$($u.name)`"] = `"???`"    # Verificar em Entra ID > Devices" -ForegroundColor DarkYellow
    }
    Write-Host ""
    Write-Host "  Opcao B — Verificar manualmente:" -ForegroundColor Yellow
    Write-Host "    1. Portal → Entra ID → Devices → procurar por nome" -ForegroundColor Gray
    Write-Host "    2. Verificar se a VM esta ligada (extensao AAD requer VM running)" -ForegroundColor Gray
    Write-Host "    3. Re-executar este script apos 5-10 min (propagacao)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Opcao C — Verificar via CLI:" -ForegroundColor Yellow
    foreach ($u in $unmatched) {
        Write-Host "    az rest --method GET --uri `"https://graph.microsoft.com/v1.0/devices?`$filter=startswith(displayName,'$(($u.name).Substring(0,[Math]::Min(8,$u.name.Length)))')&`$select=displayName,id`" -o table" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Magenta
Write-Host "  VMs: $($vmDetails.Count) | Matched: $($matched.Count) | Em Grupos: $totalInGroups" -ForegroundColor White
Write-Host "================================================================`n" -ForegroundColor Magenta

# Export matching log para diagnostico
$logFile = Join-Path $tempPath "mde-fix-v2-matching-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$eqLine = "=" * 60
$logContent = @("FIX v2 — MATCHING LOG — $(Get-Date)", $eqLine, "")
foreach ($m in $matched) {
    $logContent += "$($m.layer) | $($m.vm.name) → $($m.device.displayName) | $($m.detail)"
}
$logContent += ""
$logContent += "UNMATCHED:"
foreach ($u in $unmatched) {
    $logContent += "MISS | $($u.name) ($($u.os)) — $($u.power)"
}
$logContent | Out-File $logFile -Encoding UTF8 -Force
Write-Host "  Log exportado: $logFile" -ForegroundColor Gray
