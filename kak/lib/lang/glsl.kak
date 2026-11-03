# GLSL (OpenGL / Vulkan shaders). Kakoune has no GLSL filetype: this adds
# detection, C highlighting plus the GLSL types and qualifiers, and
# glsl_analyzer for completion, go-to-definition and diagnostics. clang-format
# understands GLSL well enough; like C, it only runs on save when the project
# has a .clang-format (`<space>cf` always formats).

hook -group config global BufCreate .*\.(glsl|vert|frag|geom|tesc|tese|comp|mesh|task|rgen|rchit|rmiss)$ %{
    set-option buffer filetype glsl
}

hook -group config global WinSetOption filetype=glsl %{
    require-module c-family
    add-highlighter window/glsl-c ref c
    add-highlighter window/glsl group
    add-highlighter window/glsl/types regex \b(void|bool|u?int|float|double|[biud]?vec[234]|d?mat[234](x[234])?|[iu]?sampler(1D|2D|3D|Cube|2DRect|1DArray|2DArray|CubeArray|Buffer|2DMS|2DMSArray)(Shadow)?|[iu]?image(1D|2D|3D|Cube|Buffer|2DArray)|atomic_uint|sampler|texture2D)\b 0:type
    add-highlighter window/glsl/qualifiers regex \b(uniform|buffer|shared|attribute|varying|in|out|inout|centroid|flat|smooth|noperspective|layout|const|invariant|precise|highp|mediump|lowp|precision|coherent|volatile|restrict|readonly|writeonly|discard|subroutine|patch|sample)\b 0:keyword
    add-highlighter window/glsl/builtins regex \b(gl_[A-Za-z]+)\b 0:builtin
    add-highlighter window/glsl/version regex ^\h*#\h*(version|extension)\b.*$ 0:meta
    hook -once -always window WinSetOption filetype=.* %{
        remove-highlighter window/glsl-c
        remove-highlighter window/glsl
    }
    try lsp-setup-window
}

hook -group config global BufSetOption filetype=glsl %{
    set-option buffer comment_line '//'
    set-option buffer comment_block_begin '/*'
    set-option buffer comment_block_end '*/'
    set-option buffer lsp_servers %{
        [glsl_analyzer]
        root_globs = [".git", ".hg"]
    }
    set-option buffer formatcmd "clang-format --assume-filename='%val{buffile}'"
    set-option buffer format_on_save true
    set-option buffer format_guard %opt{clang_format_guard}
}
