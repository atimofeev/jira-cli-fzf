# Project: jira-cli-fzf

## Overview
A lightweight, interactive Terminal User Interface (TUI) for Jira, built using Bash, `fzf`, and the `jira-cli` (Go version). It streamlines common Jira tasks like issue listing, creation, and management through a fuzzy-search interface.

## Tech Stack
- **Languages**: Bash (v4+ recommended)
- **Core Tools**:
    - [jira-cli](https://github.com/ankitpokhrel/jira-cli) (Go version) - Jira API interaction.
    - [fzf](https://github.com/junegunn/fzf) - Interactive selection and menus.
- **Packaging**: Nix Flakes for reproducible environments and builds.

## Key Features
- **Interactive Issue Listing**: Live previews of issues using `fzf`.
- **Modular Issue Creation**: Step-by-step wizard with fuzzy selection for project, type, epic, labels, and components.
- **Issue Management**: View details (with pager), comment, transition status, assign, and open in web browser.
- **Project Switching**: Quickly toggle between different Jira projects (accessible via `CTRL-P` in the main menu).
- **Persistent Selection Caching**: Stores custom labels and components in a local `.jira-config/` directory for faster selection in future sessions.

## Project Structure
- `main.sh`: Entry point containing all business logic, UI definitions, and Jira API wrappers.
- `flake.nix`: Nix configuration for building the package and providing a development shell with all dependencies.
- `flake.lock`: Lock file for Nix dependencies.
- `README.md`: Usage and installation instructions.
- `LICENSE`: MIT License.

## Architectural Patterns & Conventions
- **Functional Decomposition**: The script is divided into clear sections: Configuration, Utilities, Data Persistence, UI Components (fzf wrappers), and Jira Actions.
- **Interactive Loops**: Uses `while true` loops with `fzf` to create a multi-layered menu system.
- **Dependency Guarding**: `check_dependencies` ensures required tools are available on startup.
- **Runtime Environment**: In Nix, the script is wrapped using `makeWrapper` to ensure runtime dependencies (`jira-cli-go`, `fzf`, `gawk`, etc.) are always in the `PATH`.
- **State Management**:
    - `CURRENT_USER` and `CURRENT_PROJECT` are tracked in global variables during a session.
    - Local file-based storage for user-defined labels and components.

## Development Guidelines
- **Modifying UI**: Most UI changes happen in `select_*` functions. Use `fzf` flags like `--prompt`, `--header`, and `--preview` to maintain consistency.
- **Adding Jira Actions**: Define a new `perform_*` function and integrate it into the `main()` loop's `case` statement.
- **Nix Updates**: If adding new command-line utility dependencies (e.g., `jq`), ensure they are added to the `wrapProgram` list in `flake.nix`.
- **Testing**: Test changes by running `./main.sh` directly (if dependencies are installed) or via `nix run .`.
