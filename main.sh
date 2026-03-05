#!/usr/bin/env bash

# Check dependencies
for cmd in jira fzf; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: $cmd is not installed." >&2
        exit 1
    fi
done

# Defaults
CURRENT_USER=$(jira me 2>/dev/null)
# Default project from jira config or first one from list
CURRENT_PROJECT=$(jira project list --plain --no-headers 2>/dev/null | head -n1 | awk '{print $1}')
[[ -z "$CURRENT_PROJECT" ]] && CURRENT_PROJECT="INFRA"

# Caches for performance (session-based)
CACHE_DIR="/tmp/jira-cli-fzf-$USER"
mkdir -p "$CACHE_DIR"

# Utility: format fzf output
# fzf returns the selection (or empty if cancelled)
# If --expect is used, first line is the key pressed, second is the selection
parse_fzf() {
    local out="$1"
    echo "$out" | tail -n+2
}

parse_key() {
    local out="$1"
    echo "$out" | head -n1
}

get_recent_labels() {
    local cache="$CACHE_DIR/labels-$CURRENT_PROJECT"
    if [[ ! -f "$cache" ]] || [[ $(find "$cache" -mmin +60) ]]; then
        # Column 1 is KEY, Column 2 is LABELS. We want everything after the first column (the labels)
        jira issue list --project="$CURRENT_PROJECT" --plain --columns LABELS --no-headers --paginate 300 2>/dev/null | \
            awk '{$1=""; print $0}' | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u | grep -v '^$' > "$cache"
    fi
    cat "$cache"
}

get_recent_components() {
    # Components are harder to fetch without a dedicated command, we'll try same logic as labels
    # but jira-cli might not have a COMPONENT column in list?
    # Let's check for COMPONENTS column if possible, otherwise fallback to predefined.
    local cache="$CACHE_DIR/components-$CURRENT_PROJECT"
    if [[ ! -f "$cache" ]] || [[ $(find "$cache" -mmin +60) ]]; then
         jira issue list --project="$CURRENT_PROJECT" --plain --columns COMPONENTS --no-headers --paginate 300 2>/dev/null | \
            awk '{$1=""; print $0}' | tr ',' '\n' | sed 's/^[ \t]*//;s/[ \t]*$//' | sort -u | grep -v '^$' > "$cache"
    fi
    if [[ -s "$cache" ]]; then
        cat "$cache"
    else
        echo -e "frontend\nbackend\ndatabase\napi\nui\ninfrastructure"
    fi
}

select_project() {
    local SELECTED=$(jira project list 2>/dev/null | grep -v '^+' | \
        fzf --prompt="Select Project > " \
            --height=40% --layout=reverse --border --header-lines=1 \
            --info=inline)

    if [[ -n "$SELECTED" ]]; then
        CURRENT_PROJECT=$(echo "$SELECTED" | awk '{print $1}')
    fi
}

