# This configuration improve autocomplete contrast in light themes.
#
# In WSL, it detects the current windows theme from the registry
# and define ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE to a different color
# when the OS theme is light

if [[ -r /proc/version ]] && grep -q "microsoft" /proc/version; then
  # 1. Query Windows Registry via PowerShell
  # 2. Use 'tr' to remove the trailing Carriage Return (\r) Windows adds
  local win_theme_val
  win_theme_val=$(powershell.exe -Command '(Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize").AppsUseLightTheme' 2>/dev/null | tr -d '\r')

  # Check value (0 = Dark, 1 = Light)
  if [[ "$win_theme_val" == "1" ]]; then
    export ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="fg=250"
  fi
fi
