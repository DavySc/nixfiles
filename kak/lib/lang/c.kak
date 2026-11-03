# C and C++: clangd, clang-format, gdb.
#
# <space>m  m build   r run   d debug   g configure   a alternate source/header
# Two paths, kept apart as in ftplugin/cpp.lua: a CMake project around the file
# (build/ next to the topmost CMakeLists.txt), or this file alone.

hook -group config global WinSetOption filetype=(c|cpp) %{
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=(c|cpp) %{
    # Same flags as the clangd setup in lang/c.lua.
    set-option buffer lsp_servers %sh{
        jobs=$(( $(nproc 2>/dev/null || echo 4) / 2 ))
        [ "$jobs" -lt 2 ] && jobs=2
        cat <<EOF
[clangd]
args = [
    "--background-index", "--clang-tidy", "--completion-style=detailed",
    "--all-scopes-completion", "--function-arg-placeholders",
    "--header-insertion=iwyu", "--header-insertion-decorators",
    "--fallback-style=llvm", "--enable-config", "--pch-storage=memory", "-j=$jobs",
]
root_globs = ["compile_commands.json", ".clangd", ".git", ".hg"]
EOF
    }
    set-option buffer formatcmd "clang-format --assume-filename='%val{buffile}'"
    set-option buffer format_on_save true
    set-option buffer format_guard %opt{clang_format_guard}
    map buffer make m ': c-do build<ret>' -docstring 'build'
    map buffer make r ': c-do run<ret>' -docstring 'run'
    map buffer make d ': c-do debug<ret>' -docstring 'debug (gdb)'
    map buffer make g ': c-do configure<ret>' -docstring 'CMake configure'
    map buffer make a ': clangd-switch-source-header<ret>' -docstring 'alternate source/header'
}

define-command -override c-do -params 1 -docstring 'c-do <build|run|debug|configure>: the CMake project around the buffer, else this file alone' %{
    evaluate-commands %sh{
        action=$1
        file=$kak_buffile
        if [ -z "$file" ]; then
            echo "fail 'c: the buffer is not backed by a file'"
            exit
        fi

        # Topmost directory of the unbroken chain of CMakeLists.txt above the file.
        d=$(dirname "$file")
        while [ ! -f "$d/CMakeLists.txt" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
        root=
        if [ -f "$d/CMakeLists.txt" ]; then
            root=$d
            p=$(dirname "$d")
            while [ "$p" != "$d" ] && [ -f "$p/CMakeLists.txt" ]; do
                root=$p
                d=$p
                p=$(dirname "$p")
            done
        fi

        if [ -n "$root" ]; then
            build=$root/build
            gen=
            if [ ! -f "$build/CMakeCache.txt" ] && command -v ninja >/dev/null 2>&1; then gen='-G Ninja'; fi
            configure="cmake -S '$root' -B '$build' $gen -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON && ln -sf '$build/compile_commands.json' '$root/compile_commands.json'"
            case $action in
            configure) echo "set-option buffer makecmd %{$configure}; make" ;;
            build) echo "set-option buffer makecmd %{ [ -f '$build/CMakeCache.txt' ] || { $configure; } && cmake --build '$build' }; make" ;;
            run) echo "prompt -file-completion -init '$build/' 'Executable: ' %{ pane split %val{text} }" ;;
            debug) echo "prompt -file-completion -init '$build/' 'Executable: ' %{ pane split gdb %val{text} }" ;;
            esac
            exit
        fi

        # One file, built into the cache, keyed by its path so two main.cpp can't collide.
        # The newest standard the compiler knows: C23 / C++23, or the old spelling.
        if [ "$kak_opt_filetype" = c ]; then
            cc=gcc; command -v gcc >/dev/null 2>&1 || cc=clang
            if echo | $cc -std=c23 -x c -fsyntax-only - 2>/dev/null; then std=-std=c23; else std=-std=c2x; fi
        else
            cc=g++; command -v g++ >/dev/null 2>&1 || cc=clang++
            if echo | $cc -std=c++23 -x c++ -fsyntax-only - 2>/dev/null; then std=-std=c++23; else std=-std=c++2b; fi
        fi
        dir=${XDG_CACHE_HOME:-$HOME/.cache}/kak/cpp
        mkdir -p "$dir"
        out=$dir/$(basename "${file%.*}")-$(printf %s "$file" | cksum | cut -d' ' -f1)
        compile="$cc $std -Wall -Wextra -g '$file' -o '$out'"
        case $action in
        build) echo "set-option buffer makecmd %{$compile}; make" ;;
        run) echo "pane split sh -c %{$compile && '$out'}" ;;
        debug) echo "pane split sh -c %{$compile && gdb '$out'}" ;;
        configure) echo "fail 'c: no CMakeLists.txt above this file'" ;;
        esac
    }
}
