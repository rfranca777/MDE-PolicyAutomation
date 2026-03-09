<#
.SYNOPSIS
    FIX: Registar VMs no Entra ID + Popular grupos
.DESCRIPTION
    1. Lista todas as VMs na subscription
    2. Verifica quais ja estao registadas como devices no Entra ID
    3. Instala extensao AAD nas VMs nao registadas (regista automaticamente)
    4. Adiciona devices aos grupos
#>

$ErrorActionPreference = "Continue"

$sub       = "121129d5-3986-447b-8a52-678b70ec6f76"
$grpMain   = "ed0829b1-26ba-4c2a-b33f-3a618c3e3255"
$grpStale7 = "4a221a76-c2a4-4702-ab14-ea048d3f526b"
$grpStale30= "2de9c8f7-0bb1-4778-8d9c-4cf507527cf2"

az account set --subscription $sub 2>$null

Write-Host "`n====================================================" -ForegroundColor Magenta
Write-Host "  FIX: REGISTAR VMs NO ENTRA ID + POPULAR GRUPOS" -ForegroundColor White
Write-Host "====================================================`n" -ForegroundColor Magenta

# FASE 1: Listar VMs
Write-Host "--- FASE 1: VMs NA SUBSCRIPTION ---`n" -ForegroundColor Cyan
$vmsRaw = az vm list --subscription $sub --query "[].{name:name, rg:resourceGroup, os:storageProfile.osDisk.osType, id:id, vmId:vmId}" -o json 2>$null
$vms = $vmsRaw | ConvertFrom-Json
Write-Host "  Total VMs: $($vms.Count)" -ForegroundColor White
foreach ($v in $vms) { Write-Host "    $($v.name) ($($v.os)) - $($v.rg)" -ForegroundColor Gray }

# FASE 2: Verificar devices no Entra ID
Write-Host "`n--- FASE 2: DEVICES NO ENTRA ID ---`n" -ForegroundColor Cyan
$allDevices = az rest --method GET --uri "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,operatingSystem,approximateLastSignInDateTime" -o json 2>$null | ConvertFrom-Json
$deviceList = $allDevices.value
Write-Host "  Total devices Entra ID: $($deviceList.Count)" -ForegroundColor White

$matched = @()
$unmatched = @()

foreach ($vm in $vms) {
    $vmName = $vm.name
    # Procurar device por nome (case-insensitive, partial match)
    $found = $deviceList | Where-Object { $_.displayName -eq $vmName -or $_.displayName -like "$vmName.*" -or $_.displayName -like "*\\$vmName" }
    if ($found) {
        $dev = $found | Select-Object -First 1
        Write-Host "  [MATCH] $vmName -> Device: $($dev.displayName) (ID: $($dev.id))" -ForegroundColor Green
        $matched += @{ vm = $vm; device = $dev }
    } else {
        Write-Host "  [MISS]  $vmName -> Nao registado no Entra ID" -ForegroundColor Yellow
        $unmatched += $vm
    }
}

Write-Host "`n  Matched: $($matched.Count) | Unmatched: $($unmatched.Count)" -ForegroundColor White

# FASE 3: Instalar extensao AAD nas VMs nao registadas
if ($unmatched.Count -gt 0) {
    Write-Host "`n--- FASE 3: INSTALAR EXTENSAO AAD ---`n" -ForegroundColor Cyan
    Write-Host "  Instalando extensao para registar VMs no Entra ID..." -ForegroundColor Yellow
    
    foreach ($vm in $unmatched) {
        $extName = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
        $extPublisher = if ($vm.os -eq "Windows") { "Microsoft.Azure.ActiveDirectory" } else { "Microsoft.Azure.ActiveDirectory" }
        $extType = if ($vm.os -eq "Windows") { "AADLoginForWindows" } else { "AADSSHLoginForLinux" }
        
        $vmRg = $vm.rg
        $vmNm = $vm.name
        Write-Host "  [$($vm.os)] $vmNm -> Instalando $extName..." -ForegroundColor Yellow
        
        az vm extension set --resource-group $vmRg --vm-name $vmNm --name $extType --publisher $extPublisher --output none 2>$null
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    [OK] Extensao instalada" -ForegroundColor Green
        } else {
            Write-Host "    [WARN] Pode ja existir ou VM desligada" -ForegroundColor Gray
        }
    }
    
    Write-Host "`n  Aguardando propagacao no Entra ID (60s)..." -ForegroundColor Gray
    Start-Sleep -Seconds 60
    
    # Re-verificar devices
    Write-Host "  Re-verificando devices..." -ForegroundColor Cyan
    $allDevices2 = az rest --method GET --uri "https://graph.microsoft.com/v1.0/devices?`$top=999&`$select=displayName,id,deviceId,operatingSystem,approximateLastSignInDateTime" -o json 2>$null | ConvertFrom-Json
    $deviceList = $allDevices2.value
    
    foreach ($vm in $unmatched) {
        $found = $deviceList | Where-Object { $_.displayName -eq $vm.name -or $_.displayName -like "$($vm.name).*" }
        if ($found) {
            $dev = $found | Select-Object -First 1
            Write-Host "  [NOVO] $($vm.name) -> Device: $($dev.displayName) (ID: $($dev.id))" -ForegroundColor Green
            $matched += @{ vm = $vm; device = $dev }
        } else {
            Write-Host "  [PEND] $($vm.name) -> Ainda propagando (pode levar 5-10 min)" -ForegroundColor Yellow
        }
    }
}

