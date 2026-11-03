# Hot reload, like <leader>R in nvim: source kakrc again. Buffers already open
# get their filetype set once more so the language hooks run for them. What a
# reload cannot undo: a mapping or command you deleted stays until restart.
#
# config-reload is defined without -override on purpose: it is running while
# kakrc (and so this file) is sourced again, and replacing a command that is
# executing frees the text Kakoune is reading. A change to this file therefore
# needs a restart; the first definition stays in place until then.

try %{
    define-command config-reload -docstring 'source the config again' %{
        source "%opt{config_dir}/kakrc"
        evaluate-commands -buffer * %{
            try %{ set-option buffer filetype %opt{filetype} }
        }
        echo -markup '{Information}config reloaded'
    }
}
