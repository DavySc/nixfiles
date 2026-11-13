;;; kitty-org-tools-test.el --- clocking, habits, export, babel, roam  -*- lexical-binding: t; -*-

;; Org's own machinery, driven as you would: clock in and out, make a
;; clock table, see a habit in the agenda, export to HTML and Word, run C#
;; and C blocks.  Parts needing a program (pandoc, dotnet, a C compiler,
;; org-roam) skip without it.
;;   emacs --batch -L lisp -L lisp/lang -l test/kitty-org-tools-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-evil)                   ; the leader tree, as init.el loads it before org
(require 'kitty-org)
(require 'kitty-org-tools)
(require 'org)
(require 'kitty-ob-csharp)

(defun kot--dir (files)
  (let ((dir (file-name-as-directory (make-temp-file "kot" t))))
    (dolist (f files)
      (let ((path (expand-file-name (car f) dir)))
        (make-directory (file-name-directory path) t)
        (with-temp-file path (insert (cdr f)))))
    dir))

;;;; Agenda files

(ert-deftest kitty-org-agenda-reads-every-file-under-org ()
  "my-nvim's ~/org/**/*: nested files count, hidden directories do not."
  (let* ((org-directory (kot--dir '(("inbox.org" . "* TODO a") ("work/projects.org" . "* TODO b")
                                    ("roam/daily/2026-11-12.org" . "* x") (".git/x.org" . "") ("notes.txt" . "")))))
    (should (equal '("inbox.org" "roam/daily/2026-11-12.org" "work/projects.org")
                   (sort (mapcar (lambda (f) (file-relative-name f org-directory)) (kitty-org-agenda-files)) #'string<)))))

;;;; Clocking

(ert-deftest kitty-org-clock-in-out-and-report ()
  "Clock in and out leaves a CLOCK line in the LOGBOOK; a clock table sums it."
  (let ((org-clock-persist nil) (org-clock-idle-time nil))
    (with-temp-buffer
      (org-mode)
      (insert "* TODO Write report\n:PROPERTIES:\n:Effort: 1:00\n:END:\n")
      (goto-char (point-min))
      ;; clocked in 25 minutes ago
      (org-clock-in nil (time-subtract (current-time) (* 25 60)))
      (should (org-clocking-p))
      (org-clock-out)
      (should-not (org-clocking-p))
      (should (string-match-p ":LOGBOOK:\nCLOCK: \\[.*\\]--\\[.*\\] =>  0:25\n:END:" (buffer-string)))
      (goto-char (point-max))
      (insert "\n#+BEGIN: clocktable :scope file :maxlevel 2\n#+END:\n")
      (forward-line -2)
      (org-dblock-update)
      (should (string-match-p "\\*Total time\\*.*0:25" (buffer-string))))))

(ert-deftest kitty-org-effort-choices ()
  "Effort is picked from a fixed list, as columns and the clock report expect."
  (should (string-match-p "0:30 0:45 1:00" (cdr (assoc "Effort_ALL" org-global-properties))))
  (should (string-match-p "%Effort(Estimate)" org-columns-default-format)))

;;;; Habits

(ert-deftest kitty-org-habit-in-the-agenda ()
  "A habit shows in the agenda with its consistency graph."
  (require 'org-agenda)
  (let* ((today (format-time-string "%Y-%m-%d %a"))
         (dir (kot--dir `(("habits.org" . ,(format "* TODO Walk\n  SCHEDULED: <%s .+1d>\n  :PROPERTIES:\n  :STYLE: habit\n  :END:\n" today)))))
         (org-directory dir)
         (org-agenda-files (list (expand-file-name "habits.org" dir)))
         (org-agenda-window-setup 'current-window)
         (org-agenda-sticky nil))
    (should (memq 'org-habit org-modules))
    (org-agenda-list 1)
    (with-current-buffer org-agenda-buffer-name
      (goto-char (point-min))
      (should (search-forward "Walk" nil t))
      (let ((line (buffer-substring (line-beginning-position) (line-end-position))))
        ;; the graph starts at org-habit-graph-column; ! marks today
        (should (>= (length line) org-habit-graph-column))
        (should (string-match-p (regexp-quote (char-to-string org-habit-today-glyph))
                                (substring line org-habit-graph-column)))))
    (kill-buffer org-agenda-buffer-name)))

(ert-deftest kitty-org-habit-capture-template ()
  "Capture template h makes a habit."
  (let ((tmpl (assoc "h" org-capture-templates)))
    (should tmpl)
    (should (string-match-p ":STYLE: habit" (nth 4 tmpl)))
    (should (string-match-p "\\.\\+1d" (nth 4 tmpl)))))

;;;; Export

(ert-deftest kitty-org-export-html ()
  "HTML export works and runs the blocks it should."
  (let* ((dir (kot--dir '(("n.org" . "#+title: Notes\n* Hello\nSome *bold* text.\n#+begin_src emacs-lisp :exports both\n(+ 40 2)\n#+end_src\n"))))
         (file (expand-file-name "n.org" dir)))
    (with-current-buffer (find-file-noselect file)
      (let ((out (org-html-export-to-html)))
        (should (file-exists-p (expand-file-name out dir)))
        (let ((html (with-temp-buffer (insert-file-contents (expand-file-name out dir)) (buffer-string))))
          (should (string-match-p "<b>bold</b>" html))
          (should (string-match-p "<pre class=\"example\">\n42\n</pre>" html))
          ;; code coloured, when htmlize is there
          (when (locate-library "htmlize")
            (should (string-match-p "<span style=\"color: [^\"]+;\">+</span>" html)))))
      (kill-buffer))))

(ert-deftest kitty-org-export-word ()
  "Word export: org's export (babel results included), then pandoc; read back."
  (skip-unless (executable-find "pandoc"))
  (let* ((dir (kot--dir '(("w.org" . "#+title: Report\n* Results\nThe answer is src_emacs-lisp{(* 6 7)}.\n\n| a | b |\n|---+---|\n| 1 | 2 |\n"))))
         (file (expand-file-name "w.org" dir)))
    (with-current-buffer (find-file-noselect file)
      (let ((out (kitty-org-export-to-docx)))
        (should (equal (expand-file-name "w.docx" dir) out))
        (should (file-exists-p out))
        (let ((text (with-temp-buffer (call-process "pandoc" nil t nil out "-t" "plain") (buffer-string))))
          (should (string-match-p "Results" text))
          (should (string-match-p "answer is 42" text))
          (should (string-match-p "1 +2" text))))
      (kill-buffer))))

(ert-deftest kitty-org-word-export-in-the-dispatcher ()
  "C-c C-e (SPC o e) offers Word."
  (require 'ox)
  (should (org-export-get-backend 'kitty-docx))
  (should (eq ?w (car (org-export-backend-menu (org-export-get-backend 'kitty-docx))))))

(ert-deftest kitty-org-pandoc-reference-doc ()
  "A reference.docx in the org directory styles the export."
  (let* ((org-directory (kot--dir '(("reference.docx" . "x")))))
    (should (member "--reference-doc" (kitty-org-pandoc-command "in.org" "out.docx"))))
  (let ((org-directory (kot--dir nil)))
    (should-not (member "--reference-doc" (kitty-org-pandoc-command "in.org" "out.docx")))))

(ert-deftest kitty-org-pdf-uses-tectonic-when-there ()
  "LaTeX to PDF: tectonic when installed; xelatex for Unicode otherwise."
  (should (equal "xelatex" org-latex-compiler))
  (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (equal p "tectonic"))))
    (should (string-match-p "\\`tectonic -X compile" (car (kitty-org-latex-pdf-process)))))
  (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
    (should-not (kitty-org-latex-pdf-process))))

(ert-deftest kitty-org-latex-preview-process ()
  "Previews: dvipng with a TeX distribution, else tectonic with ImageMagick."
  (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (member p '("latex" "dvipng")))))
    (should (eq 'dvipng (kitty-org-preview-process))))
  (cl-letf (((symbol-function 'executable-find) (lambda (p &rest _) (member p '("tectonic" "magick")))))
    (should (eq 'tectonic (kitty-org-preview-process))))
  (should (assq 'tectonic org-preview-latex-process-alist)))

;;;; Babel

(ert-deftest kitty-org-csharp-expand ()
  "Packages first, then usings, variables, the body."
  (should (equal "#:package Humanizer@2.14.1\nusing System.Text;\nvar n = 5;\nvar s = \"a\\\"b\\n\";\nvar xs = new long[] {1, 2};\nConsole.WriteLine(n);\n"
                 (org-babel-expand-body:csharp
                  "Console.WriteLine(n);"
                  '((:package . "Humanizer@2.14.1") (:usings . ("System.Text"))
                    (:var . (n . 5)) (:var . (s . "a\"b\n")) (:var . (xs . (1 2))))))))

(ert-deftest kitty-org-csharp-block-runs ()
  "A C# block runs with dotnet (.NET 10) and its output is the result."
  (skip-unless (and (executable-find "dotnet")
                    (string-match-p "^\\(1[0-9]\\)\\." (shell-command-to-string "dotnet --version"))))
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src csharp :var n=7 :results output\nforeach (var i in Enumerable.Range(1, 2)) Console.WriteLine($\"{i}\\t{i * n}\");\n#+end_src\n")
    (goto-char (point-min))
    (let ((org-confirm-babel-evaluate nil))
      (should (equal "1\t7\n2\t14\n" (org-babel-execute-src-block)))
      ;; as a table
      (should (equal '((1 7) (2 14)) (org-babel-execute-src-block nil nil '((:results . "table"))))))))

(ert-deftest kitty-org-c-block-runs ()
  "A C block compiles and runs (gcc, else clang)."
  (skip-unless (or (executable-find "gcc") (executable-find "clang")))
  (require 'ob-C)
  (with-temp-buffer
    (org-mode)
    (insert "#+begin_src C :includes <stdio.h>\nprintf(\"%d\\n\", 6 * 7);\n#+end_src\n")
    (goto-char (point-min))
    (let ((org-confirm-babel-evaluate nil))
      (should (equal 42 (org-babel-execute-src-block))))))

(ert-deftest kitty-org-babel-languages ()
  "C, C#, SQL, shell, Python, Emacs Lisp and dot are on."
  (dolist (l '(C csharp sql shell python emacs-lisp dot))
    (should (alist-get l org-babel-load-languages)))
  (should (fboundp 'org-babel-execute:csharp))
  (should (fboundp 'org-babel-execute:sql)))

;;;; org-roam

(ert-deftest kitty-org-roam-notes-and-links ()
  "With org-roam: a note, a link to it, its backlink in the database."
  (skip-unless (locate-library "org-roam"))
  (skip-unless (sqlite-available-p))
  (require 'org-roam)
  (let* ((org-directory (kot--dir '(("roam/a.org" . ":PROPERTIES:\n:ID: aaaa-1\n:END:\n#+title: Alpha\n")
                                    ("roam/b.org" . ":PROPERTIES:\n:ID: bbbb-2\n:END:\n#+title: Beta\nSee [[id:aaaa-1][Alpha]].\n"))))
         (kitty-data-dir (kot--dir nil))
         (org-roam-db-location (expand-file-name "org-roam.db" kitty-data-dir)))
    (setq org-roam-directory (expand-file-name "roam/" org-directory))
    (org-roam-db-sync 'force)
    (let ((alpha (org-roam-node-from-id "aaaa-1")))
      (should (equal "Alpha" (org-roam-node-title alpha)))
      (should (equal '("Beta") (mapcar (lambda (b) (org-roam-node-title (org-roam-backlink-source-node b)))
                                       (org-roam-backlinks-get alpha)))))
    (org-roam-db-autosync-mode -1)))

(ert-deftest kitty-org-keys ()
  "Notes under SPC n (roam), nvim-orgmode's clock keys under SPC o x."
  (dolist (probe '(("n r" . org-roam-node-find) ("n i" . org-roam-node-insert) ("n b" . org-roam-buffer-toggle)
                   ("n d t" . org-roam-dailies-goto-today) ("o x o" . org-clock-out) ("o x j" . org-clock-goto)))
    (let ((b (lookup-key kitty-leader-map (kbd (car probe)))))
      (should (eq (cdr probe) (if (consp b) (cdr b) b)))))
  (with-temp-buffer
    (org-mode)
    (let ((map (kitty-leader-keymap)))
      (dolist (probe '(("o x i" . org-clock-in) ("o x e" . org-set-effort) ("o x l" . org-clock-in-last)
                       ("o x r" . org-clock-report) ("o a" . org-agenda)))
        (let ((b (lookup-key map (kbd (car probe)))))
          (should (eq (cdr probe) (if (consp b) (cdr b) b))))))))

(provide 'kitty-org-tools-test)
;;; kitty-org-tools-test.el ends here
