#Requires -Version 7
# Unit tests for Install-VouchSchedule.ps1 and the -LogDir transcript. Nothing here
# registers a task: New-ScheduledTask* only build objects in memory.

BeforeAll {
    . (Join-Path -Path $PSScriptRoot -ChildPath 'TestHelpers.ps1')
    $installer = Join-Path -Path $PSScriptRoot -ChildPath '..\Install-VouchSchedule.ps1'
    . ([scriptblock]::Create((Get-VouchFunctionSource -Path $installer)))
    . ([scriptblock]::Create((Get-VouchFunctionSource)))
}

Describe 'Get-VouchTaskArguments' {
    It 'builds a hidden, profile-free, policy-bypassing command with quoted paths' {
        $arguments = Get-VouchTaskArguments -ScriptPath 'C:\Tools\My Vouch\vouch.ps1' -LogDir 'C:\Audit Out\logs\' `
            -CsvPath 'C:\Audit\q3 itgc.csv' -OutputDir 'C:\Audit Out'
        $arguments | Should -BeLike '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Tools\My Vouch\vouch.ps1"*'
        $arguments | Should -Match '-CsvPath "C:\\Audit\\q3 itgc\.csv"'
        $arguments | Should -Match '-OutputDir "C:\\Audit Out"'
        $arguments | Should -Match '-FailOnWarning'
        # A trailing backslash would escape the closing quote.
        $arguments | Should -Match '-LogDir "C:\\Audit Out\\logs"$'
    }

    It 'passes the optional switches only when asked' {
        $plain = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' -FailOnWarning $false
        $plain | Should -Not -Match 'FailOnWarning|SaveImages|ImageFormat|CsvPath|OutputDir'
        $full = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' -ImageFormat png -SaveImages $true
        $full | Should -Match '-ImageFormat png -SaveImages -FailOnWarning'
    }

    It 'always asks for the JSON summary and passes profile and port when given' {
        $plain = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs'
        $plain | Should -Match '-JsonSummary'
        $plain | Should -Not -Match 'EdgeProfileDir|DebugPort'
        $custom = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' -EdgeProfileDir 'C:\P 2\' -DebugPort 9333
        $custom | Should -Match '-EdgeProfileDir "C:\\P 2" -DebugPort 9333'
        $plain | Should -Not -Match 'UseVirtualDesktop'
        Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' -UseVirtualDesktop $true |
            Should -Match '-UseVirtualDesktop'
    }

    It 'splits back into the same arguments the way CreateProcess would' {
        $arguments = Get-VouchTaskArguments -ScriptPath 'C:\Tools\My Vouch\vouch.ps1' -LogDir 'C:\Out\logs' -CsvPath 'C:\A B\c.csv'
        # Round-trip through a real process: echo the argv pwsh receives.
        $echo = Join-Path -Path $TestDrive -ChildPath 'echo.ps1'
        Set-Content -LiteralPath $echo -Value '$args | ForEach-Object { $_ }' -Encoding utf8
        $pwsh = (Get-Process -Id $PID).Path
        $argumentsForEcho = $arguments -replace '-File "[^"]+"', "-File `"$echo`""
        $received = & cmd.exe /c "`"$pwsh`" $argumentsForEcho"
        $received | Should -Contain 'C:\A B\c.csv'
        $received | Should -Contain 'C:\Out\logs'
    }
}

