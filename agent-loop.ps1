<#
.SYNOPSIS
Simple llama.cpp / OpenAI-compatible / Gemini agent loop that executes configured tool calls.

.DESCRIPTION
PowerShell 5 migration of the provided Python script. It intentionally avoids PowerShell 7-only
features and uses Windows PowerShell 5-compatible syntax.

Notes:
- This includes a small TOML reader that supports the subset used by the original config:
  [section], [nested.section], strings, integers, floats, booleans, and simple arrays.
- Requires a shell profile in config.toml, for example [shells.powershell].
#>

[CmdletBinding(PositionalBinding = $false)]
param(
    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete)

        Get-ChildItem -Path $WordToComplete* -Filter '*.toml' -ErrorAction SilentlyContinue |
            ForEach-Object {
                New-Object System.Management.Automation.CompletionResult `
                    $_.FullName,
                    $_.Name,
                    'ParameterValue',
                    "TOML config file for $CommandName"
            }
    })]
    [string]$Config,

    [Alias('model-profile')]
    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete)

        $configPath = Join-Path -Path $PSScriptRoot -ChildPath 'config.toml'
        if (Test-Path -LiteralPath $configPath) {
            Get-Content -LiteralPath $configPath -Encoding UTF8 |
                Where-Object { $_ -match '^\[models\.([^\]]+)\]' } |
                ForEach-Object { $Matches[1] } |
                Where-Object { $_ -like "$WordToComplete*" } |
                ForEach-Object {
                    New-Object System.Management.Automation.CompletionResult `
                        $_,
                        $_,
                        'ParameterValue',
                        "Model profile from config.toml"
                }
        }
    })]
    [string]$ModelProfile,

    [ValidateSet('powershell', 'bash')]
    [string]$Shell,

    [string]$Url,

    [string]$Model,

    [ArgumentCompleter({
        param($CommandName, $ParameterName, $WordToComplete)

        Get-ChildItem -Path $WordToComplete* -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                New-Object System.Management.Automation.CompletionResult `
                    $_.FullName,
                    $_.Name,
                    'ParameterValue',
                    "Working directory for $CommandName"
            }
    })]
    [string]$Cwd,

    [Alias('max-steps')]
    [int]$MaxSteps,

    [double]$Temperature,

    [Alias('max-tokens')]
    [int]$MaxTokens,

    [Alias('request-timeout')]
    [int]$RequestTimeout,

    [Alias('max-output-chars')]
    [int]$MaxOutputChars,

    [Alias('max-output-rows')]
    [int]$MaxOutputRows,

    [Alias('max-output-cols')]
    [int]$MaxOutputCols,

    [Alias('self-test')]
    [switch]$SelfTest,

    [switch]$Chat,

    [Alias('ask-always')]
    [switch]$AskAlways,

    [Alias('auto-run-all')]
    [switch]$AutoRunAll,

    [switch]$Help,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Request
)

Set-StrictMode -Version 2.0

$script:DEFAULT_URL = 'http://127.0.0.1:8080/v1/chat/completions'
$script:DEFAULT_MODEL = 'gemma-4-E4b-it.Q4_K_M.gguf'
$script:DEFAULT_CONFIG = Join-Path -Path $PSScriptRoot -ChildPath 'config.toml'

$script:TOOL_CALL_START_PATTERN = '<\|tool_call\>\s*call:([A-Za-z0-9_.:-]+)(.*)'
$script:TOOL_CALL_END_PATTERN = '<(?:\|)?tool_call\|>'
$script:NEXT_TOOL_CALL_PATTERN = '<\|tool_call\>'

$script:RISKY_PATTERNS = @(
    'remove-item',
    'rm ',
    'del ',
    'erase ',
    'set-content',
    'add-content',
    'new-item',
    'move-item',
    'copy-item',
    'rename-item',
    'invoke-webrequest',
    'iwr ',
    'invoke-restmethod',
    'irm ',
    'start-process',
    'stop-process',
    'set-executionpolicy',
    '>',
    '>>'
)

$script:BASH_RISKY_PATTERNS = @(
    ' rm ',
    ' rm -',
    ' mv ',
    ' cp ',
    ' chmod ',
    ' chown ',
    ' curl ',
    ' wget ',
    ' tee ',
    '>',
    '>>'
)

function New-ModelConfig {
    param(
        [string]$Profile,
        [string]$Provider,
        [string]$Url,
        [string]$Model,
        [double]$Temperature,
        [int]$MaxTokens,
        [int]$RequestTimeout,
        [string]$ApiKeyEnv
    )

    [PSCustomObject]@{
        Profile = $Profile
        Provider = $Provider
        Url = $Url
        Model = $Model
        Temperature = $Temperature
        MaxTokens = $MaxTokens
        RequestTimeout = $RequestTimeout
        ApiKeyEnv = $ApiKeyEnv
    }
}

function New-ShellConfig {
    param(
        [string]$Name,
        [string]$Tool,
        [string]$PromptPath,
        [string]$Executable,
        [string[]]$CliArgs
    )

    [PSCustomObject]@{
        Name = $Name
        Tool = $Tool
        PromptPath = $PromptPath
        Executable = $Executable
        Args = @($CliArgs)
    }
}

function New-AgentConfig {
    param(
        [string]$Cwd,
        [int]$MaxSteps,
        [int]$MaxOutputChars,
        [int]$MaxOutputRows,
        [int]$MaxOutputCols,
        [object]$Model,
        [object]$Shell
    )

    [PSCustomObject]@{
        Cwd = $Cwd
        MaxSteps = $MaxSteps
        MaxOutputChars = $MaxOutputChars
        MaxOutputRows = $MaxOutputRows
        MaxOutputCols = $MaxOutputCols
        Model = $Model
        Shell = $Shell
    }
}

function New-Message {
    param(
        [string]$Role,
        [string]$Content
    )

    [PSCustomObject]@{
        role = $Role
        content = $Content
    }
}

function Show-Usage {
    $scriptName = Split-Path -Leaf $PSCommandPath
    Write-Host @"
Usage:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptName [options] [request...]

Options:
  -Config <path>               TOML config path. Default: $script:DEFAULT_CONFIG
  -ModelProfile <name>         Model profile to use from the config.
  -Shell <powershell|bash>     Shell profile to use from the config.
  -Url <url>                   Chat completion URL. Default: $script:DEFAULT_URL
  -Model <name>                Model name. Default: $script:DEFAULT_MODEL
  -Cwd <path>                  Working directory for tool commands.
  -MaxSteps <int>              Maximum tool iterations.
  -Temperature <float>         Sampling temperature.
  -MaxTokens <int>             Maximum tokens per model response.
  -RequestTimeout <int>        Seconds to wait for each model response.
  -MaxOutputChars <int>        Maximum stdout/stderr characters to send back to the model.
  -MaxOutputRows <int>         Maximum output rows to send back to the model.
  -MaxOutputCols <int>         Maximum characters per output row to send back to the model.
  -SelfTest                    Run local parser and safety checks, then exit.
  -Chat                        Prompt for follow-up requests after each final answer.
  -AskAlways                   Ask before every tool command.
  -AutoRunAll                  Run every tool command without asking.
  -Help                        Show this help.
"@
}

function ConvertTo-ArgName {
    param([string]$Name)
    return ($Name.TrimStart('-') -replace '-', '_')
}

function Parse-CommandLineArgs {
    param([string[]]$Argv)

    $result = [ordered]@{
        request = New-Object System.Collections.ArrayList
        config = $script:DEFAULT_CONFIG
        model_profile = $null
        shell = $null
        url = $null
        model = $null
        cwd = $null
        max_steps = $null
        temperature = $null
        max_tokens = $null
        request_timeout = $null
        max_output_chars = $null
        max_output_rows = $null
        max_output_cols = $null
        self_test = $false
        chat = $false
        ask_always = $false
        auto_run_all = $false
        help = $false
    }

    $valueOptions = @(
        'config', 'model_profile', 'shell', 'url', 'model', 'cwd', 'max_steps',
        'temperature', 'max_tokens', 'request_timeout', 'max_output_chars',
        'max_output_rows', 'max_output_cols'
    )
    $flagOptions = @('self_test', 'chat', 'ask_always', 'auto_run_all', 'help')

    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $arg = [string]$Argv[$i]
        if ($arg -eq '--') {
            for ($j = $i + 1; $j -lt $Argv.Count; $j++) {
                [void]$result.request.Add([string]$Argv[$j])
            }
            break
        }
        if ($arg.StartsWith('--')) {
            $name = ConvertTo-ArgName $arg
            if ($flagOptions -contains $name) {
                $result[$name] = $true
                continue
            }
            if ($valueOptions -contains $name) {
                if (($i + 1) -ge $Argv.Count) {
                    throw "Option $arg requires a value."
                }
                $i++
                $result[$name] = [string]$Argv[$i]
                continue
            }
            throw "Unknown option: $arg"
        }
        [void]$result.request.Add($arg)
    }

    if ($result.ask_always -and $result.auto_run_all) {
        throw '--ask-always and --auto-run-all are mutually exclusive.'
    }
    if ($result.shell -and @('powershell', 'bash') -notcontains $result.shell) {
        throw "--shell must be either 'powershell' or 'bash'."
    }

    foreach ($key in @('max_steps', 'max_tokens', 'request_timeout', 'max_output_chars', 'max_output_rows', 'max_output_cols')) {
        if ($null -ne $result[$key]) {
            $result[$key] = [int]$result[$key]
        }
    }
    if ($null -ne $result.temperature) {
        $result.temperature = [double]$result.temperature
    }

    return [PSCustomObject]$result
}

function ConvertFrom-TomlLiteral {
    param([string]$Value)

    $text = $Value.Trim()
    if ($text -match '^"(.*)"$') {
        return ($Matches[1] -replace '\\"', '"' -replace '\\n', "`n" -replace '\\r', "`r" -replace '\\t', "`t" -replace '\\\\', '\')
    }
    if ($text -match "^'(.*)'$") {
        return $Matches[1]
    }
    if ($text -match '^\[(.*)\]$') {
        $inner = $Matches[1].Trim()
        if (-not $inner) {
            return @()
        }
        $items = New-Object System.Collections.ArrayList
        $current = ''
        $quote = $null
        $escape = $false
        foreach ($ch in $inner.ToCharArray()) {
            if ($escape) {
                $current += $ch
                $escape = $false
                continue
            }
            if ($quote -eq '"' -and $ch -eq '\') {
                $current += $ch
                $escape = $true
                continue
            }
            if (($ch -eq '"' -or $ch -eq "'") -and $null -eq $quote) {
                $quote = $ch
                $current += $ch
                continue
            }
            if ($null -ne $quote -and $ch -eq $quote) {
                $quote = $null
                $current += $ch
                continue
            }
            if ($ch -eq ',' -and $null -eq $quote) {
                [void]$items.Add((ConvertFrom-TomlLiteral $current))
                $current = ''
                continue
            }
            $current += $ch
        }
        if ($current.Trim().Length -gt 0) {
            [void]$items.Add((ConvertFrom-TomlLiteral $current))
        }
        return @($items)
    }
    if ($text -match '^(true|false)$') {
        return [bool]::Parse($text)
    }
    if ($text -match '^[+-]?\d+$') {
        return [int64]$text
    }
    if ($text -match '^[+-]?(\d+\.\d*|\d*\.\d+)([eE][+-]?\d+)?$|^[+-]?\d+[eE][+-]?\d+$') {
        return [double]$text
    }
    return $text
}

function Remove-TomlComment {
    param([string]$Line)

    $quote = $null
    $escape = $false
    $chars = $Line.ToCharArray()
    for ($i = 0; $i -lt $chars.Count; $i++) {
        $ch = $chars[$i]
        if ($escape) {
            $escape = $false
            continue
        }
        if ($quote -eq '"' -and $ch -eq '\') {
            $escape = $true
            continue
        }
        if (($ch -eq '"' -or $ch -eq "'") -and $null -eq $quote) {
            $quote = $ch
            continue
        }
        if ($null -ne $quote -and $ch -eq $quote) {
            $quote = $null
            continue
        }
        if ($ch -eq '#' -and $null -eq $quote) {
            return $Line.Substring(0, $i)
        }
    }
    return $Line
}

function Read-TomlFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @{}
    }

    $root = @{}
    $current = $root
    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    foreach ($rawLine in $lines) {
        $line = (Remove-TomlComment $rawLine).Trim()
        if (-not $line) {
            continue
        }
        if ($line -match '^\[(.+)\]$') {
            $parts = $Matches[1].Split('.')
            $current = $root
            foreach ($partRaw in $parts) {
                $part = $partRaw.Trim()
                if (-not $current.ContainsKey($part)) {
                    $current[$part] = @{}
                }
                $current = $current[$part]
            }
            continue
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) {
            throw "Invalid TOML line: $rawLine"
        }
        $key = $line.Substring(0, $eq).Trim()
        $valueText = $line.Substring($eq + 1)
        $current[$key] = ConvertFrom-TomlLiteral $valueText
    }

    return $root
}

