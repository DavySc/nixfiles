;;; kitty-perf-test.el --- what every keystroke costs, kept in check  -*- lexical-binding: t; -*-

;; Boots the whole configuration, opens a real file in each language
;; kittymax is for, and types Vim keys into it.  Two things are enforced:
;;
;; - Only reviewed functions run on every keystroke (pre- and
;;   post-command-hook).  A module or package that adds one fails this test
;;   until its cost is measured and it is added to the list below.
;; - Each command, with every hook, stays inside its time budget.  The
;;   budgets are ten or more times what the commands take here, so a slow
;;   machine passes, and a hook that scans the buffer on every key does not.
;;
;; Redisplay is not in these numbers (batch Emacs draws nothing).

(require 'ert)
(require 'cl-lib)

(defvar kitty-perf--root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

(defun kitty-perf--boot ()
  (unless (featurep 'kitty-core)
    (let ((home (make-temp-file "kitty-home" t)))
      (setenv "KITTYMAX_PACKAGES" "none")
      (setenv "XDG_DATA_HOME" (expand-file-name "data" home))
      (setenv "XDG_CACHE_HOME" (expand-file-name "cache" home))
      (setq treesit-auto-install-grammar 'never)
      (setq user-emacs-directory (file-name-as-directory kitty-perf--root))
      (load (expand-file-name "early-init.el" kitty-perf--root) nil t)
      (load (expand-file-name "init.el" kitty-perf--root) nil t)
      (run-hooks 'after-init-hook 'emacs-startup-hook 'window-setup-hook)
      (unless (featurep 'evil) (kitty--evil-setup)))))

(defconst kitty-perf--allowed
  '(;; Vim itself: . repeat, the jump list, normal state's cursor rules
    evil-repeat-pre-hook evil-repeat-post-hook evil-normal-post-command
    evil--jump-hook evil--jump-handle-buffer-crossing
    evil-visual-pre-command evil-visual-post-command
    ;; Emacs: repeat-mode, the current line, eldoc's timer, transient keymaps,
    ;; delete-selection, cc-mode's own bookkeeping
    repeat-post-hook global-hl-line-highlight hl-line-highlight
    eldoc-schedule-timer eldoc-pre-command-refresh-echo-area
    clear-transient-map delete-selection-pre-hook c-post-command
    ;; packages, each a check of a flag or a moved overlay when idle
    which-key--hide-popup corfu--auto-post-command org-appear--post-cmd
    evil-mc-execute-for-all evil-mc-begin-command-save evil-mc-finish-command-save
    jinx--reschedule diff-hl-flydiff-update
    ;; the marker of a buffer-local hook list
    t)
  "Functions reviewed to be cheap enough for every keystroke.")

(defun kitty-perf--lines (fmt n)
  (mapconcat (lambda (i) (format fmt i i i)) (number-sequence 1 n) "\n"))

(defconst kitty-perf--samples
  `(("a.c" . ,(kitty-perf--lines "int f%d(int x) { return x * %d + %d; } /* comment */" 400))
    ("a.cs" . ,(concat "namespace A;\npublic class C {\n" (kitty-perf--lines "    public int M%d(int x) => x * %d + %d;" 400) "\n}\n"))
    ("a.sql" . ,(kitty-perf--lines "select id, name, total_%d from dbo.orders o where o.id = %d and o.x = %d;" 400))
    ("a.org" . ,(kitty-perf--lines "* TODO Heading %d :tag:\n  Some text with *bold* and =code= %d and a [[https://x.org][link %d]]." 200))
    ("a.md" . ,(kitty-perf--lines "## Heading %d\n\nSome text with **bold** and `code` %d, - item %d" 200))
    ("a.el" . ,(kitty-perf--lines "(defun f%d (x) \"Doc.\" (+ x %d %d))" 400))
    ("a.dl" . ,(kitty-perf--lines ".decl r%d(x: number)\nr%d(x) :- r%d(x)." 200))
    ("a.facts" . ,(kitty-perf--lines "%d\t%d\t%d" 400)))
  "A file per language, a few hundred lines each.")

(defun kitty-perf--visit (name text)
  (let ((file (expand-file-name name (make-temp-file "kitty-perf" t))))
    (with-temp-file file (insert text))
    (let ((buf (find-file file)))
      (switch-to-buffer buf)
      (evil-normal-state)
      (when (derived-mode-p 'org-mode) (org-fold-show-all))
      (goto-char (point-min)) (forward-line 100) (ignore-errors (forward-char 3))
      buf)))

(defun kitty-perf--ms (keys n)
  "Mean milliseconds of typing KEYS, N times."
  (garbage-collect)
  (let ((t0 (float-time)))
    (dotimes (_ n) (execute-kbd-macro (kbd keys)))
    (/ (* 1000 (- (float-time) t0)) n)))

(defun kitty-perf--hook-functions ()
  "Functions in this buffer's pre- and post-command-hook, global ones included."
  (delete-dups
   (cl-loop for h in '(pre-command-hook post-command-hook)
            append (append (default-value h) (and (local-variable-p h) (symbol-value h))))))

(ert-deftest kitty-perf-only-reviewed-work-on-every-key ()
  "Nothing runs on every keystroke that has not been reviewed for its cost."
  (kitty-perf--boot)
  (dolist (s kitty-perf--samples)
    (with-current-buffer (kitty-perf--visit (car s) (cdr s))
      (execute-kbd-macro (kbd "j k"))
      (let ((extra (seq-remove (lambda (f) (memq f kitty-perf--allowed)) (kitty-perf--hook-functions))))
        (should (equal (list (car s) nil) (list (car s) extra))))
      (kill-buffer))))

(defconst kitty-perf--budgets
  '(("j k" 200 2.0) ("w b" 200 3.0) ("x u" 50 8.0) ("ciwab <escape> u" 50 25.0) ("A x <escape> u" 50 15.0)
    ("S-v d u" 50 15.0))
  "(KEYS TIMES MILLISECONDS): the most typing KEYS may take, on average.")

(ert-deftest kitty-perf-keystrokes-within-budget ()
  "Vim's motions and edits, with every hook kittymax adds, stay well under a millisecond or so."
  (kitty-perf--boot)
  (let (report)
    (dolist (s kitty-perf--samples)
      (with-current-buffer (kitty-perf--visit (car s) (cdr s))
        (dolist (b kitty-perf--budgets)
          (let ((ms (kitty-perf--ms (nth 0 b) (nth 1 b))))
            (push (format "%-8s %-18s %.3f ms" (car s) (nth 0 b) ms) report)
            (should (equal (list (car s) (nth 0 b) t) (list (car s) (nth 0 b) (< ms (nth 2 b)))))))
        (set-buffer-modified-p nil)
        (kill-buffer)))
    (message "kittymax keystroke costs (command + hooks, no redisplay):\n%s"
             (string-join (nreverse report) "\n"))))

(put 'kitty-perf--report-many 'flymake-always-safe t)
(defun kitty-perf--report-many (report-fn &rest _)
  "A flymake backend: a note on each of the first 2000 lines."
  (funcall report-fn
           (save-excursion
             (goto-char (point-min))
             (cl-loop repeat 2000 until (eobp)
                      collect (prog1 (flymake-make-diagnostic (current-buffer) (point) (line-end-position) :note "a note")
                                (forward-line 1))))))

(ert-deftest kitty-perf-many-diagnostics-do-not-slow-motion ()
  "Diagnostics at line ends are after-strings, not flymake's own display.
Flymake's own end-of-line display (text on the newline) made each j / k
take 160-390 ms with 2000 diagnostics, in a real terminal; batch Emacs has
no display engine, so the guard here is what draws them, and the timing is
only a sanity check."
  (kitty-perf--boot)
  (should-not flymake-show-diagnostics-at-end-of-line)
  (with-current-buffer (kitty-perf--visit "many.c" (kitty-perf--lines "int f%d(int x) { return x * %d + %d; }" 2500))
    (setq-local flymake-diagnostic-functions '(kitty-perf--report-many))
    (flymake-mode 1)
    (flymake-start)
    (should (= 2000 (length (flymake-diagnostics))))
    ;; drawn at the line ends, as after-strings
    (should (= 2000 (length kitty--flymake-eol-overlays)))
    (should (string-match-p "a note" (overlay-get (car kitty--flymake-eol-overlays) 'after-string)))
    (goto-char (point-min)) (forward-line 1000)
    (let ((ms (kitty-perf--ms "k j" 100)))
      (message "j k past 2000 diagnostics: %.3f ms" ms)
      (should (< ms 3.0)))
    (set-buffer-modified-p nil)
    (kill-buffer)))

(ert-deftest kitty-perf-no-synchronous-lint-in-lisp ()
  "checkdoc (whole buffer, in Emacs, after every pause) is off in Emacs Lisp."
  (kitty-perf--boot)
  (with-current-buffer (kitty-perf--visit "x.el" "(defun f (x) \"Doc.\" x)\n")
    (should-not (memq 'elisp-flymake-checkdoc flymake-diagnostic-functions))
    (kill-buffer)))

(ert-deftest kitty-perf-checkers-run-in-your-files ()
  "Emacs 31's flymake runs only safe checkers outside `trusted-content': kittymax's are."
  (kitty-perf--boot)
  (dolist (b '(eglot-flymake-backend kitty-sqldiff-flymake kitty-verilog-flymake kitty-dbbliss-flymake))
    (should (function-get b 'flymake-always-safe)))
  ;; a real run, in a file nobody marked as trusted
  (let ((trusted-content nil))
    (with-current-buffer (kitty-perf--visit "q.sql" "select 1;\nselect boom;\n")
      (setq-local flymake-diagnostic-functions '(kitty-dbbliss-flymake))
      (setq kitty-dbbliss--errors '((2 . "Invalid column name 'boom'.")))
      (flymake-mode 1)
      (flymake-start)
      (should (equal '("dbbliss: Invalid column name 'boom'.")
                     (mapcar #'flymake-diagnostic-text (flymake-diagnostics))))
      (set-buffer-modified-p nil)
      (kill-buffer)))
  ;; kittymax's own Lisp is trusted (the byte-compiler checks it)
  (with-current-buffer (find-file-noselect (expand-file-name "lisp/kitty-lib.el" kitty-perf--root))
    (should (trusted-content-p))
    (kill-buffer)))

(ert-deftest kitty-perf-settings-that-keep-it-fast ()
  "The settings that keep redisplay and process output cheap stay set."
  (kitty-perf--boot)
  (should redisplay-skip-fontification-on-input)
  (should fast-but-imprecise-scrolling)
  (should (eq 'left-to-right (default-value 'bidi-paragraph-direction)))
  (should (default-value 'bidi-inhibit-bpa))
  (should (>= read-process-output-max (* 1024 1024)))
  (should (null auto-window-vscroll))
  (should (> jit-lock-defer-time 0))
  (when (eq system-type 'windows-nt)
    (should inhibit-compacting-font-caches)
    (should (zerop w32-pipe-read-delay)))
  ;; nothing redraws every buffer's whitespace on every change
  (should-not (bound-and-true-p global-whitespace-mode)))

(provide 'kitty-perf-test)
;;; kitty-perf-test.el ends here
