$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "common.ps1")

$root = Resolve-RepoRoot
$gameDir = Get-ConfigPath "GameDir"
$version = $ProjectConfig.MinecraftVersion

try {
    $manifest = Invoke-WebRequest -Uri 'https://piston-meta.mojang.com/mc/game/version_manifest_v2.json' | ConvertFrom-Json
} catch {
    Write-Error "Failed to download version manifest: $_"
    exit 1
}

$v = $manifest.versions | Where-Object { $_.id -eq $version } | Select-Object -First 1
if (-not $v) {
    throw "Minecraft version $version not found in manifest."
}

try {
    $vj = Invoke-WebRequest -Uri $v.url | ConvertFrom-Json
} catch {
    Write-Error "Failed to download version JSON from $($v.url): $_"
    exit 1
}

$versionDir = Join-Path $gameDir "versions\$version"
New-Item -ItemType Directory -Force -Path $versionDir | Out-Null

$clientUrl = $vj.downloads.client.url
$clientJar = Join-Path $versionDir "$version.jar"
try {
    Invoke-WebRequest -Uri $clientUrl -OutFile $clientJar
} catch {
    Write-Error "Failed to download client jar from $clientUrl`: $_"
    exit 1
}
Write-Host "Client jar done -> $clientJar"

$libs = $vj.libraries | Where-Object { $_.downloads.artifact -ne $null }
foreach ($lib in $libs) {
    $artifact = $lib.downloads.artifact
    $dest = Join-Path $gameDir ("libraries\" + $artifact.path.Replace('/', '\'))
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    if (-not (Test-Path $dest)) {
        try {
            Invoke-WebRequest -Uri $artifact.url -OutFile $dest
            Write-Host "Downloaded: $($artifact.path)"
        } catch {
            Write-Error "Failed to download library $($artifact.path) from $($artifact.url): $_"
            exit 1
        }
    }
}

Write-Host "All done"
