;;; kitty-csharp.el --- C#  -*- lexical-binding: t; -*-

;;; Commentary:

;; csharp-ts-mode (tree-sitter), csharp-ls as the language server (needs the
;; .NET SDK: the project's dev shell or the one in the kittymax PATH), and the
;; `dotnet' commands from SPC m.  There is no formatter on save: csharp-ls
;; formats through LSP, on request (SPC c f) and when saving.

;;; Code:

(require 'kitty-lib)

(setq csharp-ts-mode-indent-offset 4)

(add-to-list 'auto-mode-alist '("\\.\\(csproj\\|fsproj\\|props\\|targets\\|slnx\\)\\'" . nxml-mode))
(add-to-list 'auto-mode-alist '("\\.cs\\'" . csharp-ts-mode))

(defun kitty--csharp-setup ()
  (kitty-eglot-ensure-for "csharp-ls")
  (setq-local fill-column 120
              tab-width 4
              indent-tabs-mode nil)
  ;; Format through the language server before saving.
  (add-hook 'before-save-hook
            (lambda ()
              (when (and (fboundp 'eglot-managed-p) (eglot-managed-p))
                (ignore-errors (eglot-format-buffer))))
            nil t))
(kitty-add-hook 'csharp-ts-mode-hook #'kitty--csharp-setup)
(kitty-add-hook 'csharp-mode-hook #'kitty--csharp-setup)

;;;; dotnet

(defun kitty-csharp-dotnet (command)
  "Run `dotnet COMMAND' at the project root."
  (let ((default-directory (kitty-project-root)))
    (compile (concat "dotnet " command))))

(defun kitty-csharp-build () "Build." (interactive) (kitty-csharp-dotnet "build"))
(defun kitty-csharp-run () "Run." (interactive) (kitty-csharp-dotnet "run"))
(defun kitty-csharp-test () "Test." (interactive) (kitty-csharp-dotnet "test"))
(defun kitty-csharp-restore () "Restore packages." (interactive) (kitty-csharp-dotnet "restore"))
(defun kitty-csharp-watch ()
  "Run `dotnet watch' in a terminal buffer."
  (interactive)
  (let ((default-directory (kitty-project-root)))
    (compile "dotnet watch run" t)))
(defun kitty-csharp-add-package (name)
  "Add NuGet package NAME to the project."
  (interactive "sNuGet package: ")
  (kitty-csharp-dotnet (concat "add package " (shell-quote-argument name))))

(dolist (mode '(csharp-mode csharp-ts-mode))
  (kitty-local-leader mode
    "m" '("build" . kitty-csharp-build)
    "r" '("run" . kitty-csharp-run)
    "t" '("test" . kitty-csharp-test)
    "w" '("watch" . kitty-csharp-watch)
    "R" '("restore" . kitty-csharp-restore)
    "p" '("add package" . kitty-csharp-add-package)
    "f" '("format" . kitty-format)
    "o" '("organize usings" . eglot-code-action-organize-imports)))

(provide 'kitty-csharp)
;;; kitty-csharp.el ends here
