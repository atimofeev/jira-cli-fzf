#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================

# Defaults
DEFAULT_LABELS="bug feature documentation enhancement help-wanted question"
DEFAULT_COMPONENTS="frontend backend database api ui infrastructure"

# Configuration Paths
CONFIG_DIR=".jira-config"
LABEL_FILE="$CONFIG_DIR/labels.txt"
COMPONENT_FILE="$CONFIG_DIR/components.txt"
CACHE_DIR="/tmp/jira-cli-fzf-$USER"

# Global State
CURRENT_USER=""
CURRENT_PROJECT=""

# ==============================================================================
# UTILITIES & LOGGING
# ==============================================================================

log_error() {
    echo "Error: $1" >&2
}

log_info() {
    echo "Info: $1"
}

check_dependencies() {
    for cmd in jira fzf; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is not installed."
            exit 1
        fi
    done
}

ensure_config_dirs() {
    mkdir -p "$CACHE_DIR"
    # Note: We do NOT auto-create CONFIG_DIR per requirements, only use it if exists
}

# fzf helpers
parse_fzf_selection() {
    echo "$1" | tail -n+2
}

parse_fzf_key() {
    echo "$1" | head -n1
}

# ==============================================================================
# DATA PERSISTENCE & RETRIEVAL
# ==============================================================================

init_session() {
    CURRENT_USER=$(jira me 2>/dev/null)
    # Default project from jira config or first one from list
    CURRENT_PROJECT=$(jira project list --plain --no-headers 2>/dev/null | head -n1 | awk '{print $1}')
    [[ -z "$CURRENT_PROJECT" ]] && CURRENT_PROJECT="INFRA"
}

get_list_from_file_or_default() {
    local file="$1"
    local defaults="$2"
    if [[ -f "$file" ]]; then
        sort -u "$file"
    else
        echo "$defaults" | tr ' ' '\n'
    fi
}

save_item_to_file() {
    local item="$1"
    local file="$2"
    [[ -z "$item" || ! -d "$CONFIG_DIR" ]] && return

    # Ensure file exists before grepping
    touch "$file"
    if ! grep -qx "$item" "$file"; then
        echo "$item" >> "$file"
    fi
}

get_labels() {
    get_list_from_file_or_default "$LABEL_FILE" "$DEFAULT_LABELS"
}

get_components() {
    get_list_from_file_or_default "$COMPONENT_FILE" "$DEFAULT_COMPONENTS"
}

# ==============================================================================
# UI COMPONENTS (SELECTION MENUS)
# ==============================================================================

