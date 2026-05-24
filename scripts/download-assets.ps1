$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root = Resolve-RepoRoot
$gameDir = Get-ConfigPath "GameDir"
$version = $ProjectConfig.MinecraftVersion

try {
    $response = Invoke-WebRequest -Uri 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json'
    if (-not $response -or -not $response.Content) {
        throw "Empty response from version manifest API"
    }
    $manifest = $response | ConvertFrom-Json
    if (-not $manifest) {
        throw "Failed to parse JSON response"
    }
} catch {
    Write-Error "Failed to download version manifest: $_"
    exit 1
}

# ... rest of the script remains the same
$v = $manifest.versions | Where-Object { $_.id -eq $version } | Select-Object -First 1
if (-not $v) {
    throw "Minecraft version $version not found in manifest."
}

try {
    $response = Invoke-WebRequest -Uri $v.url -TimeoutSec 30
    $vj = $response.Content | ConvertFrom-Json
} catch {
    throw "Failed to download version JSON: $_"
}

# Download asset index
$assetIndexUrl = $vj.assetIndex.url
$assetIndexId = $vj.assetIndex.id
Write-Host "Downloading asset index: $assetIndexId"
Invoke-WebRequest -Uri $assetIndexUrl -OutFile "$assetsDir\indexes\$assetIndexId.json"

# Download all assets
$index = Get-Content "$assetsDir\indexes\$assetIndexId.json" | ConvertFrom-Json
$objects = $index.objects.PSObject.Properties
$total = ($objects | Measure-Object).Count
$i = 0

foreach ($obj in $objects) {
    $hash = $obj.Value.hash
    $subdir = $hash.Substring(0, 2)
    $destDir = "$assetsDir\objects\$subdir"
    $dest = "$destDir\$hash"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    if (-not (Test-Path $dest)) {
        $url = "https://resources.download.minecraft.net/$subdir/$hash"
        Invoke-WebRequest -Uri $url -OutFile $dest
    }
    $i++
    if ($i % 100 -eq 0) { Write-Host "$i / $total assets downloaded" }
}
Write-Host "All $total assets downloaded"