function Get-ConfigValue {
    param(
        [object]$CliArgs,
        [hashtable]$Section,
        [string]$Attr,
        [object]$Default
    )

    $argValue = $CliArgs.$Attr
    if ($null -ne $argValue) {
        return $argValue
    }

    $hyphen = $Attr -replace '_', '-'
    if ($Section -and $Section.ContainsKey($hyphen)) {
        return $Section[$hyphen]
    }
    if ($Section -and $Section.ContainsKey($Attr)) {
        return $Section[$Attr]
    }
    return $Default
}

function Resolve-ConfigPath {
    param(
        [string]$Path,
        [string]$Base
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded.StartsWith('~')) {
        $expanded = Join-Path $HOME $expanded.Substring(1).TrimStart('\', '/')
    }
    if ([System.IO.Path]::IsPathRooted($expanded)) {
        return [System.IO.Path]::GetFullPath($expanded)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $expanded))
}

function Load-AgentConfig {
    param([object]$CliArgs)

    $configPath = Resolve-ConfigPath ([string]$CliArgs.config) (Get-Location).Path
    $configBase = Split-Path -Parent $configPath
    $raw = Read-TomlFile $configPath

    $modelSection = @{}
    $modelsSection = @{}
    $agentSection = @{}
    $shellsSection = @{}

    if ($raw.ContainsKey('model')) { $modelSection = $raw['model'] }
    if ($raw.ContainsKey('models')) { $modelsSection = $raw['models'] }
    if ($raw.ContainsKey('agent')) { $agentSection = $raw['agent'] }
    if ($raw.ContainsKey('shells')) { $shellsSection = $raw['shells'] }

    $modelProfile = $CliArgs.model_profile
    if (-not $modelProfile) {
        if ($agentSection.ContainsKey('model_profile')) { $modelProfile = $agentSection['model_profile'] } else { $modelProfile = 'local' }
    }

    if ($modelsSection.Count -gt 0) {
        if (-not $modelsSection.ContainsKey($modelProfile)) {
            throw "Model profile '$modelProfile' is not defined in $configPath."
        }
        $modelSection = $modelsSection[$modelProfile]
    } elseif ($modelProfile -ne 'local') {
        throw "Model profile '$modelProfile' is not defined in $configPath."
    }

    $shellName = $CliArgs.shell
    if (-not $shellName) {
        if ($agentSection.ContainsKey('shell')) { $shellName = $agentSection['shell'] } else { $shellName = 'powershell' }
    }
    if (-not $shellsSection.ContainsKey($shellName)) {
        throw "Shell profile '$shellName' is not defined in $configPath."
    }

    $shellRaw = $shellsSection[$shellName]
    $promptValue = $null
    if ($shellRaw.ContainsKey('prompt')) { $promptValue = $shellRaw['prompt'] }
    if (-not $promptValue) {
        throw "Shell profile '$shellName' must define a prompt path."
    }

    $shellArgs = @()
    if ($shellRaw.ContainsKey('args')) {
        foreach ($value in @($shellRaw['args'])) {
            $shellArgs += [string]$value
        }
    }

    $shellTool = $shellName
    if ($shellRaw.ContainsKey('tool')) { $shellTool = [string]$shellRaw['tool'] }
    $shellExecutable = $shellName
    if ($shellRaw.ContainsKey('executable')) { $shellExecutable = [string]$shellRaw['executable'] }

    $shell = New-ShellConfig `
        -Name $shellName `
        -Tool $shellTool `
        -PromptPath (Resolve-ConfigPath ([string]$promptValue) $configBase) `
        -Executable $shellExecutable `
        -CliArgs $shellArgs

    $provider = 'openai-chat'
    if ($modelSection.ContainsKey('provider')) { $provider = [string]$modelSection['provider'] }
    $apiKeyEnv = ''
    if ($modelSection.ContainsKey('api_key_env')) { $apiKeyEnv = [string]$modelSection['api_key_env'] }

    $model = New-ModelConfig `
        -Profile ([string]$modelProfile) `
        -Provider $provider `
        -Url ([string](Get-ConfigValue $CliArgs $modelSection 'url' $script:DEFAULT_URL)) `
        -Model ([string](Get-ConfigValue $CliArgs $modelSection 'model' $script:DEFAULT_MODEL)) `
        -Temperature ([double](Get-ConfigValue $CliArgs $modelSection 'temperature' 0.0)) `
        -MaxTokens ([int](Get-ConfigValue $CliArgs $modelSection 'max_tokens' 1024)) `
        -RequestTimeout ([int](Get-ConfigValue $CliArgs $modelSection 'request_timeout' 600)) `
        -ApiKeyEnv $apiKeyEnv

    return New-AgentConfig `
        -Cwd ([string](Get-ConfigValue $CliArgs $agentSection 'cwd' '.')) `
        -MaxSteps ([int](Get-ConfigValue $CliArgs $agentSection 'max_steps' 5)) `
        -MaxOutputChars ([int](Get-ConfigValue $CliArgs $agentSection 'max_output_chars' 20000)) `
        -MaxOutputRows ([int](Get-ConfigValue $CliArgs $agentSection 'max_output_rows' 250)) `
        -MaxOutputCols ([int](Get-ConfigValue $CliArgs $agentSection 'max_output_cols' 400)) `
        -Model $model `
        -Shell $shell
}

