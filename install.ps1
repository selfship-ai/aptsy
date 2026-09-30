# Install Aptsy on Windows from a GitHub release and run first-time config.
#
#   irm https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.ps1 | iex
#
# Optional environment variables (set them in the same command):
#   APTSY_VERSION=v0.2.16     pin a release instead of the latest
#   APTSY_NONINTERACTIVE=1    skip questions: install, start, configure every tool
#   APTSY_UNINSTALL=1         remove Aptsy from this machine
#
# Saved copy:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 --uninstall

$__aptsyArgs = @($args)
try {
  & {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $Repo = 'selfship-ai/aptsy'
    $HomeDir = $env:USERPROFILE
    $AptsyHome = Join-Path $HomeDir '.aptsy'
    $Log = Join-Path $AptsyHome 'install.log'
    $Bindir = Join-Path (Join-Path $HomeDir '.local') 'bin'
    $HooksDir = Join-Path $AptsyHome 'hooks'

    $Uninstall = $false
    $NonInteractive = $false
    if ($env:APTSY_UNINSTALL -match '^(1|true|yes)$') { $Uninstall = $true }
    if ($env:APTSY_NONINTERACTIVE -match '^(1|true|yes)$') { $NonInteractive = $true }
    Remove-Item Env:\APTSY_UNINSTALL -ErrorAction SilentlyContinue
    Remove-Item Env:\APTSY_NONINTERACTIVE -ErrorAction SilentlyContinue
    foreach ($arg in $__aptsyArgs) {
      switch -Regex ($arg) {
        '^(-Uninstall|--uninstall)$' { $Uninstall = $true }
        '^(-NonInteractive|--non-interactive)$' { $NonInteractive = $true }
      }
    }

    try {
      $proto = [Net.ServicePointManager]::SecurityProtocol
      $proto = $proto -bor [Net.SecurityProtocolType]::Tls12
      [Net.ServicePointManager]::SecurityProtocol = $proto
    } catch {}

    function Write-Info([string]$Message) {
      Write-Host $Message
      if ($Message -eq '') { return }
      $dir = Split-Path -Parent $Log
      if (Test-Path -LiteralPath $dir) {
        Add-Content -LiteralPath $Log -Value $Message
      }
    }

    function Fail([string]$Message) {
      Write-Host "install: $Message"
      $dir = Split-Path -Parent $Log
      if (Test-Path -LiteralPath $dir) {
        Add-Content -LiteralPath $Log -Value "install: $Message"
      }
      throw "install: $Message"
    }

    function Test-Prompt {
      if ($NonInteractive) { return $false }
      try {
        if ([Console]::IsInputRedirected) { return $false }
      } catch {}
      return $true
    }

    function Get-AptsyArch {
      $arch = $env:PROCESSOR_ARCHITECTURE
      if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
      switch ($arch) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { Fail "unsupported CPU architecture: $arch" }
      }
    }

    function Get-ReleaseTag {
      if ($env:APTSY_VERSION) {
        $tag = $env:APTSY_VERSION.Trim()
        if ($tag -notmatch '^v') { $tag = "v$tag" }
        return $tag
      }
      $uri = "https://api.github.com/repos/$Repo/releases/latest"
      try {
        $resp = Invoke-WebRequest -UseBasicParsing -Headers @{
          'User-Agent' = 'aptsy-install'
          'Accept'     = 'application/vnd.github+json'
        } -Uri $uri -TimeoutSec 20
      } catch {
        Fail "could not read the latest release. $_"
      }
      $rel = $resp.Content | ConvertFrom-Json
      if (-not $rel.tag_name) { Fail 'could not read the latest release' }
      return [string]$rel.tag_name
    }

    function Save-Url([string]$Url, [string]$Dest) {
      Write-Info "Downloading $(Split-Path -Leaf $Dest)"
      $last = $null
      for ($i = 0; $i -lt 3; $i++) {
        try {
          Invoke-WebRequest -UseBasicParsing -Headers @{ 'User-Agent' = 'aptsy-install' } -Uri $Url -OutFile $Dest -TimeoutSec 180
          return
        } catch {
          $last = $_
          Start-Sleep -Seconds (2 * ($i + 1))
        }
      }
      Fail "could not download $(Split-Path -Leaf $Dest). $last"
    }

    function Assert-Checksum([string]$File, [string]$Sums) {
      $name = Split-Path -Leaf $File
      $want = $null
      foreach ($line in Get-Content -LiteralPath $Sums) {
        $trimmed = $line.Trim()
        if ($trimmed.EndsWith($name)) {
          $want = ($trimmed -split '\s+')[0].ToLower()
          break
        }
      }
      if (-not $want) { Fail "checksums.txt has no entry for $name" }
      $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $File).Hash.ToLower()
      if ($got -ne $want) { Fail "checksum mismatch for $name" }
      Write-Info 'Checksum ok.'
    }

    function Install-Binary([string]$Src, [string]$Dest) {
      $dir = Split-Path -Parent $Dest
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      Unblock-File -LiteralPath $Src -ErrorAction SilentlyContinue
      if (Test-Path -LiteralPath $Dest) {
        try {
          Remove-Item -LiteralPath $Dest -Force -ErrorAction Stop
        } catch {
          $leaf = Split-Path -Leaf $Dest
          $oldLeaf = $leaf + '.old'
          $old = Join-Path $dir $oldLeaf
          if (Test-Path -LiteralPath $old) {
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
          }
          Rename-Item -LiteralPath $Dest -NewName $oldLeaf -Force
        }
      }
      Copy-Item -LiteralPath $Src -Destination $Dest -Force
      Unblock-File -LiteralPath $Dest
    }

    function Add-UserPath([string]$Dir) {
      $norm = $Dir.TrimEnd('\')
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      $parts = @()
      if ($userPath) {
        $parts = @($userPath -split ';' | Where-Object { $_ -ne '' })
      }
      $found = $false
      foreach ($part in $parts) {
        if ($part.TrimEnd('\') -ieq $norm) { $found = $true; break }
      }
      if (-not $found) {
        if ($userPath) { $updated = $Dir + ';' + $userPath } else { $updated = $Dir }
        [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
        Write-Info "Added $Dir to your user PATH."
        Write-Info 'Open a new terminal before typing aptsy. This window can run it after install finishes.'
      }
      if (-not $env:Path -or ($env:Path -notlike "*${norm}*")) {
        $env:Path = $Dir + ';' + $env:Path
      }
    }

    function Remove-UserPathEntry([string]$Dir) {
      $norm = $Dir.TrimEnd('\')
      $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
      if (-not $userPath) { return }
      $kept = @()
      foreach ($part in ($userPath -split ';')) {
        if ($part -eq '') { continue }
        if ($part.TrimEnd('\') -ieq $norm) { continue }
        $kept += $part
      }
      [Environment]::SetEnvironmentVariable('Path', ($kept -join ';'), 'User')
    }

    function Test-Up([string]$Url) {
      try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 2
        return ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 500)
      } catch {
        return $false
      }
    }

    function Stop-AptsyProcess {
      Get-Process -Name aptsy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    }

    function Remove-InstalledCommand {
      foreach ($name in @('aptsy.exe', 'aptsy.exe.old')) {
        $path = Join-Path $Bindir $name
        if (Test-Path -LiteralPath $path) {
          Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        }
      }
      $left = @()
      if (Test-Path -LiteralPath $Bindir) {
        $left = @(Get-ChildItem -Force -LiteralPath $Bindir -ErrorAction SilentlyContinue)
      }
      if ($left.Count -eq 0) {
        Remove-Item -LiteralPath $Bindir -Force -ErrorAction SilentlyContinue
        $localDir = Split-Path -Parent $Bindir
        $localLeft = @()
        if (Test-Path -LiteralPath $localDir) {
          $localLeft = @(Get-ChildItem -Force -LiteralPath $localDir -ErrorAction SilentlyContinue)
        }
        if ($localLeft.Count -eq 0) {
          Remove-Item -LiteralPath $localDir -Force -ErrorAction SilentlyContinue
        }
        Remove-UserPathEntry $Bindir
      }
    }

    function Uninstall-Aptsy {
      Write-Host 'Removing Aptsy.'
      $cmd = Join-Path $Bindir 'aptsy.exe'
      if (-not (Test-Path -LiteralPath $cmd)) {
        $found = Get-Command aptsy -ErrorAction SilentlyContinue
        if ($found) { $cmd = $found.Source }
      }
      if ($cmd -and (Test-Path -LiteralPath $cmd)) {
        & $cmd uninstall --yes
        if ($LASTEXITCODE -ne 0) {
          Write-Host 'aptsy uninstall did not finish. Removing the files it left behind.'
        }
      } else {
        Write-Host 'Hook entries in other tools are removed when aptsy uninstall is available.'
      }
      Stop-AptsyProcess
      if (Test-Path -LiteralPath $AptsyHome) {
        Remove-Item -LiteralPath $AptsyHome -Recurse -Force -ErrorAction SilentlyContinue
      }
      $logDir = Join-Path $env:LOCALAPPDATA 'aptsy'
      if (Test-Path -LiteralPath $logDir) {
        Remove-Item -LiteralPath $logDir -Recurse -Force -ErrorAction SilentlyContinue
      }
      Remove-InstalledCommand
      Write-Host 'Aptsy has been uninstalled.'
    }

    if ($Uninstall) {
      Uninstall-Aptsy
      return
    }

    New-Item -ItemType Directory -Force -Path $AptsyHome | Out-Null
    if (-not (Test-Path -LiteralPath $Log)) { New-Item -ItemType File -Path $Log | Out-Null }

    $arch = Get-AptsyArch
    Write-Info "Detected windows/${arch}."
    $tag = Get-ReleaseTag
    $version = $tag -replace '^v', ''
    $asset = "aptsy_${version}_windows_${arch}.zip"
    Write-Info "Release ${tag} (${asset})."

    $work = Join-Path $env:TEMP ('aptsy-install-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    try {
      $zip = Join-Path $work $asset
      $sums = Join-Path $work 'checksums.txt'
      $base = "https://github.com/$Repo/releases/download/$tag"
      Save-Url "$base/$asset" $zip
      Save-Url "$base/checksums.txt" $sums
      Assert-Checksum $zip $sums
      $out = Join-Path $work 'out'
      Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
      $aptsySrc = Get-ChildItem -LiteralPath $out -Recurse -Filter 'aptsy.exe' | Select-Object -First 1
      $bridgeSrc = Get-ChildItem -LiteralPath $out -Recurse -Filter 'aptsy-bridge.exe' | Select-Object -First 1
      if (-not $aptsySrc) { Fail 'archive has no aptsy.exe' }
      if (-not $bridgeSrc) { Fail 'archive has no aptsy-bridge.exe' }

      Write-Info "Installing the aptsy command to $Bindir."
      Install-Binary $aptsySrc.FullName (Join-Path $Bindir 'aptsy.exe')
      # init writes hook commands as ~/.aptsy/hooks/aptsy-bridge with no .exe.
      # Windows runs that path only when the file has that exact name.
      Install-Binary $bridgeSrc.FullName (Join-Path $HooksDir 'aptsy-bridge')
      Install-Binary $bridgeSrc.FullName (Join-Path $HooksDir 'aptsy-bridge.exe')
      Add-UserPath $Bindir
      $Aptsy = Join-Path $Bindir 'aptsy.exe'
      Write-Info "Installed $Aptsy"
      Write-Info "Installed $(Join-Path $HooksDir 'aptsy-bridge')"
      & $Aptsy version
    } finally {
      Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }

    if ($NonInteractive -or -not (Test-Prompt)) {
      Write-Info 'This install cannot open a browser. Run: aptsy login; aptsy init; aptsy start'
      return
    }
    # whoami is checked first so a release that does not yet understand
    # "login --if-needed" still keeps an existing account.
    $summary = ''
    try { $summary = (& $Aptsy whoami 2>&1 | Out-String).Trim() } catch { $summary = '' }
    $signedOut = $summary -like 'account: signed out*' -or $summary -like '*unreadable or empty*' -or $summary -eq ''
    $signedIn = -not $signedOut -and $summary -like 'account: *'
    if ($signedIn) {
      Write-Info $summary
      Write-Info 'Already signed in. Leaving the existing account in place.'
    } else {
      Write-Info 'Sign in to your free Aptsy account. A browser will open.'
      & $Aptsy login --if-needed
      if ($LASTEXITCODE -ne 0) {
        Write-Info 'Sign-in did not finish. Create the account if you were asked to, then run: aptsy login; aptsy init; aptsy start'
        return
      }
    }

    $running = (Test-Up 'http://127.0.0.1:45117/health') -or (Test-Up 'http://127.0.0.1:8787/health')
    if ($running) {
      Write-Info 'aptsy is already running. The new binary is used after a restart.'
      $restart = -not $NonInteractive -and (Test-Prompt)
      $answer = 'Y'
      if ($restart) { $answer = Read-Host 'Restart it with the new binary? [Y/n]' }
      if ($answer -eq '' -or $answer -match '^[Yy]$') {
        & $Aptsy stop
        Stop-AptsyProcess
        & $Aptsy start
        if ($LASTEXITCODE -ne 0) {
          Fail "aptsy did not become healthy. See $env:LOCALAPPDATA\aptsy\aptsy.log"
        }
      } elseif ($answer -match '^[Nn]$') {
        Write-Info 'Left the current process running.'
      } else {
        Fail "unknown choice: $answer"
      }
    } elseif ($NonInteractive -or -not (Test-Prompt)) {
      Write-Info 'Starting aptsy.'
      & $Aptsy start
      if ($LASTEXITCODE -ne 0) {
        Fail "aptsy did not become healthy. See $env:LOCALAPPDATA\aptsy\aptsy.log"
      }
    } else {
      Write-Info ''
      Write-Info 'Aptsy starts before tool setup, so MCP clients connect to a server that is already running.'
      $answer = Read-Host 'Start aptsy in the background? [Y/n]'
      if ($answer -eq '' -or $answer -match '^[Yy]$') {
        & $Aptsy start
        if ($LASTEXITCODE -ne 0) {
          Fail "aptsy did not become healthy. See $env:LOCALAPPDATA\aptsy\aptsy.log"
        }
      } elseif ($answer -match '^[Nn]$') {
        Write-Info "Run 'aptsy start' when you want the daemon. MCP entries are added then, after the server is up. Stop it with 'aptsy stop'."
      } else {
        Fail "unknown choice: $answer"
      }
    }

    $config = Join-Path $AptsyHome 'config.yml'
    Write-Info ''
    if (Test-Path -LiteralPath $config) {
      if ($NonInteractive -or -not (Test-Prompt)) {
        Write-Info "Config already exists at $config. Leaving it in place."
      } else {
        $answer = Read-Host 'Config already exists. Re-run setup and update hooks? [y/N]'
        if ($answer -match '^[Yy]$') {
          Write-Info 'Configuring hooks and config.'
          & $Aptsy init
          if ($LASTEXITCODE -ne 0) { Fail 'aptsy init failed' }
        } else {
          Write-Info "Keeping $config."
        }
      }
    } else {
      Write-Info 'Configuring hooks and config.'
      Write-Info 'aptsy will list the coding tools it found on this machine.'
      if ((Test-Prompt) -and -not $NonInteractive) {
        & $Aptsy init
      } else {
        Write-Info 'Configuring every discovered tool.'
        'Y' | & $Aptsy init
      }
      if ($LASTEXITCODE -ne 0) { Fail 'aptsy init failed' }
    }

    Write-Info ''
    Write-Info "You're all set — welcome to Aptsy."
    Write-Info ''
    Write-Info 'Your agent chats are being captured locally. Open the dashboard in your browser:'
    Write-Info ''
    Write-Info '  http://127.0.0.1:45117'
    Write-Info ''
    Write-Info 'Browse sessions, inspect messages, and adjust evaluation settings at:'
    Write-Info ''
    Write-Info '  http://127.0.0.1:45117/settings'
    Write-Info ''
    Write-Info "Install log: $Log"
    Write-Info 'Windows starts Aptsy in the background for this sign-in. Run aptsy start again after you sign in next time.'
  }
} finally {
  Remove-Variable -Name __aptsyArgs -ErrorAction SilentlyContinue
}
