# Bash completion for crew command (crew-setup skill)
# Source this file or add to ~/.bash_completion.d/

_crew_completions() {
    local cur prev commands
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Subcomandos principais
    commands="check setup audit"

    case "$prev" in
        crew)
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
            ;;
        setup)
            COMPREPLY=( $(compgen -W "--plan --reconfigure --yes --rebuild" -- "$cur") )
            return 0
            ;;
        audit)
            COMPREPLY=( $(compgen -W "--no-save --since --quiet -q" -- "$cur") )
            return 0
            ;;
        check)
            # check não tem flags específicas
            return 0
            ;;
    esac

    # Se já estiver num subcomando, completar flags
    if [[ ${COMP_WORDS[1]} == "setup" ]]; then
        COMPREPLY=( $(compgen -W "--plan --reconfigure --yes --rebuild" -- "$cur") )
    elif [[ ${COMP_WORDS[1]} == "audit" ]]; then
        COMPREPLY=( $(compgen -W "--no-save --since --quiet -q" -- "$cur") )
    fi
}

complete -F _crew_completions crew
complete -F _crew_completions crew-setup
complete -F _crew_completions crew-check
complete -F _crew_completions crew-audit
