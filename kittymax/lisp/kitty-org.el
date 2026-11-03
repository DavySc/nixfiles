;;; kitty-org.el --- org-mode  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org for notes, tasks and literate documents: a readable, modernised
;; display (org-modern), emphasis markers that appear only under the cursor
;; (org-appear), capture templates, an agenda, and babel for the languages
;; this configuration is about (C, SQL, shell, Emacs Lisp).  Notes live in
;; `org-directory' (~/org); set it in local.el to move them.

;;; Code:

(require 'kitty-lib)

(defvar org-directory)

(setq org-directory (expand-file-name "~/org/"))

(defun kitty-org-file (name)
  "Absolute path of NAME inside `org-directory'."
  (expand-file-name name org-directory))

(setq org-startup-indented t
      org-startup-folded 'content
      org-startup-with-inline-images t
      org-image-actual-width '(640)
      org-hide-emphasis-markers t
      org-pretty-entities t
      org-ellipsis " ▾"
      org-fontify-quote-and-verse-blocks t
      org-fontify-whole-heading-line t
      org-auto-align-tags nil
      org-tags-column 0
      org-catch-invisible-edits 'show-and-error
      org-special-ctrl-a/e t
      org-insert-heading-respect-content t
      org-return-follows-link t
      org-use-sub-superscripts '{}
      ;; source blocks
      org-src-fontify-natively t
      org-src-tab-acts-natively t
      org-src-preserve-indentation t
      org-edit-src-content-indentation 0
      org-src-window-setup 'current-window
      org-confirm-babel-evaluate nil
      ;; tasks
      org-todo-keywords '((sequence "TODO(t)" "NEXT(n)" "WAIT(w@)" "|" "DONE(d!)" "CANCELLED(c@)"))
      org-log-done 'time
      org-log-into-drawer t
      org-enforce-todo-dependencies t
      org-use-fast-todo-selection 'expert
      org-refile-use-outline-path 'file
      org-outline-path-complete-in-steps nil
      org-refile-targets '((org-agenda-files :maxlevel . 3))
      ;; agenda
      org-agenda-files (list (kitty-org-file "inbox.org") (kitty-org-file "projects.org")
                             (kitty-org-file "journal.org"))
      org-agenda-window-setup 'current-window
      org-agenda-start-with-log-mode t
      org-agenda-skip-deadline-if-done t
      org-agenda-skip-scheduled-if-done t
      org-agenda-tags-column 0
      org-agenda-block-separator ?─
      org-deadline-warning-days 5)

(setq org-capture-templates
      `(("t" "Task" entry (file ,(kitty-org-file "inbox.org"))
         "* TODO %?\n  %i\n  %a")
        ("n" "Note" entry (file ,(kitty-org-file "inbox.org"))
         "* %?\n  %U\n  %i")
        ("j" "Journal" entry (file+olp+datetree ,(kitty-org-file "journal.org"))
         "* %<%H:%M> %?\n")))

;;;; Babel

(with-eval-after-load 'org
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((emacs-lisp . t) (shell . t) (C . t) (sql . t) (python . t) (dot . t)))
  (add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))
  (add-to-list 'org-structure-template-alist '("sh" . "src shell"))
  (add-to-list 'org-structure-template-alist '("sql" . "src sql"))
  (add-to-list 'org-structure-template-alist '("c" . "src C"))
  (add-to-list 'org-structure-template-alist '("v" . "src verilog")))

;;;; Looks

(setq org-modern-star 'replace
      org-modern-hide-stars " "
      org-modern-table nil                 ; valign draws tables better in proportional text
      org-modern-list '((?- . "•") (?+ . "‣") (?* . "◦"))
      org-modern-block-name t
      org-modern-keyword t)

(defun kitty--org-setup ()
  (visual-line-mode 1)
  (when (display-graphic-p)
    (when (fboundp 'mixed-pitch-mode) (mixed-pitch-mode 1))
    (when (fboundp 'valign-mode) (valign-mode 1)))
  (when (fboundp 'org-modern-mode) (org-modern-mode 1))
  (when (fboundp 'org-appear-mode) (org-appear-mode 1))
  (when (fboundp 'toc-org-mode) (toc-org-mode 1))
  (setq-local line-spacing 0.2)
  (electric-indent-local-mode -1))        ; org indents itself
(kitty-add-hook 'org-mode-hook #'kitty--org-setup)

(setq org-appear-autoemphasis t
      org-appear-autolinks t
      org-appear-autosubmarkers t
      org-appear-autoentities t)

(with-eval-after-load 'org-agenda
  (add-hook 'org-agenda-finalize-hook #'org-modern-agenda))

;;;; Commands referred to from the SPC tree

(defun kitty-org-find-file ()
  "Find a note under `org-directory'."
  (interactive)
  (make-directory org-directory t)
  (consult-fd org-directory))

(defun kitty-org-search ()
  "Search all notes."
  (interactive)
  (consult-ripgrep org-directory))

(defun kitty-org-todo-list ()
  "All TODO items from the agenda files."
  (interactive)
  (org-todo-list))

(defun kitty-org-journal ()
  "Open today's journal entry (a datetree in journal.org)."
  (interactive)
  (org-capture nil "j"))

;;;; SPC m in org buffers

(kitty-local-leader 'org-mode
  "t" '("todo" . org-todo)
  "s" '("schedule" . org-schedule)
  "d" '("deadline" . org-deadline)
  "p" '("priority" . org-priority)
  "T" '("tags" . org-set-tags-command)
  "r" '("refile" . org-refile)
  "A" '("archive" . org-archive-subtree)
  "e" '("export" . org-export-dispatch)
  "l" '("link" . org-insert-link)
  "L" '("store link" . org-store-link)
  "." '("timestamp" . org-timestamp)
  "x" '("checkbox" . org-toggle-checkbox)
  "h" '("heading" . org-insert-heading-respect-content)
  "H" '("todo heading" . org-insert-todo-heading)
  "i" '("clock in" . org-clock-in)
  "o" '("clock out" . org-clock-out)
  "b" '("babel tangle" . org-babel-tangle)
  "B" '("babel execute" . org-babel-execute-src-block)
  "n" '("narrow subtree" . org-narrow-to-subtree)
  "N" '("widen" . widen)
  "'" '("edit special" . org-edit-special)
  "c" '("column view" . org-columns)
  "v" '("show images" . org-toggle-inline-images)
  "u" '("up heading" . outline-up-heading))

(provide 'kitty-org)
;;; kitty-org.el ends here
