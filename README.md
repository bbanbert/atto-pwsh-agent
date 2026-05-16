
## $PROFILE entries
$miniSweAgentEnv = Join-Path $env:LOCALAPPDATA 'mini-swe-agent\.env'
if (Test-Path $miniSweAgentEnv) {
    Get-Content -LiteralPath $miniSweAgentEnv | ForEach-Object {
        if ($_ -match '^(OPENROUTER_API_KEY|GEMINI_API_KEY|GROQ_API_KEY)=(.*)$') {
            $name = $Matches[1]
            $value = $Matches[2].Trim().Trim('"').Trim("'")
            Set-Item -Path "Env:$name" -Value $value
        }
    }
}
# <<< mini-swe-agent API keys <<<

# >>> atto-agent alias >>>
function atto-agent {
    py -3.14 'C:\Users\j9100\tmp\agents\simple\agent_loop.py' @args
}
# <<< atto-agent alias <<<

# >>> atto-pwsh-agent alias >>>
function atto-pwsh-agent {
    & 'C:\Users\j9100\tmp\agents\atto-pwsh-agent\agent-loop.ps1' @args
}


## manuell in Terminal
´´´ POWERSHELL
[Environment]::SetEnvironmentVariable(
  "OPENROUTER_API_KEY",
  "sk-or-v1-fiktiver-schluessel-1234567890abcdef",
  "User"
)
´´´
echo $env:OPENROUTER_API_KEY
