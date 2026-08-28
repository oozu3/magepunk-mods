#requires -Version 5.1
<#
  Sincronizador de mods - Magepunk SMP
  Baixa, atualiza e remove APENAS os mods do pack.
  Mods pessoais do jogador (shaders, minimapa, etc) nao sao tocados.
#>
param([string]$PastaMods)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ===================== CONFIGURACAO =====================
# (estas 2 linhas sao reescritas automaticamente por publicar.ps1)
$ManifestUrl = 'https://raw.githubusercontent.com/oozu3/magepunk-mods/main/manifest.json'
$PackName    = 'Magepunk SMP'
# ========================================================

$Raiz        = $PSScriptRoot
$ArquivoPath = Join-Path $Raiz 'pasta-mods.txt'

function Titulo($t) {
    Write-Host ''
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * $t.Length)) -ForegroundColor DarkCyan
}
function Ok($t)    { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Info($t)  { Write-Host "  [..]   $t" -ForegroundColor Gray }
function Aviso($t) { Write-Host "  [!]    $t" -ForegroundColor Yellow }
function Erro($t)  { Write-Host "  [X]    $t" -ForegroundColor Red }

function Get-ModKey([string]$nome) {
    $n = [IO.Path]::GetFileNameWithoutExtension($nome).ToLowerInvariant()
    $partes = $n -split '[-_+]'
    $manter = New-Object System.Collections.Generic.List[string]
    foreach ($p in $partes) {
        if ($p -match '^v?\d' -or $p -match '^mc\d') { break }
        if ($p -in @('neoforge','forge','fabric','neo','mc','all','universal','merged','shadow')) { continue }
        if ($p.Length -gt 0) { [void]$manter.Add($p) }
    }
    if ($manter.Count -eq 0) { return $n }
    return ($manter -join '-')
}

function Find-PastasMods {
    $cands = New-Object System.Collections.Generic.List[string]
    $roaming = $env:APPDATA
    $perfil  = $env:USERPROFILE
    $raizes = @(
        (Join-Path $roaming 'ModrinthApp\profiles'),
        (Join-Path $roaming 'com.modrinth.theseus\profiles'),
        (Join-Path $roaming 'PrismLauncher\instances'),
        (Join-Path $roaming '.minecraft\mods'),
        (Join-Path $perfil  'curseforge\minecraft\Instances'),
        (Join-Path $roaming 'gdlauncher_next\instances'),
        (Join-Path $roaming 'ATLauncher\instances')
    )
    foreach ($r in $raizes) {
        if (-not (Test-Path $r)) { continue }
        if ((Split-Path $r -Leaf) -eq 'mods') { [void]$cands.Add($r); continue }
        foreach ($d in Get-ChildItem $r -Directory -ErrorAction SilentlyContinue) {
            foreach ($sub in @('mods', '.minecraft\mods', 'minecraft\mods')) {
                $p = Join-Path $d.FullName $sub
                if (Test-Path $p) { [void]$cands.Add($p) }
            }
        }
    }
    return ($cands | Select-Object -Unique)
}

function Resolve-PastaMods {
    if ($PastaMods -and (Test-Path $PastaMods)) { return (Resolve-Path $PastaMods).Path }
    if (Test-Path $ArquivoPath) {
        $salvo = (Get-Content $ArquivoPath -Raw -Encoding UTF8).Trim()
        if ($salvo -and (Test-Path $salvo)) { return $salvo }
    }
    $achados = @(Find-PastasMods)
    Titulo 'Escolha a pasta de mods do seu Minecraft'
    if ($achados.Count -eq 0) {
        Aviso 'Nenhuma instalacao encontrada automaticamente.'
    } else {
        for ($i = 0; $i -lt $achados.Count; $i++) {
            $qtd = @(Get-ChildItem $achados[$i] -Filter *.jar -ErrorAction SilentlyContinue).Count
            Write-Host ("   {0}) {1}  ({2} mods)" -f ($i + 1), $achados[$i], $qtd)
        }
    }
    Write-Host ("   {0}) Digitar o caminho manualmente" -f ($achados.Count + 1))
    Write-Host ''
    $esc = Read-Host '  Numero'
    $n = 0
    if (-not [int]::TryParse($esc, [ref]$n)) { throw 'Opcao invalida.' }
    if ($n -ge 1 -and $n -le $achados.Count) {
        $escolhida = $achados[$n - 1]
    } elseif ($n -eq ($achados.Count + 1)) {
        $escolhida = (Read-Host '  Caminho completo da pasta mods').Trim([char]34, [char]32)
    } else {
        throw 'Opcao invalida.'
    }
    if (-not (Test-Path $escolhida)) { New-Item -ItemType Directory -Path $escolhida -Force | Out-Null }
    Set-Content -Path $ArquivoPath -Value $escolhida -Encoding UTF8
    Ok 'Pasta salva. Nas proximas vezes o script ja vai direto.'
    return $escolhida
}

function Get-Sha1($caminho) {
    return (Get-FileHash -Path $caminho -Algorithm SHA1).Hash.ToLowerInvariant()
}

function Baixar($url, $destino) {
    $tmp = "$destino.parcial"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 600 -Headers @{ 'User-Agent' = 'MagepunkSync/1.0' }
    } catch {
        if (Test-Path $tmp) { Remove-Item $tmp -Force }
        throw
    }
    return $tmp
}