select_generic_multi() {
    local prompt="$1"
    local source_func="$2"     # e.g., "get_labels"
    local save_func="$3"       # Function to save new item
    local type_name="$4"       # e.g. "Label" or "Component"
    local file_path="$5"       # Path to save to

    local CREATE_OPTION="+ Create New $type_name..."
    local -a current_selection=()

    while true; do
        local source_data
        source_data=$($source_func)

        # Filter out already selected items from the source to prevent duplicates in list
        local display_source="$source_data"
        if [[ ${#current_selection[@]} -gt 0 ]]; then
            # Use grep to exclude lines that match exactly
            # We construct a pattern like ^item1$|^item2$
            local pattern=""
            for item in "${current_selection[@]}"; do
                pattern="${pattern}^${item}$|"
            done
            pattern=${pattern%|} # remove trailing pipe

            if [[ -n "$pattern" ]]; then
                display_source=$(echo "$source_data" | grep -vE "$pattern")
            fi
        fi

        # Prepend the Create Option
        display_source=$(echo -e "$CREATE_OPTION\n$display_source")

        local selection_str
        selection_str=$(IFS=','; echo "${current_selection[*]}")
        local header
        header=$(echo -e "Current: [ $selection_str ]\nTAB: Multi-select | ENTER: Confirm Selection / Create New")

        local fzf_out
        fzf_out=$(echo "$display_source" | \
            fzf --multi --prompt="$prompt > " --height=40% --layout=reverse --border \
                --header-first --header="$header")

        local exit_code=$?
        [[ $exit_code -ne 0 ]] && break # Cancelled or ESC, but keep what we have

        # Check for Create Option
        local creating_new=false
        if echo "$fzf_out" | grep -Fq "$CREATE_OPTION"; then
            creating_new=true
            local new_item
            read -p "Enter new $type_name: " new_item
            if [[ -n "$new_item" ]]; then
                save_item_to_file "$new_item" "$file_path"
                current_selection+=("$new_item")
            fi
            # Remove create option line from output to process rest
            fzf_out=$(echo "$fzf_out" | grep -vF "$CREATE_OPTION")
        fi

        # Add other selected items
        while read -r item; do
            [[ -n "$item" ]] && current_selection+=("$item")
        done <<< "$fzf_out"

        # If we were not creating new, then the Enter key meant "Confirm Selection"
        if ! $creating_new; then
            break
        fi

        # Loop back to show updated list (with new items in 'Current' header)
    done

    # Output final selection
    printf "%s\n" "${current_selection[@]}"
}

select_project() {
    local selected
    selected=$(jira project list 2>/dev/null | grep -v '^+' | \
        fzf --prompt="Select Project > " \
            --height=40% --layout=reverse --border --header-lines=1 \
            --info=inline)

    if [[ -n "$selected" ]]; then
        CURRENT_PROJECT=$(echo "$selected" | awk '{print $1}')
    fi
}

select_issue_type() {
    echo -e "Task\nStory\nBug\nEpic\nSub-task" | \
        fzf --prompt="Issue Type > " --height=40% --layout=reverse --border
}

select_epic() {
    echo "Fetching Epics..." >&2
    local selected_epic
    # Fetch only KEY and SUMMARY for cleaner display
    selected_epic=$(jira epic list --plain --columns KEY,SUMMARY --no-headers --project="$CURRENT_PROJECT" 2>/dev/null | \
        fzf --prompt="Link to Epic (Optional, ESC to skip) > " --height=40% --layout=reverse --border --header="Select parent Epic")

    echo "$selected_epic"
}
select_assignee() {
    local option
    option=$(echo -e "Me ($CURRENT_USER)\nUnassigned\nSearch/Manual..." | \
        fzf --prompt="Assignee (ESC to skip) > " --height=40% --layout=reverse --border)

    case "$option" in
        "Me ($CURRENT_USER)") echo "$CURRENT_USER" ;;
        "Unassigned") echo "x" ;;
        "Search/Manual...")
            read -p "Enter assignee email/name: " manual_assignee
            echo "$manual_assignee"
            ;;
        *) echo "" ;; # Cancelled/ESC returns empty
    esac
}

select_reporter() {
    local option
    option=$(echo -e "Me ($CURRENT_USER)\nSearch/Manual..." | \
        fzf --prompt="Reporter (ESC to skip) > " --height=40% --layout=reverse --border)

    case "$option" in
        "Me ($CURRENT_USER)") echo "$CURRENT_USER" ;;
        "Search/Manual...")
            read -p "Enter reporter email/name: " manual_reporter
            echo "$manual_reporter"
            ;;
        *) echo "" ;; # Cancelled/ESC returns empty
    esac
}

select_sprint() {
    local active_sprint
    active_sprint=$(jira sprint list --table --plain --columns ID,NAME --state active --no-headers --project="$CURRENT_PROJECT" 2>/dev/null | head -n1)

    if [[ -n "$active_sprint" ]]; then
        local sprint_id=$(echo "$active_sprint" | awk '{print $1}')
        local sprint_name=$(echo "$active_sprint" | cut -f2-)

        echo "Current active sprint: $sprint_name" >&2
        echo -n "Add to this sprint? (y/n/ESC to skip): " >&2

        local char
        read -r -s -n 1 char
        if [[ "$char" == $'\e' ]]; then
            echo "Skipped." >&2
            return
        fi

        case "$char" in
            [Yy])
                echo "Yes" >&2
                echo "$sprint_id|$sprint_name"
                ;;
            [Nn])
                echo "No, selecting another..." >&2
                local selected
                selected=$(jira sprint list --table --plain --columns ID,NAME --state future,active --no-headers --project="$CURRENT_PROJECT" 2>/dev/null | \
                    fzf --prompt="Select Sprint > " --height=40% --layout=reverse --border)
                if [[ -n "$selected" ]]; then
                    local sid=$(echo "$selected" | awk '{print $1}')
                    local sname=$(echo "$selected" | cut -f2-)
                    echo "$sid|$sname"
                fi
                ;;
            *)
                echo "Skipped." >&2
                ;;
        esac
    else
        local selected
        selected=$(jira sprint list --table --plain --columns ID,NAME --state future,active --no-headers --project="$CURRENT_PROJECT" 2>/dev/null | \
            fzf --prompt="Select Sprint (Optional, ESC to skip) > " --height=40% --layout=reverse --border)
        if [[ -n "$selected" ]]; then
            local sid=$(echo "$selected" | awk '{print $1}')
            local sname=$(echo "$selected" | cut -f2-)
            echo "$sid|$sname"
        fi
    fi
}

