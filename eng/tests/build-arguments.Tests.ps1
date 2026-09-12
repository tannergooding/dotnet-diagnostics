# Licensed to the .NET Foundation under one or more agreements.
# The .NET Foundation licenses this file to you under the MIT license.

Describe 'Windows build and test argument forwarding' {
    BeforeEach {
        $repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $fixture = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Force "$fixture\eng\common" | Out-Null
        Copy-Item "$repoRoot\Build.cmd", "$repoRoot\Test.cmd" $fixture
        Copy-Item "$repoRoot\eng\build.ps1" "$fixture\eng"
        Set-Content "$fixture\eng\Build-Native.cmd" "@echo off`r`nexit /b 0"

        # Keep Arcade's real parameter binding, replacing only build execution.
        $tokens = $null
        $parseErrors = $null
        $common = [System.Management.Automation.Language.Parser]::ParseFile(
            "$repoRoot\eng\common\build.ps1", [ref]$tokens, [ref]$parseErrors)
        $parseErrors.Count | Should Be 0
        $capture = '[CmdletBinding(PositionalBinding=$false)]' + "`n" + $common.ParamBlock.Extent.Text + @'

[pscustomobject]@{
    Restore = [bool]$restore
    Build = [bool]$build
    Test = [bool]$test
    Properties = @($properties)
} | ConvertTo-Json -Compress | Add-Content "$PSScriptRoot\..\..\calls.jsonl"
$global:LASTEXITCODE = 0
if ($test -and $properties -contains '/p:SimulateTestFailure=true') {
    exit 23
}
'@
        Set-Content "$fixture\eng\common\build.ps1" $capture
        Set-Content "$fixture\calls.jsonl" ''
    }

    It 'keeps build actions out of the test invocation for <action>' -TestCases @(
        @{ action = '-restore' }, @{ action = '-r' }, @{ action = '-build' },
        @{ action = '-b' }, @{ action = '-rebuild' }, @{ action = '-clean' },
        @{ action = '-deployDeps' }, @{ action = '-deploy' },
        @{ action = '-integrationTest' }, @{ action = '-performanceTest' },
        @{ action = '-sign' }, @{ action = '-pack' }, @{ action = '-publish' },
        @{ action = '-productBuild' }, @{ action = '-pb' },
        @{ action = '-BUILD:$false' }
    ) {
        param($action)
        $forward = @($action, '/p:OfficialBuildId=20260911.21', '/property:PackageWithCDac=true', '/m:1')
        & "$fixture\eng\build.ps1" -test -skipnative -skipmanaged @forward
        $calls = @(Get-Content "$fixture\calls.jsonl" | Where-Object { $_ } | ConvertFrom-Json)
        $calls.Count | Should Be 2
        $calls[1].Test | Should Be $true
        $calls[1].Build | Should Be $false
        $calls[1].Restore | Should Be $true
        ($calls[1].Properties -contains $action) | Should Be $false
        ($calls[1].Properties -contains '/p:OfficialBuildId=20260911.21') | Should Be $true
        ($calls[1].Properties -contains '/property:PackageWithCDac=true') | Should Be $true
        ($calls[1].Properties -contains '/m:1') | Should Be $true
    }

    It 'preserves the wrapper phase contract for <entryPoint> <runTests>' -TestCases @(
        @{ entryPoint = 'Build.cmd'; runTests = $false },
        @{ entryPoint = 'Build.cmd'; runTests = $true },
        @{ entryPoint = 'Test.cmd'; runTests = $true }
    ) {
        param($entryPoint, $runTests)
        $forward = @('/p:OfficialBuildId=20260911.21')
        if ($entryPoint -eq 'Build.cmd' -and $runTests) {
            $forward += '-test'
        }
        & "$fixture\$entryPoint" @forward
        $LASTEXITCODE | Should Be 0
        $calls = @(Get-Content "$fixture\calls.jsonl" | Where-Object { $_ } | ConvertFrom-Json)
        $calls.Count | Should Be $(if ($runTests) { 2 } else { 1 })
        $calls[0].Restore | Should Be $true
        $calls[0].Build | Should Be $true
        $calls[0].Test | Should Be $false
        if ($runTests) {
            $calls[1].Test | Should Be $true
            $calls[1].Build | Should Be $false
            $calls[1].Restore | Should Be ($entryPoint -eq 'Test.cmd')
            ($calls[1].Properties -contains '-restore') | Should Be $false
            ($calls[1].Properties -contains '-build') | Should Be $false
            ($calls[1].Properties -contains '/p:OfficialBuildId=20260911.21') | Should Be $true
        }
    }

    It 'preserves test failures' {
        & "$fixture\Build.cmd" -test /p:SimulateTestFailure=true
        $LASTEXITCODE | Should Be 1
    }
}
