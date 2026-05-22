# build.ps1 - Build and package MC Java UWP
param(
    [string]$MesaRuntimeDir = $env:MESA_UWP_DIR,
    [string]$McVersion,
    [string]$FabricLoader,
    [string]$AssetIndex,
    [switch]$KeepStaging
)

$ErrorActionPreference = "Stop"

# Push command-line overrides into the environment before sourcing config.
# scripts/config.ps1 honors these so every downstream script (compat mod,
# patch-fabric, etc.) sees the same chosen version.
if ($McVersion)    { $env:MC_VERSION = $McVersion }
if ($FabricLoader) { $env:FABRIC_LOADER_VERSION = $FabricLoader }
if ($AssetIndex)   { $env:MC_ASSET_INDEX = $AssetIndex }

. (Join-Path $PSScriptRoot "scripts\common.ps1")

$root = Resolve-RepoRoot
$pkg = Get-ConfigPath "PackageContentDir"
$buildDir = Get-ConfigPath "BuildDir"
$outDir = Get-ConfigPath "OutputDir"
$gameDir = Get-ConfigPath "GameDir"
$assetsDir = Get-ConfigPath "AssetsDir"
$nativesSourceDir = Get-ConfigPath "NativesDir"
$certDir = Get-ConfigPath "CertificateDir"
$mcBuildDir = Join-Path $buildDir "MC.Xbox"
$glfwBuildDir = Join-Path $buildDir "glfw_shim"
$mcExe = Join-Path $mcBuildDir "MC.Xbox.exe"
$shimDll = Join-Path $glfwBuildDir "glfw.dll"
$jreSrc = Resolve-JavaHome
$pythonExe = Resolve-Python
$tools = Resolve-VSTools
$sdk = Resolve-WindowsSdk
$sdkRoot = $sdk.Root
$sdkVer = $sdk.Version

New-Item -ItemType Directory -Force -Path $buildDir, $outDir, $certDir, $mcBuildDir, $glfwBuildDir | Out-Null

Write-Host "=== Generating runtime_config.h ==="
# Token-substitute MC.Xbox/runtime_config.h.in into the build dir. App.cpp
# picks it up via the INCLUDE path below. Regenerated every build so the
# header always matches the currently selected MC version.
$runtimeConfigTemplate = Join-Path $root "MC.Xbox\runtime_config.h.in"
$runtimeConfigOutput   = Join-Path $mcBuildDir "runtime_config.h"
if (-not (Test-Path $runtimeConfigTemplate)) { throw "runtime_config.h.in not found at $runtimeConfigTemplate" }
$runtimeConfigContent = [System.IO.File]::ReadAllText($runtimeConfigTemplate)
$runtimeConfigContent = $runtimeConfigContent.Replace('@@MC_VERSION@@',           $ProjectConfig.MinecraftVersion)
$runtimeConfigContent = $runtimeConfigContent.Replace('@@FABRIC_LOADER_VERSION@@', $ProjectConfig.FabricLoaderVersion)
$runtimeConfigContent = $runtimeConfigContent.Replace('@@MC_ASSET_INDEX@@',       $ProjectConfig.MinecraftAssetIndex)
if ($runtimeConfigContent -match '@@[A-Z_]+@@') { throw "runtime_config.h still contains unsubstituted tokens after generation: $($Matches[0])" }
[System.IO.File]::WriteAllText($runtimeConfigOutput, $runtimeConfigContent)
Write-Host "runtime_config.h written for MC $($ProjectConfig.MinecraftVersion) / fabric-loader $($ProjectConfig.FabricLoaderVersion) / asset index $($ProjectConfig.MinecraftAssetIndex)"

Write-Host "=== Building MC.Xbox.exe ==="
Push-Location (Join-Path $root "MC.Xbox")

$env:INCLUDE = "$mcBuildDir;$($tools.MsvcRoot)\include;${sdkRoot}Include\$sdkVer\ucrt;${sdkRoot}Include\$sdkVer\shared;${sdkRoot}Include\$sdkVer\um;${sdkRoot}Include\$sdkVer\winrt;${sdkRoot}Include\$sdkVer\cppwinrt;$jreSrc\include;$jreSrc\include\win32"
$env:LIB = "$($tools.MsvcRoot)\lib\x64;${sdkRoot}Lib\$sdkVer\ucrt\x64;${sdkRoot}Lib\$sdkVer\um\x64"

& $tools.ClExe App.cpp /std:c++17 /EHsc /W3 /O2 /D_UNICODE /DUNICODE /D_WIN32_WINNT=0x0A00 /Fo"$mcBuildDir\" `
    /DWINAPI_FAMILY=WINAPI_FAMILY_APP `
    /link /SUBSYSTEM:WINDOWS /ENTRY:wWinMainCRTStartup /MACHINE:X64 `
    /OUT:"$mcExe" kernel32.lib shell32.lib runtimeobject.lib windowsapp.lib ole32.lib oleaut32.lib
if ($LASTEXITCODE -ne 0) { throw "Compile failed" }
Pop-Location
Write-Host "MC.Xbox.exe built"