# ==============================================================================
# JIRA ACTIONS
# ==============================================================================

perform_create_issue() {
    echo "Creating issue in project: $CURRENT_PROJECT"

    # 1. Summary
    read -p "Summary: " summary
    if [[ -z "$summary" ]]; then
        log_error "Summary is required. Aborting."
        sleep 1; return
    fi

    # 2. Type
    local type
    type=$(select_issue_type)
    [[ -z "$type" ]] && return

    # 3. Epic
    local epic_selection=""
    local epic_key=""
    local epic_flag=""
    if [[ "$type" != "Epic" ]]; then
        epic_selection=$(select_epic)
        if [[ -n "$epic_selection" ]]; then
            # Extract KEY from "KEY SUMMARY" format
            epic_key=$(echo "$epic_selection" | awk '{print $1}')
            [[ -n "$epic_key" ]] && epic_flag="-P$epic_key"
        fi
    fi

    # 4. Assignee
    local assignee
    assignee=$(select_assignee)
    # If assignee is empty (ESC), we proceed as Unassigned (no -a flag)

    # 5. Reporter
    local reporter
    reporter=$(select_reporter)

    # 6. Sprint
    local sprint_data
    sprint_data=$(select_sprint)
    local sprint_id=$(echo "$sprint_data" | cut -d'|' -f1)
    local sprint_name=$(echo "$sprint_data" | cut -d'|' -f2)

    # 7. Labels
    local -a selected_labels
    mapfile -t selected_labels < <(select_generic_multi "Labels" "get_labels" "save_item_to_file" "Label" "$LABEL_FILE")

    # 8. Components
    local -a selected_components
    mapfile -t selected_components < <(select_generic_multi "Components" "get_components" "save_item_to_file" "Component" "$COMPONENT_FILE")

    # 9. Description
    echo "Description (Press CTRL-D to end, or just ENTER for empty):"
    local body
    body=$(cat)

    # Review
    clear
    echo "Review your issue:"
    echo "---------------------------"
    echo "Project:   $CURRENT_PROJECT"
    echo "Type:      $type"
    echo "Summary:   $summary"
    [[ -n "$epic_selection" ]] && echo "Epic:      $epic_selection"
    echo "Assignee:  ${assignee:-(Project Default)}"
    echo "Reporter:  ${reporter:-(Me)}"
    echo "Sprint:    ${sprint_name:-None}"
    echo "Labels:    ${selected_labels[*]:-None}"
    echo "Components: ${selected_components[*]:-None}"
    echo "---------------------------"

    read -p "Create this issue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        sleep 1; return
    fi

    echo "Creating issue..."

    # Construct Args
    local -a args=("--no-input" "--web" "-p$CURRENT_PROJECT" "-t$type" "-s$summary")
    [[ -n "$assignee" ]] && args+=("-a$assignee")
    [[ -n "$reporter" ]] && args+=("-r$reporter")
    [[ -n "$epic_flag" ]] && args+=("$epic_flag")
    [[ -n "$body" ]] && args+=("-b$body")

    for l in "${selected_labels[@]}"; do [[ -n "$l" ]] && args+=("-l$l"); done
    for c in "${selected_components[@]}"; do [[ -n "$c" ]] && args+=("-C$c"); done

    # Execute
    local out
    out=$(jira issue create "${args[@]}" 2>&1)
    local res=$?

    if [[ $res -eq 0 ]]; then
        echo "Successfully created issue!"
        echo "$out"

        # Add to sprint if selected
        if [[ -n "$sprint_id" ]]; then
            local key=$(echo "$out" | grep -oE '[A-Z]+-[0-9]+' | head -n1)
            if [[ -n "$key" ]]; then
                echo "Adding $key to sprint $sprint_name ($sprint_id)..."
                jira sprint add "$sprint_id" "$key" >/dev/null
            fi
        fi
    else
        log_error "Error creating issue (Exit Code: $res):"
        echo "$out"
    fi

    echo "Press any key to continue..."
    read -n 1
}