create_issue() {
    echo "Creating issue in project: $CURRENT_PROJECT"

    # 1. Summary
    read -p "Summary: " SUMMARY
    if [[ -z "$SUMMARY" ]]; then
        echo "Summary is required. Aborting."
        sleep 1
        return
    fi

    # 2. Issue Type
    local TYPE=$(echo -e "Task\nStory\nBug\nEpic\nSub-task" | \
        fzf --prompt="Issue Type > " --height=40% --layout=reverse --border)
    [[ -z "$TYPE" ]] && return

    # 3. Epic Selection (Parent)
    local EPIC_FLAG=""
    local EPIC_KEY=""
    if [[ "$TYPE" != "Epic" ]]; then
        echo "Fetching Epics..."
        local SELECTED_EPIC=$(jira epic list --table --plain --no-headers --project="$CURRENT_PROJECT" 2>/dev/null | \
            fzf --prompt="Link to Epic (Optional, ESC to skip) > " --height=40% --layout=reverse --border --header="Select parent Epic")
        if [[ -n "$SELECTED_EPIC" ]]; then
            EPIC_KEY=$(echo "$SELECTED_EPIC" | awk '{print $2}')
            EPIC_FLAG="-P$EPIC_KEY"
        fi
    fi

    # 4. Assignee
    local ASSIGNEE_OPT=$(echo -e "Me ($CURRENT_USER)\nUnassigned\nSearch/Manual..." | \
        fzf --prompt="Assignee > " --height=40% --layout=reverse --border)

    local ASSIGNEE=""
    case "$ASSIGNEE_OPT" in
        "Me ($CURRENT_USER)") ASSIGNEE="$CURRENT_USER" ;;
        "Unassigned") ASSIGNEE="x" ;;
        "Search/Manual...") read -p "Enter assignee email/name: " ASSIGNEE ;;
        *) return ;; # Cancelled
    esac

    # 5. Labels (Interactive Selection)
    local LABELS_SOURCE=$(get_recent_labels)
    local FZF_LABELS=$(echo "$LABELS_SOURCE" | \
        fzf --multi --print-query --prompt="Labels (Tab to select, Enter to add query) > " --height=40% --layout=reverse --border --header="Recently used labels")

    local LABEL_FLAGS=""
    if [[ -n "$FZF_LABELS" ]]; then
        # If no items selected, use the query itself
        if [[ $(echo "$FZF_LABELS" | wc -l) -eq 1 ]]; then
            LABEL_FLAGS="-l$(echo "$FZF_LABELS" | head -n1)"
        else
            # Skip the first line (query) if multiple lines (selections) exist
            while read -r label; do
                [[ -z "$label" ]] && continue
                LABEL_FLAGS="$LABEL_FLAGS -l$label"
            done <<< "$(echo "$FZF_LABELS" | tail -n+2)"
        fi
    fi

    # 6. Components
    local COMPONENT_SOURCE=$(get_recent_components)
    local FZF_COMPONENTS=$(echo "$COMPONENT_SOURCE" | \
        fzf --multi --print-query --prompt="Components (Tab to select, Enter to add query) > " --height=40% --layout=reverse --border)

    local COMPONENT_FLAGS=""
    if [[ -n "$FZF_COMPONENTS" ]]; then
        if [[ $(echo "$FZF_COMPONENTS" | wc -l) -eq 1 ]]; then
            COMPONENT_FLAGS="-C$(echo "$FZF_COMPONENTS" | head -n1)"
        else
            while read -r component; do
                [[ -z "$component" ]] && continue
                COMPONENT_FLAGS="$COMPONENT_FLAGS -C$component"
            done <<< "$(echo "$FZF_COMPONENTS" | tail -n+2)"
        fi
    fi

    # 7. Description (Body)
    echo "Description (Press CTRL-D to end, or just ENTER for empty):"
    local BODY=$(cat)

    # Confirm
    clear
    echo "Review your issue:"
    echo "---------------------------"
    echo "Project:   $CURRENT_PROJECT"
    echo "Type:      $TYPE"
    echo "Summary:   $SUMMARY"
    [[ -n "$EPIC_KEY" ]] && echo "Epic:      $EPIC_KEY"
    echo "Assignee:  $ASSIGNEE"
    # Format labels/components for display
    local DISPLAY_LABELS=$(if [[ $(echo "$FZF_LABELS" | wc -l) -eq 1 ]]; then echo "$FZF_LABELS"; else echo "$FZF_LABELS" | tail -n+2 | tr '\n' ',' | sed 's/,$//'; fi)
    local DISPLAY_COMPONENTS=$(if [[ $(echo "$FZF_COMPONENTS" | wc -l) -eq 1 ]]; then echo "$FZF_COMPONENTS"; else echo "$FZF_COMPONENTS" | tail -n+2 | tr '\n' ',' | sed 's/,$//'; fi)
    echo "Labels:    $DISPLAY_LABELS"
    echo "Components: $DISPLAY_COMPONENTS"
    echo "---------------------------"
    read -p "Create this issue? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Creating issue..."
        jira issue create --no-input -p"$CURRENT_PROJECT" -t"$TYPE" -s"$SUMMARY" -a"$ASSIGNEE" $EPIC_FLAG $LABEL_FLAGS $COMPONENT_FLAGS -b"$BODY"
    else
        echo "Aborted."
    fi
    sleep 2
}

