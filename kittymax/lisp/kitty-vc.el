;;; kitty-vc.el --- magit and the gutter  -*- lexical-binding: t; -*-

;;; Commentary:

;; magit for everything (SPC g g), diff-hl for the fringe markers and hunk
;; commands, git-timemachine to walk a file's history.

;;; Code:

(require 'kitty-lib)

(setq magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1
      magit-bury-buffer-function #'magit-restore-window-configuration
      magit-save-repository-buffers 'dontask
      magit-diff-refine-hunk 'all
      magit-diff-paint-whitespace t
      magit-refresh-status-buffer nil          ; do not refresh status buffers in the background
      magit-section-visibility-indicator '("…" . t)
      magit-revision-show-gravatars nil
      transient-default-level 5
      git-commit-summary-max-length 72
      git-commit-style-convention-checks '(non-empty-second-line overlong-summary-line))

;; Commit messages: spell check and fill like prose.
(add-hook 'git-commit-mode-hook (lambda () (setq-local fill-column 72)))

;;;; diff-hl: changes in the fringe, stage/revert hunks

(setq diff-hl-draw-borders nil
      diff-hl-show-staged-changes nil
      diff-hl-update-async t
      diff-hl-flydiff-delay 0.4)

(defun kitty--diff-hl ()
  (when (require 'diff-hl nil t)
    (global-diff-hl-mode 1)
    (diff-hl-flydiff-mode 1)
    (unless (display-graphic-p) (diff-hl-margin-mode 1))
    (add-hook 'magit-pre-refresh-hook #'diff-hl-magit-pre-refresh)
    (add-hook 'magit-post-refresh-hook #'diff-hl-magit-post-refresh)
    (add-hook 'dired-mode-hook #'diff-hl-dired-mode)))
(add-hook 'emacs-startup-hook #'kitty--diff-hl)

(provide 'kitty-vc)
;;; kitty-vc.el ends here
