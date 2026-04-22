# List available commands
help:
    @just --list

# Run local dev server at http://localhost:1111
run:
    nix run .#serve

# Open blog in browser
open:
    open http://localhost:1111

# Format Nix files
format:
    nix fmt