function Build-Headers {
    param([object]$ModelConfig)

    $headers = @{'Content-Type' = 'application/json'}
    if ($ModelConfig.ApiKeyEnv) {
        $apiKey = [Environment]::GetEnvironmentVariable($ModelConfig.ApiKeyEnv)
        if (-not $apiKey) {
            throw "Model profile '$($ModelConfig.Profile)' requires `$$($ModelConfig.ApiKeyEnv), but that environment variable is not set."
        }
        if ($ModelConfig.Provider -eq 'google-gemini') {
            $headers['x-goog-api-key'] = $apiKey
        } else {
            $headers['Authorization'] = "Bearer $apiKey"
        }
    }
    return $headers
}

function Build-GooglePayload {
    param(
        [object]$ModelConfig,
        [object[]]$Messages
    )

    $systemParts = New-Object System.Collections.ArrayList
    $contents = New-Object System.Collections.ArrayList

    foreach ($message in $Messages) {
        $role = $message.role
        $content = [string]$message.content
        if ($role -eq 'system') {
            [void]$systemParts.Add([PSCustomObject]@{ text = $content })
        } elseif ($role -eq 'assistant') {
            [void]$contents.Add([PSCustomObject]@{
                role = 'model'
                parts = @([PSCustomObject]@{ text = $content })
            })
        } else {
            [void]$contents.Add([PSCustomObject]@{
                role = 'user'
                parts = @([PSCustomObject]@{ text = $content })
            })
        }
    }

    $payload = [ordered]@{
        contents = @($contents)
        generationConfig = [ordered]@{
            temperature = $ModelConfig.Temperature
            maxOutputTokens = $ModelConfig.MaxTokens
        }
    }
    if ($systemParts.Count -gt 0) {
        $payload['systemInstruction'] = [ordered]@{ parts = @($systemParts) }
    }
    return $payload
}

function ConvertTo-JsonUtf8Bytes {
    param([object]$Payload)

    $json = $Payload | ConvertTo-Json -Depth 100 -Compress
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetBytes($json)
}

function Invoke-JsonPost {
    param(
        [string]$Url,
        [hashtable]$Headers,
        [object]$Payload,
        [int]$TimeoutSec
    )

    $bodyBytes = ConvertTo-JsonUtf8Bytes $Payload
    $request = [System.Net.WebRequest]::Create($Url)
    $request.Method = 'POST'
    $request.ContentType = 'application/json; charset=utf-8'
    $request.ContentLength = $bodyBytes.Length
    if ($TimeoutSec -gt 0) {
        $timeoutMs = [Math]::Min([int64]$TimeoutSec * 1000, [int64][int]::MaxValue)
        $request.Timeout = [int]$timeoutMs
        $request.ReadWriteTimeout = [int]$timeoutMs
    }

    foreach ($key in $Headers.Keys) {
        if ($key -eq 'Content-Type') {
            continue
        }
        if ($key -eq 'Accept') {
            $request.Accept = [string]$Headers[$key]
            continue
        }
        $request.Headers[$key] = [string]$Headers[$key]
    }

    try {
        $requestStream = $request.GetRequestStream()
        try {
            $requestStream.Write($bodyBytes, 0, $bodyBytes.Length)
        } finally {
            $requestStream.Close()
        }

        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $responseText = $reader.ReadToEnd()
        } finally {
            $response.Close()
        }
        return ($responseText | ConvertFrom-Json)
    } catch [System.Net.WebException] {
        $response = $_.Exception.Response
        if ($response) {
            $code = [int]$response.StatusCode
            try {
                $stream = $response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                $detail = $reader.ReadToEnd()
            } finally {
                $response.Close()
            }
            throw "HTTP $code`: $detail"
        }
        throw "Could not reach model endpoint: $($_.Exception.Message)"
    } catch {
        throw $_.Exception.Message
    }
}

