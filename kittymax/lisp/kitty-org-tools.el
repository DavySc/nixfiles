;;; kitty-org-tools.el --- org's heavier features: time, habits, export, babel, linked notes  -*- lexical-binding: t; -*-

;;; Commentary:

;; What kitty-org.el leaves out: the parts of org that need more than a
;; buffer.  Everything loads with org (or later), never at startup.
;;
;; Agenda      every .org file under `org-directory', as my-nvim's ~/org/**/*
;; Clocking    SPC o x i / o / q / j (in, out, cancel, go to: nvim-orgmode's)
;;             and e (effort), r (clock table), l (clock in last), d (sums);
;;             a running clock survives restarting Emacs; the agenda's R shows
;;             the clock report
;; Habits      SCHEDULED with .+1d and :STYLE: habit; the agenda draws their
;;             consistency graph (capture template h makes one)
;; Export      SPC o e: HTML (code coloured by htmlize), PDF (LaTeX: tectonic
;;             if it is there, else xelatex from MiKTeX / TeX Live), Word
;;             (.docx: org's own export, then pandoc; ~/org/reference.docx
;;             styles it when it exists)
;; Babel       C and C++ (gcc, else clang), C# (kitty-ob-csharp.el: .NET 10's
;;             file-based apps, cached), SQL (SQL Server through kitty-dbbliss:
;;             #+begin_src sql :dbbliss work), shell, Python, Emacs Lisp, dot
;; LaTeX       SPC m L previews the fragments in the buffer
;; Notes       org-roam: SPC n r find, n i insert a link, n b backlinks,
;;             n c capture, n d t/y/d today's, yesterday's, a date's daily note

;;; Code:

(require 'kitty-lib)
(require 'subr-x)
(require 'seq)

(declare-function kitty-org-file "kitty-org")
(declare-function org-clock-persistence-insinuate "org-clock")
(declare-function org-export-define-derived-backend "ox")
(declare-function org-export-output-file-name "ox")
(declare-function org-export-to-file "ox")
(declare-function org-open-file "org")
(declare-function org-roam-db-autosync-mode "org-roam-db")
(declare-function org-roam-db-sync "org-roam-db")
(defvar org-directory)
(defvar org-agenda-files)
(defvar org-capture-templates)
(defvar org-modules)
(defvar org-preview-latex-process-alist)
(defvar org-preview-latex-default-process)
(defvar org-roam-directory)

;;;; Agenda: every org file under org-directory

(defun kitty-org-agenda-files ()
  "Every .org file under `org-directory' (hidden directories skipped)."
  (when (file-directory-p org-directory)
    (directory-files-recursively
     org-directory "\\.org\\'" nil
     (lambda (dir) (not (string-prefix-p "." (file-name-nondirectory (directory-file-name dir))))))))

(defun kitty--org-refresh-agenda-files (&rest _)
  "Read the agenda's files again: notes come and go."
  (when-let* ((files (kitty-org-agenda-files)))
    (setq org-agenda-files files)))

