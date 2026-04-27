#!/usr/bin/env bash

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================

# Defaults
DEFAULT_LABELS="bug feature documentation enhancement help-wanted question"
DEFAULT_COMPONENTS="frontend backend database api ui infrastructure"
DEFAULT_ISSUE_TYPES=$'Task\nStory\nBug\nEpic\nSub-task'

# Cache/query tuning
# jira-cli enforces maxResults between 1 and 100 (inclusive).
CACHE_PAGINATE="0:100"
API_PAGE_SIZE_USERS=1000
API_PAGE_SIZE_SEARCH=100

# Cache Paths (project-scoped)
# Stored as newline-separated text files:
#   $XDG_CACHE_HOME/jira-cli-fzf/<jira-project>/<object_type>.txt
CACHE_BASE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/jira-cli-fzf"

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
    for cmd in jira fzf jq; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is not installed."
            exit 1
        fi
    done

    if [[ -n "${JIRA_API_TOKEN:-}" ]] && ! command -v curl &> /dev/null; then
        log_error "curl is required when using JIRA_API_TOKEN."
        exit 1
    fi
}

ensure_config_dirs() {
    mkdir -p "$CACHE_BASE_DIR"
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

sanitize_project_key() {
    # Project keys are usually safe, but avoid path traversal surprises.
    echo "$1" | tr '/ ' '__'
}

cache_project_dir() {
    local project
    project=$(sanitize_project_key "$1")
    echo "$CACHE_BASE_DIR/$project"
}

cache_file() {
    local project="$1"
    local object_type="$2"
    echo "$(cache_project_dir "$project")/${object_type}.txt"
}

cache_has() {
    local project="$1"
    local object_type="$2"
    [[ -s "$(cache_file "$project" "$object_type")" ]]
}

cache_read() {
    local project="$1"
    local object_type="$2"
    local file
    file=$(cache_file "$project" "$object_type")
    [[ -f "$file" ]] && cat "$file"
}

cache_write_from_stdin() {
    local project="$1"
    local object_type="$2"
    local file
    file=$(cache_file "$project" "$object_type")
    mkdir -p "$(dirname "$file")"
    cat > "$file"
}

############################
# Jira REST API integration #
############################

JIRA_API_BASE=""
JIRA_API_LOGIN=""

jira_config_path() {
    echo "${JIRA_CONFIG_FILE:-$HOME/.config/.jira/.config.yml}"
}

jira_config_get() {
    local key="$1"
    local file
    file=$(jira_config_path)
    [[ -f "$file" ]] || return 1

    awk -v k="$key" '
      $0 ~ "^[[:space:]]*"k"[[:space:]]*:" {
        sub("^[[:space:]]*"k"[[:space:]]*:[[:space:]]*", "", $0)
        gsub(/^[\"\047]/, "", $0)
        gsub(/[\"\047]$/, "", $0)
        print $0
        exit
      }
    ' "$file"
}

jira_api_init() {
    [[ -n "$JIRA_API_BASE" && -n "$JIRA_API_LOGIN" ]] && return 0

    local server login
    server=$(jira_config_get "server" 2>/dev/null) || return 1
    login=$(jira_config_get "login" 2>/dev/null) || return 1

    [[ -z "$server" || -z "$login" ]] && return 1

    JIRA_API_BASE="${server%/}"
    JIRA_API_LOGIN="$login"
}

jira_api_available() {
    [[ -n "${JIRA_API_TOKEN:-}" ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    jira_api_init
}

jira_api_uri_encode() {
    local s="$1"
    jq -nr --arg s "$s" '$s|@uri'
}

jira_api_get() {
    local path="$1"
    [[ "$path" != /* ]] && path="/$path"

    jira_api_available || {
        log_error "Jira REST API unavailable. Ensure JIRA_API_TOKEN is set and Jira config has server/login."
        return 1
    }

    if [[ "${JIRA_CLI_FZF_API_DEBUG:-0}" == "1" ]]; then
        echo "API GET ${path}" >&2
    fi

    # Use basic auth with API token (Jira Cloud).
    curl -fsS \
        -u "${JIRA_API_LOGIN}:${JIRA_API_TOKEN}" \
        -H "Accept: application/json" \
        "${JIRA_API_BASE}${path}"
}

query_epic_issuetype_id_api() {
    local project="$1"
    local pid
    pid=$(jira_api_get "/rest/api/3/project/${project}" | jq -r '.id // empty')
    [[ -z "$pid" ]] && return 1

    jira_api_get "/rest/api/3/issuetype/project?projectId=${pid}" | jq -r '
      def items:
        if type=="array" then . else (.values // []) end;
      (items
        | map(select((.subtask? // false) == false))
        | (
            map(select((.name? // "") | ascii_downcase == "epic"))[0].id
            // map(select((.hierarchyLevel? // -999) == 1))[0].id
            // empty
          )
      )
    '
}

query_issue_types_fallback() {
    local project="$1"
    local out=""
    out=$(jira issue list --plain --columns key,type --no-headers --paginate "$CACHE_PAGINATE" --project="$project" 2>/dev/null | \
        awk -F'\t' '{ if (NF >= 2) print $2; else print $1 }' | \
        sed '/^[[:space:]]*$/d' | sort -u) || true

    if [[ -n "$out" ]]; then
        echo "$out"
    else
        echo "$DEFAULT_ISSUE_TYPES"
    fi
}

query_users_fallback() {
    local project="$1"
    jira issue list --plain --columns key,assignee,reporter --no-headers --paginate "$CACHE_PAGINATE" --project="$project" 2>/dev/null | \
        awk -F'\t' '
          {
            if (NF >= 3) { print $2 "\n" $3 }
            else if (NF == 2) { print $2 }
            else { print $1 }
          }
        ' | \
        sed -e 's/^[[:space:]]*//; s/[[:space:]]*$//' | \
        sed '/^$/d; /^Unassigned$/d; /^None$/d; /^-$/d; /^x$/d' | \
        sort -u
}

query_labels_fallback() {
    local project="$1"
    jira issue list --plain --columns key,labels --no-headers --paginate "$CACHE_PAGINATE" --project="$project" 2>/dev/null | \
        awk -F'\t' '{ if (NF >= 2) print $2; else print $1 }' | \
        sed -e 's/[][]//g' -e 's/,/ /g' | \
        tr ' ' '\n' | \
        sed '/^$/d' | \
        sort -u
}

query_components_fallback() {
    local project="$1"
    jira issue list --raw --paginate "$CACHE_PAGINATE" --project="$project" 2>/dev/null | \
        jq -r '..|.components? // empty | .[]? | .name? // empty' | \
        sed '/^$/d' | sort -u
}

query_epics_fallback() {
    local project="$1"
    jira epic list --plain --columns KEY,SUMMARY --no-headers --project="$project" 2>/dev/null
}

query_issue_types_api() {
    local project="$1"
    local pid
    pid=$(jira_api_get "/rest/api/3/project/${project}" | jq -r '.id // empty')
    [[ -z "$pid" ]] && return 1

    jira_api_get "/rest/api/3/issuetype/project?projectId=${pid}" | \
        jq -r '
          if type=="array" then .[]? | .name? // empty
          else (.values[]?.name // empty) end
        ' | \
        sed '/^$/d' | sort -u
}

query_components_api() {
    local project="$1"
    jira_api_get "/rest/api/3/project/${project}/components" | \
        jq -r '.[]?.name // empty' | \
        sed '/^$/d' | sort -u
}

query_users_api() {
    local project="$1"
    local mode="${JIRA_CLI_FZF_USERS_API_MODE:-assignable}" # assignable | all
    local start=0
    local max="$API_PAGE_SIZE_USERS"

    query_users_with_permission_api() {
        local start_perm=0
        while true; do
            # This endpoint often returns a more complete set than "assignable/search".
            local json
            json=$(jira_api_get "/rest/api/3/user/permission/search?projectKey=${project}&permissions=ASSIGN_ISSUES,CREATE_ISSUES&startAt=${start_perm}&maxResults=${max}")

            local count
            count=$(printf "%s\n" "$json" | jq -r '
              if has("values") then (.values | length)
              elif has("users") then (.users | length)
              else 0 end
            ')
            [[ "$count" -eq 0 ]] && break

            printf "%s\n" "$json" | jq -r '
              def users:
                if has("values") then (.values[]?.user // empty)
                elif has("users") then (.users[]? // empty)
                else empty end;
              users
              | select((.active? // true) == true)
              | (.emailAddress? // .displayName? // empty)
            ' | sed '/^$/d'

            start_perm=$((start_perm + count))
            [[ "$count" -lt "$max" ]] && break
        done
    }

    {
        # Primary source.
        while true; do
            local json
            if [[ "$mode" == "all" ]]; then
                # Requires the "Browse users and groups" global permission in many Jira setups.
                # Some instances allow an empty query; if not, switch to assignable mode.
                json=$(jira_api_get "/rest/api/3/user/search?query=&startAt=${start}&maxResults=${max}")
            else
                json=$(jira_api_get "/rest/api/3/user/assignable/search?project=${project}&startAt=${start}&maxResults=${max}")
            fi

            local count
            count=$(printf "%s\n" "$json" | jq 'length')
            [[ "$count" -eq 0 ]] && break

            # Prefer email when available; otherwise fall back to displayName.
            printf "%s\n" "$json" | jq -r '
              .[]?
              | select((.active? // true) == true)
              | (.emailAddress? // .displayName? // empty)
            ' | sed '/^$/d'

            start=$((start + count))
            [[ "$count" -lt "$max" ]] && break
        done

        # Optional secondary source for better coverage.
        if [[ "${JIRA_CLI_FZF_USERS_INCLUDE_PERMISSIONS:-1}" == "1" ]]; then
            query_users_with_permission_api || true
        fi
    } | sort -u
}

query_labels_api() {
    local project="$1"
    local start=0
    local max="$API_PAGE_SIZE_SEARCH"
    local jql="project=${project} AND labels is not EMPTY ORDER BY created DESC"
    local jql_enc
    jql_enc=$(jira_api_uri_encode "$jql")

    while true; do
        local json
        json=$(jira_api_get "/rest/api/3/search?jql=${jql_enc}&fields=labels&startAt=${start}&maxResults=${max}")

        local count
        count=$(printf "%s\n" "$json" | jq -r '.issues | length')
        [[ "$count" -eq 0 ]] && break

        printf "%s\n" "$json" | jq -r '.issues[]?.fields.labels[]? // empty' | sed '/^$/d'

        start=$((start + count))
        [[ "$count" -lt "$max" ]] && break
    done | sort -u | uniq
}

query_epics_api() {
    local project="$1"
    local start=0
    local max="$API_PAGE_SIZE_SEARCH"
    local epic_type_id=""
    epic_type_id=$(query_epic_issuetype_id_api "$project" 2>/dev/null || true)

    local jql=""
    if [[ -n "$epic_type_id" ]]; then
        jql="project=${project} AND issuetype=${epic_type_id} ORDER BY created DESC"
    else
        jql="project=${project} AND issuetype=Epic ORDER BY created DESC"
    fi
    local jql_enc
    jql_enc=$(jira_api_uri_encode "$jql")

    while true; do
        local json
        json=$(jira_api_get "/rest/api/3/search?jql=${jql_enc}&fields=summary&startAt=${start}&maxResults=${max}")

        local count
        count=$(printf "%s\n" "$json" | jq -r '.issues | length')
        [[ "$count" -eq 0 ]] && break

        printf "%s\n" "$json" | jq -r '
          .issues[]?
          | "\(.key)\t\((.fields.summary // "") | gsub(\"[\\r\\n\\t]\"; \" \"))"
        '

        start=$((start + count))
        [[ "$count" -lt "$max" ]] && break
    done
}

append_unique_line() {
    local line="$1"
    local file="$2"
    [[ -z "$line" ]] && return 0
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if ! grep -Fxq -- "$line" "$file"; then
        echo "$line" >> "$file"
    fi
}

cache_append_unique() {
    local project="$1"
    local object_type="$2"
    local line="$3"
    append_unique_line "$line" "$(cache_file "$project" "$object_type")"
}

query_issue_types() {
    local project="$1"
    if jira_api_available; then
        local out=""
        out=$(query_issue_types_api "$project" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            printf "%s\n" "$out"
            return 0
        fi
    fi

    query_issue_types_fallback "$project"
}

query_epics() {
    local project="$1"
    if jira_api_available; then
        local out=""
        out=$(query_epics_api "$project" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            printf "%s\n" "$out"
            return 0
        fi
    fi

    query_epics_fallback "$project"
}

query_users() {
    local project="$1"
    if jira_api_available; then
        local out=""
        out=$(query_users_api "$project" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            printf "%s\n" "$out"
            return 0
        fi
    fi

    query_users_fallback "$project"
}

query_labels() {
    local project="$1"
    if jira_api_available; then
        local out=""
        out=$(query_labels_api "$project" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            printf "%s\n" "$out"
            return 0
        fi
    fi

    query_labels_fallback "$project"
}

query_components() {
    local project="$1"
    if jira_api_available; then
        local out=""
        out=$(query_components_api "$project" 2>/dev/null || true)
        if [[ -n "$out" ]]; then
            printf "%s\n" "$out"
            return 0
        fi
    fi

    query_components_fallback "$project"
}

get_cached_or_query() {
    local project="$1"
    local object_type="$2"
    local query_func="$3"

    if cache_has "$project" "$object_type"; then
        cache_read "$project" "$object_type"
    else
        "$query_func" "$project" 2>/dev/null
    fi
}

get_issue_types() { get_cached_or_query "$CURRENT_PROJECT" "issue_types" "query_issue_types"; }
get_epics() { get_cached_or_query "$CURRENT_PROJECT" "epics" "query_epics"; }
get_users() { get_cached_or_query "$CURRENT_PROJECT" "users" "query_users"; }
get_labels() {
    local out
    out=$(get_cached_or_query "$CURRENT_PROJECT" "labels" "query_labels") || true
    if [[ -n "$out" ]]; then
        echo "$out"
    else
        echo "$DEFAULT_LABELS" | tr ' ' '\n'
    fi
}
get_components() {
    local out
    out=$(get_cached_or_query "$CURRENT_PROJECT" "components" "query_components") || true
    if [[ -n "$out" ]]; then
        echo "$out"
    else
        echo "$DEFAULT_COMPONENTS" | tr ' ' '\n'
    fi
}

# ==============================================================================
# UI COMPONENTS (SELECTION MENUS)
# ==============================================================================

select_generic_multi() {
    local prompt="$1"
    local source_func="$2"     # e.g., "get_labels"
    local cache_object_type="$3" # e.g., "labels"
    local type_name="$4"       # e.g. "Label" or "Component"
    local project="$5"

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
                cache_append_unique "$project" "$cache_object_type" "$new_item"
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
    get_issue_types | \
        fzf --prompt="Issue Type > " --height=40% --layout=reverse --border
}

select_epic() {
    local selected_epic
    selected_epic=$(get_epics | \
        fzf --prompt="Link to Epic (Optional, ESC to skip) > " --height=40% --layout=reverse --border --header="Select parent Epic")

    echo "$selected_epic"
}

select_user() {
    local kind="$1" # Assignee | Reporter
    local allow_unassigned="$2" # true | false

    local -a base_options=("Me ($CURRENT_USER)")
    if [[ "$allow_unassigned" == "true" ]]; then
        base_options+=("Unassigned")
    fi
    base_options+=("Search/Manual...")

    local users
    users=$(get_users 2>/dev/null || true)

    local option
    if [[ -n "$users" ]]; then
        option=$(
            {
                printf "%s\n" "${base_options[@]}"
                printf "%s\n" "$users"
            } | sed '/^$/d' | \
                fzf --prompt="$kind (ESC to skip) > " --height=60% --layout=reverse --border --info=inline
        )
    else
        option=$(printf "%s\n" "${base_options[@]}" | \
            fzf --prompt="$kind (ESC to skip) > " --height=40% --layout=reverse --border --info=inline)
    fi

    case "$option" in
        "Me ($CURRENT_USER)") echo "$CURRENT_USER" ;;
        "Unassigned") echo "x" ;;
        "Search/Manual...")
            if [[ "$kind" == "Assignee" ]]; then
                read -p "Enter assignee email/name: " manual_value
            else
                read -p "Enter reporter email/name: " manual_value
            fi
            echo "$manual_value"
            ;;
        "") echo "" ;; # Cancelled/ESC returns empty
        *) echo "$option" ;;
    esac
}

select_assignee() { select_user "Assignee" "true"; }
select_reporter() { select_user "Reporter" "false"; }

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
    mapfile -t selected_labels < <(select_generic_multi "Labels" "get_labels" "labels" "Label" "$CURRENT_PROJECT")

    # 8. Components
    local -a selected_components
    mapfile -t selected_components < <(select_generic_multi "Components" "get_components" "components" "Component" "$CURRENT_PROJECT")

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

perform_create_cache() {
    local project="$CURRENT_PROJECT"
    if [[ -z "$project" ]]; then
        log_error "No current project selected."
        sleep 1
        return
    fi

    if ! jira_api_available; then
        log_error "Jira REST API cache generation requires JIRA_API_TOKEN (and Jira config server/login)."
        echo "Press any key to continue..."
        read -n 1
        return
    fi

    clear
    echo "Build cache for project: $project"
    echo "This will query Jira and write newline-separated text files under:"
    echo "  $(cache_project_dir "$project")"
    echo
    read -p "Continue? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        sleep 1
        return
    fi

    mkdir -p "$(cache_project_dir "$project")"

    refresh_cache_entry() {
        local object_type="$1"
        local query_func="$2"
        local data=""
        local count=0
        local res=0

        data=$("$query_func" "$project")
        res=$?
        [[ $res -ne 0 ]] && echo "  (warning) ${object_type}: query failed (exit ${res})" >&2
        data=$(printf "%s\n" "$data" | sed '/^[[:space:]]*$/d')

        echo "$data" | cache_write_from_stdin "$project" "$object_type"

        if [[ -n "$data" ]]; then
            count=$(printf "%s\n" "$data" | wc -l | tr -d ' ')
        fi

        echo "  -> ${object_type}.txt: ${count} entries"
    }

    echo "Caching issue types..."
    refresh_cache_entry "issue_types" "query_issue_types"

    echo "Caching epics..."
    refresh_cache_entry "epics" "query_epics"

    echo "Caching users..."
    refresh_cache_entry "users" "query_users"
    cache_append_unique "$project" "users" "$CURRENT_USER"

    echo "Caching labels..."
    refresh_cache_entry "labels" "query_labels"

    echo "Caching components..."
    refresh_cache_entry "components" "query_components"

    echo
    echo "Done."
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
        fzf_out=$(echo -e "1. List My Issues\n2. Create Issue\n3. Create Cache\n4. Current Sprint\n5. Search Issues\n6. Exit" | \
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
            "3. Create Cache") perform_create_cache ;;
            "4. Current Sprint")
                jira sprint list --current --assignee="$CURRENT_USER" --project="$CURRENT_PROJECT"
                ;;
            "5. Search Issues")
                read -p "Search query: " query
                [[ -n "$query" ]] && list_issues_flow "$query"
                ;;
            "6. Exit"|"") exit 0 ;;
        esac
    done
}

# Run Main
main "$@"