function Chat-OpenAICompatible {
    param(
        [object]$ModelConfig,
        [object[]]$Messages
    )

    $payload = [ordered]@{
        model = $ModelConfig.Model
        messages = @($Messages)
        temperature = $ModelConfig.Temperature
        max_tokens = $ModelConfig.MaxTokens
    }

    $body = Invoke-JsonPost -Url $ModelConfig.Url -Headers (Build-Headers $ModelConfig) -Payload $payload -TimeoutSec $ModelConfig.RequestTimeout
    return [string]$body.choices[0].message.content
}

function Recover-GoogleMalformedToolCall {
    param([string]$FinishMessage)

    $prefix = 'Malformed function call:'
    if (-not $FinishMessage.StartsWith($prefix)) {
        return ''
    }
    $body = $FinishMessage.Substring($prefix.Length).Trim()
    if ($body.ToLowerInvariant().StartsWith('call:')) {
        return "<|tool_call>$body"
    }
    return $body
}

function Chat-GoogleGemini {
    param(
        [object]$ModelConfig,
        [object[]]$Messages
    )

    $url = $ModelConfig.Url.TrimEnd('/') + '/' + $ModelConfig.Model + ':generateContent'
    $payload = Build-GooglePayload -ModelConfig $ModelConfig -Messages $Messages
    $body = Invoke-JsonPost -Url $url -Headers (Build-Headers $ModelConfig) -Payload $payload -TimeoutSec $ModelConfig.RequestTimeout

    $candidate = $null
    if ($body.candidates -and $body.candidates.Count -gt 0) {
        $candidate = $body.candidates[0]
    }
    if (-not $candidate) {
        throw ('Google Gemini response did not contain candidates: ' + (($body | ConvertTo-Json -Depth 20 -Compress).Substring(0, [Math]::Min(1000, ($body | ConvertTo-Json -Depth 20 -Compress).Length))))
    }

    $parts = @()
    if ($candidate.content -and $candidate.content.parts) {
        $parts = @($candidate.content.parts)
    }
    $builder = New-Object System.Text.StringBuilder
    foreach ($part in $parts) {
        if ($null -ne $part.text) {
            [void]$builder.Append([string]$part.text)
        }
    }
    $text = $builder.ToString()

    if (-not $text -and $candidate.finishReason -eq 'MALFORMED_FUNCTION_CALL') {
        $recovered = Recover-GoogleMalformedToolCall ([string]$candidate.finishMessage)
        if ($recovered) {
            return $recovered
        }
    }
    if (-not $text) {
        $raw = $body | ConvertTo-Json -Depth 50 -Compress
        throw "Google Gemini response did not contain text: $($raw.Substring(0, [Math]::Min(1000, $raw.Length)))"
    }
    return $text
}

function Invoke-Chat {
    param(
        [object]$ModelConfig,
        [object[]]$Messages
    )

    if ($ModelConfig.Provider -eq 'google-gemini') {
        return Chat-GoogleGemini -ModelConfig $ModelConfig -Messages $Messages
    }
    if ($ModelConfig.Provider -ne 'openai-chat') {
        throw "Unsupported model provider for profile '$($ModelConfig.Profile)': $($ModelConfig.Provider)"
    }
    return Chat-OpenAICompatible -ModelConfig $ModelConfig -Messages $Messages
}

