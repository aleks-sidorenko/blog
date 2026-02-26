# List available commands
help:
    @just --list

# Start local dev server at http://localhost:1111
start:
    nix run .#serve

# Open blog in browser
open:
    open http://localhost:1111

# Format Nix files
format:
    nix fmt