Write-Host "=== Building GLFW CoreWindow shim ==="
& (Join-Path $root "glfw_shim\build_glfw.ps1") -OutputDir $glfwBuildDir

Write-Host "=== Building Xbox compatibility mod ==="
& (Join-Path $root "compat_mod\build_compat_mod.ps1")

Write-Host "=== Assembling PackageContent ==="
Remove-Item -Recurse -Force $pkg -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "Assets") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "natives") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "assets") | Out-Null
# runtime/ holds the immutable game stack (libraries, versions, fabric remapped
# jars, bundled mods, log configs). Writable state (saves, mods folder,
# config, logs) lives in LocalState and is set up by App.cpp at startup.
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "runtime") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "runtime\log_configs") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $pkg "runtime\bundled-mods") | Out-Null

Copy-Item $mcExe (Join-Path $pkg "MC.Xbox.exe")
Copy-Item (Join-Path $root "MC.Xbox\Package.appxmanifest") (Join-Path $pkg "AppxManifest.xml")

Write-Host "Copying runtime files..."
Copy-Item -Recurse (Join-Path $gameDir "libraries") (Join-Path $pkg "runtime\libraries")
Copy-Item -Recurse (Join-Path $gameDir "versions")  (Join-Path $pkg "runtime\versions")
# Bundled mods (compat mod, optionally diagnostics) live under runtime\bundled-mods.
# App.cpp copies them into LocalState\game\mods on launch.
Copy-Item -Recurse (Join-Path $gameDir "mods\*") (Join-Path $pkg "runtime\bundled-mods\") -Force
if (Test-Path (Join-Path $gameDir ".fabric")) {
    Copy-Item -Recurse (Join-Path $gameDir ".fabric") (Join-Path $pkg "runtime\.fabric")
}

$remapped = Join-Path $gameDir ".fabric\remappedJars"
if (Test-Path $remapped) {
    Write-Host "Copying .fabric remapped jars..."
    New-Item -ItemType Directory -Force (Join-Path $pkg "runtime\.fabric\remappedJars") | Out-Null
    Copy-Item -Recurse (Join-Path $remapped "*") (Join-Path $pkg "runtime\.fabric\remappedJars\") -Force
}

Write-Host "Copying natives..."
Copy-Item (Join-Path $nativesSourceDir "*.dll") (Join-Path $pkg "natives\")

Write-Host "Extracting JNA native..."
Add-Type -AssemblyName System.IO.Compression.FileSystem
$jnaVersion = $ProjectConfig.JnaVersion
$jnaJar = Join-Path $gameDir "libraries\net\java\dev\jna\jna\$jnaVersion\jna-$jnaVersion.jar"
if (Test-Path $jnaJar) {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($jnaJar)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq "com/sun/jna/win32-x86-64/jnidispatch.dll" } | Select-Object -First 1
        if ($entry) {
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $pkg "natives\jnidispatch.dll"), $true)
            Write-Host "JNA: jnidispatch.dll"
        } else {
            Write-Warning "win32-x86-64/jnidispatch.dll not found in $jnaJar"
        }
    } finally {
        $zip.Dispose()
    }
}

Write-Host "Injecting GLFW shim into LWJGL JAR..."
$lwjglGlfwVersion = $ProjectConfig.LwjglGlfwVersion
$glfwJar  = Join-Path $pkg "runtime\libraries\org\lwjgl\lwjgl-glfw\$lwjglGlfwVersion\lwjgl-glfw-$lwjglGlfwVersion-natives-windows.jar"
$jarExe   = Join-Path $jreSrc "bin\jar.exe"
if (-not (Test-Path $jarExe)) { $jarExe = "jar" }

if (Test-Path $glfwJar) {
    # Extract JAR into a fresh temp dir, replace glfw.dll, repack
    $jarTmpDir = Join-Path $buildDir "glfw_jar_tmp"
    Remove-Item -Recurse -Force $jarTmpDir -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path $jarTmpDir | Out-Null
    Push-Location $jarTmpDir
    & $jarExe xf $glfwJar
    Pop-Location

    $glfwInJar = Get-ChildItem -Recurse $jarTmpDir -Filter "glfw.dll" | Select-Object -First 1
    if ($glfwInJar) {
        Copy-Item $shimDll $glfwInJar.FullName -Force
        Write-Host "  Replaced $($glfwInJar.FullName)"
        Push-Location $jarTmpDir
        & $jarExe cf $glfwJar .
        Pop-Location
        Write-Host "  JAR repacked: $glfwJar"
    } else {
        Write-Warning "  glfw.dll entry not found inside JAR after extraction"
    }
} else {
    Write-Warning "  LWJGL GLFW JAR not found: $glfwJar"
}
Copy-Item $shimDll (Join-Path $pkg "natives\glfw.dll") -Force

Write-Host "Copying Mesa runtime..."
$mesaRuntime = Resolve-MesaRuntimeDir -MesaRuntimeDir $MesaRuntimeDir
Write-Host "Mesa runtime source: $mesaRuntime"
foreach ($dll in Get-MesaRuntimeDllNames) {
    $source = Join-Path $mesaRuntime $dll
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $pkg $dll) -Force
        Copy-Item $source (Join-Path $pkg "natives\$dll") -Force
        Write-Host "Mesa: $dll"
    }
}

