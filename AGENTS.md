# Project: jira-cli-fzf

## Overview
A lightweight, interactive Terminal User Interface (TUI) for Jira, built using Bash, `fzf`, and the `jira-cli` (Go version). It streamlines common Jira tasks like issue listing, creation, and management through a fuzzy-search interface with advanced metadata support via Jira's REST API.

## Tech Stack
- **Languages**: Bash (v4+ recommended)
- **Core Tools**:
    - [jira-cli](https://github.com/ankitpokhrel/jira-cli) (Go version) - Primary Jira CLI interaction.
    - [fzf](https://github.com/junegunn/fzf) - Interactive selection and menus.
    - [jq](https://stedolan.github.io/jq/) - JSON processing for API responses.
    - [curl](https://curl.se/) - Direct Jira REST API v3 interaction.
- **Packaging**: Nix Flakes for reproducible environments and builds.

## Key Features
- **Interactive Issue Listing**: Live previews of issues using `fzf`.
- **Modular Issue Creation**: Step-by-step wizard with fuzzy selection for project, type, epic, labels, and components.
- **Hybrid API Architecture**: Uses `jira-cli` for common actions and falls back to direct REST API calls (via `curl` + `JIRA_API_TOKEN`) for richer metadata like assignable users and epics.
- **Issue Management**: View details (with pager), comment, transition status, assign, and open in web browser.
- **Project Switching**: Quickly toggle between different Jira projects (accessible via `CTRL-P` in the main menu).
- **Persistent Selection Caching**: Stores project-specific metadata (users, labels, components, epics) in `$XDG_CACHE_HOME/jira-cli-fzf/` for sub-second selection menus.

## Project Structure
- `main.sh`: Entry point containing business logic, UI definitions, and the hybrid Jira API wrapper.
- `flake.nix`: Nix configuration for building the package and providing a development shell with all dependencies.
- `flake.lock`: Lock file for Nix dependencies.
- `README.md`: Usage and installation instructions.
- `LICENSE`: MIT License.

## Architectural Patterns & Conventions
- **Functional Decomposition**: Divided into Configuration, Utilities, Data Persistence, API Integration (REST vs CLI), UI Components (fzf), and Jira Actions.
- **Hybrid Data Retrieval**: Prefers REST API for metadata if `JIRA_API_TOKEN` is present; falls back to parsing `jira-cli` table output for air-gapped or token-less environments.
- **Interactive Loops**: Multi-layered menu system using `while true` loops and `fzf --expect`.
- **Dependency Guarding**: `check_dependencies` ensures `jira`, `fzf`, and `jq` are available.
- **Runtime Environment**: Nix `makeWrapper` ensures `jira-cli-go`, `fzf`, `jq`, and coreutils are in the `PATH` regardless of host system.
- **State Management**:
    - `CURRENT_USER` and `CURRENT_PROJECT` tracked in global session variables.
    - Project-scoped cache directory: `~/.cache/jira-cli-fzf/<PROJECT_KEY>/`.

## Development Guidelines
- **Modifying UI**: Use `select_*` functions. Maintain consistency with `fzf` flags: `--prompt`, `--header`, and `--preview`.
- **Adding Jira Actions**: Define a `perform_*` function and integrate it into the `main()` loop.
- **API Enhancements**: Use `jira_api_get` for new metadata. Ensure a fallback `query_*_fallback` exists using the standard CLI.
- **Nix Updates**: Add new runtime dependencies (e.g. `gawk`, `sed`) to the `wrapProgram` list in `flake.nix`.
- **Testing**: Test via `nix run .` or direct execution inside `nix develop`.
