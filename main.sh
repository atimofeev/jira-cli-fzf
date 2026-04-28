#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONFIG & INIT
# ==============================================================================

JIRA_CONF="${JIRA_CONFIG_FILE:-$HOME/.config/.jira/.config.yml}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jira-cli-fzf"
mkdir -p "$CACHE_DIR"

if [[ -z "${JIRA_API_TOKEN:-}" ]]; then
    echo "Error: JIRA_API_TOKEN environment variable is required for API access." >&2
    exit 1
fi

CURRENT_USER=$(jira me 2>/dev/null || true)
CURRENT_PROJECT=$(awk '
    $1 == "project:" {
        if ($2 != "") { print $2; exit }
        else { in_proj=1; next }
    }
    in_proj && $1 == "key:" { print $2; exit }
    in_proj && /^[a-zA-Z]/ { in_proj=0 }
' "$JIRA_CONF" 2>/dev/null | tr -d '"'\''')

# ==============================================================================
# API & CACHE
# ==============================================================================

jira_api_get() {
    local path="$1"
    local server=$(awk '/^[[:space:]]*server:/ {print $2; exit}' "$JIRA_CONF" | tr -d '"'\')
    local login=$(awk '/^[[:space:]]*login:/ {print $2; exit}' "$JIRA_CONF" | tr -d '"'\')

    curl -fsS -u "${login}:${JIRA_API_TOKEN}" -H "Accept: application/json" "${server%/}${path}"
}

# Generic function for non-paginated endpoints
get_cached_api() {
    local type="$1"
    local endpoint="$2"
    local jq_filter="$3"
    local cache_file="$CACHE_DIR/${CURRENT_PROJECT}_${type}.txt"

    if [[ ! -s "$cache_file" ]]; then
        jira_api_get "$endpoint" | jq -r "$jq_filter" | sed '/^$/d' | sort -u > "$cache_file"
    fi
    cat "$cache_file"
}

get_project_id() {
    jira_api_get "/rest/api/3/project/${CURRENT_PROJECT}" | jq -r '.id'
}

# ==============================================================================
# DATA SOURCES (Strictly API)
# ==============================================================================

get_issue_types() {
    get_cached_api "issue_types" "/rest/api/3/issuetype/project?projectId=$(get_project_id)" '.[]?.name // .values[]?.name'
}

get_epics() {
    get_cached_api "epics" "/rest/api/3/search/jql?jql=project=${CURRENT_PROJECT}%20AND%20issuetype=Epic&maxResults=100&fields=summary" '.issues[]? | "\(.key) \(.fields.summary)"'
}

get_users() {
    get_cached_api "users" "/rest/api/3/user/assignable/search?project=${CURRENT_PROJECT}&maxResults=1000" '.[]? | select(.active) | (.emailAddress // .displayName)'
}

get_labels() {
    get_cached_api "labels" "/rest/api/3/search/jql?jql=project=${CURRENT_PROJECT}%20AND%20labels%20is%20not%20EMPTY&maxResults=100&fields=labels" '.issues[]?.fields.labels[]?'
}

get_components() {
    get_cached_api "components" "/rest/api/3/project/${CURRENT_PROJECT}/components" '.[]?.name'
}

# ==============================================================================
# UI CONTROLS & FLOWS
# ==============================================================================

select_single() { fzf --prompt="$1 > " --height=40% --layout=reverse --border; }
select_multi()  { fzf -m --prompt="$1 (TAB multi-select) > " --height=40% --layout=reverse --border; }

create_issue() {
    local type=$(get_issue_types | select_single "Issue Type")
    [[ -z "$type" ]] && return

    local epic=""
    if [[ "$type" != "Epic" ]]; then
        epic=$(get_epics | select_single "Epic (ESC to skip)" | awk '{print $1}')
    fi

    # Assignee selection (fzf selected on "Me", ESC sets to unassigned)
    local a_sel=$( (echo "Me ($CURRENT_USER)"; get_users) | select_single "Assignee (ESC for Unassigned)") || true
    local assignee="x"
    if [[ "$a_sel" == "Me ($CURRENT_USER)" ]]; then assignee="$CURRENT_USER"
    elif [[ -n "$a_sel" ]]; then assignee="$a_sel"
    fi

    # Reporter selection (fzf selected on "Me", ESC sets to Me)
    local r_sel=$( (echo "Me ($CURRENT_USER)"; get_users) | select_single "Reporter (ESC for Me)") || true
    local reporter="$CURRENT_USER"
    if [[ -n "$r_sel" && "$r_sel" != "Me ($CURRENT_USER)" ]]; then reporter="$r_sel"; fi

    local labels=$(get_labels | select_multi "Labels (ESC to skip)" | paste -sd, -)
    local components=$(get_components | select_multi "Components (ESC to skip)" | paste -sd, -)

    read -p "Summary: " summary
    [[ -z "$summary" ]] && return

    echo "Description (Press CTRL-D to end, or just ENTER for empty):"
    local body=$(cat)

    # Build Jira CLI arguments
    local args=("--no-input" "-p$CURRENT_PROJECT" "-t$type" "-s$summary")
    [[ -n "$epic" ]] && args+=("-P$epic")
    [[ -n "$assignee" ]] && args+=("-a$assignee")
    [[ -n "$reporter" ]] && args+=("-r$reporter")
    [[ -n "$body" ]] && args+=("-b$body")

    # Process comma-separated multi-selects
    IFS=',' read -ra L_ARR <<< "$labels"
    for l in "${L_ARR[@]}"; do [[ -n "$l" ]] && args+=("-l$l"); done

    IFS=',' read -ra C_ARR <<< "$components"
    for c in "${C_ARR[@]}"; do [[ -n "$c" ]] && args+=("-C$c"); done

    echo -e "\nCreating issue..."
    jira issue create "${args[@]}" || true

    read -n 1 -s -r -p "Press any key to return to menu..."
}

view_issue() {
    local key="$1"
    while true; do
        clear
        jira issue view "$key" --plain 2>/dev/null | head -n 15
        echo "---------------------------"
        local action=$(echo -e "1. View Full\n2. Comment\n3. Transition\n4. Open in Web\n5. Back" | select_single "Action")

        case "$action" in
            "1"*) jira issue view "$key" | ${PAGER:-less -R} ;;
            "2"*) read -p "Comment: " c; [[ -n "$c" ]] && jira issue comment add "$key" "$c" ;;
            "3"*) jira issue move "$key" ;;
            "4"*) jira open "$key" ;;
            *) return ;;
        esac
    done
}

list_issues() {
    local filter="$1"
    while true; do
        local selection=$(jira issue list $filter --project="$CURRENT_PROJECT" --plain --columns key,summary,status --no-headers | \
            fzf --prompt="Issues > " --height=80% --layout=reverse --preview 'jira issue view {1}')
        [[ -z "$selection" ]] && return
        view_issue $(echo "$selection" | awk '{print $1}')
    done
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

while true; do
    clear
    action=$(echo -e "1. List My Issues\n2. Create Issue\n3. Search Issues\n4. Refresh API Cache\n5. Exit" | \
        fzf --prompt="Main Menu > " --header="User: $CURRENT_USER | Project: $CURRENT_PROJECT" --height=40% --layout=reverse)

    case "$action" in
        "1"*) list_issues "-a$CURRENT_USER" ;;
        "2"*) create_issue ;;
        "3"*) read -p "JQL/Text Query: " q; [[ -n "$q" ]] && list_issues "$q" ;;
        "4"*) rm -f "$CACHE_DIR/${CURRENT_PROJECT}_"*.txt; echo "Cache cleared."; sleep 1 ;;
        *) exit 0 ;;
    esac
done
