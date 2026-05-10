#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# CONFIG & INIT
# ==============================================================================

JIRA_CONF="${JIRA_CONFIG_FILE:-$HOME/.config/.jira/.config.yml}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jira-cli-fzf"
mkdir -p "$CACHE_DIR"

[[ -z "${JIRA_API_TOKEN:-}" ]] && { echo "Error: JIRA_API_TOKEN is required." >&2; exit 1; }

_awk_conf() { awk "/^[[:space:]]*${1}:/ {print \$2; exit}" "$JIRA_CONF" | tr -d '"'\'''; }

JIRA_SERVER=$(_awk_conf server)
JIRA_LOGIN=$(_awk_conf login)
CURRENT_USER=$(jira me 2>/dev/null || true)
CURRENT_PROJECT=$(awk '
    $1 == "project:" {
        if ($2 != "") { print $2; exit }
        else { in_proj=1; next }
    }
    in_proj && $1 == "key:" { print $2; exit }
    in_proj && /^[a-zA-Z]/  { in_proj=0 }
' "$JIRA_CONF" 2>/dev/null | tr -d '"'\''')

# ==============================================================================
# API & CACHE
# ==============================================================================

jira_api_get() {
    curl -fsS \
        -u "${JIRA_LOGIN}:${JIRA_API_TOKEN}" \
        -H "Accept: application/json" \
        "${JIRA_SERVER%/}${1}"
}

fetch_api_cached() {
    local type="$1" endpoint="$2" jq_values="$3" jq_total="${4:-}"
    local cache_file="$CACHE_DIR/${CURRENT_PROJECT}_${type}.txt"

    if [[ ! -s "$cache_file" ]]; then
        > "$cache_file"
        if [[ -z "$jq_total" ]]; then
            jira_api_get "$endpoint" | jq -r "$jq_values" | sed '/^$/d' >> "$cache_file"
        else
            local start=0 page_size=100 total=1
            while [[ $start -lt $total ]]; do
                local sep; sep=$( [[ "$endpoint" == *"?"* ]] && echo "&" || echo "?" )
                local response
                response=$(jira_api_get "${endpoint}${sep}startAt=${start}&maxResults=${page_size}")
                total=$(echo "$response" | jq -r "$jq_total")

                # Ensure total is an integer to prevent bash arithmetic evaluation errors
                [[ "$total" =~ ^[0-9]+$ ]] || total=0

                echo "$response" | jq -r "$jq_values" | sed '/^$/d' >> "$cache_file"
                start=$((start + page_size))
            done
        fi
        sort -u -o "$cache_file" "$cache_file"
    fi
    cat "$cache_file"
}

# ==============================================================================
# DATA SOURCES
# ==============================================================================

CURRENT_PROJECT_ID=$(jira_api_get "/rest/api/3/project/${CURRENT_PROJECT}" | jq -r '.id')
[[ -z "$CURRENT_PROJECT_ID" || "$CURRENT_PROJECT_ID" == "null" ]] && {
    echo "Error: could not resolve project ID for '${CURRENT_PROJECT}'" >&2; exit 1
}

get_issue_types() {
    fetch_api_cached "issue_types" \
        "/rest/api/3/issuetype/project?projectId=${CURRENT_PROJECT_ID}" \
        '.[]?.name // .values[]?.name'
}

get_epics() {
    local cache_file="$CACHE_DIR/${CURRENT_PROJECT}_epics.txt"

    if [[ ! -s "$cache_file" ]]; then
        > "$cache_file"
        local page_size=100
        local next_page_token=""

        # Clean any hidden carriage returns from the project key
        local proj="${CURRENT_PROJECT//$'\r'/}"

        while true; do
            local json_body
            # Build the payload (injecting nextPageToken only if we have one)
            if [[ -z "$next_page_token" ]]; then
                json_body=$(jq -n \
                    --arg jql "project=\"$proj\" AND issuetype=Epic" \
                    --argjson max "$page_size" \
                    '{jql: $jql, maxResults: $max, fields: ["summary"]}')
            else
                json_body=$(jq -n \
                    --arg jql "project=\"$proj\" AND issuetype=Epic" \
                    --argjson max "$page_size" \
                    --arg token "$next_page_token" \
                    '{jql: $jql, maxResults: $max, fields: ["summary"], nextPageToken: $token}')
            fi

            local response
            response=$(curl -sS -X POST \
                -u "${JIRA_LOGIN}:${JIRA_API_TOKEN}" \
                -H "Accept: application/json" \
                -H "Content-Type: application/json" \
                -d "$json_body" \
                "${JIRA_SERVER%/}/rest/api/3/search/jql")

            # Check if Jira explicitly returned an error message
            local error_msg
            error_msg=$(echo "$response" | jq -r '.errorMessages[0] // empty')
            if [[ -n "$error_msg" ]]; then
                echo "Jira API Error: $error_msg" >&2
                rm -f "$cache_file"
                return 1
            fi

            # Append this page's results to the cache
            echo "$response" | jq -r '.issues[]? | "\(.key) \(.fields.summary)"' | sed '/^$/d' >> "$cache_file"

            # The new endpoint uses nextPageToken instead of startAt for pagination
            next_page_token=$(echo "$response" | jq -r '.nextPageToken // empty')

            # If no token is returned, or it is explicitly "null", we have reached the end
            [[ -z "$next_page_token" || "$next_page_token" == "null" ]] && break
        done

        sort -u -o "$cache_file" "$cache_file"
    fi

    cat "$cache_file"
}

get_users() {
    local cache_file="$CACHE_DIR/${CURRENT_PROJECT}_users.txt"
    if [[ ! -s "$cache_file" ]]; then
        > "$cache_file"
        local start=0 page_size=1000
        while true; do
            local response
            response=$(jira_api_get "/rest/api/3/users/search?startAt=${start}&maxResults=${page_size}")
            local count
            count=$(echo "$response" | jq 'length')
            [[ "$count" -eq 0 ]] && break
            echo "$response" \
                | jq -r '.[] | select(.accountType == "atlassian") | (.emailAddress // .displayName)' \
                | sed '/^$/d' >> "$cache_file"
            start=$((start + page_size))
            [[ "$count" -lt "$page_size" ]] && break
        done
        sort -u -o "$cache_file" "$cache_file"
    fi
    cat "$cache_file"
}

get_labels() {
    fetch_api_cached "labels" \
        "/rest/api/3/label" \
        '.values[]?' \
        '.total'
}

get_components() {
    fetch_api_cached "components" \
        "/rest/api/3/project/${CURRENT_PROJECT}/components" \
        '.[]?.name'
}

# ==============================================================================
# UI HELPERS
# ==============================================================================

select_single() { fzf --prompt="$1 > " --height=40% --layout=reverse --border; }
select_multi()  { fzf -m --prompt="$1 (TAB multi-select) > " --height=40% --layout=reverse --border; }

# ==============================================================================
# FLOWS
# ==============================================================================

create_issue() {
    local type
    type=$(get_issue_types | select_single "Issue Type") || return
    [[ -z "$type" ]] && return

    local epic=""
    if [[ "$type" != "Epic" ]]; then
        epic=$(get_epics | select_single "Epic (ESC to skip)" | awk '{print $1}') || true
    fi

    local a_sel
    a_sel=$( (echo "Me ($CURRENT_USER)"; get_users) | select_single "Assignee (ESC for Unassigned)") || true
    local assignee="x"
    [[ "$a_sel" == "Me ($CURRENT_USER)" ]] && assignee="$CURRENT_USER"
    [[ -n "$a_sel" && "$a_sel" != "Me ($CURRENT_USER)" ]] && assignee="$a_sel"

    local r_sel
    r_sel=$( (echo "Me ($CURRENT_USER)"; get_users) | select_single "Reporter (ESC for Me)") || true
    local reporter="$CURRENT_USER"
    [[ -n "$r_sel" && "$r_sel" != "Me ($CURRENT_USER)" ]] && reporter="$r_sel"

    local labels components
    labels=$(get_labels     | select_multi "Labels (ESC to skip)"     | paste -sd, -) || true
    components=$(get_components | select_multi "Components (ESC to skip)" | paste -sd, -) || true

    local summary
    read -rp "Summary: " summary
    [[ -z "$summary" ]] && return

    echo "Description (CTRL-D to end, ENTER for empty):"
    local body; body=$(cat)

    local a_disp="$assignee"; [[ "$assignee" == "x" ]] && a_disp="Unassigned"

    clear
    cat <<-EOF
		Review your issue:
		---------------------------
		Project:     $CURRENT_PROJECT
		Type:        $type
		Summary:     $summary
		Epic:        ${epic:-N/A}
		Assignee:    $a_disp
		Reporter:    $reporter
		Labels:      ${labels:-None}
		Components:  ${components:-None}
		Description: ${body:-None}
		---------------------------
		EOF

    local confirm
    read -rp "Create this issue? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Aborted."; sleep 1; return; }

    local args=("--no-input" "-p$CURRENT_PROJECT" "-t$type" "-s$summary")
    [[ -n "$epic" ]]     && args+=("-P$epic")
    [[ "$assignee" != "x" ]] && args+=("-a$assignee")
    [[ -n "$reporter" ]] && args+=("-r$reporter")
    [[ -n "$body" ]]     && args+=("-b$body")

    local item
    IFS=',' read -ra L_ARR <<< "$labels";     for item in "${L_ARR[@]}"; do [[ -n "$item" ]] && args+=("-l$item"); done
    IFS=',' read -ra C_ARR <<< "$components"; for item in "${C_ARR[@]}"; do [[ -n "$item" ]] && args+=("-C$item"); done

    echo -e "\nCreating issue..."
    jira issue create "${args[@]}" || true
    read -n 1 -srp "Press any key to return to menu..."
}

view_issue() {
    local key="$1"
    while true; do
        clear
        jira issue view "$key" --plain 2>/dev/null | head -n 15
        echo "---------------------------"
        local action
        action=$(printf '%s\n' "1. View Full" "2. Comment" "3. Transition" "4. Open in Web" "5. Back" \
            | select_single "Action") || return

        case "$action" in
            "1"*) jira issue view "$key" | ${PAGER:-less -R} ;;
            "2"*) local c; read -rp "Comment: " c; [[ -n "$c" ]] && jira issue comment add "$key" "$c" ;;
            "3"*) jira issue move "$key" ;;
            "4"*) jira open "$key" ;;
            *)    return ;;
        esac
    done
}

list_issues() {
    local filter="$1"
    while true; do
        local selection
        selection=$(jira issue list $filter --project="$CURRENT_PROJECT" --plain --columns key,summary,status --no-headers | \
            fzf --prompt="Issues > " --height=80% --layout=reverse --preview 'jira issue view {1}') || break
        [[ -z "$selection" ]] && break
        view_issue "$(echo "$selection" | awk '{print $1}')"
    done
}

# ==============================================================================
# MAIN MENU
# ==============================================================================

while true; do
    clear
    action=$(printf '%s\n' "1. List My Issues" "2. Create Issue" "3. Search Issues" "4. Refresh API Cache" "5. Exit" | \
        fzf --prompt="Main Menu > " --header="User: $CURRENT_USER | Project: $CURRENT_PROJECT" --height=40% --layout=reverse) || true

    case "$action" in
        "1"*) list_issues "-a$CURRENT_USER" ;;
        "2"*) create_issue ;;
        "3"*)
            q=""
            read -rp "JQL/Text Query: " q
            [[ -n "$q" ]] && list_issues "$q"
            ;;
        "4"*) rm -f "$CACHE_DIR/${CURRENT_PROJECT}_"*.txt; echo "Cache cleared."; sleep 1 ;;
        *)    exit 0 ;;
    esac
done
