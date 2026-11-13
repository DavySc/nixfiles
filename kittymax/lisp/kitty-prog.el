;;; kitty-prog.el --- tree-sitter, language servers, formatting  -*- lexical-binding: t; -*-

;;; Commentary:

;; The common ground for code: tree-sitter modes (grammars come from Nix),
;; eglot as the LSP client with emacs-lsp-booster in front of it, flymake for
;; diagnostics (shown at the end of the line, like an inline error lens),
;; apheleia for formatting on save without blocking the editor.

;;; Code:

(require 'kitty-lib)

;;;; Tree-sitter

;; Under Nix the grammars are provided.  Elsewhere Emacs offers to build the
;; one a file needs, and until then the classic mode is used.  Building needs
;; a C compiler: Emacs looks for cc, gcc or c99, which native Windows has
;; none of; there kittymax builds with clang (LLVM, from windows/install.ps1)
;; in the MSVC environment, without the -fPIC clang refuses for Windows.
;; With no compiler at all nothing is offered (no prompt that can only fail).

(defun kitty-treesit-compiler ()
  "The C compiler grammars are built with, or nil when there is none."
  (seq-find #'executable-find '("cc" "gcc" "c99" "clang")))

(setq treesit-font-lock-level 4
      treesit-auto-install (cond ((kitty-nix-p) nil)
                                 ((kitty-treesit-compiler) 'prompt))
      treesit-auto-install-grammar (if (and (not (kitty-nix-p)) (kitty-treesit-compiler)) 'ask 'never))

(defun kitty-treesit-compile-args (program args)
  "(PROGRAM . ARGS) as kittymax runs them to build a grammar.
cc and c++ become clang and clang++ when only those exist; on Windows
clang refuses -fPIC (every DLL is position-independent there), so it goes."
  (let ((program (if (and (member program '("cc" "c++")) (not (executable-find program)))
                     (let ((clang (if (equal program "cc") "clang" "clang++")))
                       (if (executable-find clang) clang program))
                   program)))
    (cons program
          (if (and (eq system-type 'windows-nt) (member (file-name-base program) '("clang" "clang++")))
              (remove "-fPIC" args)
            args))))

(defun kitty--treesit-call-process (orig program infile destination display &rest args)
  (let ((pa (kitty-treesit-compile-args program args)))
    (apply orig (car pa) infile destination display (cdr pa))))
(advice-add 'treesit--call-process-signal :around #'kitty--treesit-call-process)

;; Built grammars go to the data directory, not into this checkout.
(defvar kitty-treesit-dir (expand-file-name "tree-sitter/" kitty-data-dir)
  "Where grammars built here are kept (and loaded from).")
(unless (kitty-nix-p)
  (add-to-list 'treesit-extra-load-path kitty-treesit-dir))

(defun kitty--treesit-out-dir (args)
  "ARGS of `treesit-install-language-grammar', the directory defaulted to ours."
  (if (or (kitty-nix-p) (nth 1 args)) args (list (car args) kitty-treesit-dir)))
(advice-add 'treesit-install-language-grammar :filter-args #'kitty--treesit-out-dir)

(declare-function kitty-msvc-ensure-env "kitty-msvc")
(defun kitty--treesit-msvc-env (&rest _)
  "clang links a grammar DLL with MSVC's linker and libraries."
  (when (and (eq system-type 'windows-nt) (fboundp 'kitty-msvc-ensure-env))
    (kitty-msvc-ensure-env)))
(advice-add 'treesit-install-language-grammar :before #'kitty--treesit-msvc-env)

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
      ;; drawn by kittymax instead: see below
      flymake-show-diagnostics-at-end-of-line nil
      flymake-indicator-type 'margins
      flymake-margin-indicators-string
      '((error "●" compilation-error) (warning "●" compilation-warning)
        (note "●" compilation-info)))
(kitty-add-hook 'prog-mode-hook #'flymake-mode)
;; Emacs 31's flymake runs a checker only in `trusted-content' files, unless
;; the checker is marked safe; none is, out of the box, so C#, C, SQL and
;; Verilog files would get no diagnostics at all.  These checkers do not run
;; the file's code (eglot relays the language server's findings, sqldiff
;; parses, verilator lints, dbbliss shows a query's error), so they are safe.
;; The Emacs Lisp byte-compiler can run macros: it checks only kittymax itself.
(dolist (backend '(eglot-flymake-backend kitty-sqldiff-flymake kitty-verilog-flymake kitty-dbbliss-flymake))
  (put backend 'flymake-always-safe t))
(unless (eq trusted-content :all)
  (add-to-list 'trusted-content (abbreviate-file-name (file-name-as-directory kitty-config-dir))))

;; Diagnostics at the end of their line, as my-nvim's virtual text.
;;
;; Flymake's own `flymake-show-diagnostics-at-end-of-line' puts the text on
;; each line's newline as a display property, and moving past many of those
;; is slow: with 2000 diagnostics every j / k took 160-390 ms (Emacs 31.1,
;; even with emacs -Q).  The same text as an after-string costs nothing to
;; move past, so kittymax draws it that way, once per flymake report, with
;; nothing to do on each keystroke.

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-oneliner "flymake")

(defvar-local kitty--flymake-eol-overlays nil)

(defun kitty--flymake-category (type)
  (or (get type 'flymake-category) type))

(defun kitty--flymake-severity (diag)
  (or (get (kitty--flymake-category (flymake-diagnostic-type diag)) 'severity) 0))

(defun kitty-flymake-eol-refresh ()
  "Draw this buffer's diagnostics at the ends of their lines (the worst first)."
  (mapc #'delete-overlay kitty--flymake-eol-overlays)
  (setq kitty--flymake-eol-overlays nil)
  (when (bound-and-true-p flymake-mode)
    (let ((by-line (make-hash-table)))
      (save-excursion
        (save-restriction
          (widen)
          (dolist (d (flymake-diagnostics))
            (goto-char (flymake-diagnostic-beg d))
            (push d (gethash (line-end-position) by-line)))))
      (maphash
       (lambda (eol diags)
         (let* ((diags (sort diags (lambda (a b) (> (kitty--flymake-severity a) (kitty--flymake-severity b)))))
                (top (car diags))
                (face (or (get (kitty--flymake-category (flymake-diagnostic-type top)) 'eol-face) 'shadow))
                (text (concat "  "
                              (propertize (flymake-diagnostic-oneliner top t) 'face face)
                              (if (cdr diags)
                                  (propertize (format " and %d more" (1- (length diags))) 'face 'shadow)
                                "")))
                ;; both ends advance: typing at the end of the line keeps it after the text
                (ov (make-overlay eol eol nil t t)))
           (put-text-property 0 1 'cursor t text)
           (overlay-put ov 'after-string text)
           (overlay-put ov 'kitty-flymake-eol t)
           (push ov kitty--flymake-eol-overlays)))
       by-line))))

(defun kitty--flymake-eol-after-report (&rest _)
  (kitty-flymake-eol-refresh))
(advice-add 'flymake--handle-report :after #'kitty--flymake-eol-after-report)
(kitty-add-hook 'flymake-mode-hook #'kitty-flymake-eol-refresh)
(define-key mode-specific-map (kbd "e") '("next error" . flymake-goto-next-error))

;;;; Formatting

(defvar kitty-no-format-on-save-modes '(markdown-mode gfm-mode org-mode)
  "Modes that are only formatted on request.")

(defun kitty--apheleia-on ()
  (unless (or (derived-mode-p kitty-no-format-on-save-modes) (not (fboundp 'apheleia-mode)))
    (apheleia-mode 1)))
(kitty-add-hook 'prog-mode-hook #'kitty--apheleia-on)

(with-eval-after-load 'apheleia
  (setf (alist-get 'pgformatter apheleia-formatters) '("pg_format" "-"))
  (setf (alist-get 'sqlfluff-tsql apheleia-formatters)
        '("sqlfluff" "format" "--dialect" "tsql" "--nocolor" "-"))
  (setf (alist-get 'verible-format apheleia-formatters) '("verible-verilog-format" "-"))
  ;; OCaml: apheleia's ocamlformat (the project's .ocamlformat decides; the default
  ;; profile without one) is used as it is; .mli files and dune files are added.
  (setf (alist-get 'dune-format apheleia-formatters) '("dune" "format-dune-file"))
  (setf (alist-get 'tuareg-interface-mode apheleia-mode-alist) 'ocamlformat)
  (setf (alist-get 'dune-mode apheleia-mode-alist) 'dune-format)
  ;; SQL has no formatter per mode: kitty-sql picks one per buffer, by dialect.
  (setf (alist-get 'sql-mode apheleia-mode-alist nil 'remove) nil)
  (setf (alist-get 'verilog-mode apheleia-mode-alist) 'verible-format))

(defvar kitty-after-format-functions nil
  "Run by `kitty-format' once the buffer is formatted, with the text from before.
Buffer-local entries let a mode check what the formatter did (kitty-sqldiff).")

(defun kitty-format ()
  "Format the buffer: with its formatter if it has one, else through the language server."
  (interactive)
  (let* ((buffer (current-buffer))
         (before (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max))))
         (done (lambda ()
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer
                     (run-hook-with-args 'kitty-after-format-functions before))))))
    (cond
     ((and (fboundp 'apheleia--get-formatters)
           (ignore-errors (apheleia--get-formatters)))
      (apheleia-format-buffer (apheleia--get-formatters)
                              (lambda (&rest _) (message "formatted") (funcall done))))
     ((and (fboundp 'eglot-managed-p) (eglot-managed-p)) (eglot-format-buffer) (funcall done))
     (t (indent-region (point-min) (point-max)) (funcall done)))))

;;;; Comments and structure

(global-set-key (kbd "M-;") #'comment-dwim)
(define-key mode-specific-map (kbd "j")
  (kitty-prefix "jump"
    "j" '("char" . avy-goto-char-timer)
    "w" '("word" . avy-goto-word-1)
    "l" '("line" . avy-goto-line)))

(kitty-add-hook 'emacs-lisp-mode-hook (lambda () (when (fboundp 'puni-mode) (puni-mode 1))))

;; Emacs Lisp: checkdoc's docstring advice runs in Emacs itself, on the whole
;; buffer, each time you stop typing (400 ms on a 2000-function file, input
;; blocked).  The byte-compiler's check runs in a separate process and stays.
(declare-function elisp-flymake-checkdoc "elisp-mode")
(defun kitty--elisp-no-checkdoc ()
  (remove-hook 'flymake-diagnostic-functions #'elisp-flymake-checkdoc t))
(kitty-add-hook 'emacs-lisp-mode-hook #'kitty--elisp-no-checkdoc)

(provide 'kitty-prog)
;;; kitty-prog.el ends here
