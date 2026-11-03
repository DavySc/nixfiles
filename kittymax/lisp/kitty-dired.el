;;; kitty-dired.el --- dired, with dirvish on top  -*- lexical-binding: t; -*-

;;; Commentary:

;; dired is the file manager; dirvish makes it look and feel modern (icons,
;; file preview, a sidebar, quick-access directories) without replacing it,
;; so every dired command still works.  Dired buffers start in meow's MOTION
;; state (see kitty-meow.el): the dired keys are the ones you press; SPC
;; still opens the leader tree.

;;; Code:

(require 'kitty-lib)

(setq dired-listing-switches "-alhv --group-directories-first"
      dired-dwim-target t
      dired-kill-when-opening-new-dired-buffer t
      dired-recursive-copies 'always
      dired-recursive-deletes 'top
      dired-create-destination-dirs 'ask
      dired-auto-revert-buffer #'dired-directory-changed-p
      dired-free-space nil
      dired-mouse-drag-files t
      delete-by-moving-to-trash nil)

(add-hook 'dired-mode-hook #'dired-hide-details-mode)
(add-hook 'dired-mode-hook #'diredfl-mode)

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
        ("n" "~/nixfiles/" "nixfiles")
        ("c" "~/.config/" "Config")))

(add-hook 'emacs-startup-hook
          (lambda () (when (require 'dirvish nil t) (dirvish-override-dired-mode 1))))

(with-eval-after-load 'dirvish
  (let ((m dirvish-mode-map))
    (define-key m (kbd "TAB") #'dirvish-subtree-toggle)
    (define-key m (kbd "a") #'dirvish-quick-access)
    (define-key m (kbd "f") #'dirvish-file-info-menu)
    (define-key m (kbd "y") #'dirvish-yank-menu)
    (define-key m (kbd "N") #'dirvish-narrow)
    (define-key m (kbd "^") #'dirvish-history-last)
    (define-key m (kbd "h") #'dired-up-directory)
    (define-key m (kbd "l") #'dired-find-file)
    (define-key m (kbd "?") #'dirvish-dispatch)
    (define-key m (kbd "q") #'dirvish-quit)))

(provide 'kitty-dired)
;;; kitty-dired.el ends here