# ============================ INICIO ============================
Clear-Host
Write-Host ''
Write-Host "  ###  SINCRONIZADOR DE MODS - $PackName  ###" -ForegroundColor Magenta
Write-Host ''

$mods       = Resolve-PastaMods
$perfilDir  = Split-Path $mods -Parent
$quarentena = Join-Path $perfilDir 'mods-removidos-pelo-sync'
$estadoPath = Join-Path $mods '.magepunk-sync.json'

Info "Pasta de mods: $mods"

# ---- baixar manifesto ----
Titulo 'Buscando a lista de mods do servidor'
$sep = '?'
if ($ManifestUrl.Contains('?')) { $sep = '&' }
$urlBust = $ManifestUrl + $sep + 't=' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
try {
    $resp = Invoke-WebRequest -Uri $urlBust -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'MagepunkSync/1.0'; 'Cache-Control' = 'no-cache' }
    # decodifica sempre como UTF-8, nao importa o header que o servidor mandou
    $bruto = $null
    if ($resp.RawContentStream) {
        $ms = $resp.RawContentStream
        $ms.Position = 0
        $bytes = New-Object byte[] ($ms.Length)
        [void]$ms.Read($bytes, 0, $bytes.Length)
        $bruto = [Text.Encoding]::UTF8.GetString($bytes)
    } elseif ($resp.Content -is [byte[]]) {
        $bruto = [Text.Encoding]::UTF8.GetString($resp.Content)
    } else {
        $bruto = [string]$resp.Content
    }
    if ($bruto.Length -gt 0 -and $bruto[0] -eq [char]0xFEFF) { $bruto = $bruto.Substring(1) }
    $manifesto = $bruto.Trim() | ConvertFrom-Json
} catch {
    Erro "Nao consegui baixar a lista: $($_.Exception.Message)"
    Erro "URL: $ManifestUrl"
    Write-Host ''
    Read-Host '  Enter para sair'
    exit 1
}
$arquivos = @($manifesto.files)
Ok ("{0} mods no pack (lista gerada em {1})" -f $arquivos.Count, $manifesto.generated)

# ---- lista de exclusao ----
# O pack so tem duas listas:
#   files      -> mods obrigatorios
#   removeKeys -> lista de exclusao
# Qualquer mod fora dessas duas e pessoal do jogador e nao e tocado.
$removeKeys = @{}
if ($manifesto.removeKeys) { foreach ($k in @($manifesto.removeKeys)) { $removeKeys[$k] = $true } }

# ---- indexar pasta local ----
$locais = @{}
foreach ($f in Get-ChildItem $mods -Filter *.jar -ErrorAction SilentlyContinue) { $locais[$f.Name] = $f }

$nomesManifesto  = @{}
$chavesManifesto = @{}
foreach ($e in $arquivos) {
    $nomesManifesto[$e.name] = $e
    $chavesManifesto[(Get-ModKey $e.name)] = $true
}

# ---- planejar ----
Titulo 'Comparando com o que voce tem instalado'
$baixar = New-Object System.Collections.Generic.List[object]
$manter = 0
$i = 0
foreach ($e in $arquivos) {
    $i++
    Write-Host ("`r  verificando {0}/{1}   " -f $i, $arquivos.Count) -NoNewline -ForegroundColor DarkGray
    $lf = $locais[$e.name]
    if ($lf -and $lf.Length -eq $e.size -and (Get-Sha1 $lf.FullName) -eq $e.sha1) { $manter++; continue }
    [void]$baixar.Add($e)
}
Write-Host ("`r" + (' ' * 45) + "`r") -NoNewline

