# jira-cli-fzf

A simple, interactive TUI for Jira using `jira-cli` and `fzf`.

This project provides a Bash script (`main.sh`) that wraps the [Go Jira CLI](https://github.com/ankitpokhrel/jira-cli) with `fzf` to provide a faster, more interactive experience for common Jira tasks directly from your terminal.

## Features

- **Interactive Issue Listing**: Browse, search, and filter issues with live previews.
- **Issue Creation**: Step-by-step creation with fuzzy selection for projects, issue types, epics, labels, and components.
- **Issue Management**: View details, add comments, transition status, and assign issues.
- **Project Switching**: Quickly switch between different Jira projects.
- **Performance**: Session-based caching for labels and components.

## Dependencies

Before using this script, ensure you have the following installed and configured:

1. **[jira-cli](https://github.com/ankitpokhrel/jira-cli)**: The core CLI for Jira interaction.
   - Make sure it's authenticated (`jira init` or `jira me` should work).
2. **[fzf](https://github.com/junegunn/fzf)**: Command-line fuzzy finder.

## Installation

### Manual

1. Clone this repository:

   ```bash
   git clone https://github.com/atimofeev/jira-cli-fzf.git
   cd jira-cli-fzf
   ```

2. Make the script executable:

   ```bash
   chmod +x main.sh
   ```

3. (Optional) Create an alias in your `.bashrc` or `.zshrc`:
   ```bash
   alias jira-fzf='/path/to/jira-cli-fzf/main.sh'
   ```

### Nix (Flakes)

Run directly:

```bash
nix run github:atimofeev/jira-cli-fzf
```

Add to your `flake.nix` inputs:

```nix
inputs.jira-cli-fzf.url = "github:atimofeev/jira-cli-fzf";
```

Then add `inputs.jira-cli-fzf.packages.${system}.default` to your `environment.systemPackages` or `home.packages`.

## Usage

Simply run the script:

```bash
./main.sh
```

Use the arrow keys or `fzf` search to navigate the menus.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
