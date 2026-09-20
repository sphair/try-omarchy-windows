set shell := ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]

repo := "F:\\GitHub\\try-omarchy-windows"
qemu_repo := "F:\\GitHub\\qemusphair\\qemu"
app_dir := repo + "\\app"
runtime_root := repo + "\\runtime-build\\output\\borderless-qemu"
runtime_bin := runtime_root + "\\bin"
qemu_build_cache_volume := "try-omarchy-qemu-build-cache"

[private]
default:
    @just --unsorted --list

# Start Docker Desktop if needed and wait for the Docker daemon.
build-docker-ready:
    if (!(Get-Command docker -ErrorAction SilentlyContinue)) { throw 'docker.exe not found on PATH.' }; docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Host 'Docker daemon is ready.'; exit 0 }; $desktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'; if (!(Test-Path $desktop)) { throw 'Docker daemon is not running and Docker Desktop.exe was not found.' }; Write-Host 'Starting Docker Desktop...'; Start-Process $desktop; $deadline = (Get-Date).AddMinutes(3); do { Start-Sleep -Seconds 3; docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Host 'Docker daemon is ready.'; exit 0 } } while ((Get-Date) -lt $deadline); throw 'Docker Desktop did not become ready within 3 minutes.'

# Build the Fedora MinGW Docker image used for the QEMU cross-build.
build-qemu-image: build-docker-ready
    Set-Location '{{qemu_repo}}'; docker build --tag qemu/fedora-win64-cross --file tests\docker\dockerfiles\fedora-win64-cross.docker .

# Build the local borderless QEMU runtime into runtime-build\output\borderless-qemu\bin.
# Reuses a persistent Docker volume for QEMU's cloned source and build
# directory, so only the first build (or one after the recipe/patches change)
# does a full clone + configure + make; later runs recompile incrementally.
build-qemu-runtime: build-docker-ready
    $repo = '{{repo}}'; $out = '{{runtime_bin}}'; $winq = Join-Path $env:LOCALAPPDATA 'TryOmarchy\runtime\bin'; if (!(Test-Path $winq)) { throw "Installed WINQ runtime not found at $winq" }; New-Item -ItemType Directory -Force $out | Out-Null; docker volume create {{qemu_build_cache_volume}} *> $null; docker run --rm -v "$($repo):/app:ro" -v "$($out):/out" -v "$($winq):/winq:ro" -v {{qemu_build_cache_volume}}:/work qemu/fedora-win64-cross bash -lc '/app/runtime-build/build-winq-borderless-docker.sh /out'

# Discard the cached QEMU source/build tree so the next build-qemu-runtime does a full rebuild from scratch.
build-qemu-runtime-clean:
    docker volume rm -f {{qemu_build_cache_volume}}

# Run the Try Omarchy app tests.
build-app-test:
    Set-Location '{{app_dir}}'; go test .

# Build TryOmarchy.exe.
build-app:
    Set-Location '{{app_dir}}'; go build -trimpath -ldflags "-H windowsgui -s -w" -o TryOmarchy.exe .

# Run TryOmarchy.exe with the locally built runtime using -winq.
run-local-runtime:
    Set-Location '{{app_dir}}'; .\TryOmarchy.exe -winq '{{runtime_root}}' -render gpu -borderless

# Install the locally built QEMU runtime into the managed Try Omarchy runtime cache.
build-install-runtime:
    $ErrorActionPreference = 'Stop'; $candidate = '{{runtime_bin}}'; $installedRuntime = Join-Path $env:LOCALAPPDATA 'TryOmarchy\runtime'; $installedBin = Join-Path $installedRuntime 'bin'; $receiptPath = Join-Path $installedRuntime 'runtime-install-state.json'; if (Get-Process TryOmarchy,qemu-system-x86_64w,qemu-system-x86_64 -ErrorAction SilentlyContinue) { throw 'Stop Try Omarchy and QEMU before replacing the installed runtime.' }; foreach ($path in @($candidate, $installedBin, $receiptPath)) { if (!(Test-Path $path)) { throw "Required path not found: $path" } }; $backup = Join-Path $installedRuntime ('borderless-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '\bin'); New-Item -ItemType Directory -Force $backup | Out-Null; Copy-Item -Recurse -Force (Join-Path $installedBin '*') $backup; Copy-Item -Recurse -Force (Join-Path $candidate '*') $installedBin; $exe = Get-Item (Join-Path $installedBin 'qemu-system-x86_64w.exe'); $receipt = Get-Content -Raw $receiptPath | ConvertFrom-Json; $sha256 = [System.Security.Cryptography.SHA256]::Create(); $stream = [System.IO.File]::OpenRead($exe.FullName); try { $hashBytes = $sha256.ComputeHash($stream) } finally { $stream.Dispose() }; $receipt.executable.sha256 = -join ($hashBytes | ForEach-Object { $_.ToString('x2') }); $receipt.executable.size = $exe.Length; $epoch = [DateTimeOffset]::FromUnixTimeSeconds(0).UtcDateTime; $receipt.executable.modTimeUnixNano = [int64](($exe.LastWriteTimeUtc.Ticks - $epoch.Ticks) * 100); $receipt | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $receiptPath; Write-Host "Installed runtime. Backup: $backup"

# Build QEMU, build TryOmarchy.exe, and install the runtime so TryOmarchy.exe can be run directly.
build-complete: build-qemu-runtime build-app-test build-app build-install-runtime

# Run TryOmarchy.exe directly against the managed runtime cache, without -winq.
run:
    Set-Location '{{app_dir}}'; .\TryOmarchy.exe -render gpu -borderless