Write-Host "Copying assets..."
Copy-Item -Recurse -Force (Join-Path $assetsDir "*") (Join-Path $pkg "assets\")
Copy-Item -Force (Join-Path $root "log_configs\client-uwp.xml") (Join-Path $pkg "runtime\log_configs\client-uwp.xml")

Write-Host "Copying JRE..."
Write-Host "JRE source: $jreSrc"
Copy-Item -Recurse $jreSrc (Join-Path $pkg "jre")
Copy-Item (Join-Path $root "xbox_security.properties") (Join-Path $pkg "jre\conf\security\xbox.properties")

Write-Host "Generating UWP tile assets..."
& $pythonExe (Join-Path $root "scripts\generate-assets.py") $pkg
if ($LASTEXITCODE -ne 0) { throw "Asset generation failed" }

Write-Host "=== Packaging ==="
$cert = Join-Path $certDir $ProjectConfig.CertificateFileName
$appx = Join-Path $outDir $ProjectConfig.AppxFileName
$certName = if ($env:APPX_CERT_SUBJECT) { $env:APPX_CERT_SUBJECT } else { $ProjectConfig.DefaultCertificateSubject }

if (-not (Test-Path $cert)) {
    $c = New-SelfSignedCertificate -Type CodeSigningCert -Subject $certName `
        -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
    Export-PfxCertificate -Cert $c -FilePath $cert `
        -Password (ConvertTo-SecureString $ProjectConfig.CertificatePassword -AsPlainText -Force) | Out-Null
    Write-Host "Generated cert"
}

$allSigningCertCandidates = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object {
        $_.HasPrivateKey -and
        ($_.EnhancedKeyUsageList | Where-Object { $_.FriendlyName -eq 'Code Signing' })
    }
$banditVaultSigningCertCandidates = $allSigningCertCandidates | Where-Object { $_.Subject -like '*BanditVault*' } | Sort-Object NotBefore -Descending
$otherSigningCertCandidates = $allSigningCertCandidates | Where-Object { $_.Subject -notlike '*BanditVault*' } | Sort-Object NotBefore -Descending
$signingCertCandidates = @($banditVaultSigningCertCandidates) + @($otherSigningCertCandidates)
if (-not $signingCertCandidates) {
    throw "Signing certificate not found in the current user certificate store."
}

$makeappx = Get-ChildItem "${sdkRoot}bin\$sdkVer\x64\makeappx.exe","${sdkRoot}bin\10.0.26100.0\x64\makeappx.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $makeappx) {
    $cmd = Get-Command makeappx -ErrorAction SilentlyContinue
    if ($cmd) { $makeappx = $cmd.Source }
}
if (-not $makeappx) { throw "makeappx.exe not found. Add Windows SDK bin to PATH." }
$signtool = Get-ChildItem "${sdkRoot}bin\$sdkVer\x64\signtool.exe","${sdkRoot}bin\10.0.26100.0\x64\signtool.exe" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $signtool) { $signtool = "signtool" }

& $makeappx pack /d $pkg /p $appx /overwrite
if ($LASTEXITCODE -ne 0) { throw "MakeAppx failed" }

function Invoke-AppxSign {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppxPath,

        [Parameter(Mandatory = $true)]
        [string]$CertificateThumbprint,

        [Parameter(Mandatory = $true)]
        [string]$SigntoolPath
    )

    & $SigntoolPath sign /fd SHA256 /sha1 $CertificateThumbprint $AppxPath
    return ($LASTEXITCODE -eq 0)
}

$signingSucceeded = $false
foreach ($signingCert in $signingCertCandidates) {
    if (Invoke-AppxSign -AppxPath $appx -CertificateThumbprint $signingCert.Thumbprint -SigntoolPath $signtool) {
        $signingSucceeded = $true
        Write-Host "Signed appx with $($signingCert.Subject)"
        break
    }
}

if (-not $signingSucceeded) {
    Write-Warning "Appx signing failed with the existing store certificates; generating a fresh dev certificate and retrying once."
    Remove-Item $cert -Force -ErrorAction SilentlyContinue

    $c = New-SelfSignedCertificate -Type CodeSigningCert -Subject $certName `
        -KeyUsage DigitalSignature -CertStoreLocation "Cert:\CurrentUser\My" `
        -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3","2.5.29.19={text}")
    Export-PfxCertificate -Cert $c -FilePath $cert `
        -Password (ConvertTo-SecureString $ProjectConfig.CertificatePassword -AsPlainText -Force) | Out-Null

    if (-not (Invoke-AppxSign -AppxPath $appx -CertificateThumbprint $c.Thumbprint -SigntoolPath $signtool)) {
        throw "Appx signing failed"
    }
}
if (-not (Test-Path $appx)) { throw "Appx package was not created" }

if (-not $KeepStaging) {
    Remove-Item -Recurse -Force $pkg -ErrorAction SilentlyContinue
    Write-Host "Removed staging package directory"
}

Write-Host ""
Write-Host "=== Done ==="
Write-Host "Package: $appx"