# Decide o que sai. So existem dois motivos para remover um arquivo:
#   1. e um mod obrigatorio, mas numa versao diferente da do pack
#   2. o nome dele esta na lista de exclusao
# Qualquer outra coisa e um mod pessoal do jogador. Nao se toca.
$remover = @()
foreach ($nome in $locais.Keys) {
    if ($nomesManifesto.ContainsKey($nome)) { continue }
    $chave = Get-ModKey $nome

    $motivo = $null
    if ($chavesManifesto.ContainsKey($chave)) { $motivo = 'versao diferente da do pack' }
    elseif ($removeKeys.ContainsKey($chave))  { $motivo = 'esta na lista de exclusao' }

    if ($motivo) { $remover += [pscustomobject]@{ nome = $nome; motivo = $motivo } }
}

$pessoais = $locais.Count - $manter - $remover.Count
Write-Host ("  ja atualizados : {0}" -f $manter)
$corB = 'Gray'; if ($baixar.Count -gt 0)  { $corB = 'Yellow' }
$corR = 'Gray'; if ($remover.Count -gt 0) { $corR = 'Yellow' }
Write-Host ("  a baixar       : {0}" -f $baixar.Count)  -ForegroundColor $corB
Write-Host ("  a remover      : {0}" -f $remover.Count) -ForegroundColor $corR
Write-Host ("  seus, intactos : {0}" -f $pessoais)      -ForegroundColor DarkGray

$estado = @{ managed = @($arquivos | ForEach-Object { $_.name }); updated = (Get-Date -Format o) }

if ($baixar.Count -eq 0 -and $remover.Count -eq 0) {
    Write-Host ''
    Ok 'Tudo certo! Seus mods ja estao iguais aos do servidor.'
    Set-Content -Path $estadoPath -Value ($estado | ConvertTo-Json -Compress) -Encoding UTF8
    Write-Host ''
    Read-Host '  Enter para fechar'
    exit 0
}

# ---- remover ----
if ($remover.Count -gt 0) {
    Titulo 'Removendo mods que nao fazem mais parte do pack'
    if (-not (Test-Path $quarentena)) { New-Item -ItemType Directory -Path $quarentena -Force | Out-Null }
    foreach ($r in $remover) {
        try {
            $dest = Join-Path $quarentena $r.nome
            if (Test-Path $dest) { Remove-Item $dest -Force }
            Move-Item -Path (Join-Path $mods $r.nome) -Destination $dest -Force
            Write-Host ("  - {0}" -f $r.nome) -NoNewline -ForegroundColor DarkYellow
            Write-Host ("   ({0})" -f $r.motivo) -ForegroundColor DarkGray
        } catch {
            Erro "nao consegui remover $($r.nome) ($($_.Exception.Message))"
        }
    }
    Info "Movidos para: $quarentena"
    Info 'Nada foi apagado de verdade - da pra recuperar de la se precisar.'
}

# ---- baixar ----
$falhas = New-Object System.Collections.Generic.List[string]
if ($baixar.Count -gt 0) {
    Titulo 'Baixando mods'
    $totalMB = [math]::Round((($baixar | Measure-Object -Property size -Sum).Sum) / 1MB, 1)
    Info "$totalMB MB no total"
    $n = 0
    foreach ($e in $baixar) {
        $n++
        $mb = [math]::Round($e.size / 1MB, 1)
        Write-Host ("  [{0}/{1}] {2} ({3} MB)" -f $n, $baixar.Count, $e.name, $mb) -NoNewline
        try {
            $tmp = Baixar $e.url (Join-Path $mods $e.name)
            $h = Get-Sha1 $tmp
            if ($h -ne $e.sha1) {
                Remove-Item $tmp -Force
                throw 'hash nao confere (download corrompido)'
            }
            $final = Join-Path $mods $e.name
            if (Test-Path $final) { Remove-Item $final -Force }
            Move-Item $tmp $final -Force
            Write-Host '  OK' -ForegroundColor Green
        } catch {
            Write-Host '  FALHOU' -ForegroundColor Red
            Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
            [void]$falhas.Add($e.name)
        }
    }
}

Set-Content -Path $estadoPath -Value ($estado | ConvertTo-Json -Compress) -Encoding UTF8

Titulo 'Resultado'
if ($falhas.Count -eq 0) {
    Ok 'Sincronizacao concluida. Pode abrir o Minecraft e entrar no servidor.'
} else {
    Erro ("{0} mod(s) falharam. Rode o script de novo:" -f $falhas.Count)
    foreach ($f in $falhas) { Write-Host "         - $f" -ForegroundColor DarkRed }
}
Write-Host ''
Read-Host '  Enter para fechar'







