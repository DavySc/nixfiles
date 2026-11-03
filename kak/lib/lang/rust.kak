# Rust. Like HLS, rust-analyzer must match the project's toolchain (its
# proc-macro server is tied to rustc), so in a flake project it runs through
# `nix develop` to get the flake's rust-analyzer / cargo / RUST_SRC_PATH;
# otherwise from PATH. Formatting falls to the server (rustfmt).

hook -group config global WinSetOption filetype=rust %{
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=rust %{
    set-option buffer lsp_servers %sh{
        # The nearest flake.nix above the file, unless we are already in a dev shell.
        cmd=
        if [ -z "$IN_NIX_SHELL" ]; then
            d=$(dirname "$kak_buffile")
            while [ "$d" != / ] && [ ! -f "$d/flake.nix" ]; do d=$(dirname "$d"); done
            if [ -f "$d/flake.nix" ]; then
                cmd="command = \"nix\"
args = [\"develop\", \"$d\", \"--command\", \"rust-analyzer\"]"
            fi
        fi
        cat <<EOF
[rust-analyzer]
$cmd
root_globs = ["Cargo.toml", "rust-project.json"]
single_instance = true
[rust-analyzer.experimental]
commands.commands = ["rust-analyzer.runSingle"]
hoverActions = true
[rust-analyzer.settings.rust-analyzer]
check.command = "clippy"
EOF
    }
    set-option buffer format_on_save true
    set-option buffer format_with_lsp true
}