# FASE 4: Adicionar devices aos grupos
Write-Host "`n--- FASE 4: ADICIONAR AOS GRUPOS ---`n" -ForegroundColor Cyan

$addedMain = 0; $addedStale = 0

foreach ($m in $matched) {
    $devId = $m.device.id
    $devName = $m.device.displayName
    $lastSign = $m.device.approximateLastSignInDateTime
    
    # Determinar grupo (main se activo <7d, senao stale)
    $targetGroup = $grpMain
    $targetLabel = "Main"
    
    if ($lastSign) {
        $lastDate = [DateTime]::Parse($lastSign)
        $daysAgo = ((Get-Date) - $lastDate).Days
        if ($daysAgo -gt 30) { $targetGroup = $grpStale30; $targetLabel = "Stale-30d" }
        elseif ($daysAgo -gt 7) { $targetGroup = $grpStale7; $targetLabel = "Stale-7d" }
    } else {
        $targetGroup = $grpStale7; $targetLabel = "Stale-7d (sem sign-in)"
    }
    
    # Verificar se ja e membro
    $members = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members" --query "value[].id" -o json 2>$null | ConvertFrom-Json
    if ($members -contains $devId) {
        Write-Host "  [SKIP] $devName ja no grupo $targetLabel" -ForegroundColor Gray
        continue
    }
    
    # Adicionar ao grupo
    $addBody = @{ "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$devId" } | ConvertTo-Json
    if (-not (Test-Path "C:\temp")) { New-Item -ItemType Directory -Path "C:\temp" -Force | Out-Null }
    $addBody | Out-File "C:\temp\add-member.json" -Encoding UTF8 -Force -NoNewline
    
    az rest --method POST --uri "https://graph.microsoft.com/v1.0/groups/$targetGroup/members/`$ref" --headers "Content-Type=application/json" --body "@C:\temp\add-member.json" --output none 2>&1 | Out-Null
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] $devName -> $targetLabel" -ForegroundColor Green
        $addedMain++
    } else {
        Write-Host "  [WARN] $devName -> pode ja estar no grupo" -ForegroundColor Gray
    }
}

# FASE 5: Resultado
Write-Host "`n--- RESULTADO ---`n" -ForegroundColor Cyan

foreach ($g in @(
    @{id=$grpMain; n="Main"},
    @{id=$grpStale7; n="Stale-7d"},
    @{id=$grpStale30; n="Stale-30d"}
)) {
    $raw = az rest --method GET --uri "https://graph.microsoft.com/v1.0/groups/$($g.id)/members" --query "value[].displayName" -o json 2>$null
    $list = @(); if ($raw) { try { $list = $raw | ConvertFrom-Json } catch {} }
    Write-Host "  $($g.n): $($list.Count) devices" -ForegroundColor $(if($list.Count -gt 0){'Green'}else{'Yellow'})
    foreach ($m in $list) { Write-Host "    - $m" -ForegroundColor DarkGray }
}

Write-Host "`n====================================================" -ForegroundColor Magenta
Write-Host "  VMs: $($vms.Count) | Devices Entra: $($matched.Count) | Adicionados: $addedMain" -ForegroundColor White
if ($unmatched.Count -gt 0 -and $matched.Count -lt $vms.Count) {
    Write-Host "  [ACAO] $($unmatched.Count) VMs ainda sem device Entra ID" -ForegroundColor Yellow
    Write-Host "  Extensao AAD foi instalada. Aguarde 5-10 min e reexecute." -ForegroundColor Yellow
}
Write-Host "====================================================`n" -ForegroundColor Magenta
