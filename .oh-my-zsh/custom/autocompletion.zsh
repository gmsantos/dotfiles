# This configuration improve autocomplete contrast in light themes.
# Define an envvar named ZSH_AUTOSUGGEST_LIGHT with "fg=250" as the value.
#
# I use this especially in vscode, becasue I like light themes :)
#
# "terminal.integrated.env.linux": {
#     "ZSH_AUTOSUGGEST_LIGHT": "fg=250"
# }

ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE="${ZSH_AUTOSUGGEST_LIGHT:-fg=8}"
