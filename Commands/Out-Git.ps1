﻿function Out-Git
{
    <#
    .Synopsis
        Outputs Git to PowerShell
    .Description
        Outputs Git as PowerShell Objects.

        Git Output can be provided by any number of extensions to Out-Git.

        Extensions use two attributes to indicate if they should be run:

        ~~~PowerShell
        [Management.Automation.Cmdlet("Out","Git")] # This signals that this is an extension for Out-Git
        [ValidatePattern("RegularExpression")]      # This is run on $GitCommand to determine if the extension should run.
        ~~~
    .LINK
        Invoke-Git
    .Example
        # Log entries are returned as objects, with properties and methods.
        git log -n 1 | Get-Member
    .Example
        # Status entries are converted into objects.
        git status
    .Example
        # Display untracked files.
        git status | Select-Object -ExpandProperty Untracked
    .Example
        # Display the list of branches, as objects.
        git branch
    .NOTES
        Out-Git will generate two events upon completion.  They will have the source identifiers of "Out-Git" and "Out-Git $GitArgument"
    #>
    [CmdletBinding(PositionalBinding=$false)]
    param(
    # One or more output lines from Git.
    [Parameter(ValueFromPipeline)]
    [Alias('GitOutputLines')]
    [string[]]
    $GitOutputLine,

    # The arguments that were passed to git.
    [string[]]
    $GitArgument,

    # The root of the current git repository.
    [string]
    $GitRoot,

    # The timestamp.   This can be used for tracking.  Defaults to [DateTime]::Now
    [DateTime]
    $TimeStamp = [DateTime]::Now
    )

    begin {
        # First, we need to determine what the combined git command was.
        # Luckily, this is easy:  just combine "git" with the list of git argument
        $gitCommand = @('git') + $GitArgument[0..$GitArgument.Length] -join ' '

        # Now we need to see if we have have a cached for extension mapping.
        if (-not $script:GitExtensionMappingCache) {
            $script:GitExtensionMappingCache = @{} # If we don't, create one.
        }

        if (-not $script:GitExtensionMappingCache[$gitCommand]) { # If we don't have a cached extension list

            # let's initialize an empty variable to keep any extension validation errors.
            $extensionValidationErrors = $null
            # Then we create a hashtable containing the parameters to Get-UGitExtension:
            $uGitExtensionParams = @{
                    CommandName   = $MyInvocation.MyCommand      # We want extensions for this command
                    ValidateInput = $gitCommand                  # that are valid, given $GitCommand.

            }

            # If -Verbose is -Debug is set, we will want to populate extensionValidationErrors
            if ($VerbosePreference -ne 'silentlyContinue' -or
                $DebugPreference -ne 'silentlyContinue') {
                $uGitExtensionParams.ErrorAction   = 'SilentlyContinue'           # We do not want to display errors
                $uGitExtensionParams.ErrorVariable = 'extensionValidationErrors'  # we want to redirect them into $extensionValidationErrors.
                $uGitExtensionParams.AllValid      = $true                        # and we want to see that all of the validation attributes are correct.
            } else {
                $uGitExtensionParams.ErrorAction = 'Ignore'
            }

            # Now we get a list of git output extensions and store it in the cache.
            $script:GitExtensionMappingCache[$gitCommand] = $gitOutputExtensions = @(Get-UGitExtension @uGitExtensionParams)

            # If any of them had errors, and we want to see the -Verbose channel
            if ($extensionValidationErrors -and $VerbosePreference -ne 'silentlyContinue')  {
                foreach ($validationError in $extensionValidationErrors) {
                    Write-Verbose "$validationError" # write the validation errors to verbose.
                    # It should be noted that there will almost always be validation errors,
                    # since most extensions will not apply to a given $GitCommand
                }
            }
        } else {
            # If there was already an extension cached, we can skip the previous steps and just reuse the cached extensions.
            $gitOutputExtensions = $script:GitExtensionMappingCache[$gitCommand]
        }

        # Next we want to create a collection of SteppablePipelines.
        # These allow us to run the begin/process/end blocks of each Extension.
        $steppablePipelines =
            [Collections.ArrayList]::new(@(if ($gitOutputExtensions) {
                foreach ($ext in $gitOutputExtensions) {
                    $scriptCmd = {& $ext}
                    $scriptCmd.GetSteppablePipeline()
                }
            }))


        # Next we need to start any steppable pipelines.
        # Each extension can break, continue in it's begin block to indicate it should not be processed.
        $spi = 0
        $spiToRemove = @()
        $beginIsRunning = $false
        # Walk over each steppable pipeline.
        :NextExtension foreach ($steppable in $steppablePipelines) {
            if ($beginIsRunning) { # If beginIsRunning is set, then the last steppable pipeline continued
                $spiToRemove+=$steppablePipelines[$spi] # so mark it to be removed.
            }
            $beginIsRunning = $true      # Note that beginIsRunning=$false,
            try {
                $steppable.Begin($true) # then try to run begin
            } catch {
                $PSCmdlet.WriteError($_) # Write any exceptions as errors
            }
            $beginIsRunning = $false     # Note that beginIsRunning=$false
            $spi++                       # and increment the index.
        }

        # If this is still true, an extenion used 'break', which signals to stop processing of it any subsequent pipelines.
        if ($beginIsRunning) {
            $spiToRemove += @(for (; $spi -lt $steppablePipelines.Count; $spi++) {
                $steppablePipelines[$spi]
            })
        }

        # Remove all of the steppable pipelines that signaled they no longer wish to run.
        foreach ($tr in $spiToRemove) {
            $steppablePipelines.Remove($tr)
        }

        $AllGitOutput    = [Collections.Queue]::new()
        $ProcessedOutput = [Collections.Queue]::new()
        $OutputLineCount = 0
        $errorTypeNames  = @()
    }

    process {
        # Walk over each output.

        foreach ($out in $GitOutputLine) {
            $OutputLineCount++
            # If the out was a literal string of 'System.Management.Automation.RemoteException',
            if ("$out" -eq "System.Management.Automation.RemoteException") {
                # ignore it and continue (these things happen with some exes from time to time).
                continue
            }

            try {
                $AllGitOutput.Enqueue($out)
                
                # Wrap the output in a PSObject
                $gitOut = [PSObject]::new($out)
            } catch {                
                # [AMSI](https://learn.microsoft.com/en-us/windows/win32/amsi/how-amsi-helps) will prevent creation of a PSObject from a string if it is deemed malicious
                # Therefore, if we could not create the object, complain with the exact line and keep moving.
                Write-Error "Line $outputLineCount : $_"
                continue
            }

            # Next, clear it's typenames and determine an automatic typename.
            # The first typename is the complete set of arguments ( separated by periods )
            # Followed by each smaller set of arguments, separated by periods
            # Followed by a PSTypeName of 'git'
            # Thus, for example, git clone $repo
            # Would have the typenames of :"git.clone.$repo.output", "git.clone.output","git.output"
            $gitOut.pstypenames.clear()
            for ($n = $GitArgument.Length - 2 ; $n -ge 0; $n--) {
                $gitOut.pstypenames.add(@('git') + $GitArgument[0..$n]  + @('output') -join '.')
            }
            $gitOut.pstypenames.add('git.output')

            # All gitOutput should attach the original output line, as well as the command that produced that line.
            $gitOut.psobject.properties.add([PSNoteProperty]::new('GitOutput',"$out"))
            $gitOut.psobject.properties.add([PSNoteProperty]::new('GitCommand',
                $(@('git') + $GitArgument) -join ' ')
            )

            # If the output started with "error" or "fatal"
            if ("$out" -match "^(?:error|fatal):") {
                $exception = [Exception]::new($("$out" -replace '^(?:error|fatal):')) # Create an exception
                # Clean up --shallow-since exceptions, since git gives less than obvious error messages in this scenario.
                # Hat tip @ninmonkey for the scenario! (see #276)
                if ($exception -match 'shallow info: \d+\s{0,}$' -and $gitCommand -match '--shallow-since=(?<shallowdate>\S+)') {
                    $exception = [Exception]::new("No commits found -Since $($matches.shallowdate)")
                }
                $errorRecord = [Management.Automation.ErrorRecord]::new($exception,"$GitCommand", 'NotSpecified',$gitOut)
                $errorTypeNames = @($gitOut.pstypenames -replace 'output','error')
                foreach ($typename in $errorTypeNames) {
                    $errorRecord.pstypenames.add($typename)
                }
                
                $PSCmdlet.WriteError( # and write an error using $psCmdlet (this simplifies the displayed callstack).
                    $errorRecord
                )
                # If there was an error, cancel all steppable pipelines (thus stopping any extensions)
                $steppablePipelines = @()
                continue # then move onto the next output.
            } else {
                Write-Verbose "$out"
            }

            if ("$out" -match '^hint:') {
                Write-Warning ("$out" -replace '^hint:')
                continue
            }

            if (-not $steppablePipelines) {
                # If we do not have steppable pipelines, output directly
                if ($errorTypeNames -and $gitOut.pstypenames) {
                    foreach ($typeName in $errorTypeNames) {
                        $gitOut.pstypenames.add($typename)
                    }
                    $gitOut
                } else {
                    $gitOut
                }                
            }
            else {
                # If we have steppable pipelines, then we have to do a similar operation as we did for begin.
                $spi = 0
                $spiToRemove = @()
                $processIsRunning = $false
                # We have to walk thru each steppable pipeline,
                :NextExtension foreach ($steppable in $steppablePipelines) {
                    if ($processIsRunning) {  # if $ProcessIsRunning, the pipeline was skipped with continue.
                        $spiToRemove+=$steppablePipelines[$spi] # and we should add it to the list of pipelines to remove
                    }
                    $processIsRunning = $true # Set $processIsRunning,
                    try {
                        $steppable.Process($gitOut) | & {
                            process {
                                $ProcessedOutput.Enqueue($_)
                                $_
                            }
                        } # attempt to run process, using the $gitOut object.
                    } catch {
                        $PSCmdlet.WriteError($_)    # (catch any exceptions and write them as errors).
                    }
                    $processIsRunning = $false # Set $processIsRunning to $false for the next step.
                }


                if ($processIsRunning) {  # If $ProcessIsRunning was true, the extension used break
                    # which should signal cancellation of all subsequent extensions.
                    $spiToRemove += @(for (; $spi -lt $steppablePipelines.Count; $spi++) {
                        $steppablePipelines[$spi]
                    })


                    $gitOut # We will also output the gitOut object in this case.
                }

                # Remove any steppable pipelines we need to remove.
                foreach ($tr in $spiToRemove) { $steppablePipelines.Remove($tr) }
            }
        }
    }

    end {
        $global:lastGitOutput = $AllGitOutput.ToArray()

        # End remaining steppable pipelines need to end.
        # Ending does not support the cancellation of other extensions.
        foreach ($steppable in $steppablePipelines) {
            try {
                $steppable.End() | & { process {
                    $ProcessedOutput.Enqueue($_)
                    $_
                }}
            } catch {
                Write-Error -ErrorRecord $_
            }
        }

        if (-not $global:gitHistory -or
            $global:gitHistory -isnot [Collections.IDictionary]) {
            $global:gitHistory = [Ordered]@{}
        }
        $messageData = [Ordered]@{
            OutputObject  = $ProcessedOutput.ToArray()
            GitOutputLine = $AllGitOutput.ToArray()
            GitArgument   = $GitArgument
            GitCommand    = @(@("git") + $GitArgument) -join ' '
            GitRoot       = $GitRoot
            TimeStamp     = $TimeStamp
        }

        $eventSourceIds = @("Out-Git","Out-Git $gitArgument")

        $null =
            foreach ($sourceIdentifier in $eventSourceIds) {
                New-Event -SourceIdentifier $sourceIdentifier -MessageData $messageData
            }

        $global:gitHistory["$($MyInvocation.HistoryId)::$GitRoot::$GitArgument"] = $messageData
    }
}
