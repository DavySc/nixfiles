;;; kitty-prog.el --- tree-sitter, language servers, formatting  -*- lexical-binding: t; -*-

;;; Commentary:

;; The common ground for code: tree-sitter modes (grammars come from Nix),
;; eglot as the LSP client with emacs-lsp-booster in front of it, flymake for
;; diagnostics (shown at the end of the line, like an inline error lens),
;; apheleia for formatting on save without blocking the editor.

;;; Code:

(require 'kitty-lib)

;;;; Tree-sitter

;; Under Nix the grammars are provided; elsewhere treesit-auto offers to build
;; the one a file needs (it needs a C compiler), and until then the classic
;; mode is used.
(setq treesit-font-lock-level 4
      treesit-auto-install (if (kitty-nix-p) nil 'prompt))

(add-hook 'emacs-startup-hook
          (lambda ()
            (when (require 'treesit-auto nil t)
              (treesit-auto-add-to-auto-mode-alist 'all)
              (global-treesit-auto-mode 1))))

;;;; Projects

(setq project-vc-extra-root-markers
      '(".project" "flake.nix" "CMakeLists.txt" "Cargo.toml" "*.sln" "*.csproj" "Makefile")
      project-switch-commands #'project-find-file)

;;;; eglot

(setq eglot-autoshutdown t
      eglot-sync-connect nil              ; never freeze waiting for a server
      eglot-extend-to-xref t
      eglot-events-buffer-config '(:size 0 :format full)
      eglot-report-progress nil
      eglot-send-changes-idle-time 0.4
      eglot-code-action-indications '(eldoc-hint)
      jsonrpc-default-request-timeout 20
      eldoc-idle-delay 0.25
      eldoc-echo-area-use-multiline-p nil
      eldoc-echo-area-display-truncation-message nil)

(defvar kitty-clangd-args
  '("clangd" "--background-index" "--clang-tidy" "--header-insertion=never"
    "--completion-style=detailed" "--function-arg-placeholders=false"
    "--pch-storage=memory" "-j=4")
  "The command line clangd is started with.")

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `((c-mode c-ts-mode c++-mode c++-ts-mode) . ,kitty-clangd-args))
  (add-to-list 'eglot-server-programs
               '((csharp-mode csharp-ts-mode) . ("csharp-ls")))
  (add-to-list 'eglot-server-programs
               '(sql-mode . ("sqls")))
  (add-to-list 'eglot-server-programs
               '((verilog-mode verilog-ts-mode) . ("verible-verilog-ls")))
  (add-to-list 'eglot-server-programs
               '((nix-mode nix-ts-mode) . ("nil")))
  ;; Candidates that change as you type must be re-fetched, not filtered.
  (when (fboundp 'cape-wrap-buster)
    (advice-add 'eglot-completion-at-point :around #'cape-wrap-buster))
  ;; JSON parsing in a Rust process: the biggest single latency win for LSP.
  (when (and (executable-find "emacs-lsp-booster") (require 'eglot-booster nil t))
    (eglot-booster-mode 1)))

(defun kitty-eglot-ensure-for (program)
  "Start eglot in this buffer when PROGRAM, its language server, is installed."
  (when (and (executable-find program) (not (file-remote-p default-directory)))
    (eglot-ensure)))

;;;; flymake: diagnostics at the end of the line

(setq flymake-no-changes-timeout 0.6
      flymake-show-diagnostics-at-end-of-line 'short
      flymake-indicator-type 'margins
      flymake-margin-indicators-string
      '((error "●" compilation-error) (warning "●" compilation-warning)
        (note "●" compilation-info)))
(kitty-add-hook 'prog-mode-hook #'flymake-mode)
(define-key mode-specific-map (kbd "e") '("next error" . flymake-goto-next-error))

;;;; Formatting

(defvar kitty-no-format-on-save-modes '(markdown-mode gfm-mode org-mode)
  "Modes that are only formatted on request.")

(defun kitty--apheleia-on ()
  (unless (derived-mode-p kitty-no-format-on-save-modes)
    (apheleia-mode 1)))
(kitty-add-hook 'prog-mode-hook #'kitty--apheleia-on)

(with-eval-after-load 'apheleia
  (setf (alist-get 'pgformatter apheleia-formatters) '("pg_format" "-"))
  (setf (alist-get 'verible-format apheleia-formatters) '("verible-verilog-format" "-"))
  (setf (alist-get 'sql-mode apheleia-mode-alist) 'pgformatter)
  (setf (alist-get 'verilog-mode apheleia-mode-alist) 'verible-format))

(defun kitty-format ()
  "Format the buffer: with its formatter if it has one, else through the language server."
  (interactive)
  (cond
   ((and (fboundp 'apheleia--get-formatters)
         (ignore-errors (apheleia--get-formatters)))
    (apheleia-format-buffer (apheleia--get-formatters) (lambda () (message "formatted"))))
   ((and (fboundp 'eglot-managed-p) (eglot-managed-p)) (eglot-format-buffer))
   (t (indent-region (point-min) (point-max)))))

;;;; Comments and structure

(global-set-key (kbd "M-;") #'comment-dwim)
(define-key mode-specific-map (kbd "j")
  (kitty-prefix "jump"
    "j" '("char" . avy-goto-char-timer)
    "w" '("word" . avy-goto-word-1)
    "l" '("line" . avy-goto-line)))

(kitty-add-hook 'emacs-lisp-mode-hook (lambda () (when (fboundp 'puni-mode) (puni-mode 1))))

(provide 'kitty-prog)
;;; kitty-prog.el ends here