(dolist (f '(org-agenda org-todo-list org-agenda-list org-refile org-tags-view))
  (advice-add f :before #'kitty--org-refresh-agenda-files))

;;;; Clocking and effort

(setq org-clock-persist t
      org-clock-persist-file (expand-file-name "org-clock-save.el" kitty-data-dir)
      org-clock-in-resume t
      org-clock-persist-query-resume nil
      org-clock-out-remove-zero-time-clocks t
      org-clock-out-when-done t
      org-clock-report-include-clocking-task t
      org-clock-idle-time 15
      org-clock-mode-line-total 'today
      org-clock-history-length 25
      org-columns-default-format
      "%50ITEM(Task) %TODO %3PRIORITY %Effort(Estimate){:} %CLOCKSUM(Clocked){:} %CLOCKSUM_T(Today){:}"
      org-global-properties '(("Effort_ALL" . "0:15 0:30 0:45 1:00 1:30 2:00 3:00 4:00 6:00 8:00"))
      org-agenda-clockreport-parameter-plist
      '(:link t :maxlevel 3 :fileskip0 t :compact t :narrow 60 :formula %))

(with-eval-after-load 'org
  ;; Before the first org buffer's hooks run: the clock left running last
  ;; time is picked up again there.
  (require 'org-clock)
  (org-clock-persistence-insinuate))

;;;; Habits

(setq org-habit-graph-column 50
      org-habit-preceding-days 21
      org-habit-following-days 7
      org-habit-show-habits-only-for-today t)

(with-eval-after-load 'org
  (add-to-list 'org-modules 'org-habit)
  (add-to-list 'org-capture-templates
               `("h" "Habit" entry (file ,(kitty-org-file "habits.org"))
                 "* TODO %?\n  SCHEDULED: %(format-time-string \"<%Y-%m-%d %a .+1d>\")\n  :PROPERTIES:\n  :STYLE: habit\n  :END:\n")
               t))
(with-eval-after-load 'org-agenda (require 'org-habit))

;;;; Export: HTML, PDF, Word

(setq org-html-validation-link nil
      org-export-with-sub-superscripts '{}
      org-latex-compiler "xelatex")          ; Unicode (é, →, ✓) without inputenc

(defun kitty-org-latex-pdf-process ()
  "How LaTeX becomes PDF: tectonic when installed, else org's default."
  (when (executable-find "tectonic")
    '("tectonic -X compile --outdir=%o -Z shell-escape %f")))

(with-eval-after-load 'ox-latex
  (when-let* ((process (kitty-org-latex-pdf-process)))
    (setq org-latex-pdf-process process)))

(defvar kitty-org-docx-reference nil
  "A .docx whose styles Word exports use; nil: ~/org/reference.docx when it exists.")

(defun kitty-org--docx-reference ()
  (let ((f (or kitty-org-docx-reference (kitty-org-file "reference.docx"))))
    (and (file-exists-p f) f)))

(defun kitty-org-pandoc-command (in out)
  "pandoc's arguments turning IN (exported org) into the Word file OUT."
  (append (list in "--from" "org" "--to" "docx" "--output" out)
          (when-let* ((ref (kitty-org--docx-reference))) (list "--reference-doc" ref))))

(defun kitty-org-export-to-docx (&optional async subtreep visible-only body-only ext-plist)
  "Export to Word: org's own export (babel, macros, includes), then pandoc.
Return the .docx file.  ASYNC, SUBTREEP, VISIBLE-ONLY, BODY-ONLY and
EXT-PLIST are the export dispatcher's."
  (interactive)
  (ignore async)
  (require 'ox-org)
  (unless (executable-find "pandoc") (user-error "Word export needs pandoc"))
  (let* ((out (expand-file-name (org-export-output-file-name ".docx" subtreep)))
         (tmp (make-temp-file "kitty-docx" nil ".org"))
         (default-directory (file-name-directory out)))
    (unwind-protect
        (progn
          (org-export-to-file 'kitty-docx tmp nil subtreep visible-only body-only ext-plist)
          (with-temp-buffer
            (unless (zerop (apply #'call-process "pandoc" nil t nil (kitty-org-pandoc-command tmp out)))
              (user-error "pandoc failed: %s" (string-trim (buffer-string))))))
      (delete-file tmp))
    (message "Exported %s" out)
    out))

(with-eval-after-load 'ox
  (require 'ox-org)
  (org-export-define-derived-backend 'kitty-docx 'org
    :menu-entry
    '(?w "Export to Word (.docx)"
         ((?w "As .docx file" kitty-org-export-to-docx)
          (?o "As .docx file and open"
              (lambda (a s v b) (org-open-file (kitty-org-export-to-docx a s v b))))))))

;;;; LaTeX fragments

(setq org-preview-latex-image-directory (expand-file-name "ltximg/" kitty-cache-dir)
      org-format-latex-options '(:foreground default :background default :scale 1.4
                                             :html-foreground "Black" :html-background "Transparent"
                                             :html-scale 1.0 :matchers ("begin" "$1" "$" "$$" "\\(" "\\[")))

(defconst kitty-org-tectonic-preview
  '(tectonic :programs ("tectonic" "magick")
             :description "pdf > png"
             :message "you need tectonic and ImageMagick"
             :image-input-type "pdf" :image-output-type "png"
             :image-size-adjust (1.0 . 1.0)
             :latex-compiler ("tectonic -X compile --outdir=%o %f")
             :image-converter ("magick -density %D %f -trim -antialias -quality 100 %O"))
  "Previews with tectonic (no TeX distribution needed) and ImageMagick.")

(defun kitty-org-preview-process ()
  "The preview process the installed programs support: dvipng (MiKTeX, TeX
Live), else tectonic and ImageMagick."
  (cond ((and (executable-find "latex") (executable-find "dvipng")) 'dvipng)
        ((and (executable-find "latex") (executable-find "dvisvgm")) 'dvisvgm)
        ((and (executable-find "tectonic") (executable-find "magick")) 'tectonic)
        (t 'dvipng)))

(with-eval-after-load 'org
  (add-to-list 'org-preview-latex-process-alist kitty-org-tectonic-preview)
  (setq org-preview-latex-default-process (kitty-org-preview-process)))

;;;; Babel: compilers and SQL Server

(with-eval-after-load 'ob-C
  (setq org-babel-C-compiler (or (seq-find #'executable-find '("gcc" "clang")) "gcc")
        org-babel-C++-compiler (or (seq-find #'executable-find '("g++" "clang++")) "g++")))

;;;; Linked notes: org-roam

(defvar kitty-org-roam-directory nil
  "Where org-roam keeps its notes; nil: roam/ in `org-directory' (set either in local.el).")

(setq org-roam-db-location (expand-file-name "org-roam.db" kitty-data-dir)
      org-roam-dailies-directory "daily/"
      org-roam-completion-everywhere nil
      org-roam-node-display-template "${title:*} ${tags:20}"
      org-roam-capture-templates
      '(("d" "default" plain "%?"
         :target (file+head "%<%Y%m%d%H%M%S>-${slug}.org" "#+title: ${title}\n#+filetags:\n")
         :unnarrowed t)))

(with-eval-after-load 'org-roam
  (setq org-roam-directory (or kitty-org-roam-directory (expand-file-name "roam/" org-directory)))
  (make-directory org-roam-directory t)
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (display-warning 'kittymax "org-roam needs an Emacs built with SQLite (29 or newer)" :warning))
  (org-roam-db-autosync-mode 1))

(defun kitty-org-roam-sync ()
  "Read every note again into org-roam's database."
  (interactive)
  (require 'org-roam)
  (org-roam-db-sync 'force))

(kitty-leader
 "n r" '("find note (roam)" . org-roam-node-find)
 "n i" '("insert link to note" . org-roam-node-insert)
 "n b" '("backlinks" . org-roam-buffer-toggle)
 "n c" '("capture note (roam)" . org-roam-capture)
 "n d" (kitty-prefix "daily"
         "t" '("today" . org-roam-dailies-goto-today)
         "y" '("yesterday" . org-roam-dailies-goto-yesterday)
         "T" '("tomorrow" . org-roam-dailies-goto-tomorrow)
         "d" '("a date" . org-roam-dailies-goto-date)
         "c" '("capture to today" . org-roam-dailies-capture-today))
 "n S" '("sync roam database" . kitty-org-roam-sync)
 ;; nvim-orgmode's clock keys, from anywhere (a clock runs across buffers)
 "o x o" '("clock out" . org-clock-out)
 "o x j" '("go to clock" . org-clock-goto)
 "o x q" '("cancel clock" . org-clock-cancel)
 "o x l" '("clock in last" . org-clock-in-last))

(kitty-mode-leader 'org-mode
  "o x l" '("clock in last" . org-clock-in-last)
  "o x e" '("effort" . org-set-effort)
  "o x r" '("clock table" . org-clock-report)
  "o x d" '("clock sums" . org-clock-display))

(kitty-local-leader 'org-mode
  "E" '("effort" . org-set-effort)
  "L" '("LaTeX previews" . org-latex-preview)
  "W" '("export to Word" . kitty-org-export-to-docx))

(provide 'kitty-org-tools)
;;; kitty-org-tools.el ends here
