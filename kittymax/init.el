;;; init.el --- kittymax  -*- lexical-binding: t; -*-

;; A Doom-inspired, meow-based Emacs. This file only wires the modules in
;; lisp/ together; each one is a few hundred lines about one topic.
;;
;;   kitty-platform    Nix vs Windows: state directories, where packages come from
;;   kitty-packages    the package list, and installing it without Nix
;;   kitty-lib         loader (byte-compiles into the cache), macros, local leader
;;   kitty-core        defaults, performance, state directories
;;   kitty-ui          catppuccin mocha, modeline, fonts, icons, which-key
;;   kitty-splash      the start screen
;;   kitty-cat         a kitten gives you a paw when you save
;;   kitty-meow        modal editing and the SPC leader tree
;;   kitty-mc          multiple cursors on top of meow's beacon
;;   kitty-ex          the : command line (:q :w :wq :e :%s ...)
;;   kitty-completion  vertico, orderless, consult, embark, corfu
;;   kitty-vc          magit, diff-hl
;;   kitty-dired       dirvish
;;   kitty-org         org-mode
;;   kitty-markdown    the markdown editing experience
;;   kitty-prog        tree-sitter, eglot, formatting
;;   lang/*            C and C++, C#, SQL (+ sqldiff), Verilog and SystemVerilog, Nix

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
(kitty-load 'kitty-meow)
(kitty-load 'kitty-mc)
(kitty-load 'kitty-ex)
(kitty-load 'kitty-completion)
(kitty-load 'kitty-vc)
(kitty-load 'kitty-dired)
(kitty-load 'kitty-org)
(kitty-load 'kitty-markdown)
(kitty-load 'kitty-prog)
(dolist (lang '(kitty-c kitty-csharp kitty-sql kitty-sqldiff kitty-verilog kitty-nix))
  (kitty-load lang))

;; Machine-specific settings (git-ignored): fonts, org directory, work SQL
;; connections ...
(let ((local (expand-file-name "local.el" kitty-config-dir)))
  (when (file-exists-p local) (load local nil 'nomessage)))

;;; init.el ends here