view_issue_details() {
    local key="$1"
    while true; do
        clear
        # Show a decent summary at the top (first 15 lines)
        jira issue view "$key" --plain 2>/dev/null | head -n 15
        echo "---------------------------"
        local ACTION=$(echo -e "1. View (Full/Pager)\n2. Comment\n3. Move/Transition\n4. Assign\n5. Open in Web\n6. Back" | \
            fzf --prompt="Action for $key > " \
                --height=45% \
                --layout=reverse \
                --border)

        case "$ACTION" in
            "1. View (Full/Pager)")
                clear
                jira issue view "$key" | ${PAGER:-less -R}
                ;;
            "2. Comment")
                read -p "Comment: " COMMENT
                if [[ -n "$COMMENT" ]]; then
                    jira issue comment add "$key" "$COMMENT"
                fi
                ;;
            "3. Move/Transition")
                jira issue move "$key"
                ;;
            "4. Assign")
                read -p "Assign to (email or name): " ASSIGNEE
                if [[ -n "$ASSIGNEE" ]]; then
                    jira issue assign "$key" "$ASSIGNEE"
                fi
                ;;
            "5. Open in Web")
                jira open "$key"
                ;;
            "6. Back"|"")
                return
                ;;
        esac
    done
}

list_issues() {
    local filter="$1"
    while true; do
        local SELECTED=$(jira issue list $filter --project="$CURRENT_PROJECT" --plain --columns key,summary,status,assignee --no-headers --paginate 100 2>/dev/null | \
            fzf --prompt="Issues > " \
                --height=80% \
                --layout=reverse \
                --border \
                --header="ENTER: View/Manage | CTRL-R: Refresh | ESC: Back" \
                --preview 'jira issue view {1}' \
                --bind 'ctrl-r:reload(jira issue list '$filter' --project="'$CURRENT_PROJECT'" --plain --columns key,summary,status,assignee --no-headers --paginate 100)')

        if [[ -z "$SELECTED" ]]; then
            return
        fi

        local KEY=$(echo "$SELECTED" | awk '{print $1}')
        view_issue_details "$KEY"
    done
}

# Main Loop
while true; do
    clear
    FZF_OUT=$(echo -e "1. List My Issues\n2. Create Issue\n3. Current Sprint\n4. Search Issues\n5. Exit" | \
        fzf --prompt="Jira Action > " \
            --height=40% \
            --layout=reverse \
            --border \
            --cycle \
            --header="User: [$CURRENT_USER] | Project: [$CURRENT_PROJECT] (CTRL-P: Change Project)" \
            --info=inline \
            --expect=ctrl-p)

    KEY=$(parse_key "$FZF_OUT")
    ACTION=$(parse_fzf "$FZF_OUT")

    if [[ "$KEY" == "ctrl-p" ]]; then
        select_project
        continue
    fi

    case "$ACTION" in
        "1. List My Issues")
            list_issues "-a$CURRENT_USER"
            ;;
        "2. Create Issue")
            create_issue
            ;;
        "3. Current Sprint")
            jira sprint list --current --project="$CURRENT_PROJECT"
            echo "Press any key to continue..."
            read -n 1
            ;;
        "4. Search Issues")
            read -p "Search query: " QUERY
            if [[ -n "$QUERY" ]]; then
                list_issues "$QUERY"
            fi
            ;;
        "5. Exit"|"")
            exit 0
            ;;
    esac
done
