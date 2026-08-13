# Collaborate module loader.
#
# Source files are split by concern under ./functions and dot-sourced here. The
# Functions host imports this module from profile.ps1, so every run.ps1 entry
# point gets the whole surface.

$ErrorActionPreference = 'Stop'

Get-ChildItem -Path (Join-Path $PSScriptRoot 'functions') -Filter '*.ps1' |
    Sort-Object Name |
    ForEach-Object { . $_.FullName }

# Export everything shaped like a Collaborate function (contains "-CB").
Export-ModuleMember -Function '*-CB*'
