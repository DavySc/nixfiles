;;; init.el --- kittymax  -*- lexical-binding: t; -*-

;; An Emacs with my-nvim's keys (evil). This file only wires the modules in
;; lisp/ together; each one is a few hundred lines about one topic.
;;
;;   kitty-platform    Nix vs Windows: state directories, where packages come from
;;   kitty-packages    the package list, and installing it without Nix
;;   kitty-lib         loader (byte-compiles into the cache), macros, local leader
;;   kitty-core        defaults, performance, state directories
;;   kitty-ui          catppuccin mocha, modeline, fonts, icons, which-key
;;   kitty-splash      the start screen
;;   kitty-cat         a kitten gives you a paw when you save
;;   kitty-evil        Vim keys and the SPC leader tree, as in my-nvim
;;   kitty-vim         my-nvim's operators, text objects and multiple cursors
;;   kitty-completion  vertico, orderless, consult, embark, corfu
;;   kitty-vc          magit, diff-hl
;;   kitty-dired       dirvish
;;   kitty-org         org-mode
;;   kitty-org-tools   clocking, habits, export (HTML, PDF, Word), babel, org-roam
;;   kitty-markdown    the markdown editing experience
;;   kitty-prog        tree-sitter, eglot, formatting
;;   kitty-rss         elfeed: RSS and Atom feeds
;;   lang/*            C and C++ (+ msvc: Visual Studio's compiler and MSBuild), C#, OCaml,
;;                     SQL (+ dbbliss: the database client, + sqldiff), Soufflé,
;;                     Verilog and SystemVerilog, Nix

(add-to-list 'load-path (expand-file-name "lisp" kitty-config-dir))
(add-to-list 'load-path (expand-file-name "lisp/lang" kitty-config-dir))
(require 'kitty-lib)

;; Without Nix (native Windows): install the packages on the first start.
(require 'kitty-packages)
(kitty-ensure-packages)

(kitty-load 'kitty-core)
(kitty-load 'kitty-ui)
(kitty-load 'kitty-splash)
(kitty-load 'kitty-cat)
(kitty-load 'kitty-evil)
(kitty-load 'kitty-vim)
(kitty-load 'kitty-completion)
(kitty-load 'kitty-vc)
(kitty-load 'kitty-dired)
(kitty-load 'kitty-org)
(kitty-load 'kitty-org-tools)
(kitty-load 'kitty-markdown)
(kitty-load 'kitty-prog)
(kitty-load 'kitty-rss)
(dolist (lang '(kitty-msvc kitty-c kitty-csharp kitty-ocaml kitty-sql kitty-dbbliss kitty-sqldiff
                kitty-souffle kitty-verilog kitty-nix))
  (kitty-load lang))

;; Machine-specific settings (git-ignored): fonts, org directory, work SQL
;; connections ...
(let ((local (expand-file-name "local.el" kitty-config-dir)))
  (when (file-exists-p local) (load local nil 'nomessage)))

;;; init.el ends here
