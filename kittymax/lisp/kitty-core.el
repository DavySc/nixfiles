;;; kitty-core.el --- defaults and performance  -*- lexical-binding: t; -*-

;;; Commentary:

;; Sane defaults, the performance settings, and keeping state out of the
;; checkout.  Nothing here loads a package eagerly except the few that must
;; configure paths first.

;;; Code:

(require 'kitty-lib)

(defvar kitty-data-dir)
(defvar kitty-cache-dir)

;;;; State directories (no-littering sends everything to var/ and etc/)

(setq no-littering-etc-directory (expand-file-name "etc/" kitty-data-dir)
      no-littering-var-directory (expand-file-name "var/" kitty-data-dir))
(require 'no-littering nil t)
(setq custom-file (expand-file-name "custom.el" kitty-data-dir))
(when (file-exists-p custom-file) (load custom-file nil 'nomessage))
(when (fboundp 'no-littering-theme-backups) (no-littering-theme-backups))

;;;; Text encoding: UTF-8 everywhere (Windows defaults to a legacy code page)

(set-language-environment "UTF-8")
(prefer-coding-system 'utf-8)
(set-default-coding-systems 'utf-8)

;;;; Performance

;; Garbage collection: huge while Emacs is busy starting, then gcmh keeps it
;; high while editing and collects when idle.
(setq gcmh-idle-delay 'auto
      gcmh-auto-idle-delay-factor 10
      gcmh-high-cons-threshold (* 128 1024 1024)
      gcmh-low-cons-threshold (* 16 1024 1024))
(add-hook 'emacs-startup-hook
          (lambda ()
            (if (require 'gcmh nil t)
                (gcmh-mode 1)
              (setq gc-cons-threshold (* 64 1024 1024)
                    gc-cons-percentage 0.1))))

;; Language servers talk a lot: the default 4k read size is far too small.
;; Adaptive buffering waits after short reads to gather more: added latency
;; for every small reply (completion, hover, a query's rows).
(setq read-process-output-max (* 4 1024 1024)
      process-adaptive-read-buffering nil)

;; Windows: asking the file system for every file's attributes, and the default
;; pipe buffering, are the slow parts of Emacs there (git, LSP, ripgrep).
(when (kitty-windows-p)
  (setq w32-get-true-file-attributes nil
        w32-pipe-read-delay 0
        w32-pipe-buffer-size (* 64 1024)))

;; Rendering: skip work that does not change what is on screen.
(setq-default bidi-paragraph-direction 'left-to-right
              bidi-inhibit-bpa t
              cursor-in-non-selected-windows nil)
(setq redisplay-skip-fontification-on-input t
      fast-but-imprecise-scrolling t
      auto-window-vscroll nil
      scroll-conservatively 101
      scroll-margin 2
      scroll-preserve-screen-position t
      jit-lock-defer-time 0.05
      jit-lock-stealth-time 0.2
      jit-lock-stealth-nice 0.1
      jit-lock-stealth-verbose nil
      inhibit-compacting-font-caches t
      highlight-nonselected-windows nil
      ffap-machine-p-known 'reject
      vc-handled-backends '(Git)        ; the others stat for files on every open
      vc-follow-symlinks t)

;; Long lines are what makes Emacs slow: so-long switches off the expensive
;; modes for them, and the editor stays usable on minified files.
(global-so-long-mode 1)
(setq so-long-threshold 1500)

;; Pasting and large buffers
(setq-default fill-column 80
              indent-tabs-mode nil
              tab-width 4)
(setq sentence-end-double-space nil
      require-final-newline t
      select-enable-clipboard t
      save-interprogram-paste-before-kill t
      kill-do-not-save-duplicates t
      visible-bell nil
      ring-bell-function #'ignore
      confirm-kill-processes nil
      create-lockfiles nil
      make-backup-files t
      auto-save-default t
      delete-by-moving-to-trash nil
      use-short-answers t
      echo-keystrokes 0.02
      help-window-select t
      window-combination-resize t
      enable-recursive-minibuffers t
      read-extended-command-predicate #'command-completion-default-include-p
      text-quoting-style 'curve
      tab-always-indent 'complete
      ;; one place for custom-set and the like
      load-prefer-newer t)

;;;; Built-in conveniences, turned on late so they cost nothing at startup

(defun kitty--late-modes ()
  (save-place-mode 1)
  (recentf-mode 1)
  (savehist-mode 1)
  (global-auto-revert-mode 1)
  (delete-selection-mode 1)
  (electric-pair-mode 1)
  (show-paren-mode 1)
  (column-number-mode 1)
  (global-hl-line-mode 1)
  (repeat-mode 1)
  (pixel-scroll-precision-mode 1))
(add-hook 'emacs-startup-hook #'kitty--late-modes)

(setq recentf-max-saved-items 500
      recentf-auto-cleanup 'never       ; cleanup stats every file: slow on network drives
      savehist-additional-variables '(search-ring regexp-search-ring kill-ring)
      history-length 1000
      auto-revert-verbose nil
      global-auto-revert-non-file-buffers t
      show-paren-delay 0
      show-paren-context-when-offscreen 'overlay
      electric-pair-skip-whitespace nil
      pixel-scroll-precision-use-momentum nil)

;; Line numbers in code, not in prose or tool buffers.
(setq display-line-numbers-type 'relative
      display-line-numbers-width-start t)
(dolist (hook '(prog-mode-hook conf-mode-hook))
  (kitty-add-hook hook #'display-line-numbers-mode))

;; Whitespace: show trailing space in code, strip it on save.
(kitty-add-hook 'prog-mode-hook (lambda () (setq-local show-trailing-whitespace t)))
(add-hook 'before-save-hook #'delete-trailing-whitespace)

;; Compilation output and the like should not need a keyboard shortcut to scroll.
(setq compilation-scroll-output 'first-error
      compilation-ask-about-save nil
      compilation-always-kill t)

(provide 'kitty-core)
;;; kitty-core.el ends here
