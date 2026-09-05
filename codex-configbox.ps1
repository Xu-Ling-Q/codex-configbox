param(
  [int]$Port = 17855,
  [string]$SwitchSlot = '',
  [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$CodexHome = Join-Path $env:USERPROFILE '.codex'
$Config = Join-Path $CodexHome 'config.toml'
$Auth = Join-Path $CodexHome 'auth.json'
$ProviderRoot = Join-Path $CodexHome 'provider-profiles'
$AuthRoot = Join-Path $CodexHome 'auth-profiles'
$AdapterStatePath = Join-Path $CodexHome 'provider-chat-adapter-active.json'
$InstructionsStatePath = Join-Path $CodexHome 'model-instructions-settings.json'
$CustomModelsStatePath = Join-Path $CodexHome 'custom-models.json'
$InstructionsPathsStatePath = Join-Path $CodexHome 'model-instructions-paths.json'
New-Item -ItemType Directory -Force -Path $ProviderRoot | Out-Null
New-Item -ItemType Directory -Force -Path $AuthRoot | Out-Null

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Json($obj, [int]$status = 200) {
  $res = $script:ctx.Response
  $res.StatusCode = $status
  $res.ContentType = 'application/json; charset=utf-8'
  $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 30))
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function Text($txt, $type = 'text/html; charset=utf-8') {
  $res = $script:ctx.Response
  $res.ContentType = $type
  $bytes = [Text.Encoding]::UTF8.GetBytes($txt)
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.Close()
}

function Read-BodyJson() {
  $reader = [IO.StreamReader]::new($script:ctx.Request.InputStream, [Text.Encoding]::UTF8)
  $raw = $reader.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
  return $raw | ConvertFrom-Json
}

function ConvertTo-Hashtable($Obj) {
  $hash = [ordered]@{}
  if ($null -eq $Obj) { return $hash }
  foreach ($prop in $Obj.PSObject.Properties) {
    $hash[$prop.Name] = $prop.Value
  }
  return $hash
}

function Read-JsonHashtable([string]$Path) {
  if (!(Test-Path $Path)) { return [ordered]@{} }
  try {
    return ConvertTo-Hashtable (Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
  } catch {
    return [ordered]@{}
  }
}

function Get-ProviderBlock([string]$Text) {
  $m = [regex]::Match($Text, '(?s)\[model_providers\.custom\]\r?\n.*?(?=\r?\n\[[^\r\n]+\]|\z)')
  if ($m.Success) { return $m.Value }
  return ''
}

function Get-ProfileBlock([string]$Text) {
  $m = [regex]::Match($Text, '(?s)\[profiles\.custom\]\r?\n.*?(?=\r?\n\[[^\r\n]+\]|\z)')
  if ($m.Success) { return $m.Value }
  return ''
}

function Get-Field([string]$Block, [string]$Name) {
  $m = [regex]::Match($Block, "(?m)^$Name\s*=\s*`"([^`"]*)`"")
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-RootString([string]$Text, [string]$Name) {
  $m = [regex]::Match($Text, "(?m)^$Name\s*=\s*`"([^`"]*)`"")
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}

function Get-CustomModels() {
  if (!(Test-Path -LiteralPath $CustomModelsStatePath -PathType Leaf)) { return @() }
  try {
    $data = Get-Content -LiteralPath $CustomModelsStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $values = if ($null -ne $data.models) { @($data.models) } else { @($data) }
    return @($values | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  } catch {
    return @()
  }
}

function Save-CustomModels([object[]]$Models) {
  $values = @($Models | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $payload = [ordered]@{ models=$values; updated_at=(Get-Date).ToString('o') }
  Write-Utf8NoBom $CustomModelsStatePath (($payload | ConvertTo-Json -Depth 10) + "`n")
  return $values
}

function Add-CustomModel([string]$Model) {
  $Model = ([string]$Model).Trim()
  if ([string]::IsNullOrWhiteSpace($Model)) { throw 'Custom model ID cannot be empty' }
  return @(Save-CustomModels (@((Get-CustomModels)) + $Model))
}

function Remove-CustomModel([string]$Model) {
  $Model = ([string]$Model).Trim()
  if ([string]::IsNullOrWhiteSpace($Model)) { throw 'Custom model ID cannot be empty' }
  return @(Save-CustomModels (@(Get-CustomModels) | Where-Object { $_ -ne $Model }))
}

function Ensure-ProviderPlusRelay() {
  $statusUrl = 'http://127.0.0.1:17856/api/status'
  try {
    $status = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri $statusUrl -TimeoutSec 2
    if ([bool]$status.ok) { return $status }
  } catch {}

  $relay = Join-Path $CodexHome 'provider-plus\relay.py'
  if (!(Test-Path -LiteralPath $relay -PathType Leaf)) { throw "Provider Plus relay not found: $relay" }
  $python = (Get-Command python.exe -ErrorAction Stop).Source
  Start-Process -FilePath $python -WindowStyle Hidden -ArgumentList @($relay,'--admin-port','17856','--relay-port','17857','--debug-port','19229','--no-browser') | Out-Null
  $deadline = (Get-Date).AddSeconds(12)
  do {
    Start-Sleep -Milliseconds 300
    try {
      $status = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri $statusUrl -TimeoutSec 2
      if ([bool]$status.ok) { return $status }
    } catch {}
  } while ((Get-Date) -lt $deadline)
  throw 'Provider Plus relay did not become ready on ports 17856/17857'
}

function Get-ProviderPlusStatusSafe() {
  try {
    $status = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/status' -TimeoutSec 2
    if ([bool]$status.ok) { return $status }
  } catch {}
  return $null
}

function Get-CodexAppServerState() {
  $items = @()
  try {
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object {
      $name = [string]$_.Name
      $commandLine = [string]$_.CommandLine
      if ($name -notmatch '(?i)^(?:codex|codex-stream-retry|codex-app-server).*\.exe$') { return }
      if ($commandLine -notmatch '(?i)(?:^|\s)app-server(?:\s|$)') { return }
      try {
        $process = Get-Process -Id ([int]$_.ProcessId) -ErrorAction Stop
        $items += [ordered]@{
          pid = [int]$_.ProcessId
          started_utc = $process.StartTime.ToUniversalTime()
        }
      } catch {}
    }
  } catch {}
  $latest = $null
  if (@($items).Count -gt 0) {
    $latest = @($items | Sort-Object started_utc -Descending | Select-Object -First 1)[0]
  }
  $configUpdatedUtc = $null
  if (Test-Path -LiteralPath $Config -PathType Leaf) {
    $configUpdatedUtc = (Get-Item -LiteralPath $Config).LastWriteTimeUtc
  }
  $reloadRequired = $false
  if ($null -ne $latest -and $null -ne $configUpdatedUtc) {
    $reloadRequired = $configUpdatedUtc -gt ([DateTime]$latest.started_utc).AddMilliseconds(250)
  }
  return [ordered]@{
    running = (@($items).Count -gt 0)
    process_ids = @($items | ForEach-Object { [int]$_.pid })
    started_at = $(if ($null -ne $latest) { ([DateTime]$latest.started_utc).ToString('o') } else { '' })
    config_updated_at = $(if ($null -ne $configUpdatedUtc) { $configUpdatedUtc.ToString('o') } else { '' })
    reload_required = [bool]$reloadRequired
  }
}

function Start-CodexDesktopRestart() {
  $tmpRoot = Join-Path $CodexHome '.tmp'
  New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
  $helper = Join-Path $tmpRoot ("configbox-restart-codex-{0}.ps1" -f ([Guid]::NewGuid().ToString('N')))
  $logPath = Join-Path $CodexHome 'configbox-codex-restart.log'
  $helperText = @'
param([string]$LogPath, [string]$SelfPath)
$ErrorActionPreference = 'Stop'
function Write-RestartLog([string]$Message) {
  Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}
try {
  Start-Sleep -Milliseconds 1200
  $targets = @(Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -like '*\WindowsApps\OpenAI.Codex_*' } catch { $false }
  })
  Write-RestartLog ("stopping Codex Desktop pids={0}" -f ((@($targets.Id) -join ',')))
  if ($targets) { $targets | Stop-Process -Force }
  $deadline = (Get-Date).AddSeconds(20)
  do {
    Start-Sleep -Milliseconds 300
    $alive = @(Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue | Where-Object {
      try { $_.Path -like '*\WindowsApps\OpenAI.Codex_*' } catch { $false }
    })
  } while ($alive.Count -gt 0 -and (Get-Date) -lt $deadline)
  $package = Get-AppxPackage -Name OpenAI.Codex | Select-Object -First 1
  if (-not $package) { throw 'OpenAI.Codex package is not installed' }
  $application = @(Get-AppxPackageManifest -Package $package).Package.Applications.Application | Select-Object -First 1
  $aumid = "$($package.PackageFamilyName)!$($application.Id)"
  Start-Process explorer.exe -ArgumentList "shell:AppsFolder\$aumid"
  Write-RestartLog ("relaunch requested via {0}" -f $aumid)
} catch {
  Write-RestartLog ("FAILED: {0}" -f $_.Exception.Message)
} finally {
  Start-Sleep -Milliseconds 500
  Remove-Item -LiteralPath $SelfPath -Force -ErrorAction SilentlyContinue
}
'@
  Write-Utf8NoBom $helper $helperText
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',("`"{0}`"" -f $helper),'-LogPath',("`"{0}`"" -f $logPath),'-SelfPath',("`"{0}`"" -f $helper)) | Out-Null
  return [ordered]@{ ok=$true; state='scheduled'; log=$logPath }
}

function Sync-ProviderPlusProfile([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$SlotName, [string]$Protocol) {
  Ensure-ProviderPlusRelay | Out-Null
  $safe = Convert-SlotName $(if ([string]::IsNullOrWhiteSpace($SlotName)) { 'current' } else { $SlotName })
  $normalizedProtocol = Normalize-UpstreamProtocol $Protocol
  $payload = [ordered]@{
    id = $safe
    name = $safe
    provider_type = 'configbox'
    protocol = $normalizedProtocol
    base_url = $BaseUrl
    api_key = $ApiKey
    model = $Model
  }
  if ($normalizedProtocol -eq 'anthropic') {
    # Anthropic Messages is served through Provider Plus so Codex can keep
    # wire_api=responses while the relay talks to /v1/messages upstream.
    $payload.transport = 'curl_cffi'
    $payload.impersonate = 'chrome'
    $payload.transport_retries = 3
    $payload.proxy_url = 'http://127.0.0.1:7890'
  }
  $json = $payload | ConvertTo-Json -Depth 10 -Compress
  Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/profile/save' -Method Post -ContentType 'application/json' -Body $json -TimeoutSec 10 | Out-Null
  return Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/apply' -Method Post -ContentType 'application/json' -Body (@{ id=$safe } | ConvertTo-Json -Compress) -TimeoutSec 15
}

function Start-NativePickerSync() {
  Ensure-ProviderPlusRelay | Out-Null
  $helperUrl = 'http://127.0.0.1:17856/codex-model-catalog'
  $catalog = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri $helperUrl -TimeoutSec 5
  $status = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/status' -TimeoutSec 5
  if (-not [bool]$status.native_injection) {
    $launch = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/enable-native-injection' -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 10
    return [ordered]@{
      ok=$true
      state='launching'
      helper_url=$helperUrl
      model_count=@($catalog.models).Count
      native_injection=$true
      message='Codex is restarting once with native model-menu injection enabled. The synchronized models will be visible after relaunch.'
      launch=$launch
    }
  }
  return [ordered]@{
    ok=$true
    state='refreshed'
    helper_url=$helperUrl
    model_count=@($catalog.models).Count
    native_injection=$true
    message='Provider Plus model catalog, models_cache.json, and the running Codex native picker are synchronized.'
  }
}

function Unescape-TomlBasicString([string]$Value) {
  if ($null -eq $Value) { return '' }
  $result = [Text.StringBuilder]::new()
  for ($i = 0; $i -lt $Value.Length; $i++) {
    if ($Value[$i] -ne '\' -or $i + 1 -ge $Value.Length) {
      [void]$result.Append($Value[$i])
      continue
    }

    $i++
    $escaped = $Value[$i]
    switch ($escaped) {
      '"' { [void]$result.Append('"'); continue }
      '\' { [void]$result.Append('\'); continue }
      'b' { [void]$result.Append([char]8); continue }
      't' { [void]$result.Append("`t"); continue }
      'n' { [void]$result.Append("`n"); continue }
      'f' { [void]$result.Append([char]12); continue }
      'r' { [void]$result.Append("`r"); continue }
      { $_ -eq 'u' -or $_ -eq 'U' } {
        $digits = if ($escaped -eq 'u') { 4 } else { 8 }
        if ($i + $digits -lt $Value.Length) {
          $hex = $Value.Substring($i + 1, $digits)
          $codePoint = 0
          if ([int]::TryParse($hex, [Globalization.NumberStyles]::HexNumber, [Globalization.CultureInfo]::InvariantCulture, [ref]$codePoint) -and
              $codePoint -le 0x10ffff -and ($codePoint -lt 0xd800 -or $codePoint -gt 0xdfff)) {
            [void]$result.Append([char]::ConvertFromUtf32($codePoint))
            $i += $digits
            continue
          }
        }
        [void]$result.Append('\').Append($escaped)
        continue
      }
      default { [void]$result.Append('\').Append($escaped) }
    }
  }
  return $result.ToString()
}

function Normalize-ModelInstructionsPath([string]$Value) {
  $path = ([string]$Value).Trim()
  if ([string]::IsNullOrWhiteSpace($path)) { return '' }
  try {
    if ([IO.Path]::IsPathRooted($path)) { return [IO.Path]::GetFullPath($path) }
  } catch {}
  return $path
}


function Get-CustomInstructionPaths() {
  if (!(Test-Path -LiteralPath $InstructionsPathsStatePath -PathType Leaf)) { return @() }
  try {
    $data = Get-Content -LiteralPath $InstructionsPathsStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $values = if ($null -ne $data.paths) { @($data.paths) } else { @($data) }
    return @($values | ForEach-Object { Normalize-ModelInstructionsPath ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  } catch {
    return @()
  }
}

function Save-CustomInstructionPaths([object[]]$Paths) {
  $values = @($Paths | ForEach-Object { Normalize-ModelInstructionsPath ([string]$_) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
  $payload = [ordered]@{ paths=$values; updated_at=(Get-Date).ToString('o') }
  Write-Utf8NoBom $InstructionsPathsStatePath (($payload | ConvertTo-Json -Depth 10) + "`n")
  return $values
}

function Add-CustomInstructionPath([string]$Path) {
  $Path = Normalize-ModelInstructionsPath $Path
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'model_instructions_file path cannot be empty' }
  if (-not ($Path.ToLowerInvariant().EndsWith('.md'))) { throw 'model_instructions_file should be a .md file' }
  return @(Save-CustomInstructionPaths (@((Get-CustomInstructionPaths)) + $Path))
}

function Remove-CustomInstructionPath([string]$Path) {
  $Path = Normalize-ModelInstructionsPath $Path
  if ([string]::IsNullOrWhiteSpace($Path)) { throw 'model_instructions_file path cannot be empty' }
  return @(Save-CustomInstructionPaths (@(Get-CustomInstructionPaths) | Where-Object { $_ -ne $Path }))
}

function Get-TopLevelString([string]$Text, [string]$Name) {
  $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*(?:"((?:\\.|[^"\\])*)"|''([^'']*)'')\s*$'
  $m = [regex]::Match($Text, $pattern)
  if ($m.Success) {
    if ($m.Groups[1].Success) { return Unescape-TomlBasicString $m.Groups[1].Value }
    return $m.Groups[2].Value
  }
  return ''
}

function Remove-TopLevelString([string]$Text, [string]$Name) {
  $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*(?:"(?:\\.|[^"\\])*"|''[^'']*'')\s*(?:\r?\n|$)'
  return [regex]::Replace($Text, $pattern, '', 1)
}

function Get-ModelInstructionsSettings([string]$ConfigText = '') {
  if ([string]::IsNullOrWhiteSpace($ConfigText) -and (Test-Path $Config)) {
    $ConfigText = Get-Content $Config -Raw -Encoding UTF8
  }
  $configuredPath = Normalize-ModelInstructionsPath (Get-TopLevelString $ConfigText 'model_instructions_file')
  $stored = Read-JsonHashtable $InstructionsStatePath
  $storedPath = if ($stored.Contains('path')) { Normalize-ModelInstructionsPath ([string]$stored['path']) } else { '' }
  return [ordered]@{
    enabled = -not [string]::IsNullOrWhiteSpace($configuredPath)
    path = if (-not [string]::IsNullOrWhiteSpace($configuredPath)) { $configuredPath } else { $storedPath }
  }
}

function Set-ModelInstructions([string]$Text, [Nullable[bool]]$Enabled, [string]$Path) {
  $current = Get-ModelInstructionsSettings $Text
  if ($null -eq $Enabled) { $Enabled = [bool]$current.enabled }
  if ([string]::IsNullOrWhiteSpace($Path)) { $Path = [string]$current.path }
  $Path = Normalize-ModelInstructionsPath $Path
  if ($Enabled -and [string]::IsNullOrWhiteSpace($Path)) { throw 'model_instructions_file path cannot be empty when loading is enabled' }
  $updated = if ($Enabled) { Set-TopLevelString $Text 'model_instructions_file' $Path } else { Remove-TopLevelString $Text 'model_instructions_file' }
  Write-Utf8NoBom $InstructionsStatePath (([ordered]@{ enabled=[bool]$Enabled; path=$Path } | ConvertTo-Json -Depth 10) + "`n")
  return $updated
}

function Get-ProfileModel([string]$Text) {
  $profile = Get-ProfileBlock $Text
  $model = Get-Field $profile 'model'
  if (-not [string]::IsNullOrWhiteSpace($model)) { return $model }
  $rootModel = Get-RootString $Text 'model'
  if (-not [string]::IsNullOrWhiteSpace($rootModel)) { return $rootModel }
  return 'gpt-5.5'
}

function Set-TopLevelString([string]$Text, [string]$Name, [string]$Value) {
  $escaped = Escape-TomlBasicString $Value
  $pattern = '(?m)^' + [regex]::Escape($Name) + '\s*=\s*(?:"(?:\\.|[^"\\])*"|''[^'']*'')\s*$'
  $line = "$Name = `"$escaped`""
  if ([regex]::IsMatch($Text, $pattern)) {
    return [regex]::Replace($Text, $pattern, $line, 1)
  }
  return $line + "`r`n" + $Text
}

function Escape-TomlBasicString([string]$Value) {
  if ($null -eq $Value) { return '' }
  return $Value.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n')
}

function Mask-Secret([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '[empty]' }
  if ($Value.Length -le 10) { return '[set]' }
  return $Value.Substring(0, 6) + '...' + $Value.Substring($Value.Length - 4)
}

function Get-CurrentApiKey([string]$ConfigText = '') {
  $key = ''
  if (-not [string]::IsNullOrWhiteSpace($ConfigText)) {
    $key = Get-Field (Get-ProviderBlock $ConfigText) 'api_key'
  }
  if ([string]::IsNullOrWhiteSpace($key)) {
    $authObj = Read-JsonHashtable $Auth
    if ($authObj.Contains('OPENAI_API_KEY')) { $key = [string]$authObj['OPENAI_API_KEY'] }
  }
  return $key
}

function Ensure-CodexProviderEnvironment([string]$ApiKey) {
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    [Environment]::SetEnvironmentVariable('OPENAI_API_KEY', $ApiKey, 'User')
  }
  $noProxy = '127.0.0.1,localhost,::1,0.0.0.0,host.docker.internal'
  [Environment]::SetEnvironmentVariable('NO_PROXY', $noProxy, 'User')
  [Environment]::SetEnvironmentVariable('no_proxy', $noProxy, 'User')
}
function Sync-ApiKeyAuth([string]$ApiKey) {
  $authObj = Read-JsonHashtable $Auth
  $authObj['OPENAI_API_KEY'] = $ApiKey
  $authObj['auth_mode'] = 'apikey'
  Write-Utf8NoBom $Auth (($authObj | ConvertTo-Json -Depth 20) + "`n")
  Ensure-CodexProviderEnvironment $ApiKey
}

function Resolve-ApiKey([string]$ApiKey, [string]$SlotName = '', [string]$ConfigText = '') {
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { return $ApiKey }
  if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    $safe = Convert-SlotName $SlotName
    $provider = Join-Path $ProviderRoot "$safe\provider.toml"
    $ptext = if (Test-Path $provider) { Get-Content $provider -Raw -Encoding UTF8 } else { '' }
    $slotKey = Get-SlotApiKey $safe $ptext
    if (-not [string]::IsNullOrWhiteSpace($slotKey)) { return $slotKey }
  }
  if ([string]::IsNullOrWhiteSpace($ConfigText) -and (Test-Path $Config)) {
    $ConfigText = Get-Content $Config -Raw -Encoding UTF8
  }
  return Get-CurrentApiKey $ConfigText
}

function Convert-SlotName([string]$Name) {
  return ($Name -replace '[^a-zA-Z0-9_.-]', '_')
}

function Assert-UnderRoot([string]$Root, [string]$Path) {
  $rootFull = (Remove-TrailingBackslash ([IO.Path]::GetFullPath($Root))) + '\'
  $pathFull = (Remove-TrailingBackslash ([IO.Path]::GetFullPath($Path))) + '\'
  if (-not $pathFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to modify path outside expected root: $Path"
  }
}

function Remove-TrailingBackslash([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return [regex]::Replace([string]$Value, '\\+$', '')
}

function Remove-TrailingForwardSlash([string]$Value) {
  if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
  return [regex]::Replace(([string]$Value).Trim(), '/+$', '')
}

function Build-Headers([string]$ApiKey) {
  $headers = @{
    'User-Agent' = 'codex-provider-ui/2.0'
    'Content-Type' = 'application/json'
  }
  if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
    $headers['Authorization'] = "Bearer $ApiKey"
  }
  return $headers
}



function Invoke-WebRequest {
  # codex-provider-ui curl compatibility: Windows PowerShell's HttpWebRequest can be routed to openresty 503 by some upstreams.
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [hashtable]$Headers = @{},
    [string]$Method = 'GET',
    $Body = $null,
    [int]$TimeoutSec = 100,
    [switch]$UseBasicParsing
  )

  $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
  if ($null -eq $curl) {
    $params = @{
      Uri = $Uri
      Headers = $Headers
      Method = $Method
      TimeoutSec = $TimeoutSec
      UseBasicParsing = $true
    }
    if ($null -ne $Body) { $params['Body'] = $Body }
    return Microsoft.PowerShell.Utility\Invoke-WebRequest @params
  }

  $bodyFile = [IO.Path]::GetTempFileName()
  $headerFile = [IO.Path]::GetTempFileName()
  $payloadFile = $null
  try {
    $connectTimeout = [Math]::Min([Math]::Max($TimeoutSec, 1), 15)
    $curlArgs = @(
      '--silent',
      '--show-error',
      '--location',
      '--connect-timeout', [string]$connectTimeout,
      '--max-time', [string]$TimeoutSec,
      '-D', $headerFile,
      '-o', $bodyFile,
      '-X', $Method.ToUpperInvariant()
    )

    foreach ($key in $Headers.Keys) {
      $value = [string]$Headers[$key]
      if (-not [string]::IsNullOrWhiteSpace($value)) {
        $curlArgs += @('-H', "${key}: $value")
      }
    }

    if ($null -ne $Body) {
      $payloadFile = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($payloadFile, [string]$Body, [Text.UTF8Encoding]::new($false))
      $curlArgs += @('--data-binary', "@$payloadFile")
    }

    $curlArgs += $Uri
    & $curl.Source @curlArgs | Out-Null
    $exitCode = $LASTEXITCODE

    $content = if (Test-Path -LiteralPath $bodyFile) { Get-Content -LiteralPath $bodyFile -Raw -Encoding UTF8 } else { '' }
    $headerText = if (Test-Path -LiteralPath $headerFile) { Get-Content -LiteralPath $headerFile -Raw -Encoding UTF8 } else { '' }
    $statusMatches = [regex]::Matches($headerText, '(?m)^HTTP/\S+\s+(\d{3})\b')
    $statusCode = 0
    if ($statusMatches.Count -gt 0) {
      $statusCode = [int]$statusMatches[$statusMatches.Count - 1].Groups[1].Value
    }

    if ($exitCode -ne 0 -or $statusCode -ge 400 -or $statusCode -eq 0) {
      throw "HTTP_STATUS=$statusCode`n$content"
    }

    return [pscustomobject]@{
      StatusCode = $statusCode
      Content = $content
    }
  } finally {
    foreach ($path in @($bodyFile, $headerFile, $payloadFile)) {
      if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
      }
    }
  }
}




function Get-Prop($Obj, [string]$Name, $Default = $null) {
  if ($null -eq $Obj) { return $Default }
  if ($Obj -is [Collections.IDictionary]) {
    if ($Obj.Contains($Name)) { return $Obj[$Name] }
    return $Default
  }
  $prop = $Obj.PSObject.Properties[$Name]
  if ($null -ne $prop) { return $prop.Value }
  return $Default
}

function Get-AdapterBaseUrl() {
  return "http://127.0.0.1:$Port/v1"
}

function Read-AdapterState() {
  if (!(Test-Path $AdapterStatePath)) { return [ordered]@{} }
  return Read-JsonHashtable $AdapterStatePath
}

function Write-AdapterState([string]$UpstreamBaseUrl, [string]$ApiKey, [string]$Model, [string]$SlotName) {
  $state = [ordered]@{
    upstream_protocol = 'chat'
    upstream_base_url = (Remove-TrailingForwardSlash $UpstreamBaseUrl)
    api_key = $ApiKey
    model = $Model
    slot = $SlotName
    adapter_base_url = (Get-AdapterBaseUrl)
    updated_at = (Get-Date).ToString('o')
  }
  Write-Utf8NoBom $AdapterStatePath (($state | ConvertTo-Json -Depth 20) + "`n")
}

function Get-AdapterRequestApiKey($State) {
  try {
    $auth = [string]$script:ctx.Request.Headers['Authorization']
    if ($auth -match '^Bearer\s+(.+)$') { return $Matches[1] }
  } catch {}
  return [string](Get-Prop $State 'api_key' '')
}

function Get-ContentText($Content) {
  if ($null -eq $Content) { return '' }
  if ($Content -is [string]) { return $Content }
  $parts = New-Object Collections.Generic.List[string]
  if ($Content -is [System.Collections.IEnumerable]) {
    foreach ($part in $Content) {
      if ($null -eq $part) { continue }
      if ($part -is [string]) {
        $parts.Add($part)
        continue
      }
      $text = Get-Prop $part 'text' ''
      if ([string]::IsNullOrWhiteSpace($text)) { $text = Get-Prop $part 'output_text' '' }
      if ([string]::IsNullOrWhiteSpace($text)) { $text = Get-Prop $part 'input_text' '' }
      if (-not [string]::IsNullOrWhiteSpace($text)) { $parts.Add([string]$text) }
    }
    return ($parts -join "`n")
  }
  return ($Content | ConvertTo-Json -Depth 20 -Compress)
}

function Convert-ResponsesInputToChatMessages($Body) {
  $messages = [Collections.ArrayList]::new()
  $instructions = Get-Prop $Body 'instructions' ''
  if (-not [string]::IsNullOrWhiteSpace($instructions)) {
    [void]$messages.Add([ordered]@{ role='system'; content=[string]$instructions })
  }
  $input = Get-Prop $Body 'input' ''
  if ($input -is [string]) {
    if (-not [string]::IsNullOrWhiteSpace($input)) {
      [void]$messages.Add([ordered]@{ role='user'; content=$input })
    }
    return @($messages)
  }
  if ($input -is [System.Collections.IEnumerable]) {
    foreach ($item in $input) {
      if ($null -eq $item) { continue }
      $type = [string](Get-Prop $item 'type' '')
      if ($type -eq 'function_call_output') {
        [void]$messages.Add([ordered]@{
          role='tool'
          tool_call_id=[string](Get-Prop $item 'call_id' (Get-Prop $item 'id' ''))
          content=(Get-ContentText (Get-Prop $item 'output' ''))
        })
        continue
      }
      $role = [string](Get-Prop $item 'role' 'user')
      if ($role -eq 'developer') { $role = 'system' }
      if ($role -notin @('system','user','assistant','tool')) { $role = 'user' }
      $content = Get-ContentText (Get-Prop $item 'content' $item)
      $msg = [ordered]@{ role=$role; content=$content }
      $toolCallId = Get-Prop $item 'tool_call_id' ''
      if ($role -eq 'tool' -and -not [string]::IsNullOrWhiteSpace($toolCallId)) { $msg['tool_call_id'] = [string]$toolCallId }
      [void]$messages.Add($msg)
    }
  }
  if ($messages.Count -eq 0) {
    [void]$messages.Add([ordered]@{ role='user'; content='Continue.' })
  }
  return @($messages)
}

function Convert-ResponsesToolsToChatTools($Body) {
  $tools = Get-Prop $Body 'tools' $null
  if ($null -eq $tools) { return @() }
  $out = [Collections.ArrayList]::new()
  foreach ($tool in @($tools)) {
    if ($null -eq $tool) { continue }
    $type = [string](Get-Prop $tool 'type' '')
    $fn = Get-Prop $tool 'function' $null
    if ($type -eq 'function' -and $null -ne $fn) {
      [void]$out.Add($tool)
      continue
    }
    $name = [string](Get-Prop $tool 'name' '')
    if ([string]::IsNullOrWhiteSpace($name)) { continue }
    $desc = [string](Get-Prop $tool 'description' '')
    $params = Get-Prop $tool 'parameters' $null
    if ($null -eq $params) { $params = [ordered]@{ type='object'; properties=[ordered]@{} } }
    [void]$out.Add([ordered]@{
      type='function'
      function=[ordered]@{
        name=$name
        description=$desc
        parameters=$params
      }
    })
  }
  return @($out)
}

function Invoke-ChatForResponses($Body, $State) {
  $upstream = Remove-TrailingForwardSlash ([string](Get-Prop $State 'upstream_base_url' ''))
  if ([string]::IsNullOrWhiteSpace($upstream)) { throw 'No active Chat Completions adapter upstream. Apply a chat slot first.' }
  $model = [string](Get-Prop $Body 'model' (Get-Prop $State 'model' ''))
  if ([string]::IsNullOrWhiteSpace($model)) { $model = [string](Get-Prop $State 'model' 'gpt-5.5') }
  $payload = [ordered]@{
    model=$model
    messages=(Convert-ResponsesInputToChatMessages $Body)
    stream=$false
  }
  $maxTokens = Get-Prop $Body 'max_output_tokens' (Get-Prop $Body 'max_tokens' $null)
  if ($null -ne $maxTokens) { $payload['max_tokens'] = $maxTokens }
  foreach ($k in @('temperature','top_p','presence_penalty','frequency_penalty','seed','stop')) {
    $v = Get-Prop $Body $k $null
    if ($null -ne $v) { $payload[$k] = $v }
  }
  $tools = @(Convert-ResponsesToolsToChatTools $Body)
  if ($tools.Count -gt 0) {
    $payload['tools'] = $tools
    $toolChoice = Get-Prop $Body 'tool_choice' $null
    if ($null -ne $toolChoice) { $payload['tool_choice'] = $toolChoice }
    $parallelToolCalls = Get-Prop $Body 'parallel_tool_calls' $null
    if ($null -ne $parallelToolCalls) { $payload['parallel_tool_calls'] = $parallelToolCalls }
  }
  $json = $payload | ConvertTo-Json -Depth 80 -Compress
  $apiKey = Get-AdapterRequestApiKey $State
  $uri = "$upstream/chat/completions"
  $resp = Invoke-WebRequest -Uri $uri -Headers (Build-Headers $apiKey) -Method POST -Body $json -TimeoutSec 600 -UseBasicParsing -ErrorAction Stop
  return ($resp.Content | ConvertFrom-Json)
}

function Convert-ChatCompletionToResponse($Chat, [string]$Model) {
  $choice = $null
  try { $choice = $Chat.choices[0] } catch {}
  $message = Get-Prop $choice 'message' $null
  $content = [string](Get-Prop $message 'content' '')
  $toolCalls = Get-Prop $message 'tool_calls' $null
  $output = [Collections.ArrayList]::new()
  foreach ($tc in @($toolCalls)) {
    if ($null -eq $tc) { continue }
    $fn = Get-Prop $tc 'function' $null
    [void]$output.Add([ordered]@{
      type='function_call'
      id=[string](Get-Prop $tc 'id' ('fc_' + [guid]::NewGuid().ToString('N')))
      call_id=[string](Get-Prop $tc 'id' ('call_' + [guid]::NewGuid().ToString('N')))
      name=[string](Get-Prop $fn 'name' '')
      arguments=[string](Get-Prop $fn 'arguments' '{}')
      status='completed'
    })
  }
  if (-not [string]::IsNullOrWhiteSpace($content) -or $output.Count -eq 0) {
    [void]$output.Add([ordered]@{
      type='message'
      id=('msg_' + [guid]::NewGuid().ToString('N'))
      role='assistant'
      status='completed'
      content=@([ordered]@{ type='output_text'; text=$content })
    })
  }
  $created = Get-Prop $Chat 'created' ([int][double]::Parse((Get-Date -UFormat %s)))
  return [ordered]@{
    id=('resp_' + [string](Get-Prop $Chat 'id' ([guid]::NewGuid().ToString('N'))))
    object='response'
    created_at=$created
    status='completed'
    model=$Model
    output=@($output)
    output_text=$content
    usage=(Get-Prop $Chat 'usage' $null)
  }
}

function Write-SseJsonEvent([string]$Event, $Data) {
  $json = $Data | ConvertTo-Json -Depth 80 -Compress
  $bytes = [Text.Encoding]::UTF8.GetBytes("event: $Event`ndata: $json`n`n")
  $script:ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  $script:ctx.Response.OutputStream.Flush()
}

function Write-ResponsesStream($ResponseObj) {
  $res = $script:ctx.Response
  $res.StatusCode = 200
  $res.ContentType = 'text/event-stream; charset=utf-8'
  $res.Headers['Cache-Control'] = 'no-cache'
  Write-SseJsonEvent 'response.created' ([ordered]@{ type='response.created'; response=[ordered]@{ id=$ResponseObj.id; object='response'; status='in_progress'; model=$ResponseObj.model } })
  $idx = 0
  foreach ($item in @($ResponseObj.output)) {
    if ($item.type -eq 'message') {
      $text = ''
      try { $text = [string]$item.content[0].text } catch {}
      Write-SseJsonEvent 'response.output_item.added' ([ordered]@{ type='response.output_item.added'; output_index=$idx; item=[ordered]@{ id=$item.id; type='message'; role='assistant'; status='in_progress' } })
      Write-SseJsonEvent 'response.content_part.added' ([ordered]@{ type='response.content_part.added'; output_index=$idx; content_index=0; part=[ordered]@{ type='output_text'; text='' } })
      if (-not [string]::IsNullOrEmpty($text)) {
        Write-SseJsonEvent 'response.output_text.delta' ([ordered]@{ type='response.output_text.delta'; output_index=$idx; content_index=0; delta=$text })
      }
      Write-SseJsonEvent 'response.output_text.done' ([ordered]@{ type='response.output_text.done'; output_index=$idx; content_index=0; text=$text })
      Write-SseJsonEvent 'response.content_part.done' ([ordered]@{ type='response.content_part.done'; output_index=$idx; content_index=0; part=[ordered]@{ type='output_text'; text=$text } })
      Write-SseJsonEvent 'response.output_item.done' ([ordered]@{ type='response.output_item.done'; output_index=$idx; item=$item })
    } else {
      Write-SseJsonEvent 'response.output_item.added' ([ordered]@{ type='response.output_item.added'; output_index=$idx; item=$item })
      Write-SseJsonEvent 'response.output_item.done' ([ordered]@{ type='response.output_item.done'; output_index=$idx; item=$item })
    }
    $idx++
  }
  Write-SseJsonEvent 'response.completed' ([ordered]@{ type='response.completed'; response=$ResponseObj })
  $res.Close()
}

function Handle-AdapterModels() {
  $state = Read-AdapterState
  $upstream = Remove-TrailingForwardSlash ([string](Get-Prop $state 'upstream_base_url' ''))
  if ([string]::IsNullOrWhiteSpace($upstream)) {
    Json ([ordered]@{ error=[ordered]@{ message='No active Chat Completions adapter upstream. Apply a chat slot first.' } }) 503
    return
  }
  try {
    $resp = Invoke-WebRequest -Uri "$upstream/models" -Headers (Build-Headers (Get-AdapterRequestApiKey $state)) -Method GET -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
    $script:ctx.Response.StatusCode = [int]$resp.StatusCode
    Text $resp.Content 'application/json; charset=utf-8'
  } catch {
    $code = Get-HttpStatusCode $_
    if ($code -le 0) { $code = 502 }
    Json ([ordered]@{ error=[ordered]@{ message=(ShortText (Read-HttpErrorText $_)); type='adapter_upstream_error' } }) $code
  }
}

function Handle-AdapterResponses() {
  try {
    $body = Read-BodyJson
    $state = Read-AdapterState
    $chat = Invoke-ChatForResponses $body $state
    $model = [string](Get-Prop $body 'model' (Get-Prop $state 'model' 'gpt-5.5'))
    $responseObj = Convert-ChatCompletionToResponse $chat $model
    $stream = [bool](Get-Prop $body 'stream' $false)
    if ($stream) {
      Write-ResponsesStream $responseObj
    } else {
      Json $responseObj
    }
  } catch {
    $code = Get-HttpStatusCode $_
    if ($code -le 0) { $code = 502 }
    Json ([ordered]@{ error=[ordered]@{ message=(ShortText (Read-HttpErrorText $_)); type='adapter_upstream_error' } }) $code
  }
}

function Get-BaseUrlCandidates([string]$BaseUrl) {
  $base = Remove-TrailingForwardSlash $BaseUrl
  if ([string]::IsNullOrWhiteSpace($base)) { return @() }
  $items = @($base)
  if (-not $base.EndsWith('/v1', [StringComparison]::OrdinalIgnoreCase)) {
    $items += ($base + '/v1')
  }
  return @($items | Select-Object -Unique)
}

function Get-SuggestedBaseUrl([string]$Candidate, [string]$Original) {
  $candidateBase = Remove-TrailingForwardSlash $Candidate
  $originalBase = Remove-TrailingForwardSlash $Original
  if ($candidateBase -ne $originalBase) { return $candidateBase }
  return ''
}

function Read-HttpErrorText($ErrorRecord) {
  $parts = @()
  if ($null -ne $ErrorRecord.Exception.Message) { $parts += [string]$ErrorRecord.Exception.Message }
  try {
    $resp = $ErrorRecord.Exception.Response
    if ($resp -and $resp.GetResponseStream) {
      $stream = $resp.GetResponseStream()
      if ($stream) {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8)
        $body = $reader.ReadToEnd()
        if (-not [string]::IsNullOrWhiteSpace($body)) { $parts += $body }
      }
    }
  } catch {}
  try {
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
      $parts += [string]$ErrorRecord.ErrorDetails.Message
    }
  } catch {}
  return ($parts -join "`n")
}

function Get-HttpStatusCode($ErrorRecord) {
  try {
    if ($ErrorRecord.Exception.Response) { return [int]$ErrorRecord.Exception.Response.StatusCode }
  } catch {}
  try {
    $m = [regex]::Match([string]$ErrorRecord.Exception.Message, 'HTTP_STATUS=(\d{3})')
    if ($m.Success) { return [int]$m.Groups[1].Value }
  } catch {}
  return 0
}

function ShortText([string]$Text, [int]$Max = 700) {
  if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
  return $Text.Substring(0, [Math]::Min($Max, $Text.Length))
}

function Extract-AvailableModels([string]$Text) {
  $models = @()
  if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
  $message = $Text
  try {
    $obj = $Text | ConvertFrom-Json
    if ($null -ne $obj.error.message) { $message = [string]$obj.error.message }
    elseif ($null -ne $obj.message) { $message = [string]$obj.message }
  } catch {}

  $patterns = @(
    'available\s+models?\s*[:\uff1a]\s*(.+)$',
    'supported\s+models?\s*[:\uff1a]\s*(.+)$',
    '\u53ef\u7528\u6a21\u578b\s*[:\uff1a]\s*(.+)$',
    '\u652f\u6301\u7684\u6a21\u578b\s*[:\uff1a]\s*(.+)$'
  )
  foreach ($pattern in $patterns) {
    $m = [regex]::Match($message, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (!$m.Success) { continue }
    $tail = $m.Groups[1].Value
    $tail = [regex]::Replace($tail, '[\r\n].*$', '')
    $tail = [regex]::Replace($tail, '[\u3002].*$', '')
    foreach ($item in ($tail -split '\s*/\s*|[,;\uFF0C\u3001\uFF1B]|\s+\|\s+')) {
      $v = [regex]::Replace($item, '^[\s"'':\uFF1A/]+|[\s"'':\uFF1A/]+$', '')
      if ($v -match '^[A-Za-z0-9][A-Za-z0-9._:/-]*$') { $models += $v }
    }
  }
  return @($models | Sort-Object -Unique)
}

function Extract-ModelsFromJson($Body) {
  $models = @()
  if ($null -eq $Body) { return @() }
  if ($null -ne $Body.data) {
    foreach ($item in @($Body.data)) {
      if ($item -is [string]) { $models += $item; continue }
      if ($null -ne $item.id -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) { $models += [string]$item.id; continue }
      if ($null -ne $item.name -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) { $models += [string]$item.name; continue }
    }
  } elseif ($null -ne $Body.models) {
    foreach ($item in @($Body.models)) {
      if ($item -is [string]) { $models += $item; continue }
      if ($null -ne $item.id -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) { $models += [string]$item.id; continue }
      if ($null -ne $item.name -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) { $models += [string]$item.name; continue }
    }
  } elseif ($Body -is [array]) {
    foreach ($item in @($Body)) {
      if ($item -is [string]) { $models += $item; continue }
      if ($null -ne $item.id -and -not [string]::IsNullOrWhiteSpace([string]$item.id)) { $models += [string]$item.id; continue }
      if ($null -ne $item.name -and -not [string]::IsNullOrWhiteSpace([string]$item.name)) { $models += [string]$item.name; continue }
    }
  }
  return @($models | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Invoke-ProviderGetModels([string]$BaseUrl, [string]$ApiKey) {
  $candidates = @(Get-BaseUrlCandidates $BaseUrl)
  if ($candidates.Count -eq 0) { return @{ ok=$false; error='Base URL is empty'; models=@() } }
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $base = [string]$candidates[$i]
    try {
      $uri = (Remove-TrailingForwardSlash $base) + '/models'
      $resp = Invoke-WebRequest -Uri $uri -Headers (Build-Headers $ApiKey) -Method GET -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
      $body = $resp.Content | ConvertFrom-Json
      $models = @(Extract-ModelsFromJson $body)
      return @{
        ok=$true
        status=[int]$resp.StatusCode
        source='models_endpoint'
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        count=$models.Count
        models=$models
      }
    } catch {
      $code = Get-HttpStatusCode $_
      if ($code -eq 404 -and $i -lt ($candidates.Count - 1)) { continue }
      $errText = Read-HttpErrorText $_
      $models = @(Extract-AvailableModels $errText)
      return @{
        ok=($models.Count -gt 0)
        status=$code
        source='models_error'
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        error=(ShortText $errText)
        count=$models.Count
        models=$models
      }
    }
  }
}

function Probe-ResponsesModels([string]$BaseUrl, [string]$ApiKey) {
  $candidates = @(Get-BaseUrlCandidates $BaseUrl)
  if ($candidates.Count -eq 0) { return @{ ok=$false; error='Base URL is empty'; models=@() } }
  $payload = @{
    model='__codex_provider_ui_probe__'
    input='probe'
    max_output_tokens=1
  } | ConvertTo-Json -Depth 20 -Compress
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $base = [string]$candidates[$i]
    try {
      $uri = (Remove-TrailingForwardSlash $base) + '/responses'
      $resp = Invoke-WebRequest -Uri $uri -Headers (Build-Headers $ApiKey) -Method POST -Body $payload -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
      return @{
        ok=$true
        status=[int]$resp.StatusCode
        source='responses_probe_success'
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        count=0
        models=@()
        preview=(ShortText $resp.Content 500)
      }
    } catch {
      $code = Get-HttpStatusCode $_
      if ($code -eq 404 -and $i -lt ($candidates.Count - 1)) { continue }
      $errText = Read-HttpErrorText $_
      $models = @(Extract-AvailableModels $errText)
      return @{
        ok=($models.Count -gt 0)
        status=$code
        source='responses_error'
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        error=(ShortText $errText)
        count=$models.Count
        models=$models
      }
    }
  }
}

function Test-Responses([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
  if ([string]::IsNullOrWhiteSpace($Model)) { return @{ ok=$false; error='Model is empty' } }
  $candidates = @(Get-BaseUrlCandidates $BaseUrl)
  if ($candidates.Count -eq 0) { return @{ ok=$false; error='Base URL is empty' } }
  $payload = @{
    model=$Model
    input='Reply with OK.'
    max_output_tokens=16
  } | ConvertTo-Json -Depth 20 -Compress
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $base = [string]$candidates[$i]
    try {
      $uri = (Remove-TrailingForwardSlash $base) + '/responses'
      $resp = Invoke-WebRequest -Uri $uri -Headers (Build-Headers $ApiKey) -Method POST -Body $payload -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
      return @{
        ok=$true
        status=[int]$resp.StatusCode
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        preview=(ShortText $resp.Content 700)
      }
    } catch {
      $code = Get-HttpStatusCode $_
      if ($code -eq 404 -and $i -lt ($candidates.Count - 1)) { continue }
      $errText = Read-HttpErrorText $_
      $models = @(Extract-AvailableModels $errText)
      return @{
        ok=$false
        status=$code
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        error=(ShortText $errText)
        models=$models
      }
    }
  }
}

function Test-ChatCompletions([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
  if ([string]::IsNullOrWhiteSpace($Model)) { return @{ ok=$false; error='Model is empty' } }
  $candidates = @(Get-BaseUrlCandidates $BaseUrl)
  if ($candidates.Count -eq 0) { return @{ ok=$false; error='Base URL is empty' } }
  $payload = @{
    model=$Model
    messages=@(@{ role='user'; content='Reply with OK.' })
    max_tokens=16
    stream=$false
  } | ConvertTo-Json -Depth 20 -Compress
  for ($i = 0; $i -lt $candidates.Count; $i++) {
    $base = [string]$candidates[$i]
    try {
      $uri = (Remove-TrailingForwardSlash $base) + '/chat/completions'
      $resp = Invoke-WebRequest -Uri $uri -Headers (Build-Headers $ApiKey) -Method POST -Body $payload -TimeoutSec 30 -UseBasicParsing -ErrorAction Stop
      return @{
        ok=$true
        status=[int]$resp.StatusCode
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        preview=(ShortText $resp.Content 700)
        note='Chat Completions test only. Current Codex builds still require wire_api = "responses" for provider config.'
      }
    } catch {
      $code = Get-HttpStatusCode $_
      if ($code -eq 404 -and $i -lt ($candidates.Count - 1)) { continue }
      $errText = Read-HttpErrorText $_
      $models = @(Extract-AvailableModels $errText)
      return @{
        ok=$false
        status=$code
        base_url=$base
        suggested_base_url=(Get-SuggestedBaseUrl $base $BaseUrl)
        error=(ShortText $errText)
        models=$models
        note='Chat Completions test only. To use this upstream from Codex, expose a Responses-compatible adapter.'
      }
    }
  }
}

function Test-AnthropicMessages([string]$BaseUrl, [string]$ApiKey, [string]$Model) {
  if ([string]::IsNullOrWhiteSpace($Model)) { return @{ ok=$false; error='Model is empty' } }
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) { return @{ ok=$false; error='Base URL is empty' } }
  Ensure-ProviderPlusRelay | Out-Null
  $payload = [ordered]@{
    name = 'configbox-messages-test'
    provider_type = 'configbox-test'
    protocol = 'anthropic'
    base_url = $BaseUrl
    api_key = $ApiKey
    model = $Model
    transport = 'curl_cffi'
    impersonate = 'chrome'
    transport_retries = 3
    proxy_url = 'http://127.0.0.1:7890'
  }
  try {
    return Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri 'http://127.0.0.1:17856/api/test' -Method Post -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 20 -Compress) -TimeoutSec 120
  } catch {
    return @{ ok=$false; error=(Read-HttpErrorText $_) }
  }
}

function Set-CustomProvider([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$SlotName = '', [string]$UpstreamProtocol = 'responses', [object]$InstructionsEnabled = $null, [string]$InstructionsPath = '') {
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw 'Base URL cannot be empty' }
  if ([string]::IsNullOrWhiteSpace($Model)) { $Model = 'gpt-5.5' }
  $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
  if (Test-Path $Config) { Copy-Item -LiteralPath $Config -Destination "$Config.bak.ui-$ts" -Force }
  if (Test-Path $Auth) { Copy-Item -LiteralPath $Auth -Destination "$Auth.bak.ui-$ts" -Force }
  $text = if (Test-Path $Config) { Get-Content $Config -Raw -Encoding UTF8 } else { '' }
  $effectiveApiKey = $ApiKey
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey) -and -not [string]::IsNullOrWhiteSpace($SlotName)) {
    $safeSlotName = Convert-SlotName $SlotName
    $slotProvider = Join-Path $ProviderRoot "$safeSlotName\provider.toml"
    $slotProviderText = if (Test-Path $slotProvider) { Get-Content $slotProvider -Raw -Encoding UTF8 } else { '' }
    $effectiveApiKey = Get-SlotApiKey $safeSlotName $slotProviderText
  }
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) { $effectiveApiKey = Get-CurrentApiKey $text }
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) { throw 'API key is empty and no existing key could be reused' }
  $protocol = Normalize-UpstreamProtocol $UpstreamProtocol
  $providerBaseUrl = $BaseUrl
  if ($protocol -eq 'chat') {
    Write-AdapterState $BaseUrl $effectiveApiKey $Model $SlotName
    $providerBaseUrl = 'http://127.0.0.1:17857/v1'
  } elseif ($protocol -eq 'anthropic') {
    # Messages profiles use the full Provider Plus relay (17857), not the
    # legacy 17855 chat-only adapter.
    $providerBaseUrl = 'http://127.0.0.1:17857/v1'
  }

  if ($text -match '(?m)^[ \t]*profile\s*=\s*"custom"\s*$') {
    $text = [regex]::Replace($text, '(?m)^[ \t]*profile\s*=\s*"custom"\s*(?:\r?\n)?', '', 1)
  }
  $text = Set-TopLevelString $text 'model_provider' 'custom'
  $text = Set-TopLevelString $text 'model' $Model

  $profilePattern = '(?s)\[profiles\.custom\]\r?\n.*?(?=\r?\n\[[^\r\n]+\]|\z)'
  if ([regex]::IsMatch($text, $profilePattern)) {
    $block = [regex]::Match($text, $profilePattern).Value
    foreach ($pair in @(@('model_provider','custom'), @('model',$Model))) {
      $k = $pair[0]
      $v = Escape-TomlBasicString $pair[1]
      if ($block -match "(?m)^$k\s*=") {
        $block = [regex]::Replace($block, "(?m)^$k\s*=\s*`"[^`"]*`"", "$k = `"$v`"", 1)
      } else {
        $block += "`r`n$k = `"$v`""
      }
    }
    $text = [regex]::Replace($text, $profilePattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, 1)
  } else {
    $m = Escape-TomlBasicString $Model
    $text += "`r`n[profiles.custom]`r`nmodel_provider = `"custom`"`r`nmodel = `"$m`"`r`nmodel_reasoning_effort = `"high`"`r`ndisable_response_storage = true`r`n"
  }

  $baseEsc = Escape-TomlBasicString $providerBaseUrl
  $keyEsc = Escape-TomlBasicString $effectiveApiKey
  $providerBlock = "[model_providers.custom]`r`nname = `"custom`"`r`nwire_api = `"responses`"`r`nrequires_openai_auth = false`r`nbase_url = `"$baseEsc`"`r`napi_key = `"$keyEsc`"`r`nenv_key = `"OPENAI_API_KEY`""
  $providerPattern = '(?s)\[model_providers\.custom\]\r?\n.*?(?=\r?\n\[[^\r\n]+\]|\z)'
  if ([regex]::IsMatch($text, $providerPattern)) {
    $text = [regex]::Replace($text, $providerPattern, [Text.RegularExpressions.MatchEvaluator]{ param($m) $providerBlock }, 1)
  } else {
    $text += "`r`n$providerBlock`r`n"
  }
  $instructionsEnabledValue = if ($null -eq $InstructionsEnabled) { $null } else { [Nullable[bool]]([bool]$InstructionsEnabled) }
  $text = Set-ModelInstructions $text $instructionsEnabledValue $InstructionsPath
  Write-Utf8NoBom $Config $text
  Sync-ApiKeyAuth $effectiveApiKey
  Add-CustomModel $Model | Out-Null

  if (-not [string]::IsNullOrWhiteSpace($SlotName)) {
    Save-SlotConfig $BaseUrl $effectiveApiKey $Model $SlotName $protocol $InstructionsEnabled $InstructionsPath | Out-Null
  }
  Sync-ProviderPlusProfile $BaseUrl $effectiveApiKey $Model $SlotName $protocol | Out-Null
  if ($protocol -eq 'responses') {
    # Provider Plus versions predating direct Responses routing may rewrite the
    # provider to 17857. ConfigBox is authoritative, so finish with the direct
    # upstream block and matching API key.
    Write-Utf8NoBom $Config $text
    Sync-ApiKeyAuth $effectiveApiKey
    $finalText = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
    $finalBase = Get-Field (Get-ProviderBlock $finalText) 'base_url'
    if ((Remove-TrailingForwardSlash $finalBase) -ne (Remove-TrailingForwardSlash $BaseUrl) -or $finalBase -match '^http://127\.0\.0\.1:17857(?:/|$)') {
      throw "Responses slot did not finish as a direct provider: $finalBase"
    }
  }
  return "$Config.bak.ui-$ts"
}

function Get-SlotApiKey([string]$SafeName, [string]$ProviderText = '') {
  $key = ''
  if (-not [string]::IsNullOrWhiteSpace($ProviderText)) {
    $key = Get-Field $ProviderText 'api_key'
  }
  if (-not [string]::IsNullOrWhiteSpace($key)) { return $key }
  $authSlot = Join-Path $AuthRoot "$SafeName\auth.json"
  if (Test-Path $authSlot) {
    $authObj = Read-JsonHashtable $authSlot
    if ($authObj.Contains('OPENAI_API_KEY')) { return [string]$authObj['OPENAI_API_KEY'] }
  }
  return ''
}

function Normalize-UpstreamProtocol([string]$Protocol) {
  $p = ([string]$Protocol).Trim().ToLowerInvariant()
  if ($p -in @('chat', 'chat_completions', 'chat-completions')) { return 'chat' }
  if ($p -in @('anthropic', 'messages', 'message', 'anthropic_messages', 'anthropic-messages')) { return 'anthropic' }
  return 'responses'
}

function Get-SlotProtocol([string]$SafeName) {
  $meta = Join-Path $ProviderRoot "$SafeName\metadata.json"
  if (Test-Path $meta) {
    try {
      $obj = Read-JsonHashtable $meta
      if ($obj.Contains('upstream_protocol')) { return Normalize-UpstreamProtocol ([string]$obj['upstream_protocol']) }
    } catch {}
  }
  return 'responses'
}

function Save-SlotConfig([string]$BaseUrl, [string]$ApiKey, [string]$Model, [string]$SlotName, [string]$UpstreamProtocol = 'responses', [object]$InstructionsEnabled = $null, [string]$InstructionsPath = '') {
  if ([string]::IsNullOrWhiteSpace($SlotName)) { throw 'Slot name cannot be empty' }
  if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw 'Base URL cannot be empty' }
  if ([string]::IsNullOrWhiteSpace($Model)) { $Model = 'gpt-5.5' }
  $safe = Convert-SlotName $SlotName
  $pd = Join-Path $ProviderRoot $safe
  $ad = Join-Path $AuthRoot $safe
  New-Item -ItemType Directory -Force -Path $pd,$ad | Out-Null
  $existingProvider = Join-Path $pd 'provider.toml'
  $existingText = if (Test-Path $existingProvider) { Get-Content $existingProvider -Raw -Encoding UTF8 } else { '' }
  $effectiveApiKey = $ApiKey
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) { $effectiveApiKey = Get-SlotApiKey $safe $existingText }
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) { $effectiveApiKey = Get-CurrentApiKey (Get-Content $Config -Raw -Encoding UTF8) }
  if ([string]::IsNullOrWhiteSpace($effectiveApiKey)) { throw 'API key is empty and no existing key could be reused' }
  $baseEsc = Escape-TomlBasicString $BaseUrl
  $keyEsc = Escape-TomlBasicString $effectiveApiKey
  $modelEsc = Escape-TomlBasicString $Model
  $providerBlock = "[model_providers.custom]`r`nname = `"custom`"`r`nwire_api = `"responses`"`r`nrequires_openai_auth = false`r`nbase_url = `"$baseEsc`"`r`napi_key = `"$keyEsc`"`r`nenv_key = `"OPENAI_API_KEY`""
  Write-Utf8NoBom (Join-Path $pd 'provider.toml') ($providerBlock + "`r`n")
  Write-Utf8NoBom (Join-Path $pd 'profile.toml') ("model = `"$modelEsc`"`r`n")
  Write-Utf8NoBom (Join-Path $ad 'auth.json') ((([ordered]@{ OPENAI_API_KEY = $effectiveApiKey; auth_mode = 'apikey' } | ConvertTo-Json -Depth 20)) + "`n")
  $instructionsEnabledValue = if ($null -eq $InstructionsEnabled) { $null } else { [Nullable[bool]]([bool]$InstructionsEnabled) }
  $currentInstructions = Get-ModelInstructionsSettings
  if ($null -eq $instructionsEnabledValue) { $instructionsEnabledValue = [bool]$currentInstructions.enabled }
  if ([string]::IsNullOrWhiteSpace($InstructionsPath)) { $InstructionsPath = [string]$currentInstructions.path }
  $InstructionsPath = Normalize-ModelInstructionsPath $InstructionsPath
  Write-Utf8NoBom (Join-Path $pd 'metadata.json') ((([ordered]@{ upstream_protocol = (Normalize-UpstreamProtocol $UpstreamProtocol); model_instructions_enabled = [bool]$instructionsEnabledValue; model_instructions_file = $InstructionsPath } | ConvertTo-Json -Depth 20)) + "`n")
  Add-CustomModel $Model | Out-Null
  return $safe
}

function Apply-Slot([string]$Name) {
  $safe = Convert-SlotName $Name
  $provider = Join-Path $ProviderRoot "$safe\provider.toml"
  $authSlot = Join-Path $AuthRoot "$safe\auth.json"
  if (!(Test-Path $provider)) { throw "Provider slot not found: $safe" }
  $ptext = Get-Content $provider -Raw -Encoding UTF8
  $base = Get-Field $ptext 'base_url'
  $key = Get-Field $ptext 'api_key'
  if ([string]::IsNullOrWhiteSpace($key) -and (Test-Path $authSlot)) {
    $authObj = Read-JsonHashtable $authSlot
    if ($authObj.Contains('OPENAI_API_KEY')) { $key = [string]$authObj['OPENAI_API_KEY'] }
  }
  $model = Get-ProfileModel (Get-Content $Config -Raw -Encoding UTF8)
  $profileSlot = Join-Path $ProviderRoot "$safe\profile.toml"
  if (Test-Path $profileSlot) {
    $slotModel = Get-Field (Get-Content $profileSlot -Raw -Encoding UTF8) 'model'
    if (-not [string]::IsNullOrWhiteSpace($slotModel)) { $model = $slotModel }
  }
  $protocol = Get-SlotProtocol $safe
  $meta = Join-Path $ProviderRoot "$safe\metadata.json"
  $instructionsEnabled = $null
  $instructionsPath = ''
  if (Test-Path $meta) {
    try {
      $obj = Read-JsonHashtable $meta
      if ($obj.Contains('model_instructions_enabled')) { $instructionsEnabled = [bool]$obj['model_instructions_enabled'] }
      if ($obj.Contains('model_instructions_file')) { $instructionsPath = [string]$obj['model_instructions_file'] }
    } catch {}
  }
  return Set-CustomProvider $base $key $model $safe $protocol $instructionsEnabled $instructionsPath
}

function Remove-Slot([string]$Name) {
  $safe = Convert-SlotName $Name
  $provider = Join-Path $ProviderRoot $safe
  $authSlot = Join-Path $AuthRoot $safe
  Assert-UnderRoot $ProviderRoot $provider
  Assert-UnderRoot $AuthRoot $authSlot
  $removed = $false
  if (Test-Path $provider) {
    Remove-Item -LiteralPath $provider -Recurse -Force
    $removed = $true
  }
  if (Test-Path $authSlot) {
    Remove-Item -LiteralPath $authSlot -Recurse -Force
    $removed = $true
  }
  if (-not $removed) { throw "Slot not found: $safe" }
  return $safe
}

function Get-SlotSummaries([string]$ConfigText = '') {
  if ([string]::IsNullOrWhiteSpace($ConfigText) -and (Test-Path $Config)) {
    $ConfigText = Get-Content $Config -Raw -Encoding UTF8
  }
  $currentBlock = Get-ProviderBlock $ConfigText
  $currentBase = Get-Field $currentBlock 'base_url'
  $currentKey = Get-CurrentApiKey $ConfigText
  $currentModel = Get-ProfileModel $ConfigText
  $adapterState = Read-AdapterState
  $adapterBase = Get-AdapterBaseUrl
  $adapterSlot = [string](Get-Prop $adapterState 'slot' '')
  $adapterUpstreamBase = [string](Get-Prop $adapterState 'upstream_base_url' '')
  $adapterKey = [string](Get-Prop $adapterState 'api_key' '')
  $providerPlusStatus = Get-ProviderPlusStatusSafe
  $providerPlusActive = $null
  if ($null -ne $providerPlusStatus) {
    $providerPlusActive = @($providerPlusStatus.profiles | Where-Object { [bool]$_.active } | Select-Object -First 1)
    if ($providerPlusActive.Count -gt 0) { $providerPlusActive = $providerPlusActive[0] } else { $providerPlusActive = $null }
  }
  $relayPort = if ($null -ne $providerPlusStatus -and [int]$providerPlusStatus.relay_port -gt 0) { [int]$providerPlusStatus.relay_port } else { 17857 }
  $relayBase = "http://127.0.0.1:$relayPort/v1"
  $items = @()
  if (!(Test-Path $ProviderRoot)) { return @() }
  Get-ChildItem $ProviderRoot -Directory | Sort-Object Name | ForEach-Object {
    $name = $_.Name
    $pt = Join-Path $_.FullName 'provider.toml'
    $pr = Join-Path $_.FullName 'profile.toml'
    $ptext = if (Test-Path $pt) { Get-Content $pt -Raw -Encoding UTF8 } else { '' }
    $model = if (Test-Path $pr) { Get-Field (Get-Content $pr -Raw -Encoding UTF8) 'model' } else { '' }
    $base = Get-Field $ptext 'base_url'
    $key = Get-SlotApiKey $name $ptext
    $protocol = Get-SlotProtocol $name
    $meta = Join-Path $_.FullName 'metadata.json'
    $slotInstructionsEnabled = $null
    $slotInstructionsPath = ''
    if (Test-Path $meta) {
      try {
        $metaObj = Read-JsonHashtable $meta
        if ($metaObj.Contains('model_instructions_enabled')) { $slotInstructionsEnabled = [bool]$metaObj['model_instructions_enabled'] }
        if ($metaObj.Contains('model_instructions_file')) { $slotInstructionsPath = [string]$metaObj['model_instructions_file'] }
      } catch {}
    }
    $isActive = ($base -eq $currentBase -and $model -eq $currentModel -and $key -eq $currentKey)
    if ($protocol -eq 'chat' -and (($currentBase -eq $adapterBase) -or ($currentBase -eq $relayBase))) {
      $legacyAdapterMatch = ($adapterSlot -eq $name) -or ($base -eq $adapterUpstreamBase -and $model -eq $currentModel -and $key -eq $adapterKey)
      $providerPlusMatch = $null -ne $providerPlusActive -and
        (([string]$providerPlusActive.id -eq $name) -or ([string]$providerPlusActive.name -eq $name)) -and
        ([string]$providerPlusActive.model -eq $model)
      $isActive = $legacyAdapterMatch -or $providerPlusMatch
    } elseif ($protocol -eq 'anthropic' -and $currentBase -eq $relayBase) {
      $isActive = $null -ne $providerPlusActive -and
        (([string]$providerPlusActive.id -eq $name) -or ([string]$providerPlusActive.name -eq $name)) -and
        ([string]$providerPlusActive.model -eq $model)
    }
    $items += [ordered]@{
      name=$name
      model=$model
      model_missing=[string]::IsNullOrWhiteSpace($model)
      wire_api=$protocol
      base_url=$base
      api_key_masked=(Mask-Secret $key)
      active=$isActive
      model_instructions_enabled=$slotInstructionsEnabled
      model_instructions_file=$slotInstructionsPath
      updated=$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
    }
  }
  return @($items)
}

function Repair-ProviderConfigs {
  $changed = 0
  if (Test-Path $Config) {
    $text = Get-Content $Config -Raw -Encoding UTF8
    $new = [regex]::Replace($text, '(?m)^wire_api\s*=\s*"[^"]*"', 'wire_api = "responses"')
    if ($new -ne $text) {
      Copy-Item -LiteralPath $Config -Destination "$Config.bak.repair-$(Get-Date -Format 'yyyyMMdd_HHmmss')" -Force
      Write-Utf8NoBom $Config $new
      $changed++
    }
  }
  if (Test-Path $ProviderRoot) {
    Get-ChildItem $ProviderRoot -Directory | ForEach-Object {
      $pt = Join-Path $_.FullName 'provider.toml'
      if (Test-Path $pt) {
        $text = Get-Content $pt -Raw -Encoding UTF8
        $new = [regex]::Replace($text, '(?m)^wire_api\s*=\s*"[^"]*"', 'wire_api = "responses"')
        if ($new -ne $text) { Write-Utf8NoBom $pt $new; $script:changedProviderCount++ }
      }
    }
  }
  $authChanged = 0
  foreach ($path in @($Auth) + @(Get-ChildItem $AuthRoot -Recurse -Filter 'auth.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
    if ([string]::IsNullOrWhiteSpace($path) -or !(Test-Path $path)) { continue }
    $obj = Read-JsonHashtable $path
    if (-not $obj.Contains('auth_mode') -or [string]$obj['auth_mode'] -ne 'apikey') {
      $obj['auth_mode'] = 'apikey'
      Write-Utf8NoBom $path (($obj | ConvertTo-Json -Depth 20) + "`n")
      $authChanged++
    }
  }
  return [ordered]@{
    ok=$true
    config_changed=$changed
    provider_profiles_changed=([int]$script:changedProviderCount)
    auth_files_changed=$authChanged
  }
}

function Sync-ThreadIndex([string]$TargetProvider = 'custom') {
  $py = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
  if (!$py) { $py = Get-Command py -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if (!$py) { throw 'Python was not found; cannot repair the SQLite thread index from this UI' }
  $script = @'
import json
import pathlib
import shutil
import sqlite3
import sys
import time

home = pathlib.Path(sys.argv[1])
target = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "custom"
thread_ids = set()
cwd_by_id = {}

for dirname in ("sessions", "archived_sessions"):
    root = home / dirname
    if not root.exists():
        continue
    for path in root.rglob("*.jsonl"):
        tid = None
        cwd = None
        has_user = False
        try:
            with path.open("r", encoding="utf-8") as f:
                for line in f:
                    try:
                        obj = json.loads(line)
                    except Exception:
                        continue
                    typ = obj.get("type")
                    payload = obj.get("payload") or {}
                    if typ == "session_meta":
                        tid = payload.get("id") or tid
                        cwd = payload.get("cwd") or cwd
                    if typ == "turn_context":
                        cwd = payload.get("cwd") or cwd
                    if typ == "response_item":
                        if payload.get("type") == "message" and payload.get("role") == "user":
                            has_user = True
            if tid and has_user:
                thread_ids.add(tid)
                if cwd:
                    cwd_by_id[tid] = cwd
        except Exception:
            continue

dbs = []
main = home / "state_5.sqlite"
if main.exists():
    dbs.append(main)
sqlite_dir = home / "sqlite"
if sqlite_dir.exists():
    for p in sqlite_dir.iterdir():
        if p.suffix.lower() in (".db", ".sqlite", ".sqlite3"):
            dbs.append(p)

stamp = time.strftime("%Y%m%d_%H%M%S")
result = {"ok": True, "target_provider": target, "dbs": [], "thread_ids_from_jsonl": len(thread_ids)}

for db_path in dbs:
    item = {"path": str(db_path), "provider_rows": 0, "user_event_rows": 0, "cwd_rows": 0, "backup": ""}
    try:
        backup = db_path.with_name(db_path.name + ".bak.provider-sync-" + stamp)
        shutil.copy2(db_path, backup)
        for suffix in ("-wal", "-shm"):
            side = pathlib.Path(str(db_path) + suffix)
            if side.exists():
                shutil.copy2(side, pathlib.Path(str(backup) + suffix))
        item["backup"] = str(backup)
        con = sqlite3.connect(db_path)
        cur = con.cursor()
        tables = [r[0] for r in cur.execute("select name from sqlite_master where type='table'")]
        if "threads" not in tables:
            con.close()
            result["dbs"].append(item)
            continue
        cols = [r[1] for r in cur.execute("pragma table_info(threads)")]
        if "model_provider" in cols:
            cur.execute("update threads set model_provider=? where coalesce(model_provider,'') <> ?", (target, target))
            item["provider_rows"] = cur.rowcount if cur.rowcount >= 0 else 0
        if "has_user_event" in cols and thread_ids:
            for tid in thread_ids:
                cur.execute("update threads set has_user_event=1 where id=? and coalesce(has_user_event,0) <> 1", (tid,))
                if cur.rowcount and cur.rowcount > 0:
                    item["user_event_rows"] += cur.rowcount
        if "cwd" in cols and cwd_by_id:
            for tid, cwd in cwd_by_id.items():
                cur.execute("update threads set cwd=? where id=? and coalesce(cwd,'') <> ?", (cwd, tid, cwd))
                if cur.rowcount and cur.rowcount > 0:
                    item["cwd_rows"] += cur.rowcount
        con.commit()
        con.close()
    except Exception as exc:
        item["ok"] = False
        item["error"] = str(exc)
    result["dbs"].append(item)

print(json.dumps(result, ensure_ascii=False))
'@
  $tmp = Join-Path $env:TEMP ("codex-thread-index-sync-" + [guid]::NewGuid().ToString('N') + ".py")
  Write-Utf8NoBom $tmp $script
  try {
    $output = & $py.Source $tmp $CodexHome $TargetProvider 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($output -join "`n") }
    return ($output -join "`n") | ConvertFrom-Json
  } finally {
    if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force }
  }
}

$html = @'
<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Codex ConfigBox</title><style>
:root{color-scheme:dark light;--bg:#10100d;--panel:#191813;--panel2:#211f18;--line:#393528;--text:#f7f1df;--muted:#b1a78e;--accent:#f0b429;--good:#6dd3b1;--bad:#ff7a7a;--warn:#f0b429;--shadow:0 24px 80px rgba(0,0,0,.28)}@media(prefers-color-scheme:light){:root{--bg:#f4efe2;--panel:#fffaf0;--panel2:#fff4d7;--line:#decfaa;--text:#221d13;--muted:#756a51;--accent:#b7791f;--good:#087f5b;--bad:#c53030;--warn:#b7791f}}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 "Segoe UI","Microsoft YaHei",sans-serif;background:radial-gradient(circle at 10% 0,#56400c 0,transparent 26rem),linear-gradient(135deg,var(--bg),#171a18);color:var(--text)}main{max-width:1200px;margin:0 auto;padding:30px 18px 54px}.top{display:flex;justify-content:space-between;gap:16px;align-items:flex-start;margin-bottom:18px}h1{margin:0 0 8px;font-size:clamp(30px,5vw,54px);letter-spacing:-.04em;line-height:.96}.sub{margin:0;color:var(--muted);max-width:820px}.badge{border:1px solid var(--line);background:color-mix(in srgb,var(--panel) 76%,transparent);border-radius:999px;padding:9px 13px;color:var(--muted);white-space:nowrap}.layout{display:grid;grid-template-columns:360px 1fr;gap:16px}.card{background:color-mix(in srgb,var(--panel) 94%,transparent);border:1px solid var(--line);border-radius:22px;padding:18px;box-shadow:var(--shadow)}.toolbar{display:flex;gap:8px;margin:12px 0}.toolbar input{min-height:40px}.slots{display:grid;gap:10px;max-height:650px;overflow:auto;padding-right:4px}.slot{border:1px solid var(--line);background:var(--panel2);border-radius:16px;padding:12px;cursor:pointer;transition:.15s transform,.15s border-color}.slot:hover{transform:translateY(-1px);border-color:color-mix(in srgb,var(--accent) 60%,var(--line))}.slot.active{outline:2px solid var(--accent);outline-offset:1px}.name{display:flex;justify-content:space-between;gap:10px;font-weight:850}.pill{display:inline-flex;align-items:center;border:1px solid var(--line);border-radius:999px;padding:2px 8px;font-size:12px;color:var(--muted);white-space:nowrap}.pill.on{border-color:var(--good);color:var(--good)}.meta{margin-top:7px;color:var(--muted);font-size:13px;word-break:break-all}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.span{grid-column:1/-1}label{display:block;font-weight:800;margin:12px 0 6px}input,select,textarea{width:100%;min-height:44px;border-radius:13px;border:1px solid var(--line);background:color-mix(in srgb,var(--bg) 70%,transparent);color:var(--text);padding:10px 12px;font:inherit}textarea{min-height:142px;resize:vertical;font-family:Consolas,"Cascadia Mono",monospace;font-size:13px}button{min-height:42px;border:0;border-radius:13px;padding:10px 13px;font-weight:850;cursor:pointer;background:var(--accent);color:#18120a}button.secondary{background:transparent;color:var(--text);border:1px solid var(--line)}button.good{background:var(--good);color:#061511}button.danger{background:transparent;color:var(--bad);border:1px solid color-mix(in srgb,var(--bad) 55%,var(--line))}button.warn{background:transparent;color:var(--warn);border:1px solid color-mix(in srgb,var(--warn) 55%,var(--line))}button:focus-visible,input:focus,select:focus,textarea:focus{outline:3px solid color-mix(in srgb,var(--accent) 40%,transparent);outline-offset:2px}.row{display:flex;gap:9px;flex-wrap:wrap;margin-top:14px}.row>*{flex:1 1 150px}.kv{display:grid;grid-template-columns:128px 1fr;gap:8px;margin:8px 0;color:var(--muted)}.kv b{color:var(--text)}code{word-break:break-all}.status{margin-top:14px;padding:12px;border-radius:14px;border:1px dashed var(--line);color:var(--muted);min-height:46px;white-space:pre-wrap}.warnbox{border-left:4px solid var(--accent);padding:10px 12px;background:color-mix(in srgb,var(--accent) 12%,transparent);border-radius:12px;color:var(--muted)}small{color:var(--muted)}@media(max-width:900px){.layout{grid-template-columns:1fr}.top{display:block}.badge{display:inline-block;margin-top:14px}.grid{grid-template-columns:1fr}}
</style></head><body><main><div class="top"><div><h1>Codex ConfigBox</h1><p class="sub">管理 Codex custom provider 配置槽位：保存槽位、测试 /models、探测可用模型，并始终写入 <code>wire_api = "responses"</code>。Responses 槽位直连；Chat Completions 和 Anthropic Messages 槽位经 Provider Plus 17857 适配为 Codex 可用的 <code>/v1/responses</code>。</p></div><div class="badge">仅监听 127.0.0.1</div></div><section class="layout"><aside class="card"><h2>配置槽位</h2><div class="toolbar"><input id="filter" placeholder="搜索槽位 / 模型 / URL" oninput="renderSlots()"><button class="secondary" onclick="newSlot()">新建</button></div><div id="slots" class="slots"></div><div class="row"><button class="secondary" onclick="loadStatus()">刷新</button><button class="warn" onclick="switchSelectedNoRestart()">应用选中（写入配置）</button><button class="secondary" onclick="exportSlots()">导出</button></div><div class="status" id="status">准备就绪</div></aside><section class="card"><h2>编辑配置</h2><div id="current"></div><div class="grid"><div><label>槽位名</label><input id="slotName" placeholder="gpt-main / claude-relay"></div><div><label>协议类型</label><select id="wireApi" onchange="renderPreview()"><option value="responses">Responses API (Codex 可用)</option><option value="chat">Chat Completions (内置适配器)</option><option value="anthropic">Anthropic Messages (Claude /v1/messages)</option></select></div><div class="span"><label>Base URL</label><input id="baseUrl" placeholder="https://example.com/v1" oninput="renderPreview()"></div><div><label>Model</label><input id="model" value="gpt-5.5" list="modelPresets" oninput="renderPreview()"><datalist id="modelPresets"><option value="gpt-5.5"><option value="gpt-5"><option value="claude-sonnet-4-6"><option value="mimo-v2.5-pro"></datalist></div><div><label>API Key</label><input id="apiKey" type="password" placeholder="留空则沿用已保存或当前 key"></div><div class="span warnbox" id="compat">Codex 使用 Responses；Chat 和 Anthropic Messages 槽位由 Provider Plus 17857 转换。</div><div class="span"><label>配置预览</label><textarea id="preview" readonly></textarea></div></div><div class="row"><button class="good" onclick="saveSlot()">保存槽位</button><button onclick="applyManual()">应用当前</button><button class="warn" onclick="switchSelectedNoRestart()">应用选中（写入配置）</button><button class="secondary" onclick="fetchModels()">获取 /models</button><button class="secondary" onclick="probeModels()">探测可用模型</button><button class="secondary" onclick="testResponses()">测试 Responses</button><button class="secondary" onclick="testMessages()">测试 Messages</button><button class="secondary" onclick="testCurrent()">测试当前</button><button class="warn" onclick="repairConfigs()">修复配置</button><button class="warn" onclick="syncThreads()">修复会话</button><button class="secondary" onclick="toggleKey()">显示/隐藏 Key</button><button class="danger" onclick="deleteSlot()">删除槽位</button></div><small>应用配置会先备份 config/auth。Responses 槽位写入上游直连地址；Chat 和 Anthropic Messages 槽位写入 17857。已启动的 Codex app-server 可能缓存旧地址，此时再重启 Codex 读取新配置。</small></section></section></main><script>
const $=id=>document.getElementById(id);let state={slots:[],selected:'',models:[]};let userEnteredKey=false;let lastEnteredKey='';function msg(t){$('status').textContent=t}function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}async function api(path,body){const r=await fetch(path,{method:body?'POST':'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});const j=await r.json();if(!r.ok||j.ok===false)throw new Error(j.error||r.statusText);return j}
function form(){return{slot:$('slotName').value.trim(),base_url:$('baseUrl').value.trim(),api_key:$('apiKey').value.trim()||lastEnteredKey,model:$('model').value.trim(),wire_api:$('wireApi').value||'responses'}}
function renderPreview(){const f=form();const adapterBase=location.origin+'/v1';const configuredBase=['chat','anthropic'].includes(f.wire_api)?'http://127.0.0.1:17857/v1':f.base_url;const note=f.wire_api==='chat'?'# 上游协议: chat_completions；应用后经 Provider Plus 17857 转为 Responses。\n':(f.wire_api==='anthropic'?'# 上游协议: Anthropic Messages；应用后经 Provider Plus 17857 转为 Responses。\n':'');$('preview').value=`${note}[profiles.custom]\nmodel_provider = "custom"\nmodel = "${f.model||'gpt-5.5'}"\n\n[model_providers.custom]\nname = "custom"\nwire_api = "responses"\nrequires_openai_auth = false\nbase_url = "${configuredBase}"\napi_key = "${f.api_key?'[新 key]':'[沿用已有 key]'}"\nenv_key = "OPENAI_API_KEY"`;updateCompat()}
function selectSlot(encoded){const name=decodeURIComponent(encoded);fillFromSlot(state.slots.find(x=>x.name===name))}
function updateKeyHint(masked){if(userEnteredKey){var k=$('apiKey').value||'';$('apiKey').placeholder=k?(k.substring(0,6)+'...(输入中,未保存)'):'输入中,留空沿用旧 key';return}userEnteredKey=false;$('apiKey').value='';$('apiKey').placeholder=masked&&masked!=='[empty]'?`已保存：${masked}；留空沿用`:'留空则沿用已保存或当前 key'}
function fillFromSlot(s){userEnteredKey=false;lastEnteredKey='';state.selected=s?.name||'';$('slotName').value=s?.name||'';$('baseUrl').value=s?.base_url||'';$('model').value=s?.model||'';$('wireApi').value=s?.wire_api||'responses';updateKeyHint(s?.api_key_masked);renderSlots();renderPreview()}
function newSlot(){state.selected='';$('slotName').value='';$('baseUrl').value='';$('model').value='gpt-5.5';$('wireApi').value='responses';updateKeyHint('');renderSlots();renderPreview();msg('已新建空槽位，填写后点击保存槽位。')}
function renderSlots(){const q=$('filter').value.trim().toLowerCase();const list=state.slots.filter(s=>!q||`${s.name} ${s.model} ${s.base_url} ${s.wire_api||''}`.toLowerCase().includes(q));$('slots').innerHTML=list.map(s=>`<div class="slot ${s.name===state.selected?'active':''}" onclick="selectSlot('${encodeURIComponent(s.name)}')"><div class="name"><span>${esc(s.name)}</span><span class="pill ${s.active?'on':''}">${s.active?'当前':(s.wire_api||'responses')}</span></div><div class="meta">${esc(s.model||'未保存模型')} - ${esc(s.api_key_masked||'')} - ${esc(s.wire_api||'responses')}</div><div class="meta">${esc(s.base_url||'')}</div><div class="meta">指令：${s.model_instructions_enabled===null||s.model_instructions_enabled===undefined?'沿用当前':(s.model_instructions_enabled?'加载':'关闭')} ${esc(s.model_instructions_file||'')}</div><div class="meta">更新于 ${esc(s.updated||'')}</div></div>`).join('')||'<div class="meta">没有匹配的槽位</div>'}
function updateCompat(){const f=form();const c=$("compat");if(!c)return;c.textContent=f.wire_api==="chat"?"Chat Completions 槽位会通过 Provider Plus 17857 转成 Responses；Provider Plus 必须保持运行。":(f.wire_api==="anthropic"?"Anthropic Messages 槽位会通过 Provider Plus 17857 调用上游 /v1/messages，再转换为 Codex Responses；支持 Claude。":"Responses API 槽位直连上游。Model 可填任意模型 ID；应用后由 Provider Plus 同步到 Codex 原生模型下拉菜单。")}
function useSuggested(j){if(j.suggested_base_url){$('baseUrl').value=j.suggested_base_url;renderPreview();return ` 已自动改用建议 Base URL：${j.suggested_base_url}。`;}return ''}
function mergeModels(models){if(!models||!models.length)return;state.models=[...new Set([...models,...state.models])];$('modelPresets').innerHTML=state.models.map(m=>`<option value="${esc(m)}">`).join('');if(!$('model').value.trim()){$('model').value=state.models[0];renderPreview()}}
async function loadStatus(){try{const j=await api('/api/status');state.slots=j.slots||[];$('current').innerHTML=`<div class=kv><b>当前模型</b><code>${esc(j.model)}</code></div><div class=kv><b>协议</b><code>${esc(j.wire_api||'responses')}</code></div><div class=kv><b>Base URL</b><code>${esc(j.base_url)}</code></div><div class=kv><b>API Key</b><code>${esc(j.api_key_masked)}</code></div>`;if(!state.selected){fillFromSlot(state.slots.find(s=>s.active)||{name:'',base_url:j.base_url,model:j.model,api_key_masked:j.api_key_masked});}else{const selectedSlot=state.slots.find(s=>s.name===state.selected);if(selectedSlot){fillFromSlot(selectedSlot)}else{renderSlots();renderPreview()}}msg('状态已刷新')}catch(e){msg('错误：'+e.message)}}
async function saveSlot(){try{const ek=document.getElementById('apiKey').value.trim();if(ek){lastEnteredKey=ek;userEnteredKey=true}const f=form();if(!f.slot)return msg('槽位名不能为空');if(!f.base_url)return msg('Base URL 不能为空');const j=await api('/api/save-slot',f);msg('已保存槽位：'+j.slot);userEnteredKey=false;lastEnteredKey='';state.selected=j.slot;await loadStatus()}catch(e){msg('错误：'+e.message)}}
async function applyManual(){try{const ek=document.getElementById('apiKey').value.trim();if(ek){lastEnteredKey=ek;userEnteredKey=true}const f=form();if(!f.base_url)return msg('Base URL 不能为空');if(!f.slot){f.slot='current';$('slotName').value='current'}const j=await api('/api/apply',f);msg(`已应用当前配置并保存到槽位 ${f.slot}，备份：${j.backup}`);userEnteredKey=false;lastEnteredKey='';state.selected=f.slot||state.selected;await loadStatus()}catch(e){msg('错误：'+e.message)}}
async function switchSelectedNoRestart(){try{const slot=$('slotName').value.trim()||state.selected;if(!slot)return msg('请先选择一个已保存槽位');msg(`正在写入槽位 ${slot}...`);const j=await api('/api/switch',{slot, sync_native_picker: document.getElementById('syncNativePicker')?.checked !== false});state.selected=slot;await loadStatus();msg(`已写入槽位 ${slot}。当前磁盘地址：${j.effective_base_url||'未知'}。备份：${j.backup}\n${j.app_server?.reload_required?'当前 Codex app-server 仍在使用切换前缓存；请点击“重启 Codex 读取新配置”。':'Codex app-server 已读取当前配置。'}`)}catch(e){msg('错误：'+e.message)}}async function fetchModels(){try{const f=form();if(!f.base_url)return msg('请先填写 Base URL');msg('正在获取 /models...');const j=await api('/api/models',f);mergeModels(j.models||[]);msg((j.models&&j.models.length)?`已从 ${j.source} 获取 ${j.models.length} 个模型。${useSuggested(j)}`:`/models 未返回可解析模型。${j.error||''}${useSuggested(j)}`)}catch(e){msg('错误：'+e.message)}}
async function testChatCompletions(){try{const f=form();if(!f.base_url)return msg('请先填写 Base URL');if(!f.model)return msg('请先填写 Model');msg('正在测试普通 /chat/completions...');const j=await api('/api/test-chat',f);mergeModels(j.models||[]);const suffix=j.note?`\n${j.note}`:'';msg(j.ok?`Chat Completions 测试成功 (HTTP ${j.status})。${useSuggested(j)}${suffix}`:`Chat Completions 测试失败 (HTTP ${j.status||0})：${j.error||'unknown'}${useSuggested(j)}${suffix}`)}catch(e){msg('错误：'+e.message)}}
async function testMessages(){try{const f=form();if(!f.base_url)return msg('请先填写 Base URL');if(!f.model)return msg('请先填写 Model');msg('正在通过 Provider Plus 测试 /v1/messages...');const j=await api('/api/test-messages',f);msg(j.ok?`Anthropic Messages 测试成功 (HTTP ${j.status})。`:`Anthropic Messages 测试失败 (HTTP ${j.status||0})：${j.preview||j.error||'unknown'}`)}catch(e){msg('错误：'+e.message)}}
function installExtraUi(){mergeModels(['gpt-5.5','gpt-5.5-chat','gpt-5.4','gpt-5','claude-sonnet-4-6','claude-opus-4-6','claude-opus-5','claude-opus-5-thinking','gork-4.6','kimi-k2.7-code','gemini-2.5-pro','gemini-2.5-flash','glm-4.5','deepseek-v3.2','mimo-v2.5-pro']);const rows=[...document.querySelectorAll('.row')];const editorRow=rows.find(r=>r.textContent.includes('测试 Responses'));if(editorRow&&!document.getElementById('testChatBtn')){const b=document.createElement('button');b.id='testChatBtn';b.className='secondary';b.textContent='测试 Chat Completions';b.onclick=testChatCompletions;editorRow.insertBefore(b,editorRow.querySelector('button.warn')||null)}const compat=$('compat');if(compat){compat.textContent='当前 Codex 版本只接受 wire_api = "responses"；Chat Completions 槽位会经内置 adapter 暴露为 /v1/responses。Model 可直接填任意模型 ID，应用后会同步到 Codex 原生模型下拉菜单。'}}
async function probeModels(){try{const f=form();if(!f.base_url)return msg('请先填写 Base URL');msg('正在用无效模型探测 /responses 的可用模型列表...');const j=await api('/api/probe-models',f);mergeModels(j.models||[]);msg((j.models&&j.models.length)?`已从上游错误信息解析出 ${j.models.length} 个可用模型。${useSuggested(j)}`:`探测完成，但上游没有暴露模型列表。${j.error||j.preview||''}${useSuggested(j)}`)}catch(e){msg('错误：'+e.message)}}
async function testResponses(){try{const f=form();if(!f.base_url)return msg('请先填写 Base URL');if(!f.model)return msg('请先填写 Model');msg('正在测试 /responses...');const j=await api('/api/test-responses',f);mergeModels(j.models||[]);msg(j.ok?`Responses 测试成功 (HTTP ${j.status})。${useSuggested(j)}`:`Responses 测试失败 (HTTP ${j.status||0})：${j.error||'unknown'}${useSuggested(j)}`)}catch(e){msg('错误：'+e.message)}}
async function testCurrent(){try{msg('正在测试当前 /responses 配置...');const j=await api('/api/test-current');mergeModels(j.models||[]);msg(j.ok?`当前配置可用 (HTTP ${j.status})。`:`当前配置失败 (HTTP ${j.status||0})：${j.error||'unknown'}`)}catch(e){msg('错误：'+e.message)}}
async function repairConfigs(){try{const j=await api('/api/repair-configs',{});msg(`修复完成：config=${j.config_changed}，provider 槽位=${j.provider_profiles_changed}，auth 文件=${j.auth_files_changed}`);await loadStatus()}catch(e){msg('错误：'+e.message)}}
async function syncThreads(){try{if(!confirm('是否备份并修复 Codex 会话索引，使旧会话在 custom provider 下继续显示？'))return;msg('正在修复会话索引...');const j=await api('/api/sync-thread-index',{});const rows=(j.dbs||[]).map(x=>`${x.path}: provider ${x.provider_rows}, user_event ${x.user_event_rows}, cwd ${x.cwd_rows}`).join('\n');msg(`会话修复完成。JSONL 用户会话：${j.thread_ids_from_jsonl}\n${rows}`)}catch(e){msg('错误：'+e.message)}}
async function deleteSlot(){try{const slot=$('slotName').value.trim()||state.selected;if(!slot)return msg('没有选中的槽位');if(!confirm(`删除槽位 ${slot}？`))return;const j=await api('/api/delete-slot',{slot});msg('已删除槽位：'+j.slot);state.selected='';await loadStatus()}catch(e){msg('错误：'+e.message)}}
async function exportSlots(){try{const j=await api('/api/export-slots');const blob=new Blob([JSON.stringify(j,null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download='codex-provider-slots.json';a.click();URL.revokeObjectURL(a.href);msg('已导出槽位 JSON，注意其中包含 API Key')}catch(e){msg('错误：'+e.message)}}
function toggleKey(){const i=$('apiKey');i.type=i.type==='password'?'text':'password'}installExtraUi();loadStatus();
</script></body></html>
'@

$instructionsUi = @'
<script>
(() => {
  const apiKeyField = document.getElementById('apiKey');
  const modelField = document.getElementById('model');
  const compat = document.getElementById('compat');
  if (!apiKeyField || !modelField || !compat || document.getElementById('loadModelInstructions')) return;

  modelField.parentElement.insertAdjacentHTML('beforeend', `
    <div class="model-actions">
      <button type="button" class="secondary" onclick="addCustomModel()">保存自定义模型</button>
      <button type="button" class="secondary" onclick="removeCustomModel()">移除自定义模型</button>
    </div>`);

  apiKeyField.parentElement.insertAdjacentHTML('afterend', `
    <div class="span">
      <label class="switchline"><input id="syncNativePicker" type="checkbox" checked><span>应用/切换后同步到 Codex 原生模型下拉菜单</span></label>
    </div>
    <div>
      <label for="loadModelInstructions">加载 model_instructions_file</label>
      <label class="switchline"><input id="loadModelInstructions" type="checkbox" onchange="renderPreview()"><span>随 Codex 启动加载</span></label>
    </div>
    <div class="span">
      <label for="modelInstructionsFile">model_instructions_file 路径</label>
      <select id="modelInstructionsFile" onchange="toggleCustomInstructionsPath();renderPreview()">
        <option value="%%CODEX_HOME%%\\prompts\\system-prompt.md">system-prompt.md</option>
        <option value="%%CODEX_HOME%%\\gpt-unrestricted.md">gpt-unrestricted.md</option>
        <option value="%%CODEX_HOME%%\\gpt-unrestricted-openclaw.md">gpt-unrestricted-openclaw.md</option>
        <option value="%%CODEX_HOME%%\\gpt-unrestricted-full.md">gpt-unrestricted-full.md</option>
        <option value="%%CODEX_HOME%%\\prompts\\codex-keysmith-v0.5.0.md">codex-keysmith v0.5.0（新版）</option>
        <option value="__custom__">手动添加...</option>
      </select>
      <input id="customModelInstructionsFile" hidden placeholder="输入完整 .md 文件路径" oninput="renderPreview()">
      <div class="model-actions">
        <button type="button" class="secondary" onclick="saveCustomInstructionsPath()">保存当前路径</button>
        <button type="button" class="secondary" onclick="removeCustomInstructionsPath()">移除当前路径</button>
      </div>
      <small>关闭后会从 config.toml 移除该配置键，同时保留这里填写的路径。保存手动路径后，下次打开会出现在下拉列表。</small>
    </div>`);

  const style = document.createElement('style');
  style.textContent = '.switchline{display:flex;align-items:center;gap:10px;min-height:44px;margin:0;font-weight:600}.switchline input{width:20px;min-height:20px;accent-color:var(--good)}.model-actions{display:flex;gap:8px;margin-top:8px}.model-actions button{flex:1 1 0;padding:8px 10px}';
  document.head.appendChild(style);

  window.addCustomModel = async function() {
    const model = modelField.value.trim();
    if (!model) return msg('请先输入自定义模型 ID');
    try {
      const result = await api('/api/add-custom-model', { model });
      mergeModels(result.models || []);
      if (document.getElementById('syncNativePicker').checked) {
        msg(`已保存自定义模型 ${model}，正在同步到 Codex 原生下拉菜单...`);
        const sync = await api('/api/sync-native-picker', {});
        msg(sync.state === 'launching'
          ? `已保存 ${model}。Codex 将自动重启一次并加载到原生下拉菜单。`
          : `已保存 ${model}，并已热更新到 Codex 原生下拉菜单。`);
      } else {
        msg(`已保存自定义模型 ${model}。`);
      }
    } catch (error) { msg('错误：' + error.message); }
  };

  window.removeCustomModel = async function() {
    const model = modelField.value.trim();
    if (!model) return msg('请先输入要移除的模型 ID');
    try {
      const result = await api('/api/remove-custom-model', { model });
      state.models = (state.models || []).filter(value => value !== model);
      mergeModels(result.models || []);
      document.getElementById('modelPresets').innerHTML = state.models.map(value => `<option value="${esc(value)}">`).join('');
      msg(`已从自定义模型列表移除 ${model}`);
    } catch (error) { msg('错误：' + error.message); }
  };

  window.syncNativePicker = async function() {
    try {
      msg('正在同步 Codex 原生模型下拉菜单...');
      const result = await api('/api/sync-native-picker', {});
      msg(result.state === 'launching'
        ? 'Provider Plus 正在通过 AUMID 自动重启 Codex，并启用原生模型菜单热同步。'
        : `已热更新 Codex 原生模型菜单，共同步 ${result.model_count || 0} 个模型。`);
    } catch (error) { msg('错误：' + error.message); }
  };

  const editorRow = [...document.querySelectorAll('.row')].find(row => row.textContent.includes('测试 Responses'));
  if (editorRow && !document.getElementById('syncNativePickerBtn')) {
    const button = document.createElement('button');
    button.id = 'syncNativePickerBtn';
    button.className = 'secondary';
    button.textContent = '同步模型菜单';
    button.onclick = syncNativePicker;
    editorRow.appendChild(button);
  }

  window.restartCodexForConfig = async function() {
    if (!confirm('将关闭并重新打开 Codex Desktop，以读取刚写入的直连地址。ConfigBox 会继续运行。是否继续？')) return;
    try {
      msg('已安排重启 Codex，窗口将在约 1 秒后重新打开...');
      await api('/api/restart-codex', {});
    } catch (error) { msg('错误：' + error.message); }
  };

  if (editorRow && !document.getElementById('restartCodexConfigBtn')) {
    const restartButton = document.createElement('button');
    restartButton.id = 'restartCodexConfigBtn';
    restartButton.className = 'warn';
    restartButton.textContent = '重启 Codex 读取新配置';
    restartButton.onclick = restartCodexForConfig;
    editorRow.appendChild(restartButton);
  }

  const baseFillFromSlot = fillFromSlot;
  fillFromSlot = function(s) {
    baseFillFromSlot(s);
    if (!s) return;
    const enabled = s.model_instructions_enabled;
    if (enabled !== null && enabled !== undefined) {
      document.getElementById('loadModelInstructions').checked = !!enabled;
    }
    const slotPath = s.model_instructions_file || '';
    if (slotPath) {
      mergeInstructionPaths([slotPath]);
      const pathSelect = document.getElementById('modelInstructionsFile');
      const isPreset = [...pathSelect.options].some(option => option.value === slotPath);
      pathSelect.value = isPreset ? slotPath : '__custom__';
      document.getElementById('customModelInstructionsFile').value = isPreset ? '' : slotPath;
      toggleCustomInstructionsPath();
    }
    renderPreview();
  };

  const baseForm = form;
  function mergeInstructionPaths(paths) {
    const select = document.getElementById('modelInstructionsFile');
    const customOption = [...select.options].find(option => option.value === '__custom__');
    const list = Array.isArray(paths) ? paths : (typeof paths === 'string' && paths ? [paths] : []);
    for (const value of list) {
      const path = String(value || '').trim();
      if (!path || [...select.options].some(option => option.value === path)) continue;
      const label = path.split(/[\\/]/).pop() || path;
      select.insertBefore(new Option(label, path), customOption);
    }
  }

  window.saveCustomInstructionsPath = async function() {
    const selectedPath = document.getElementById('modelInstructionsFile').value;
    const path = (selectedPath === '__custom__'
      ? document.getElementById('customModelInstructionsFile').value
      : selectedPath).trim();
    if (!path) return msg('请先填写 model_instructions_file 路径');
    try {
      const result = await api('/api/add-instruction-path', { path });
      mergeInstructionPaths(result.paths || []);
      document.getElementById('modelInstructionsFile').value = path;
      toggleCustomInstructionsPath();
      renderPreview();
      msg(`已保存指令文件路径 ${path}`);
    } catch (error) { msg('错误：' + error.message); }
  };

  window.removeCustomInstructionsPath = async function() {
    const selectedPath = document.getElementById('modelInstructionsFile').value;
    const path = (selectedPath === '__custom__'
      ? document.getElementById('customModelInstructionsFile').value
      : selectedPath).trim();
    if (!path) return msg('请先选择或填写要移除的路径');
    try {
      const result = await api('/api/remove-instruction-path', { path });
      const presets = new Set(['%%CODEX_HOME%%\\prompts\\system-prompt.md','%%CODEX_HOME%%\\gpt-unrestricted.md','%%CODEX_HOME%%\\gpt-unrestricted-openclaw.md','%%CODEX_HOME%%\\gpt-unrestricted-full.md','%%CODEX_HOME%%\\prompts\\codex-keysmith-v0.5.0.md','__custom__']);
      [...document.getElementById('modelInstructionsFile').options].forEach(option => {
        if (!presets.has(option.value) && option.value === path) option.remove();
      });
      mergeInstructionPaths(result.paths || []);
      msg(`已移除指令文件路径 ${path}`);
    } catch (error) { msg('错误：' + error.message); }
  };

  window.toggleCustomInstructionsPath = function() {
    const custom = document.getElementById('customModelInstructionsFile');
    custom.hidden = document.getElementById('modelInstructionsFile').value !== '__custom__';
    if (!custom.hidden) custom.focus();
  };
  form = function() {
    const values = baseForm();
    values.sync_native_picker = document.getElementById('syncNativePicker').checked;
    values.load_model_instructions = document.getElementById('loadModelInstructions').checked;
    const selectedPath = document.getElementById('modelInstructionsFile').value;
    values.model_instructions_file = (selectedPath === '__custom__'
      ? document.getElementById('customModelInstructionsFile').value
      : selectedPath).trim();
    return values;
  };

  const baseRenderPreview = renderPreview;
  renderPreview = function() {
    baseRenderPreview();
    const values = form();
    const path = values.model_instructions_file.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    const line = values.load_model_instructions
      ? `model_instructions_file = "${path || '[请填写路径]'}"\n`
      : '# model_instructions_file 未加载\n';
    document.getElementById('preview').value = line + document.getElementById('preview').value;
  };

  const baseLoadStatus = loadStatus;
  loadStatus = async function() {
    await baseLoadStatus();
    try {
      const status = await api('/api/status');
      mergeModels(status.custom_models || []);
      mergeInstructionPaths(status.custom_instruction_paths || []);
      document.getElementById('loadModelInstructions').checked = !!status.model_instructions_enabled;
      const pathSelect = document.getElementById('modelInstructionsFile');
      const configuredPath = status.model_instructions_file || '';
      const isPreset = [...pathSelect.options].some(option => option.value === configuredPath);
      pathSelect.value = isPreset ? configuredPath : '__custom__';
      document.getElementById('customModelInstructionsFile').value = isPreset ? '' : configuredPath;
      toggleCustomInstructionsPath();
      const current = document.getElementById('current');
      current.insertAdjacentHTML('beforeend', `<div class=kv><b>指令文件</b><code>${status.model_instructions_enabled ? '加载' : '关闭'} · ${esc(status.model_instructions_file || '未设置')}</code></div>`);
      const appServer = status.app_server || {};
      current.insertAdjacentHTML('beforeend', `<div class=kv><b>配置加载</b><code>${appServer.reload_required ? '需重启 Codex：当前进程仍缓存旧地址' : (appServer.running ? '当前 app-server 已读取磁盘配置' : 'Codex Desktop 未运行')}</code></div>`);
      renderPreview();
    } catch (error) {
      msg('错误：' + error.message);
    }
  };

  loadStatus();
})();
</script>
'@
$html = $html.Replace('</body></html>', $instructionsUi + '</body></html>')

# Dynamic path substitution: replace %%CODEX_HOME%% placeholder with actual $CodexHome
$escapedHome = $CodexHome.Replace('\', '\\')
$html = $html.Replace('%%CODEX_HOME%%', $escapedHome)


if (-not [string]::IsNullOrWhiteSpace($SwitchSlot)) {
  $backup = Apply-Slot $SwitchSlot
  Write-Host "Applied Codex provider slot without restarting UI: $SwitchSlot"
  Write-Host "Backup: $backup"
  Write-Host "New Codex processes/new sessions will read the updated config.toml immediately. Existing Desktop sessions may still need Reload Window/new session."
}
$listener = [Net.HttpListener]::new()
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
Ensure-ProviderPlusRelay | Out-Null
$listener.Start()
if (-not $NoBrowser) { Start-Process $prefix }
Write-Host "Codex Provider UI running: $prefix"
Write-Host "Press Ctrl+C to stop."

try {
  while ($listener.IsListening) {
    $script:ctx = $listener.GetContext()
    try {
      $path = $ctx.Request.Url.AbsolutePath
      if ($path -eq '/') { Text $html; continue }
      if ($path -eq '/v1/models') {
        Handle-AdapterModels
        continue
      }
      if ($path -eq '/v1/responses') {
        Handle-AdapterResponses
        continue
      }
      if ($path -eq '/api/status') {
        $text = if (Test-Path $Config) { Get-Content $Config -Raw -Encoding UTF8 } else { '' }
        $block = Get-ProviderBlock $text
        $base = Get-Field $block 'base_url'
        $adapterState = Read-AdapterState
        $adapterPublic = [ordered]@{}
        foreach ($p in $adapterState.GetEnumerator()) {
          if ($p.Key -eq 'api_key') { $adapterPublic['api_key_masked'] = Mask-Secret ([string]$p.Value) } else { $adapterPublic[$p.Key] = $p.Value }
        }
        $statusWire = 'responses'
        if ($base -eq (Get-AdapterBaseUrl) -and (Get-Prop $adapterState 'upstream_protocol' '') -eq 'chat') { $statusWire = 'chat-adapter' }
        $providerPlusStatus = Get-ProviderPlusStatusSafe
        if ($null -ne $providerPlusStatus) {
          $activeRelayProfile = @($providerPlusStatus.profiles | Where-Object { [bool]$_.active } | Select-Object -First 1)
          $relayPort = if ([int]$providerPlusStatus.relay_port -gt 0) { [int]$providerPlusStatus.relay_port } else { 17857 }
          if ($activeRelayProfile.Count -gt 0 -and $base -eq "http://127.0.0.1:$relayPort/v1") {
            $activeProtocol = [string]$activeRelayProfile[0].protocol
            if ($activeProtocol -eq 'anthropic') { $statusWire = 'anthropic-relay' }
            elseif ($activeProtocol -eq 'chat') { $statusWire = 'chat-relay' }
          }
        }
        $instructions = Get-ModelInstructionsSettings $text
        Json ([ordered]@{
          ok=$true
          profile='custom'
          provider='custom'
          model=(Get-ProfileModel $text)
          wire_api=$statusWire
          base_url=$base
          adapter=$adapterPublic
          api_key_masked=(Mask-Secret (Get-CurrentApiKey $text))
          model_instructions_enabled=[bool]$instructions.enabled
          model_instructions_file=[string]$instructions.path
          slots=(Get-SlotSummaries $text)
          custom_models=(Get-CustomModels)
          custom_instruction_paths=,@(Get-CustomInstructionPaths)
          app_server=(Get-CodexAppServerState)
        })
        continue
      }
      if ($path -eq '/api/apply') {
        $b = Read-BodyJson
        $instructionsEnabled = if ($b.PSObject.Properties.Name -contains 'load_model_instructions') { [bool]$b.load_model_instructions } else { $null }
        $backup = Set-CustomProvider ([string]$b.base_url) ([string]$b.api_key) ([string]$b.model) ([string]$b.slot) ([string]$b.wire_api) $instructionsEnabled ([string]$b.model_instructions_file)
        $nativeSync = $null
        if (-not ($b.PSObject.Properties.Name -contains 'sync_native_picker') -or [bool]$b.sync_native_picker) {
          try { $nativeSync = Start-NativePickerSync } catch { $nativeSync = [ordered]@{ ok=$false; state='error'; error=$_.Exception.Message } }
        }
        $afterText = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
        $effectiveBase = Get-Field (Get-ProviderBlock $afterText) 'base_url'
        Json ([ordered]@{ ok=$true; backup=$backup; native_sync=$nativeSync; effective_base_url=$effectiveBase; relay_required=($effectiveBase -match '^http://127\.0\.0\.1:1785[57](?:/|$)'); app_server=(Get-CodexAppServerState) })
        continue
      }
      if ($path -eq '/api/save-slot') {
        $b = Read-BodyJson
        $instructionsEnabled = if ($b.PSObject.Properties.Name -contains 'load_model_instructions') { [bool]$b.load_model_instructions } else { $null }
        $slot = Save-SlotConfig ([string]$b.base_url) ([string]$b.api_key) ([string]$b.model) ([string]$b.slot) ([string]$b.wire_api) $instructionsEnabled ([string]$b.model_instructions_file)
        Json ([ordered]@{ ok=$true; slot=$slot })
        continue
      }
      if ($path -eq '/api/add-custom-model') {
        $b = Read-BodyJson
        Json ([ordered]@{ ok=$true; models=(Add-CustomModel ([string]$b.model)) })
        continue
      }
      if ($path -eq '/api/remove-custom-model') {
        $b = Read-BodyJson
        Json ([ordered]@{ ok=$true; models=(Remove-CustomModel ([string]$b.model)) })
        continue
      }
      if ($path -eq '/api/add-instruction-path') {
        $b = Read-BodyJson
        Json ([ordered]@{ ok=$true; paths=,@(Add-CustomInstructionPath ([string]$b.path)) })
        continue
      }
      if ($path -eq '/api/remove-instruction-path') {
        $b = Read-BodyJson
        Json ([ordered]@{ ok=$true; paths=,@(Remove-CustomInstructionPath ([string]$b.path)) })
        continue
      }
      if ($path -eq '/api/sync-native-picker') {
        Json (Start-NativePickerSync)
        continue
      }
      if ($path -eq '/api/switch') {
        $b = Read-BodyJson
        $backup = Apply-Slot ([string]$b.slot)
        $nativeSync = $null
        if (-not ($b.PSObject.Properties.Name -contains 'sync_native_picker') -or [bool]$b.sync_native_picker) {
          try { $nativeSync = Start-NativePickerSync } catch { $nativeSync = [ordered]@{ ok=$false; state='error'; error=$_.Exception.Message } }
        }
        $afterText = Get-Content -LiteralPath $Config -Raw -Encoding UTF8
        $effectiveBase = Get-Field (Get-ProviderBlock $afterText) 'base_url'
        Json ([ordered]@{ ok=$true; backup=$backup; native_sync=$nativeSync; effective_base_url=$effectiveBase; relay_required=($effectiveBase -match '^http://127\.0\.0\.1:1785[57](?:/|$)'); app_server=(Get-CodexAppServerState) })
        continue
      }
      if ($path -eq '/api/restart-codex') {
        Json (Start-CodexDesktopRestart)
        continue
      }
      if ($path -eq '/api/delete-slot') {
        $b = Read-BodyJson
        $slot = Remove-Slot ([string]$b.slot)
        Json ([ordered]@{ ok=$true; slot=$slot })
        continue
      }
      if ($path -eq '/api/models') {
        $b = Read-BodyJson
        $key = Resolve-ApiKey ([string]$b.api_key) ([string]$b.slot)
        Json (Invoke-ProviderGetModels ([string]$b.base_url) $key)
        continue
      }
      if ($path -eq '/api/probe-models') {
        $b = Read-BodyJson
        $key = Resolve-ApiKey ([string]$b.api_key) ([string]$b.slot)
        Json (Probe-ResponsesModels ([string]$b.base_url) $key)
        continue
      }
      if ($path -eq '/api/test-responses') {
        $b = Read-BodyJson
        $key = Resolve-ApiKey ([string]$b.api_key) ([string]$b.slot)
        Json (Test-Responses ([string]$b.base_url) $key ([string]$b.model))
        continue
      }
      if ($path -eq '/api/test-chat') {
        $b = Read-BodyJson
        $key = Resolve-ApiKey ([string]$b.api_key) ([string]$b.slot)
        Json (Test-ChatCompletions ([string]$b.base_url) $key ([string]$b.model))
        continue
      }
      if ($path -eq '/api/test-messages') {
        $b = Read-BodyJson
        $key = Resolve-ApiKey ([string]$b.api_key) ([string]$b.slot)
        Json (Test-AnthropicMessages ([string]$b.base_url) $key ([string]$b.model))
        continue
      }
      if ($path -eq '/api/test-current') {
        $text = if (Test-Path $Config) { Get-Content $Config -Raw -Encoding UTF8 } else { '' }
        $block = Get-ProviderBlock $text
        Json (Test-Responses (Get-Field $block 'base_url') (Get-CurrentApiKey $text) (Get-ProfileModel $text))
        continue
      }
      if ($path -eq '/api/repair-configs') {
        $script:changedProviderCount = 0
        Json (Repair-ProviderConfigs)
        continue
      }
      if ($path -eq '/api/sync-thread-index') {
        Json (Sync-ThreadIndex 'custom')
        continue
      }
      if ($path -eq '/api/export-slots') {
        $slots = @{}
        if (Test-Path $ProviderRoot) {
          Get-ChildItem $ProviderRoot -Directory | ForEach-Object {
            $name = $_.Name
            $pt = Join-Path $_.FullName 'provider.toml'
            $pr = Join-Path $_.FullName 'profile.toml'
            $at = Join-Path $AuthRoot "$name\auth.json"
            $slots[$name] = @{
              provider=($(if (Test-Path $pt) { Get-Content $pt -Raw -Encoding UTF8 } else { '' }))
              profile=($(if (Test-Path $pr) { Get-Content $pr -Raw -Encoding UTF8 } else { '' }))
              auth=($(if (Test-Path $at) { Get-Content $at -Raw -Encoding UTF8 } else { '' }))
            }
          }
        }
        Json ([ordered]@{ ok=$true; slots=$slots })
        continue
      }
      Json ([ordered]@{ ok=$false; error='not found' }) 404
    } catch {
      Json ([ordered]@{ ok=$false; error=$_.Exception.Message }) 500
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