view_issue_menu() {
    local key="$1"
    while true; do
        clear
        jira issue view "$key" --plain 2>/dev/null | head -n 15
        echo "---------------------------"

        local action
        action=$(echo -e "1. View (Full/Pager)\n2. Comment\n3. Move/Transition\n4. Assign\n5. Open in Web\n6. Back" | \
            fzf --prompt="Action for $key > " --height=45% --layout=reverse --border)

        case "$action" in
            "1. View (Full/Pager)")
                clear
                jira issue view "$key" | ${PAGER:-less -R}
                ;;
            "2. Comment")
                read -p "Comment: " comment
                [[ -n "$comment" ]] && jira issue comment add "$key" "$comment"
                ;;
            "3. Move/Transition") jira issue move "$key" ;;
            "4. Assign")
                read -p "Assign to (email or name): " assignee
                [[ -n "$assignee" ]] && jira issue assign "$key" "$assignee"
                ;;
            "5. Open in Web") jira open "$key" ;;
            "6. Back"|"") return ;;
        esac
    done
}

list_issues_flow() {
    local filter="$1"
    while true; do
        local selected
        selected=$(jira issue list $filter --project="$CURRENT_PROJECT" --plain --columns key,summary,status,assignee --no-headers --paginate 100 2>/dev/null | \
            fzf --prompt="Issues > " \
                --height=80% \
                --layout=reverse \
                --border \
                --header="ENTER: View/Manage | CTRL-R: Refresh | ESC: Back" \
                --preview 'jira issue view {1}' \
                --bind 'ctrl-r:reload(jira issue list '$filter' --project="'$CURRENT_PROJECT'" --plain --columns key,summary,status,assignee --no-headers --paginate 100)')

        if [[ -z "$selected" ]]; then
            return
        fi

        local key
        key=$(echo "$selected" | awk '{print $1}')
        view_issue_menu "$key"
    done
}

# ==============================================================================
# MAIN ENTRYPOINT
# ==============================================================================

main() {
    check_dependencies
    ensure_config_dirs
    init_session

    while true; do
        clear
        local fzf_out
        fzf_out=$(echo -e "1. List My Issues\n2. Create Issue\n3. Current Sprint\n4. Search Issues\n5. Exit" | \
            fzf --prompt="Jira Action > " \
                --height=40% \
                --layout=reverse \
                --border \
                --cycle \
                --header="User: [$CURRENT_USER] | Project: [$CURRENT_PROJECT] (CTRL-P: Change Project)" \
                --info=inline \
                --expect=ctrl-p)

        local key
        key=$(parse_fzf_key "$fzf_out")
        local action
        action=$(parse_fzf_selection "$fzf_out")

        if [[ "$key" == "ctrl-p" ]]; then
            select_project
            continue
        fi

        case "$action" in
            "1. List My Issues") list_issues_flow "-a$CURRENT_USER" ;;
            "2. Create Issue") perform_create_issue ;;
            "3. Current Sprint")
                jira sprint list --current --assignee="$CURRENT_USER" --project="$CURRENT_PROJECT"
                ;;
            "4. Search Issues")
                read -p "Search query: " query
                [[ -n "$query" ]] && list_issues_flow "$query"
                ;;
            "5. Exit"|"") exit 0 ;;
        esac
    done
}

# Run Main
main "$@"
