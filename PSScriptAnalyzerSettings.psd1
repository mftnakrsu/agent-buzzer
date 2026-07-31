# PSScriptAnalyzer configuration.
#
# Everything runs at Error and Warning severity. The four rules below are
# excluded because they are aimed at modules and exported cmdlets, and this is a
# standalone script; each one is listed with the reason rather than being
# silenced inline.

@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These are private helpers inside a script, not cmdlets. `buzzer set
        # done bird.wav` has no business growing -WhatIf and -Confirm.
        'PSUseShouldProcessForStateChangingFunctions',

        # tests/run.ps1 prints a coloured pass/fail report for a human watching
        # it, which is exactly what Write-Host is for. buzzer.ps1 itself uses
        # Write-Output everywhere so its output stays pipeable.
        'PSAvoidUsingWriteHost',

        # Assertion helpers read as sentences: Assert-Contains, not
        # Assert-Contain.
        'PSUseSingularNouns',

        # These files stay UTF-8 with no BOM. A BOM would break the
        # `#!/usr/bin/env pwsh` shebang on macOS and Linux, and adds noise to
        # every diff.
        'PSUseBOMForUnicodeEncodedFile'
    )
}
