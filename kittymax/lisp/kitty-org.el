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

;;;; nvim-orgmode's keys (my-nvim edits org with nvim-orgmode)
;;
;; SPC o a / SPC o c work everywhere (kitty-evil.el).  In org buffers:
;;   cit / ciT  next / previous TODO state     cid  change the date
;;   ciR / cir  priority up / down             C-SPC  toggle the checkbox
;;   << / >>    promote / demote a heading     TAB / S-TAB  fold this / all
;;   } {  next / previous heading   ]] [[  same level   g{  parent heading
;;   C-a  date under the cursor up (on a timestamp)
;;   SPC o ...  the org commands under nvim-orgmode's <leader>o (below)
;;   SPC RET    heading, item or row (org-meta-return)
;; In capture buffers C-c files the entry, SPC o k drops it, SPC o r refiles.

(declare-function evil-define-key* "evil-core")
(declare-function evil-inner-tag "evil-commands")
(declare-function evil-line "evil-commands")
(declare-function kitty-increment "kitty-vim")
(defvar evil-this-operator)
(defvar evil-inhibit-operator)
(defvar org-mode-map)
(defvar org-capture-mode-map)
(defvar org-agenda-mode-map)

(defun kitty-org-refile ()
  "Refile the entry: the capture's, in a capture buffer (nvim-orgmode's <leader>or)."
  (interactive)
  (if (bound-and-true-p org-capture-mode) (org-capture-refile) (org-refile)))

(defun kitty-org-kill ()
  "Drop the capture or note being written (nvim-orgmode's <leader>ok)."
  (interactive)
  (if (bound-and-true-p org-capture-mode) (org-capture-kill) (kill-current-buffer)))

(defun kitty-org-increase (count)
  "C-a: the date under the cursor up, else the number (Vim's C-a)."
  (interactive "p")
  (if (org-at-timestamp-p 'lax) (org-timestamp-up count) (kitty-increment count)))

(defun kitty-org-toggle-pretty ()
  "Show \\alpha as α and x^{2} as x², or the text as typed (my-nvim's <leader>up)."
  (interactive)
  (setq org-pretty-entities (not org-pretty-entities))
  (dolist (b (buffer-list))
    (with-current-buffer b
      (when (derived-mode-p 'org-mode)
        (org-restart-font-lock))))
  (message "Org pretty symbols: %s" (if org-pretty-entities "on" "off")))

(defconst kitty--org-evil-definitions
  '(progn
     ;; c + these objects runs the org command instead of changing text, as
     ;; nvim-orgmode's cit / ciT / cid / ciR / cir; other operators keep Vim's
     ;; meaning (dit still deletes inside a tag).
     (defmacro kitty--org-change-object (name doc command &optional fallback)
       `(evil-define-text-object ,name (count &optional beg end type)
          ,doc
          (if (eq evil-this-operator 'evil-change)
              (progn (setq evil-inhibit-operator t)
                     (call-interactively ,command)
                     (list (point) (point)))
            ,(if fallback
                 `(,fallback count beg end type)
               '(progn (ignore count beg end type) (list (point) (point)))))))
     (kitty--org-change-object kitty-org-cit "cit: the next TODO state." #'org-todo evil-inner-tag)
     (kitty--org-change-object kitty-org-ciT "ciT: the previous TODO state."
                               (lambda () (interactive) (org-todo 'left)))
     (kitty--org-change-object kitty-org-cid "cid: change the date under the cursor." #'org-time-stamp)
     (kitty--org-change-object kitty-org-ciR "ciR: priority up." #'org-priority-up)
     (kitty--org-change-object kitty-org-cir "cir: priority down." #'org-priority-down)
     ;; << and >> on a heading promote / demote it; elsewhere they shift lines.
     (evil-define-operator kitty-org-shift-left (beg end)
       "Vim's <, but << on a heading promotes it (nvim-orgmode)."
       :type line
       (if (and (= 1 (count-lines beg end)) (save-excursion (goto-char beg) (org-at-heading-p)))
           (save-excursion (goto-char beg) (org-do-promote))
         (evil-shift-left beg end)))
     (evil-define-operator kitty-org-shift-right (beg end)
       "Vim's >, but >> on a heading demotes it (nvim-orgmode)."
       :type line
       (if (and (= 1 (count-lines beg end)) (save-excursion (goto-char beg) (org-at-heading-p)))
           (save-excursion (goto-char beg) (org-do-demote))
         (evil-shift-right beg end))))
  "evil macro forms for org buffers, evaluated when evil is there.")

(defun kitty--org-evil-keys ()
  "nvim-orgmode's keys in org buffers, the agenda and capture."
  (eval kitty--org-evil-definitions t)
  (evil-define-key* 'operator org-mode-map
    (kbd "it") 'kitty-org-cit
    (kbd "iT") 'kitty-org-ciT
    (kbd "id") 'kitty-org-cid
    (kbd "iR") 'kitty-org-ciR
    (kbd "ir") 'kitty-org-cir)
  (evil-define-key* '(normal visual) org-mode-map
    (kbd "<") 'kitty-org-shift-left
    (kbd ">") 'kitty-org-shift-right)
  (evil-define-key* 'normal org-mode-map
    (kbd "TAB") #'org-cycle
    (kbd "<backtab>") #'org-shifttab
    (kbd "C-SPC") #'org-toggle-checkbox
    (kbd "}") #'org-next-visible-heading
    (kbd "{") #'org-previous-visible-heading
    (kbd "]]") #'org-forward-heading-same-level
    (kbd "[[") #'org-backward-heading-same-level
    (kbd "g{") #'outline-up-heading
    (kbd "C-a") #'kitty-org-increase)
  (with-eval-after-load 'org-capture
    (evil-define-key* '(normal insert) org-capture-mode-map
      (kbd "C-c") #'org-capture-finalize))
  (with-eval-after-load 'org-agenda
    (evil-set-initial-state 'org-agenda-mode 'motion)
    (evil-define-key* 'motion org-agenda-mode-map
      (kbd "f") #'org-agenda-later
      (kbd "b") #'org-agenda-earlier
      (kbd ".") #'org-agenda-goto-today
      (kbd "vd") #'org-agenda-day-view
      (kbd "vw") #'org-agenda-week-view
      (kbd "vm") #'org-agenda-month-view
      (kbd "vy") #'org-agenda-year-view
      (kbd "q") #'org-agenda-quit
      (kbd "RET") #'org-agenda-switch-to
      (kbd "TAB") #'org-agenda-goto
      (kbd "J") #'org-agenda-goto-date
      (kbd "r") #'org-agenda-redo
      (kbd "t") #'org-agenda-todo
      (kbd "I") #'org-agenda-clock-in
      (kbd "O") #'org-agenda-clock-out
      (kbd "X") #'org-agenda-clock-cancel
      (kbd "R") #'org-agenda-clockreport-mode
      (kbd "+") #'org-agenda-priority-up
      (kbd "-") #'org-agenda-priority-down
      (kbd "/") #'org-agenda-filter
      (kbd "K") #'org-agenda-show-and-scroll-up
      (kbd "g?") #'org-agenda-help)))

(with-eval-after-load 'org
  (when (require 'evil nil t) (kitty--org-evil-keys)))

;; nvim-orgmode's <leader>o... in org buffers (SPC o a / SPC o c stay global).
(kitty-mode-leader 'org-mode
  "o o" '("open at point" . org-open-at-point)
  "o r" '("refile" . kitty-org-refile)
  "o t" '("tags" . org-set-tags-command)
  "o $" '("archive subtree" . org-archive-subtree)
  "o A" '("archive tag" . org-toggle-archive-tag)
  "o e" '("export" . org-export-dispatch)
  "o *" '("toggle heading" . org-toggle-heading)
  "o ," '("priority" . org-priority)
  "o K" '("subtree up" . org-move-subtree-up)
  "o J" '("subtree down" . org-move-subtree-down)
  "o k" '("drop capture / note" . kitty-org-kill)
  "o i h" '("heading after this one" . org-insert-heading-respect-content)
  "o i T" '("todo heading here" . org-insert-todo-heading)
  "o i t" '("todo heading after this one" . org-insert-todo-heading-respect-content)
  "o i d" '("deadline" . org-deadline)
  "o i s" '("schedule" . org-schedule)
  "o i ." '("timestamp" . org-time-stamp)
  "o i !" '("inactive timestamp" . org-time-stamp-inactive)
  "o l i" '("insert link" . org-insert-link)
  "o l s" '("store link" . org-store-link)
  "o x i" '("clock in" . org-clock-in)
  "o x o" '("clock out" . org-clock-out)
  "o x q" '("cancel clock" . org-clock-cancel)
  "o x j" '("go to clock" . org-clock-goto)
  "o n a" '("add note" . org-add-note)
  "RET" '("heading / item / row" . org-meta-return))

(provide 'kitty-org)
;;; kitty-org.el ends here
