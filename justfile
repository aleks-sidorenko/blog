# List available commands
help:
    @just --list

# Run local dev server at http://localhost:1111
run:
    nix run .#serve

# Open blog in browser
open:
    open http://localhost:1111

# Build the CV PDF locally (cv/cv.pdf); two passes resolve page references
cv:
    lualatex --interaction=nonstopmode --halt-on-error --output-directory=cv cv/cv.tex
    lualatex --interaction=nonstopmode --halt-on-error --output-directory=cv cv/cv.tex

# Format Nix files
format:
    nix fmt
