;;; kitty-dired.el --- dired, with dirvish on top  -*- lexical-binding: t; -*-

;;; Commentary:

;; dired is the file manager; dirvish makes it look and feel modern (icons,
;; file preview, a sidebar, quick-access directories) without replacing it,
;; so every dired command still works.  The keys are oil's, as my-nvim has
;; them (see Keys below); SPC is the leader.

;;; Code:

(require 'kitty-lib)

;; Without GNU ls (native Windows) Emacs lists directories itself, which
;; understands fewer switches.
(when (kitty-windows-p)
  (setq ls-lisp-use-insert-directory-program nil
        ls-lisp-dirs-first t
        ls-lisp-ignore-case t))

(setq dired-listing-switches (if (kitty-windows-p) "-alh" "-alhv --group-directories-first")
      dired-dwim-target t
      dired-kill-when-opening-new-dired-buffer t
      dired-recursive-copies 'always
      dired-recursive-deletes 'top
      dired-create-destination-dirs 'ask
      dired-auto-revert-buffer #'dired-directory-changed-p
      dired-free-space nil
      dired-mouse-drag-files t
      delete-by-moving-to-trash nil)

(kitty-add-hook 'dired-mode-hook #'dired-hide-details-mode)
(kitty-add-hook 'dired-mode-hook (lambda () (when (fboundp 'diredfl-mode) (diredfl-mode 1))))

;;;; dirvish

(setq dirvish-attributes '(nerd-icons file-size git-msg)
      dirvish-mode-line-format '(:left (sort symlink) :right (omit yank index))
      dirvish-header-line-format '(:left (path) :right (free-space))
      dirvish-default-layout '(0 0.4 0.6)       ; no parent column, big preview
      dirvish-preview-dispatchers '(image gif video audio epub pdf archive)
      dirvish-use-header-line t
      dirvish-reuse-session t
      dirvish-side-width 36
      dirvish-quick-access-entries
      '(("h" "~/" "Home")
        ("p" "~/Projects/" "Projects")
        ("n" "~/nixos-config/" "nixos-config")
        ("c" "~/.config/" "Config")))

(add-hook 'emacs-startup-hook
          (lambda () (when (require 'dirvish nil t) (dirvish-override-dired-mode 1))))

;;;; Keys: oil's, as my-nvim has them (config/core/files.lua)
;;
;; -  up a directory       RET  open          C-p  preview      g.  hide dotfiles
;; gd details              ga   quick access  q    close
;; Like oil, the listing is edited as text: i a A I c C start editing names
;; (wdired), dd marks a file for deletion, and :w applies it all.

(declare-function evil-define-key* "evil-core")
(declare-function wdired-change-to-wdired-mode "wdired")
(declare-function wdired-finish-edit "wdired")
(defvar dired-mode-map)
(defvar dired-omit-files)

(defun kitty-dired-toggle-hidden ()
  "Hide or show dotfiles (oil's g.)."
  (interactive)
  (require 'dired-x)
  (setq-local dired-omit-files "\\`[.][^.]")
  (dired-omit-mode 'toggle))

(defun kitty-dired-toggle-details ()
  "Show or hide sizes, dates and permissions (oil's gd)."
  (interactive)
  (dired-hide-details-mode 'toggle))

(defun kitty-dired-preview ()
  "Show the file under the cursor beside the listing (oil's C-p)."
  (interactive)
  (if (fboundp 'dirvish-layout-toggle)
      (dirvish-layout-toggle)
    (dired-display-file)))

(defun kitty-dired-quick-access ()
  "Jump to home, projects, nixos-config or ~/.config (oil's ga in my-nvim)."
  (interactive)
  (if (fboundp 'dirvish-quick-access)
      (dirvish-quick-access)
    (dired (read-directory-name "Go to: " "~/"))))

(defun kitty-dired-quit ()
  "Close the listing (oil's q)."
  (interactive)
  (if (fboundp 'dirvish-quit) (dirvish-quit) (quit-window)))

(defmacro kitty--dired-editing (name command)
  "Define NAME: start editing the listing as text (wdired), then run COMMAND."
  `(defun ,name ()
     ,(format "Edit file names as text (oil), starting with `%s'." command)
     (interactive)
     (wdired-change-to-wdired-mode)
     (call-interactively #',command)))

(kitty--dired-editing kitty-dired-insert evil-insert)
(kitty--dired-editing kitty-dired-append evil-append)
(kitty--dired-editing kitty-dired-insert-line evil-insert-line)
(kitty--dired-editing kitty-dired-append-line evil-append-line)
(kitty--dired-editing kitty-dired-change evil-change)
(kitty--dired-editing kitty-dired-change-line evil-change-line)

(defun kitty--dired-write (orig &rest args)
  "`:w' in a listing applies it, as in oil: renames, then the deletions marked with dd."
  (cond ((derived-mode-p 'wdired-mode) (wdired-finish-edit))
        ((derived-mode-p 'dired-mode) (dired-do-flagged-delete))
        (t (apply orig args))))

(defun kitty--dired-keys ()
  "oil's keys in dired's normal state."
  (when (fboundp 'evil-define-key*)
    ;; evil-collection binds d; oil's dd needs d as a prefix.
    (evil-define-key* 'normal dired-mode-map (kbd "d") nil)
    (evil-define-key* 'normal dired-mode-map
      (kbd "-") #'dired-up-directory
      (kbd "RET") #'dired-find-file
      (kbd "C-p") #'kitty-dired-preview
      (kbd "g.") #'kitty-dired-toggle-hidden
      (kbd "gd") #'kitty-dired-toggle-details
      (kbd "ga") #'kitty-dired-quick-access
      (kbd "q") #'kitty-dired-quit
      (kbd "TAB") #'dirvish-subtree-toggle
      (kbd "i") #'kitty-dired-insert
      (kbd "a") #'kitty-dired-append
      (kbd "I") #'kitty-dired-insert-line
      (kbd "A") #'kitty-dired-append-line
      (kbd "c") #'kitty-dired-change
      (kbd "C") #'kitty-dired-change-line
      (kbd "dd") #'dired-flag-file-deletion)
    (advice-add 'evil-write :around #'kitty--dired-write)))

;; Once dired and evil are both loaded, and again after evil-collection sets up
;; dired (it loads later, after the first frame), so these keys win.
(with-eval-after-load 'dired
  (with-eval-after-load 'evil (kitty--dired-keys)))
(add-hook 'evil-collection-setup-hook
          (lambda (mode _maps) (when (eq mode 'dired) (kitty--dired-keys))))

(provide 'kitty-dired)
;;; kitty-dired.el ends here