Describe 'Get-TaskArgumentValue' {
    It 'reads values back from the argument string' {
        $arguments = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\Out Dir\logs' -OutputDir 'C:\Out Dir'
        Get-TaskArgumentValue -Arguments $arguments -Name 'OutputDir' | Should -Be 'C:\Out Dir'
        Get-TaskArgumentValue -Arguments $arguments -Name 'LogDir' | Should -Be 'C:\Out Dir\logs'
        Get-TaskArgumentValue -Arguments $arguments -Name 'CsvPath' | Should -Be ''
        $root = Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -ConfigPath 'C:\c.json' -Override ([ordered]@{ OutputDir = 'D:\' })
        Get-TaskArgumentValue -Arguments $root -Name 'OutputDir' | Should -Be 'D:\'
        Get-TaskArgumentValue -Arguments $root -Name 'ConfigPath' | Should -Be 'C:\c.json'
    }
}

Describe 'Schedules of a configuration file (-ConfigPath)' {
    BeforeAll {
        $script:Root = Split-Path -Path $script:VouchPath -Parent
        $script:Sample = Join-Path $script:Root 'captures.sample.json'
        $script:EngineParams = @(([System.Management.Automation.Language.Parser]::ParseFile($script:VouchPath, [ref]$null, [ref]$null)).ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath })
        function New-TestConfig([string]$Folder, [scriptblock]$Change = $null) {
            [void][System.IO.Directory]::CreateDirectory($Folder)
            $config = ConvertFrom-VouchJson -Text ([System.IO.File]::ReadAllText($script:Sample))
            if ($null -ne $Change) { & $Change $config }
            $path = Join-Path $Folder 'evidence.json'
            [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 32), [System.Text.UTF8Encoding]::new($false))
            return $path
        }
        # What pwsh -File hands the script, from the exact string Task Scheduler stores
        # (CreateProcess, no shell in between): the echo script writes its argv as JSON.
        function Get-ReceivedArgument([string]$Arguments) {
            $echo = Join-Path $TestDrive 'echo-args.ps1'
            $out = Join-Path $TestDrive 'echo-args.json'
            [System.IO.File]::WriteAllText($echo, "[System.IO.File]::WriteAllText('$($out.Replace("'", "''"))', (ConvertTo-Json -InputObject @(`$args) -Compress), [System.Text.UTF8Encoding]::new(`$false))", [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out }
            $info = [System.Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
            $info.Arguments = [regex]::Replace($Arguments, '-File "[^"]+"', { '-File "' + $echo + '"' })
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $process = [System.Diagnostics.Process]::Start($info)
            [void]$process.WaitForExit(60000)
            return @([System.IO.File]::ReadAllText($out) | ConvertFrom-Json)
        }
    }

    It 'runs the file with -NoPrompt and the JSON summary, and passes no installer default over the file' {
        $config = New-TestConfig (Join-Path $TestDrive 'plain')
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config }
        $setup.Kind | Should -Be 'config'
        $setup.Definition | Should -Be $config
        $setup.Arguments | Should -BeLike "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$($script:VouchPath)`" -ConfigPath `"$config`" -NoPrompt -JsonSummary -LogDir *"
        $setup.Arguments | Should -Not -Match 'CsvPath|OutputDir|ImageFormat|SaveImages|FailOnWarning|EdgeProfileDir|DebugPort|UseVirtualDesktop'
        # The file's output folder ("reports", read from the file's own folder), its logs inside.
        $setup.OutputDir | Should -Be (Join-Path (Split-Path $config) 'reports')
        $setup.LogDir | Should -Be (Join-Path (Split-Path $config) 'reports\logs')
        Get-TaskArgumentValue -Arguments $setup.Arguments -Name 'LogDir' | Should -Be $setup.LogDir
    }

    It 'passes a typed installer setting on as an override, with its value, and only then' {
        $config = New-TestConfig (Join-Path $TestDrive 'typed')
        Push-Location $TestDrive
        try {
            $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters ([ordered]@{
                    ConfigPath = $config; OutputDir = 'out here'; ImageFormat = 'jpeg'; SaveImages = [switch]$false
                    AllowWarnings = [switch]$true; EdgeProfileDir = 'C:\Profiles\Audit 2\'; DebugPort = 9333; UseVirtualDesktop = [switch]$true })
        }
        finally { Pop-Location }
        $setup.Arguments | Should -Match ([regex]::Escape("-OutputDir `"$(Join-Path $TestDrive 'out here')`" -ImageFormat jpeg -SaveImages:`$false -FailOnWarning:`$false -EdgeProfileDir `"C:\Profiles\Audit 2`" -DebugPort 9333 -UseVirtualDesktop -NoPrompt"))
        $setup.OutputDir | Should -Be (Join-Path $TestDrive 'out here')
        $setup.LogDir | Should -Be (Join-Path $TestDrive 'out here\logs')
        $setup.ProfileDir | Should -Be 'C:\Profiles\Audit 2\'
        # Allowing warnings again: the file's failOnWarning is beaten the other way round.
        $strict = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config; AllowWarnings = [switch]$false; SaveImages = [switch]$true }
        $strict.Arguments | Should -Match '-SaveImages -FailOnWarning -NoPrompt'
        # Every switch it writes is one vouch.ps1 has.
        foreach ($token in (Get-ReceivedArgument $setup.Arguments)) {
            if ($token -match '^-([A-Za-z]+)(:.*)?$') { $script:EngineParams | Should -Contain $Matches[1] }
        }
    }

    It 'always passes -NoPrompt for CSV schedules too' {
        $csv = Join-Path $TestDrive 'pages.csv'
        Copy-Item -LiteralPath (Join-Path $script:Root 'captures.sample.csv') -Destination $csv
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ CsvPath = $csv }
        $setup.Kind | Should -Be 'csv'
        $setup.Arguments | Should -Match "-CsvPath `"$([regex]::Escape($csv))`" -OutputDir .* -FailOnWarning -NoPrompt -JsonSummary -LogDir "
        Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' | Should -Match ' -NoPrompt '
    }

    It 'refuses -CsvPath and -ConfigPath together, in plain words' {
        { Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = 'a.json'; CsvPath = 'b.csv' } } |
            Should -Throw 'Use either -CsvPath or -ConfigPath, not both.*'
    }

    It 'checks the file with the engine''s own messages and schedules nothing when it has problems' {
        $bad = New-TestConfig (Join-Path $TestDrive 'bad') { param($c) $c['pages'][0]['url'] = 'intranet'; $c['output']['jpegQuality'] = 500 }
        Mock Register-ScheduledTask { }
        Mock Write-Host { }
        { Install-VouchTask -ScriptRoot $script:Root -Parameters @{ ConfigPath = $bad } } | Should -Throw "Fix '$bad' and run again. Nothing was scheduled."
        Should -Invoke Register-ScheduledTask -Times 0 -Exactly
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '  - output.jpegQuality: must be a whole number from 1 to 100, without quotes (found 500).' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '  - pages[0].url: must start with http:// or https:// (found "intranet").' }
        $missing = Join-Path $TestDrive 'nowhere.json'
        { Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $missing } } | Should -Throw "Configuration file not found: $missing*"
        $none = New-TestConfig (Join-Path $TestDrive 'off') { param($c) foreach ($p in $c['pages']) { $p['enabled'] = $false } }
        { Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $none } } | Should -Throw '*Every page*is switched off*Nothing was scheduled.'
        $empty = New-TestConfig (Join-Path $TestDrive 'empty') { param($c) $c['pages'].Clear() }
        { Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $empty } } | Should -Throw '*has no pages*'
    }

    It 'points out what makes no sense unattended, and says what happens instead' {
        $config = New-TestConfig (Join-Path $TestDrive 'concerns') { param($c) $c['output']['openReport'] = $true }
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config }
        $text = $setup.Concerns -join "`n"
        $text | Should -Match 'Open the report when the run is finished" is on, but a scheduled run never opens the report'
        $text | Should -Match 'Asks you when a page is not ready \(Payroll - security settings\): in a scheduled run nobody is asked; such a page is captured as it is, with a warning\.'
        $text | Should -Match 'Pauses for you \(Payroll - security settings\): in a scheduled run the pause is skipped'
        ($setup.Notes -join ' ') | Should -Match 'Warnings count as success'
        # Switched-off pages do not run, so they are not mentioned; nothing to say for a plain file.
        $quiet = New-TestConfig (Join-Path $TestDrive 'quiet') { param($c) $c['pages'][2]['enabled'] = $false; $c['output']['failOnWarning'] = $true }
        $calm = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $quiet }
        @($calm.Concerns | Where-Object { $_ -notmatch 'audit browser profile' }).Count | Should -Be 0
        $calm.Notes.Count | Should -Be 0
        # A default onNotReady "prompt" counts for every page that does not override it.
        $all = New-TestConfig (Join-Path $TestDrive 'all-prompt') { param($c) $c['defaults']['onNotReady'] = 'prompt' }
        ((Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $all }).Concerns -join ' ') | Should -Match 'Asks you when a page is not ready \(Intranet Dashboard, App Settings - Audit Log, Payroll - security settings\)'
    }

    It 'keeps the file''s own log folder instead of adding one' {
        $config = New-TestConfig (Join-Path $TestDrive 'own-logs') { param($c) $c['output']['logDir'] = 'transcripts'; $c['output']['dir'] = 'C:\Evidence\Q3' }
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config }
        $setup.Arguments | Should -Not -Match '-LogDir'
        $setup.Arguments | Should -Match ' -NoPrompt -JsonSummary$'
        $setup.LogDir | Should -Be (Join-Path (Split-Path $config) 'transcripts')
        $setup.OutputDir | Should -Be 'C:\Evidence\Q3'
    }

    It 'stores paths so pwsh receives them exactly: <Case>' -ForEach @(
        @{ Case = 'spaces'; Folder = 'Audit files Q3' }
        @{ Case = 'an apostrophe and brackets'; Folder = "Eric's (draft)" }
        @{ Case = 'an ampersand and a semicolon'; Folder = 'R&D; review' }
        @{ Case = 'a lone percent sign'; Folder = '100% sure' }
        @{ Case = 'a percent name Windows does not know'; Folder = '%NOT_A_VOUCH_VARIABLE%' }
        @{ Case = 'non-ASCII letters'; Folder = 'Prüfung 日本 é' }
        @{ Case = 'a dollar sign and backtick'; Folder = '$HOME `n x' }
        @{ Case = 'a comma'; Folder = 'a,b' }
    ) {
        $config = New-TestConfig (Join-Path $TestDrive "quote-$Folder")
        $output = Join-Path $TestDrive "out-$Folder\"
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config; OutputDir = $output }
        $received = Get-ReceivedArgument $setup.Arguments
        $received[$received.IndexOf('-ConfigPath') + 1] | Should -BeExactly $config
        $received[$received.IndexOf('-OutputDir') + 1] | Should -BeExactly $output.TrimEnd('\')
        $received[$received.IndexOf('-LogDir') + 1] | Should -BeExactly (Join-Path $output.TrimEnd('\') 'logs')
        $received | Should -Contain '-NoPrompt'
    }

    It 'keeps a drive root a drive root' {
        $received = Get-ReceivedArgument (Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -ConfigPath 'C:\c.json' -LogDir 'C:\' -Override ([ordered]@{ OutputDir = 'C:\' }))
        $received[$received.IndexOf('-OutputDir') + 1] | Should -BeExactly 'C:\'
        $received[$received.IndexOf('-LogDir') + 1] | Should -BeExactly 'C:\'
    }

    It 'refuses a path Task Scheduler would change (%NAME% of a Windows variable)' {
        $config = New-TestConfig (Join-Path $TestDrive '%USERNAME% files')
        { Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config } } |
            Should -Throw '*between % signs*Task Scheduler would replace*Nothing was scheduled.'
    }

    It 'registers the task with the checked arguments and says what it found' {
        $config = New-TestConfig (Join-Path $TestDrive 'register')
        Mock Register-ScheduledTask { }
        Mock Write-Host { }
        Install-VouchTask -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config; Schedule = 'AtLogOn'; TaskName = 'Vouch test (never registered)' }
        Should -Invoke Register-ScheduledTask -Times 1 -Exactly -ParameterFilter {
            $TaskName -eq 'Vouch test (never registered)' -and $Action.Arguments -like "*-ConfigPath `"$config`" -NoPrompt -JsonSummary -LogDir *" -and $Action.WorkingDirectory -eq $script:Root
        }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq "  Configuration: $config" }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '  - Pauses for you (Payroll - security settings)*' }
    }

    It '-Status names the file the task runs and where its reports go, read from the file' {
        $config = New-TestConfig (Join-Path $TestDrive 'status') { param($c) $c['output']['dir'] = 'evidence out' }
        $setup = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config }
        $task = [pscustomobject]@{ State = 'Ready'; Actions = @([pscustomobject]@{ Execute = 'pwsh.exe'; Arguments = $setup.Arguments }) }
        Mock Get-VouchTask { $task }
        Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = $null; NextRunTime = $null; LastTaskResult = 267011 } }
        $script:Lines = [System.Collections.Generic.List[string]]::new()
        Mock Write-Host { $script:Lines.Add("$Object") }
        Show-VouchStatus -Name 'Vouch test' -ScriptRoot $script:Root
        $script:Lines | Should -Contain "Pages from:  $config (configuration file)"
        $script:Lines | Should -Contain "Reports go:  $(Join-Path (Split-Path $config) 'evidence out')"
        $script:Lines | Should -Contain 'Last result: Has not run yet'
        # An override on the task wins over the file; a CSV task says so.
        $typed = Get-VouchScheduleSetup -ScriptRoot $script:Root -Parameters @{ ConfigPath = $config; OutputDir = 'C:\Typed Out' }
        (Get-VouchTaskTarget -Arguments $typed.Arguments -ScriptRoot $script:Root).OutputDir | Should -Be 'C:\Typed Out'
        $csv = Get-VouchTaskTarget -Arguments (Get-VouchTaskArguments -ScriptPath 'C:\v\vouch.ps1' -LogDir 'C:\v\logs' -CsvPath 'C:\v\q.csv') -ScriptRoot 'C:\v'
        $csv.Definition | Should -Be 'C:\v\q.csv (CSV file)'
        $csv.OutputDir | Should -Be 'C:\v\reports'
        # A file that is gone or broken now is reported, not a crash.
        Remove-Item -LiteralPath $config
        $gone = Get-VouchTaskTarget -Arguments $setup.Arguments -ScriptRoot $script:Root
        $gone.Problem | Should -Match 'missing or has problems'
    }
}

Describe 'New-VouchTrigger' {
    BeforeAll { $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }

    It 'Weekdays runs Monday to Friday at the given time' {
        $trigger = New-VouchTrigger -Schedule Weekdays -At '7:05' -UserId $user
        $trigger.DaysOfWeek | Should -Be 62   # Mon..Fri bit mask
        ([datetime]$trigger.StartBoundary).ToString('HH:mm') | Should -Be '07:05'
    }

    It 'Weekly uses the given days' {
        $trigger = New-VouchTrigger -Schedule Weekly -At '18:30' -DaysOfWeek Monday, Thursday -UserId $user
        $trigger.DaysOfWeek | Should -Be (2 + 16)
    }

    It 'Daily runs every day' {
        (New-VouchTrigger -Schedule Daily -At '06:00' -UserId $user).DaysInterval | Should -Be 1
    }

    It 'AtLogOn waits three minutes after sign-in' {
        $trigger = New-VouchTrigger -Schedule AtLogOn -At '08:00' -UserId $user
        $trigger.Delay | Should -Be 'PT3M'
        $trigger.UserId | Should -Be $user
    }
}

Describe 'Get-ExitCodeMeaning' {
    It 'explains <Code>' -ForEach @(
        @{ Code = 0; Pattern = 'Success*' }, @{ Code = 2; Pattern = '*FAILED*' }
        @{ Code = 3; Pattern = '*expired login*' }, @{ Code = 267011; Pattern = 'Has not run yet' }
        @{ Code = 2147942402; Pattern = 'Task Scheduler code 0x80070002' }
    ) {
        Get-ExitCodeMeaning -Code $Code | Should -BeLike $Pattern
    }
}

Describe 'vouch.ps1 -LogDir' {
    It 'writes a transcript of the run into the folder, creating it' {
        $logDir = Join-Path -Path $TestDrive -ChildPath 'logs\nested'
        Start-RunLog -Directory $logDir | Should -BeTrue
        try { Write-Host 'hello from the run' }
        finally { [void](Stop-Transcript) }
        $log = Get-ChildItem -LiteralPath $logDir -Filter 'vouch_*.log'
        @($log).Count | Should -Be 1
        Get-Content -LiteralPath $log.FullName -Raw | Should -Match 'hello from the run'
    }

    It 'does nothing without a folder' {
        Start-RunLog -Directory '' | Should -BeFalse
    }

    It 'writes the log and exit code for a run that stops early' {
        $folder = Join-Path -Path $TestDrive -ChildPath 'early'
        [void](New-Item -ItemType Directory -Path $folder)
        Copy-Item -LiteralPath $script:VouchPath -Destination (Join-Path $folder 'vouch.ps1')
        $logDir = Join-Path -Path $folder -ChildPath 'logs'
        $pwsh = (Get-Process -Id $PID).Path
        & $pwsh -NoProfile -NonInteractive -File (Join-Path $folder 'vouch.ps1') -CsvPath (Join-Path $folder 'missing.csv') -LogDir $logDir *> $null
        $LASTEXITCODE | Should -Be 1
        $text = Get-Content -LiteralPath (Get-ChildItem -LiteralPath $logDir -Filter 'vouch_*.log').FullName -Raw
        $text | Should -Match 'Capture definition CSV not found'
        $text | Should -Match 'Exit code: 1'
    }
}