function Extract-ToolCall {
    param([string]$Text)

    $match = [regex]::Match($Text, $script:TOOL_CALL_START_PATTERN, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) {
        return $null
    }

    $toolName = $match.Groups[1].Value.Trim()
    $body = $match.Groups[2].Value

    $endMatch = [regex]::Match($body, $script:TOOL_CALL_END_PATTERN, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($endMatch.Success) {
        $body = $body.Substring(0, $endMatch.Index)
    }

    $nextMatch = [regex]::Match($body, $script:NEXT_TOOL_CALL_PATTERN, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $hadExtraToolCall = $false
    if ($nextMatch.Success) {
        $body = $body.Substring(0, $nextMatch.Index)
        $hadExtraToolCall = $true
    }

    $command = $body.Trim()
    if ($command.StartsWith('`') -and $command.EndsWith('`')) {
        $command = $command.Substring(1, $command.Length - 2).Trim()
    }

    return [PSCustomObject]@{
        ToolName = $toolName
        Command = $command
        HadExtraToolCall = $hadExtraToolCall
    }
}

function Has-ToolCallStart {
    param([string]$Text)
    return [regex]::IsMatch($Text, $script:TOOL_CALL_START_PATTERN, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function Looks-Risky {
    param([string]$Command)

    $lowered = ' ' + $Command.ToLowerInvariant() + ' '
    foreach ($pattern in $script:RISKY_PATTERNS) {
        if ($lowered.Contains($pattern)) {
            return $true
        }
    }
    return $false
}

function Looks-RiskyForShell {
    param(
        [string]$Command,
        [string]$ShellName
    )

    $lowered = ' ' + $Command.ToLowerInvariant() + ' '
    if ($ShellName -eq 'bash') {
        foreach ($pattern in $script:BASH_RISKY_PATTERNS) {
            if ($lowered.Contains($pattern)) {
                return $true
            }
        }
        return $false
    }
    return Looks-Risky $Command
}

function Uses-FragilePowerShellScriptWrite {
    param([string]$Command)

    $lowered = $Command.ToLowerInvariant()
    $writesScript = $lowered.Contains('.py') -or $lowered.Contains('.ps1')
    if (-not $writesScript -or -not $lowered.Contains('set-content')) {
        return $false
    }
    if ($lowered.Contains(' -value ')) {
        return $true
    }
    if ($Command.Contains("@'") -or $Command.Contains('@"')) {
        return $false
    }
    if ($lowered.Contains('get-content') -and ($lowered.Contains(' -replace ') -or $lowered.Contains('.replace('))) {
        return $false
    }
    return $Command.Contains('|')
}

function Uses-FragileBashScriptWrite {
    param([string]$Command)

    $lowered = $Command.ToLowerInvariant()
    $writesScript = $lowered.Contains('.py') -or $lowered.Contains('.ps1') -or $lowered.Contains('.sh')
    if (-not $writesScript) {
        return $false
    }
    if ($Command.Contains('<<')) {
        return $false
    }
    if ($lowered.Contains('python') -and $lowered.Contains('.replace(')) {
        return $false
    }
    return [regex]::IsMatch($Command, '\becho\b.+>{1,2}\s*\S+\.(py|ps1|sh)\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

function Uses-FragileScriptWrite {
    param(
        [string]$Command,
        [string]$ShellName
    )

    if ($ShellName -eq 'bash') {
        return Uses-FragileBashScriptWrite $Command
    }
    return Uses-FragilePowerShellScriptWrite $Command
}

function Should-RunCommand {
    param(
        [string]$Command,
        [object]$CliArgs,
        [string]$ShellName
    )

    if ($CliArgs.auto_run_all) {
        return $true
    }
    if ($CliArgs.ask_always -or (Looks-RiskyForShell -Command $Command -ShellName $ShellName)) {
        Write-Host "`n$ShellName command proposed:`n"
        Write-Host $Command
        try {
            $answer = (Read-Host "`nRun this command? [y/N]").Trim().ToLowerInvariant()
        } catch {
            Write-Host "`nNo interactive input available; command was not run."
            return $false
        }
        return @('y', 'yes') -contains $answer
    }
    return $true
}

function Needs-RecursiveSearch {
    param([string]$Request)

    $lowered = $Request.ToLowerInvariant()
    foreach ($word in @('subfolder', 'subfolders', 'recursive', 'recursively', 'under this folder')) {
        if ($lowered.Contains($word)) {
            return $true
        }
    }
    return $false
}

function Load-Prompt {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "System prompt file does not exist: $Path"
    }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()
}

function Build-InitialUserPrompt {
    param(
        [string]$Request,
        [string]$SystemPrompt,
        [object]$Shell
    )

    $recursiveHint = ''
    if (Needs-RecursiveSearch $Request) {
        $recursiveHint = "`n`nImportant: this request asks about subfolders or items under this folder. Use the recursive search option for the configured shell command."
    }

    $date = Get-Date -Format 'yyyy-MM-dd'
    return @"
$SystemPrompt

Current date: $date

User request: $Request$recursiveHint

When you need the shell tool, return one complete call in this exact form:
<|tool_call>call:$($Shell.Tool)
$($Shell.Name) command here
<tool_call|>

Return at most one call:$($Shell.Tool) block per response. Wait for the tool result before making another call. The call:$($Shell.Tool) body must be only the command needed to inspect or modify the system. Do not include analysis, summaries, markdown, comments, or invented results inside the block. If the request asks about command output, run that command first. If the request asks you to create, modify, fix, or debug a text file, inspect first, make the smallest useful edit, then verify by reading the file back and rerunning the relevant command. When creating a script, do not give the final answer immediately after writing it; first read it back and run it when the command is non-destructive. When asked to write a script that uses a local helper module, do not modify the helper module unless the user explicitly asks. If verification fails, adjust the generated script or its inputs first. If a generated URL or path returns not found, test small variants derived from the user's exact spelling, including preserved punctuation, dots, hyphens, and removed punctuation, then update and rerun the script.
"@.Trim()
}

function Find-Executable {
    param([string]$Executable)

    $cmd = Get-Command $Executable -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    if (Test-Path -LiteralPath $Executable) {
        return (Resolve-Path -LiteralPath $Executable).Path
    }
    return $null
}

function Decode-ProcessOutput {
    param([byte[]]$Data)

    if (-not $Data -or $Data.Length -eq 0) {
        return ''
    }

    $encodings = New-Object System.Collections.ArrayList
    [void]$encodings.Add((New-Object System.Text.UTF8Encoding($true, $true)))
    [void]$encodings.Add([System.Text.Encoding]::Default)
    [void]$encodings.Add([System.Text.Encoding]::GetEncoding(1252))

    foreach ($encoding in $encodings) {
        try {
            return $encoding.GetString($Data)
        } catch {
            continue
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($Data)
}

function Quote-NativeArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    $quote = [string][char]34
    $backslash = [string][char]92
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append($quote)

    $backslashCount = 0
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq $backslash) {
            $backslashCount++
            continue
        }

        if ($ch -eq $quote) {
            [void]$builder.Append($backslash * (($backslashCount * 2) + 1))
            [void]$builder.Append($quote)
            $backslashCount = 0
            continue
        }

        if ($backslashCount -gt 0) {
            [void]$builder.Append($backslash * $backslashCount)
            $backslashCount = 0
        }
        [void]$builder.Append($ch)
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append($backslash * ($backslashCount * 2))
    }
    [void]$builder.Append($quote)
    return $builder.ToString()
}

function Join-NativeArguments {
    param([object[]]$ArgumentValues)

    $quoted = New-Object System.Collections.ArrayList
    foreach ($argument in @($ArgumentValues)) {
        [void]$quoted.Add((Quote-NativeArgument ([string]$argument)))
    }
    return ($quoted -join ' ')
}

function Run-ShellCommand {
    param(
        [string]$Command,
        [string]$Cwd,
        [object]$Shell
    )

    $executable = Find-Executable $Shell.Executable
    if (-not $executable) {
        $executable = $Shell.Executable
    }

    $nativeArgs = @()
    foreach ($arg in @($Shell.Args)) {
        $nativeArgs += [string]$arg
    }
    $nativeArgs += $Command

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $executable
    $psi.Arguments = Join-NativeArguments $nativeArgs
    $psi.WorkingDirectory = $Cwd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch { }
        return [PSCustomObject]@{
            exit_code = 124
            stdout = ''
            stderr = "$($Shell.Name) command timed out after 120 seconds."
        }
    }

    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result

    return [PSCustomObject]@{
        exit_code = $process.ExitCode
        stdout = ([string]$stdout).Trim()
        stderr = ([string]$stderr).Trim()
    }
}

function Trim-Text {
    param(
        [string]$Text,
        [int]$MaxChars
    )

    if ($null -eq $Text) { return '' }
    if ($MaxChars -le 0 -or $Text.Length -le $MaxChars) {
        return $Text
    }
    $headLen = [int][Math]::Floor($MaxChars / 2)
    $tailLen = $MaxChars - $headLen
    $omitted = $Text.Length - $MaxChars
    return $Text.Substring(0, $headLen) + "`n`n... <omitted $omitted characters from the middle> ...`n`n" + $Text.Substring($Text.Length - $tailLen)
}

function Reduce-TextByRowsAndCols {
    param(
        [string]$Text,
        [int]$MaxRows,
        [int]$MaxCols
    )

    if (-not $Text) {
        return [PSCustomObject]@{ Text = ''; RowsRemoved = 0; ColsRemoved = 0 }
    }

    $rowsRemoved = 0
    $colsRemoved = 0
    $lines = @($Text -split "`r?`n")

    if ($MaxRows -gt 0 -and $lines.Count -gt $MaxRows) {
        $rowsRemoved = $lines.Count - $MaxRows
        $headRows = [int][Math]::Floor($MaxRows / 2)
        $tailRows = $MaxRows - $headRows
        $head = @()
        $tail = @()
        if ($headRows -gt 0) { $head = $lines[0..($headRows - 1)] }
        if ($tailRows -gt 0) { $tail = $lines[($lines.Count - $tailRows)..($lines.Count - 1)] }
        $lines = @($head + "... <omitted $rowsRemoved rows from the middle> ..." + $tail)
    }

    $reducedLines = New-Object System.Collections.ArrayList
    foreach ($line in $lines) {
        if ($MaxCols -gt 0 -and $line.Length -gt $MaxCols) {
            $omitted = $line.Length - $MaxCols
            $colsRemoved += $omitted
            $headCols = [int][Math]::Floor($MaxCols / 2)
            $tailCols = $MaxCols - $headCols
            [void]$reducedLines.Add($line.Substring(0, $headCols) + " ... <omitted $omitted columns> ... " + $line.Substring($line.Length - $tailCols))
        } else {
            [void]$reducedLines.Add($line)
        }
    }

    return [PSCustomObject]@{
        Text = ($reducedLines -join "`n")
        RowsRemoved = $rowsRemoved
        ColsRemoved = $colsRemoved
    }
}

function Build-RecoveryHint {
    param(
        [string]$Command,
        [string]$Stdout,
        [string]$Stderr,
        [string]$OriginalRequest = ''
    )

    $text = "$Command`n$Stdout`n$Stderr".ToLowerInvariant()
    if ($text.Contains('status code: 404') -or $text.Contains(' 404') -or $text.Contains('existiert leider nicht') -or $text.Contains('page does not exist')) {
        $punctuatedTokens = New-Object System.Collections.ArrayList
        foreach ($m in [regex]::Matches($OriginalRequest, '\b[A-Za-z0-9]+[.\-][A-Za-z0-9]+\b')) {
            if (-not $punctuatedTokens.Contains($m.Value)) {
                [void]$punctuatedTokens.Add($m.Value)
            }
        }

        $tokenHint = ''
        if ($punctuatedTokens.Count -gt 0) {
            $variants = New-Object System.Collections.ArrayList
            foreach ($token in $punctuatedTokens) {
                $lowered = $token.ToLowerInvariant()
                foreach ($variant in @($lowered, $lowered.Replace('.', '-'), $lowered.Replace('-', '.'), $lowered.Replace('.', '').Replace('-', ''))) {
                    if (-not $variants.Contains($variant)) {
                        [void]$variants.Add($variant)
                    }
                }
            }
            $tokenHint = " The original request contains punctuated token(s) $($punctuatedTokens -join ', '); test variants such as $($variants -join ', ')."
        }

        return "`n`nThe last check appears to have found an invalid URL or missing page. Before finalizing, debug the URL generically: test small URL variants derived from the user's exact spelling, including preserved punctuation, dots, hyphens, and removed punctuation. Prefer the variant that returns a normal result page, then update and rerun the script.$tokenHint"
    }

    if ($text.Contains('list index out of range')) {
        return "`n`nThe last script likely parsed an unexpected or empty page. Inspect the input data or URL it used, print the relevant status/heading/content shape, then update and rerun the script."
    }

    return ''
}

function Format-ToolResult {
    param(
        [string]$Command,
        [object]$Result,
        [int]$MaxOutputChars,
        [int]$MaxOutputRows,
        [int]$MaxOutputCols,
        [string]$ToolName,
        [string]$OriginalRequest = ''
    )

    $stdoutReduced = Reduce-TextByRowsAndCols ([string]$Result.stdout) $MaxOutputRows $MaxOutputCols
    $stderrReduced = Reduce-TextByRowsAndCols ([string]$Result.stderr) $MaxOutputRows $MaxOutputCols
    $stdout = Trim-Text $stdoutReduced.Text $MaxOutputChars
    $stderr = Trim-Text $stderrReduced.Text $MaxOutputChars

    $reductionSummary = @"
Reduction summary:
STDOUT removed rows: $($stdoutReduced.RowsRemoved), removed columns: $($stdoutReduced.ColsRemoved)
STDERR removed rows: $($stderrReduced.RowsRemoved), removed columns: $($stderrReduced.ColsRemoved)

"@

    $recoveryHint = Build-RecoveryHint -Command $Command -Stdout $stdout -Stderr $stderr -OriginalRequest $OriginalRequest
    $stdoutText = if ($stdout) { $stdout } else { '<empty>' }
    $stderrText = if ($stderr) { $stderr } else { '<empty>' }

    return @"
<|tool_result>call:$ToolName
Command:
$Command

Exit code: $($Result.exit_code)

$reductionSummary`STDOUT:
$stdoutText

STDERR:
$stderrText

<tool_result|>

Use this result to answer the original user request. If more inspection is needed, call $ToolName again.$recoveryHint
"@
}

function Run-ConfigSelfTests {
    $configText = @'
[agent]
model_profile = "local"
shell = "powershell"
cwd = "."
max_steps = 5
max_output_chars = 20000

[models.local]
url = "http://localhost/local"
model = "local-model"
temperature = 0.0
max_tokens = 111
request_timeout = 222

[models.openrouter-minimax-free]
url = "https://openrouter.ai/api/v1/chat/completions"
provider = "openai-chat"
model = "minimax/minimax-m2.5:free"
api_key_env = "OPENROUTER_API_KEY"
temperature = 0.0
max_tokens = 2048
request_timeout = 120

[models.google-gemma-free]
url = "https://generativelanguage.googleapis.com/v1beta"
provider = "google-gemini"
model = "models/gemma-4-26b-a4b-it"
api_key_env = "GEMINI_API_KEY"
temperature = 0.0
max_tokens = 2048
request_timeout = 120

[shells.powershell]
tool = "ps"
prompt = "SYSTEM.md"
executable = "powershell.exe"
args = ["-NoProfile", "-Command"]
'@

    $failures = New-Object System.Collections.ArrayList
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir | Out-Null
    try {
        $configPath = Join-Path $tempDir 'config.toml'
        Set-Content -LiteralPath $configPath -Value $configText -Encoding UTF8
        $baseArgs = [PSCustomObject]@{
            config = $configPath
            model_profile = $null
            shell = $null
            url = $null
            model = $null
            cwd = $null
            max_steps = $null
            temperature = $null
            max_tokens = $null
            request_timeout = $null
            max_output_chars = $null
            max_output_rows = $null
            max_output_cols = $null
        }

        $localConfig = Load-AgentConfig $baseArgs
        if ($localConfig.Model.Profile -ne 'local' -or $localConfig.Model.Model -ne 'local-model') {
            [void]$failures.Add([PSCustomObject]@{ Command = 'local model profile'; Expected = 'local, local-model'; Actual = "$($localConfig.Model.Profile), $($localConfig.Model.Model)" })
        }

        $openrouterArgs = $baseArgs.PSObject.Copy()
        $openrouterArgs.model_profile = 'openrouter-minimax-free'
        $openrouterConfig = Load-AgentConfig $openrouterArgs
        if ($openrouterConfig.Model.Model -ne 'minimax/minimax-m2.5:free') {
            [void]$failures.Add([PSCustomObject]@{ Command = 'openrouter model profile'; Expected = 'minimax/minimax-m2.5:free'; Actual = $openrouterConfig.Model.Model })
        }

        $googleArgs = $baseArgs.PSObject.Copy()
        $googleArgs.model_profile = 'google-gemma-free'
        $googleConfig = Load-AgentConfig $googleArgs
        if ($googleConfig.Model.Provider -ne 'google-gemini' -or $googleConfig.Model.Model -ne 'models/gemma-4-26b-a4b-it') {
            [void]$failures.Add([PSCustomObject]@{ Command = 'google model profile'; Expected = 'google-gemini, models/gemma-4-26b-a4b-it'; Actual = "$($googleConfig.Model.Provider), $($googleConfig.Model.Model)" })
        }

        $overrideArgs = $openrouterArgs.PSObject.Copy()
        $overrideArgs.model = 'override/model:free'
        $overrideConfig = Load-AgentConfig $overrideArgs
        if ($overrideConfig.Model.Model -ne 'override/model:free') {
            [void]$failures.Add([PSCustomObject]@{ Command = 'model override'; Expected = 'override/model:free'; Actual = $overrideConfig.Model.Model })
        }
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return @($failures)
}

function Run-SelfTest {
    $cases = @(
        @('powershell', 'Set-Content -Path ''hello.py'' -Value ''print("hello")'' -Encoding UTF8', $true),
        @('powershell', '''print("hello")'' | Set-Content -Path hello.py -Encoding UTF8', $true),
        @('powershell', "@'`nprint(`"hello`")`n'@ | Set-Content -Path hello.py -Encoding UTF8", $false),
        @('powershell', "(Get-Content -Raw buggy.py).Replace('a + c', 'a + b') | Set-Content -Path buggy.py -Encoding UTF8", $false),
        @('powershell', "(Get-Content -Raw buggy.py) -replace 'a \+ c', 'a + b' | Set-Content -Path buggy.py -Encoding UTF8", $false),
        @('powershell', 'Get-ChildItem -Filter *.py', $false),
        @('bash', 'echo ''print("hello")'' > hello.py', $true),
        @('bash', "cat > hello.py <<'PY'`nprint(`"hello`")`nPY", $false),
        @('bash', "python3 - <<'PY'`nfrom pathlib import Path`nPath('buggy.py').write_text(Path('buggy.py').read_text().replace('a + c', 'a + b'))`nPY", $false)
    )

    $parserCases = @(
        @("<|tool_call>call:ps`nGet-ChildItem`n<tool_call|>", 'ps', 'Get-ChildItem'),
        @("<|tool_call>call:ps`nGet-Location`n<|tool_call|>", 'ps', 'Get-Location'),
        @("<|tool_call>call:bash`nls -la`n<tool_call|>", 'bash', 'ls -la')
    )

    $failures = New-Object System.Collections.ArrayList

    foreach ($case in $cases) {
        $shellName = $case[0]
        $command = $case[1]
        $expected = [bool]$case[2]
        $actual = Uses-FragileScriptWrite -Command $command -ShellName $shellName
        if ($actual -ne $expected) {
            [void]$failures.Add([PSCustomObject]@{ Command = "$shellName`: $command"; Expected = $expected; Actual = $actual })
        }
    }

    foreach ($case in $parserCases) {
        $text = $case[0]
        $expectedTool = $case[1]
        $expectedCommand = $case[2]
        $parsed = Extract-ToolCall $text
        if (-not $parsed -or $parsed.ToolName -ne $expectedTool -or $parsed.Command -ne $expectedCommand) {
            $actual = if ($parsed) { "$($parsed.ToolName), $($parsed.Command)" } else { '<null>' }
            [void]$failures.Add([PSCustomObject]@{ Command = $text; Expected = "$expectedTool, $expectedCommand"; Actual = $actual })
        }
    }

    $oldTestKey = [Environment]::GetEnvironmentVariable('AGENT_LOOP_TEST_KEY')
    [Environment]::SetEnvironmentVariable('AGENT_LOOP_TEST_KEY', 'test-key', 'Process')
    try {
        $headerCases = @(
            @((New-ModelConfig 'local' 'openai-chat' $script:DEFAULT_URL $script:DEFAULT_MODEL 0.0 1024 600 ''), @{'Content-Type' = 'application/json'}),
            @((New-ModelConfig 'openrouter' 'openai-chat' 'https://openrouter.ai/api/v1/chat/completions' 'minimax/minimax-m2.5:free' 0.0 2048 120 'AGENT_LOOP_TEST_KEY'), @{'Content-Type' = 'application/json'; 'Authorization' = 'Bearer test-key'}),
            @((New-ModelConfig 'google' 'google-gemini' 'https://generativelanguage.googleapis.com/v1beta' 'models/gemma-4-26b-a4b-it' 0.0 2048 120 'AGENT_LOOP_TEST_KEY'), @{'Content-Type' = 'application/json'; 'x-goog-api-key' = 'test-key'})
        )
        foreach ($case in $headerCases) {
            $modelConfig = $case[0]
            $expectedHeaders = $case[1]
            $actualHeaders = Build-Headers $modelConfig
            foreach ($key in $expectedHeaders.Keys) {
                if (-not $actualHeaders.ContainsKey($key) -or $actualHeaders[$key] -ne $expectedHeaders[$key]) {
                    [void]$failures.Add([PSCustomObject]@{ Command = $modelConfig.Profile; Expected = ($expectedHeaders | ConvertTo-Json -Compress); Actual = ($actualHeaders | ConvertTo-Json -Compress) })
                    break
                }
            }
        }
    } finally {
        if ($null -eq $oldTestKey) {
            [Environment]::SetEnvironmentVariable('AGENT_LOOP_TEST_KEY', $null, 'Process')
        } else {
            [Environment]::SetEnvironmentVariable('AGENT_LOOP_TEST_KEY', $oldTestKey, 'Process')
        }
    }

    try {
        [void](Build-Headers (New-ModelConfig 'missing-key' 'openai-chat' $script:DEFAULT_URL $script:DEFAULT_MODEL 0.0 1024 600 'AGENT_LOOP_MISSING_KEY'))
        [void]$failures.Add([PSCustomObject]@{ Command = 'missing api key'; Expected = 'ValueError'; Actual = 'no error' })
    } catch {
        # expected
    }

    $nonAsciiText = 'Verkn' + [string][char]0x00FC + 'pfung ' + [string][char]0x2013 + ' ' + [string][char]0x20AC
    $utf8Payload = [ordered]@{ messages = @([PSCustomObject]@{ role = 'user'; content = $nonAsciiText }) }
    $utf8Bytes = ConvertTo-JsonUtf8Bytes $utf8Payload
    $utf8Json = [System.Text.Encoding]::UTF8.GetString($utf8Bytes)
    $utf8RoundTrip = $utf8Json | ConvertFrom-Json
    if ([string]$utf8RoundTrip.messages[0].content -ne $nonAsciiText -or $utf8Bytes -contains 252) {
        [void]$failures.Add([PSCustomObject]@{ Command = 'json utf8 encoding'; Expected = 'UTF-8 bytes for non-ASCII JSON'; Actual = $utf8Json })
    }

    $parsedArgs = Parse-CommandLineArgs @('--chat', 'hello')
    if (-not $parsedArgs.chat -or ($parsedArgs.request -join ' ') -ne 'hello') {
        [void]$failures.Add([PSCustomObject]@{ Command = '--chat arg parse'; Expected = 'True, hello'; Actual = "$($parsedArgs.chat), $($parsedArgs.request -join ' ')" })
    }

    foreach ($failure in Run-ConfigSelfTests) {
        [void]$failures.Add($failure)
    }

    if ($failures.Count -gt 0) {
        foreach ($failure in $failures) {
            [Console]::Error.WriteLine("FAIL: expected $($failure.Expected), got $($failure.Actual): $($failure.Command)")
        }
        return 1
    }
    Write-Host 'self-test ok'
    return 0
}

function Run-AgentTurn {
    param(
        [System.Collections.ArrayList]$Messages,
        [string]$Request,
        [object]$Config,
        [object]$CliArgs,
        [string]$Cwd
    )

    for ($step = 1; $step -le $Config.MaxSteps; $step++) {
        Write-Host "`n--- model step $step ---"
        try {
            $assistantText = Invoke-Chat -ModelConfig $Config.Model -Messages @($Messages)
        } catch {
            [Console]::Error.WriteLine($_.Exception.Message)
            return 1
        }

        Write-Host $assistantText
        if (-not $assistantText.Trim()) {
            [void]$Messages.Add((New-Message 'user' "Your previous answer was empty. Return either one complete <|tool_call>call:$($Config.Shell.Tool) tool call for inspection or a final plain-text answer."))
            continue
        }

        [void]$Messages.Add((New-Message 'assistant' $assistantText))
        $toolCall = Extract-ToolCall $assistantText

        if ($null -eq $toolCall -and (Has-ToolCallStart $assistantText)) {
            [void]$Messages.Add((New-Message 'user' "The tool call was malformed. Use exactly this format if more inspection is needed:`n<|tool_call>call:$($Config.Shell.Tool)`n$($Config.Shell.Name) command here`n<tool_call|>`nOtherwise return the final answer in plain text."))
            continue
        }
        if ($null -eq $toolCall) {
            return 0
        }

        $toolName = $toolCall.ToolName
        $command = $toolCall.Command
        $hadExtraToolCall = $toolCall.HadExtraToolCall

        if ($toolName.ToLowerInvariant() -ne $Config.Shell.Tool.ToLowerInvariant()) {
            [void]$Messages.Add((New-Message 'user' "Unsupported tool call: call:$toolName. Only call:$($Config.Shell.Tool) is available. Use call:$($Config.Shell.Tool) for shell inspection or return the final answer in plain text."))
            continue
        }
        if (-not $command) {
            [void]$Messages.Add((New-Message 'user' "The call:$($Config.Shell.Tool) tool call did not contain a command. Resend one complete call:$($Config.Shell.Tool) tool call with the command body, or return the final answer."))
            continue
        }

        if (Uses-FragileScriptWrite -Command $command -ShellName $Config.Shell.Name) {
            if ($Config.Shell.Name -eq 'powershell') {
                $rewriteHint = 'use a PowerShell here-string piped to Set-Content -Encoding UTF8'
            } else {
                $rewriteHint = "use a quoted Bash here-doc such as cat > file.py <<'PY'"
            }
            [void]$Messages.Add((New-Message 'user' "Do not write script bodies with fragile single-line redirection or quoted pipeline strings. Resend exactly one call:$($Config.Shell.Tool) command that uses $rewriteHint, then wait for the tool result."))
            continue
        }

        if (-not (Should-RunCommand -Command $command -CliArgs $CliArgs -ShellName $Config.Shell.Name)) {
            Write-Host 'Command skipped by user.'
            return 1
        }

        Write-Host "`n--- $($Config.Shell.Name) step $step ---"
        Write-Host $command
        $result = Run-ShellCommand -Command $command -Cwd $Cwd -Shell $Config.Shell

        Write-Host "Exit code: $($result.exit_code)"
        $stdoutReduced = Reduce-TextByRowsAndCols ([string]$result.stdout) $Config.MaxOutputRows $Config.MaxOutputCols
        $stderrReduced = Reduce-TextByRowsAndCols ([string]$result.stderr) $Config.MaxOutputRows $Config.MaxOutputCols

        if ($stdoutReduced.Text) {
            Write-Host '[Reduced STDOUT context]'
            Write-Host "removed rows=$($stdoutReduced.RowsRemoved), removed columns=$($stdoutReduced.ColsRemoved)"
            Write-Host (Trim-Text $stdoutReduced.Text $Config.MaxOutputChars)
        }
        if ($stderrReduced.Text) {
            [Console]::Error.WriteLine('[Reduced STDERR context]')
            [Console]::Error.WriteLine("removed rows=$($stderrReduced.RowsRemoved), removed columns=$($stderrReduced.ColsRemoved)")
            [Console]::Error.WriteLine((Trim-Text $stderrReduced.Text $Config.MaxOutputChars))
        }

        $resultMessage = Format-ToolResult `
            -Command $command `
            -Result $result `
            -MaxOutputChars $Config.MaxOutputChars `
            -MaxOutputRows $Config.MaxOutputRows `
            -MaxOutputCols $Config.MaxOutputCols `
            -ToolName $Config.Shell.Tool `
            -OriginalRequest $Request

        if ($hadExtraToolCall) {
            $resultMessage += "`n`nYour previous response contained more than one tool call. Only the first tool call was executed. If another command is still needed, send exactly one new call:$($Config.Shell.Tool) now. Do not claim that skipped commands ran."
        }
        [void]$Messages.Add((New-Message 'user' $resultMessage))
    }

    [Console]::Error.WriteLine("`nStopped after --max-steps=$($Config.MaxSteps).")
    return 1
}

function Main {
    param([string[]]$Argv)

    try {
        $parsedArgs = Parse-CommandLineArgs $Argv
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        Show-Usage
        return 2
    }

    if ($parsedArgs.help) {
        Show-Usage
        return 0
    }

    if ($parsedArgs.self_test) {
        return Run-SelfTest
    }

    try {
        $config = Load-AgentConfig $parsedArgs
        $systemPrompt = Load-Prompt $config.Shell.PromptPath
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        return 2
    }

    $request = ($parsedArgs.request -join ' ').Trim()
    if (-not $request) {
        $request = (Read-Host 'User request').Trim()
    }
    if (-not $request) {
        [Console]::Error.WriteLine('No request provided.')
        return 2
    }

    $cwd = Resolve-ConfigPath ([string]$config.Cwd) (Get-Location).Path
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        [Console]::Error.WriteLine("Working directory does not exist or is not a directory: $cwd")
        return 2
    }
    if (-not (Find-Executable $config.Shell.Executable)) {
        [Console]::Error.WriteLine("Configured shell executable was not found for '$($config.Shell.Name)': $($config.Shell.Executable)")
        return 2
    }

    $messages = New-Object System.Collections.ArrayList
    [void]$messages.Add((New-Message 'system' $systemPrompt))
    [void]$messages.Add((New-Message 'user' (Build-InitialUserPrompt -Request $request -SystemPrompt $systemPrompt -Shell $config.Shell)))

    while ($true) {
        $status = Run-AgentTurn -Messages $messages -Request $request -Config $config -CliArgs $parsedArgs -Cwd $cwd
        if ($status -ne 0 -or -not $parsedArgs.chat) {
            return $status
        }
        try {
            $request = (Read-Host "`nFollow-up request [empty to exit]").Trim()
        } catch {
            return 0
        }
        if (-not $request -or @('exit', 'quit') -contains $request.ToLowerInvariant()) {
            return 0
        }
        [void]$messages.Add((New-Message 'user' "User follow-up request: $request"))
    }
}

function ConvertTo-LegacyArgv {
    param(
        [hashtable]$BoundParameters,
        [string[]]$RemainingRequest
    )

    $translated = New-Object System.Collections.ArrayList
    $valueOptions = @(
        @('Config', '--config'),
        @('ModelProfile', '--model-profile'),
        @('Shell', '--shell'),
        @('Url', '--url'),
        @('Model', '--model'),
        @('Cwd', '--cwd'),
        @('MaxSteps', '--max-steps'),
        @('Temperature', '--temperature'),
        @('MaxTokens', '--max-tokens'),
        @('RequestTimeout', '--request-timeout'),
        @('MaxOutputChars', '--max-output-chars'),
        @('MaxOutputRows', '--max-output-rows'),
        @('MaxOutputCols', '--max-output-cols')
    )
    $flagOptions = @(
        @('SelfTest', '--self-test'),
        @('Chat', '--chat'),
        @('AskAlways', '--ask-always'),
        @('AutoRunAll', '--auto-run-all'),
        @('Help', '--help')
    )

    foreach ($option in $valueOptions) {
        $parameterName = $option[0]
        $argumentName = $option[1]
        if ($BoundParameters.ContainsKey($parameterName) -and $null -ne $BoundParameters[$parameterName]) {
            [void]$translated.Add($argumentName)
            [void]$translated.Add([string]$BoundParameters[$parameterName])
        }
    }

    foreach ($option in $flagOptions) {
        $parameterName = $option[0]
        $argumentName = $option[1]
        if ($BoundParameters.ContainsKey($parameterName) -and [bool]$BoundParameters[$parameterName]) {
            [void]$translated.Add($argumentName)
        }
    }

    foreach ($item in @($RemainingRequest)) {
        [void]$translated.Add([string]$item)
    }

    return @($translated)
}

exit (Main (ConvertTo-LegacyArgv -BoundParameters $PSBoundParameters -RemainingRequest $Request))
