;;; kitty-packages.el --- the package list, and installing it without Nix  -*- lexical-binding: t; -*-

;;; Commentary:

;; Under Nix the packages are provided by package.nix (a test keeps that list
;; and this one the same).  Everywhere else, native Windows above all,
;; `kitty-ensure-packages' installs what is missing from ELPA and MELPA on the
;; first start, into the data directory (not into this checkout).  It does
;; nothing under Nix, nor with KITTYMAX_PACKAGES=none.

;;; Code:

(require 'cl-lib)
(require 'kitty-platform)

(defconst kitty-packages
  '(;; core, performance
    no-littering gcmh puni avy vundo undo-fu-session
    ;; Vim keys, as in my-nvim
    evil evil-collection evil-surround evil-mc evil-multiedit iedit evil-args evil-lion
    evil-textobj-tree-sitter expreg
    ;; ui
    catppuccin-theme doom-modeline nerd-icons nerd-icons-completion nerd-icons-corfu
    nerd-icons-dired rainbow-delimiters hl-todo helpful
    ;; completion
    vertico orderless marginalia consult consult-eglot embark embark-consult corfu cape
    wgrep yasnippet yasnippet-snippets
    ;; git
    magit transient diff-hl git-timemachine
    ;; dired
    dirvish diredfl
    ;; org
    org-modern org-appear toc-org ox-gfm org-download
    ;; markdown
    markdown-mode markdown-toc edit-indirect olivetti valign mixed-pitch
    visual-fill-column jinx
    ;; rss
    elfeed elfeed-org
    ;; programming
    treesit-auto apheleia eglot-booster verilog-mode sql-indent sqlformat nix-ts-mode eat dape)
  "Every package the configuration uses (tree-sitter grammars aside).")

(defconst kitty-packages-not-on-windows '(jinx eat eglot-booster)
  "Packages that need a Unix pty, a native module or a binary Windows lacks.")

(defun kitty-wanted-packages (&optional system)
  "`kitty-packages' for SYSTEM (default `system-type')."
  (if (kitty-windows-p system)
      (cl-remove-if (lambda (p) (memq p kitty-packages-not-on-windows)) kitty-packages)
    kitty-packages))

(defun kitty-missing-packages ()
  "Wanted packages that are not installed."
  (require 'package)
  (cl-remove-if #'package-installed-p (kitty-wanted-packages)))

(defun kitty-install-packages (&optional packages)
  "Install PACKAGES (default: the missing ones) from ELPA/MELPA.
A package that fails to install is reported and skipped."
  (interactive)
  (require 'package)
  (let ((todo (or packages (kitty-missing-packages))))
    (when todo
      (message "kittymax: installing %d packages (first start only) ..." (length todo))
      (redisplay t)
      (condition-case err
          (package-refresh-contents)
        (error (display-warning 'kittymax (format "Cannot reach the package archives: %s" (error-message-string err)) :error)))
      (let ((i 0))
        (dolist (p todo)
          (setq i (1+ i))
          (message "kittymax: installing %s (%d/%d)" p i (length todo))
          (redisplay t)
          (condition-case err
              (package-install p)
            (error (display-warning 'kittymax
                                    (format "Installing %s failed: %s" p (error-message-string err))
                                    :error)))))
      (message "kittymax: packages installed"))))

(defun kitty-ensure-packages ()
  "Install what is missing, unless Nix provides the packages (or KITTYMAX_PACKAGES=none)."
  (when (eq (kitty-package-source) 'elpa)
    (when-let* ((missing (kitty-missing-packages)))
      (kitty-install-packages missing))))

(provide 'kitty-packages)
;;; kitty-packages.el ends here
