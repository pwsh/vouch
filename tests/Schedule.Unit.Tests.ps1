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
