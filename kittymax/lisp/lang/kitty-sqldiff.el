;;; kitty-sqldiff.el --- sqldiff: semantic SQL lint and diff  -*- lexical-binding: t; -*-

;;; Commentary:

;; sqldiff (github.com/DavySc/SQLDiff) understands T-SQL, PostgreSQL and Db2
;; for i.  kittymax uses it three ways, in buffers whose dialect is known (see
;; kitty-sql: never guessed):
;;
;; - a flymake backend: `sqldiff check' as you type (residue from other
;;   dialects, a missing ; before THROW, parse problems);
;; - SPC m D: diff this file with another, often the same object in another
;;   dialect (foo.tsql.sql vs foo.db2i.sql).  The findings go in *sqldiff*,
;;   where RET and M-g n jump to both sides;
;; - after SPC m f (format): `sqldiff diff' of before and after, and a warning
;;   when the formatter changed what the code means.
;;
;; Without the `sqldiff' executable all three are quietly off.

;;; Code:

(require 'kitty-lib)
(require 'kitty-sql)
(require 'compile)
(require 'subr-x)
(require 'seq)

(defvar flymake-diagnostic-functions)
(declare-function flymake-make-diagnostic "flymake")
(declare-function flymake-log "flymake")
(defvar kitty-after-format-functions)

(defvar kitty-sqldiff-program "sqldiff"
  "The sqldiff executable.")

(defun kitty-sqldiff--available-p ()
  (executable-find kitty-sqldiff-program))

;;;; Running sqldiff

(defun kitty-sqldiff--temp-file (dialect)
  "A new temporary file whose name carries DIALECT, as sqldiff's own fixtures do."
  (make-temp-file "kitty-sqldiff-" nil (format ".%s.sql" dialect)))

(defun kitty-sqldiff--write-buffer (file)
  "Write the whole buffer to FILE as UTF-8 with LF line ends.
sqldiff's columns count bytes of what it reads; with UTF-8 and LF they
match the buffer's own lines and bytes."
  (save-restriction
    (widen)
    (let ((coding-system-for-write 'utf-8-unix))
      (write-region (point-min) (point-max) file nil 'silent))))

(defun kitty-sqldiff--parse (buffer)
  "The JSON report in BUFFER as an alist, or nil if there is none."
  (with-current-buffer buffer
    (goto-char (point-min))
    (when (re-search-forward "^{" nil t)
      (goto-char (match-beginning 0))
      (ignore-errors
        (json-parse-buffer :object-type 'alist :array-type 'list
                           :null-object nil :false-object nil)))))

(defun kitty-sqldiff--run (name args callback)
  "Run sqldiff with ARGS; call CALLBACK with the report (or nil) and the error text.
Exit 0 and 1 are results (equal, different); 2 is a usage or I/O error.
Returns the process."
  (let ((out (generate-new-buffer (format " *%s*" name))))
    (make-process
     :name name :noquery t :connection-type 'pipe
     :buffer out
     :stderr (get-buffer-create (format " *%s-stderr*" name))
     :command (cons kitty-sqldiff-program args)
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let* ((code (process-exit-status proc))
                (stderr (get-buffer (format " *%s-stderr*" name)))
                (err (and stderr (with-current-buffer stderr (string-trim (buffer-string)))))
                (report (and (memq code '(0 1)) (kitty-sqldiff--parse out))))
           (unwind-protect
               (funcall callback report (unless report
                                          (if (string-empty-p (or err ""))
                                              (format "sqldiff exited with %s" code)
                                            err)))
             (ignore-errors (kill-buffer out))
             (ignore-errors (kill-buffer stderr)))))))))

;;;; Positions: sqldiff's lines and byte columns -> buffer positions

(defun kitty-sqldiff--position (line col)
  "The position of 1-based LINE and byte column COL in the current buffer."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- (max line 1)))
      (let* ((bol (point))
             (eol (line-end-position))
             (pos (byte-to-position (+ (position-bytes bol) (max 0 (1- (or col 1)))))))
        (if pos (min (max pos bol) eol) bol)))))

(defun kitty-sqldiff--region (loc)
  "The buffer region (BEG . END) of the sqldiff location LOC."
  (let ((beg (kitty-sqldiff--position (alist-get 'start_line loc) (alist-get 'start_col loc)))
        (end (kitty-sqldiff--position (alist-get 'end_line loc) (alist-get 'end_col loc))))
    (if (> end beg)
        (cons beg end)
      (save-excursion
        (goto-char beg)
        (cons beg (max (1+ beg) (min (line-end-position) (progn (forward-symbol 1) (point)))))))))

(defun kitty-sqldiff--severity-type (severity)
  "A flymake type for the sqldiff SEVERITY string."
  (pcase severity
    ((or "critical" "high") :error)
    ("medium" :warning)
    (_ :note)))

;;;; flymake

(defvar-local kitty--sqldiff-process nil)

(defun kitty-sqldiff-diagnostics (source report)
  "flymake diagnostics in buffer SOURCE for the `sqldiff check' REPORT."
  (with-current-buffer source
    (let (diags)
      (dolist (f (alist-get 'findings report))
        (when-let* ((loc (alist-get 'a f)))
          (let ((region (kitty-sqldiff--region loc)))
            (push (flymake-make-diagnostic
                   source (car region) (cdr region)
                   (kitty-sqldiff--severity-type (alist-get 'severity f))
                   (format "%s [%s]" (alist-get 'witness f) (alist-get 'rule f)))
                  diags))))
      (dolist (d (alist-get 'diagnostics report))
        (let* ((beg (kitty-sqldiff--position (alist-get 'line d) (alist-get 'col d)))
               (end (save-excursion (goto-char beg) (max (1+ beg) (line-end-position)))))
          (push (flymake-make-diagnostic source beg (min end (point-max)) :warning
                                         (format "%s [parse]" (alist-get 'message d)))
                diags)))
      (nreverse diags))))

(defun kitty-sqldiff-flymake (report-fn &rest _args)
  "Flymake backend: `sqldiff check' the buffer.  See `flymake-diagnostic-functions'."
  (let ((dialect (kitty-sql-dialect)))
    (if (not (and dialect (kitty-sqldiff--available-p)))
        (funcall report-fn nil)
      (when (process-live-p kitty--sqldiff-process)
        (kill-process kitty--sqldiff-process))
      (let* ((source (current-buffer))
             (tmp (kitty-sqldiff--temp-file dialect))
             proc)
        ;; Check what is in the buffer, not what is on disk.
        (kitty-sqldiff--write-buffer tmp)
        (setq proc
              (kitty-sqldiff--run
               "sqldiff-flymake"
               (list "check" tmp "-d" (symbol-name dialect) "-f" "json")
               (lambda (report err)
                 (ignore-errors (delete-file tmp))
                 (when (buffer-live-p source)
                   (cond
                    ((not (eq proc (buffer-local-value 'kitty--sqldiff-process source)))
                     (flymake-log :warning "Canceling obsolete check %s" proc))
                    (report (funcall report-fn (kitty-sqldiff-diagnostics source report)))
                    (t (funcall report-fn :panic :explanation err)))))))
        (setq kitty--sqldiff-process proc)))))

;;;; The *sqldiff* buffer

(defvar-local kitty-sqldiff--rerun nil
  "A function that runs this buffer's comparison again.")
(defvar-local kitty-sqldiff--files nil
  "(A . B): the files this buffer compares.")

(defconst kitty-sqldiff--location-regexp
  "^    [AB]  \\(\\(?:[A-Za-z]:\\)?[^:\n]+\\):\\([0-9]+\\):\\([0-9]+\\)  \\(?:\\(critical\\|high\\)\\|\\(medium\\)\\|\\(low\\|info\\)\\)$"
  "A location line in *sqldiff*: side, file:line:col, severity.")

(defvar kitty-sqldiff-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map compilation-mode-map)
    (define-key map (kbd "g") #'kitty-sqldiff-rerun)
    (define-key map (kbd "e") #'kitty-sqldiff-ediff)
    map))

(define-derived-mode kitty-sqldiff-mode compilation-mode "sqldiff"
  "The findings of sqldiff.  RET or M-g n visits a location; g reruns; e opens ediff."
  (setq-local compilation-error-regexp-alist
              (list (list kitty-sqldiff--location-regexp 1 2 3 '(5 . 6))))
  (setq-local compilation-error-screen-columns nil)
  (setq-local truncate-lines nil)
  (setq-local word-wrap t))

(defun kitty-sqldiff--side-line (side info)
  (format "%s: %s (%s %s, %s)\n" side
          (alist-get 'path info) (alist-get 'dialect info)
          (alist-get 'dialect_version info) (alist-get 'object info)))

(defun kitty-sqldiff--fill (text indent)
  (let ((fill-column 100) (fill-prefix indent))
    (with-temp-buffer
      (insert indent text)
      (fill-region (point-min) (point-max))
      (buffer-string))))

(defun kitty-sqldiff-render (report)
  "Insert REPORT, a parsed sqldiff report, into the current buffer."
  (let ((findings (alist-get 'findings report))
        (classes nil))
    (insert (kitty-sqldiff--side-line "A" (alist-get 'a report)))
    (when-let* ((b (alist-get 'b report)))
      (insert (kitty-sqldiff--side-line "B" b)))
    (insert (propertize (format "Verdict: %s\n"
                                (upcase (replace-regexp-in-string
                                         "_" " " (format "%s" (alist-get 'verdict report)))))
                        'face 'bold))
    (dolist (f findings)
      (let ((c (alist-get 'class f)))
        (setf (alist-get c classes nil nil #'equal) (1+ (alist-get c classes 0 nil #'equal)))))
    (insert (format "%d finding%s%s" (length findings) (if (= 1 (length findings)) "" "s")
                    (if classes
                        (concat " (" (mapconcat (lambda (c) (format "%d %s" (cdr c) (car c)))
                                                (nreverse classes) ", ")
                                ")")
                      "")))
    (let ((noise (alist-get 'noise report)))
      (when (and noise (> (+ (alist-get 'cosmetic noise 0) (alist-get 'structural noise 0)) 0))
        (insert (format "; hidden: %d cosmetic, %d structural"
                        (alist-get 'cosmetic noise 0) (alist-get 'structural noise 0)))))
    (insert "\n")
    (let ((n 0))
      (dolist (f findings)
        (setq n (1+ n))
        (let ((severity (alist-get 'severity f)))
          (insert "\n"
                  (propertize (format "[%d] %s · %s · %s   %s" n
                                      (upcase (format "%s" (alist-get 'class f)))
                                      severity (alist-get 'verdict f) (alist-get 'rule f))
                              'face (pcase (kitty-sqldiff--severity-type severity)
                                      (:error 'compilation-error)
                                      (:warning 'compilation-warning)
                                      (_ 'compilation-info)))
                  "\n"
                  (kitty-sqldiff--fill (alist-get 'witness f) "    ")
                  "\n")
          (dolist (side '(a b))
            (when-let* ((loc (alist-get side f)))
              (insert (format "    %s  %s:%d:%d  %s\n" (upcase (symbol-name side))
                              (alist-get 'path loc) (alist-get 'start_line loc)
                              (alist-get 'start_col loc) severity))
              (dolist (line (alist-get 'excerpt loc))
                (insert (propertize (concat "        | " line "\n") 'face 'shadow)))))
          (when-let* ((asm (alist-get 'assumptions f)))
            (insert (propertize (format "    assumes: %s\n" (string-join asm ", "))
                                'face 'shadow))))))
    (when-let* ((d (alist-get 'diagnostics report)))
      (insert "\nParse diagnostics:\n")
      (dolist (x d)
        (insert (format "    %s line %d:%d: %s\n" (upcase (format "%s" (alist-get 'side x)))
                        (alist-get 'line x) (alist-get 'col x) (alist-get 'message x)))))
    (when-let* ((u (alist-get 'unknown_reasons report)))
      (insert "\nNot checked:\n")
      (dolist (r u) (insert (kitty-sqldiff--fill r "    ") "\n")))
    (when-let* ((asm (alist-get 'assumptions report)))
      (insert "\nAssumptions:\n")
      (dolist (a asm)
        (insert (format "    %-32s %s\n" (alist-get 'id a) (alist-get 'text a)))))
    (when-let* ((norm (alist-get 'normalizations report)))
      (insert (propertize (format "\nIgnored: %s\n" (string-join norm ", ")) 'face 'shadow)))))

(defun kitty-sqldiff--show (title report files rerun &optional quiet)
  "Show REPORT in *sqldiff*, headed by TITLE.  FILES is (A . B); RERUN redoes it.
With QUIET, fill the buffer but do not display it.  Returns the buffer."
  (let ((buffer (get-buffer-create "*sqldiff*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (kitty-sqldiff-mode)
        (erase-buffer)
        (insert (propertize title 'face 'font-lock-comment-face) "\n\n")
        (kitty-sqldiff-render report)
        (goto-char (point-min)))
      (setq kitty-sqldiff--files files
            kitty-sqldiff--rerun rerun)
      (setq next-error-last-buffer buffer))
    (unless quiet (display-buffer buffer))
    buffer))

(defun kitty-sqldiff-rerun ()
  "Run this buffer's comparison again."
  (interactive)
  (if kitty-sqldiff--rerun (funcall kitty-sqldiff--rerun) (user-error "Nothing to rerun")))

(defun kitty-sqldiff-ediff ()
  "Open the two files of this comparison in ediff: the textual view."
  (interactive)
  (pcase kitty-sqldiff--files
    (`(,a . ,b) (when (and a b) (ediff-files a b)))
    (_ (user-error "Not a comparison of two files"))))

;;;; Commands

(defun kitty-sqldiff--pair-key (file)
  "sqldiff's pairing key: the name up to the first dot, lower case, without _ and -."
  (replace-regexp-in-string
   "[-_]" "" (car (split-string (downcase (file-name-nondirectory file)) "\\."))))

(defun kitty-sqldiff-siblings (file)
  "Other SQL files next to FILE that sqldiff would pair with it, by name."
  (let ((key (kitty-sqldiff--pair-key file)))
    (seq-filter (lambda (f)
                  (and (not (file-equal-p f file))
                       (equal (kitty-sqldiff--pair-key f) key)))
                (directory-files (file-name-directory (expand-file-name file)) t
                                 "\\.\\(sql\\|pgsql\\|psql\\|tsql\\|db2i\\)\\'"))))

(defun kitty-sqldiff--read-dialect (file known)
  "KNOWN, or the dialect of FILE's name, or ask."
  (or known
      (kitty-sql-dialect-from-file-name file)
      (intern (completing-read (format "Dialect of %s: " (file-name-nondirectory file))
                               (mapcar #'symbol-name kitty-sql-dialects) nil t))))

(defun kitty-sqldiff--require ()
  (unless (kitty-sqldiff--available-p)
    (user-error "sqldiff is not on PATH (build it from github.com/DavySc/SQLDiff)")))

(defun kitty-sqldiff-files (a dialect-a b dialect-b)
  "Compare files A and B (in DIALECT-A and DIALECT-B) with sqldiff; show *sqldiff*."
  (kitty-sqldiff--require)
  (let* ((a (expand-file-name a)) (b (expand-file-name b))
         (rerun (lambda () (kitty-sqldiff-files a dialect-a b dialect-b))))
    (message "sqldiff: comparing...")
    (kitty-sqldiff--run
     "sqldiff" (list "diff" a b "--dialect-a" (symbol-name dialect-a)
                     "--dialect-b" (symbol-name dialect-b) "-f" "json")
     (lambda (report err)
       (if (not report)
           (message "sqldiff: %s" err)
         (kitty-sqldiff--show (format "sqldiff %s (%s) %s (%s)"
                                      (file-name-nondirectory a) dialect-a
                                      (file-name-nondirectory b) dialect-b)
                              report (cons a b) rerun)
         (message "sqldiff: %s" (alist-get 'verdict report)))))))

(defun kitty-sqldiff-diff (other)
  "Compare this file with OTHER: a new version, or the same object in another dialect.
Offers the files next to it that share its name (foo.tsql.sql, foo.db2i.sql)."
  (interactive
   (let* ((file (or buffer-file-name (user-error "Save the buffer first")))
          (sibling (car (kitty-sqldiff-siblings file))))
     (list (read-file-name "Compare with: " (file-name-directory file) sibling t
                           (and sibling (file-name-nondirectory sibling))))))
  (kitty-sqldiff--require)
  (let* ((file (or buffer-file-name (user-error "Save the buffer first")))
         (dialect-a (kitty-sqldiff--read-dialect file (kitty-sql-dialect)))
         (visiting (find-buffer-visiting other))
         (dialect-b (kitty-sqldiff--read-dialect
                     other (and visiting (with-current-buffer visiting (kitty-sql-dialect))))))
    (when (buffer-modified-p) (save-buffer))
    (kitty-sqldiff-files file dialect-a other dialect-b)))

(defun kitty-sqldiff-check ()
  "Show what `sqldiff check' finds in this buffer in *sqldiff*."
  (interactive)
  (kitty-sqldiff--require)
  (let* ((file (or buffer-file-name (user-error "Save the buffer first")))
         (dialect (kitty-sqldiff--read-dialect file (kitty-sql-dialect))))
    (when (buffer-modified-p) (save-buffer))
    (kitty-sqldiff--run
     "sqldiff" (list "check" (expand-file-name file) "-d" (symbol-name dialect) "-f" "json")
     (lambda (report err)
       (if report
           (kitty-sqldiff--show (format "sqldiff check %s (%s)" (file-name-nondirectory file) dialect)
                                report (cons file nil) #'kitty-sqldiff-check)
         (message "sqldiff: %s" err))))))

;;;; Did formatting change the meaning?

(defun kitty-sqldiff-verify-format (before)
  "After `kitty-format': compare BEFORE with the buffer, warn if the meaning changed."
  (let ((dialect (kitty-sql-dialect))
        (after (save-restriction (widen) (buffer-substring-no-properties (point-min) (point-max)))))
    (when (and dialect (kitty-sqldiff--available-p) (not (equal before after)))
      (let ((old (kitty-sqldiff--temp-file dialect))
            (new (kitty-sqldiff--temp-file dialect))
            (name (buffer-name)))
        (let ((coding-system-for-write 'utf-8-unix))
          (with-temp-file old (insert before))
          (with-temp-file new (insert after)))
        (kitty-sqldiff--run
         "sqldiff-format" (list "diff" old new "-d" (symbol-name dialect) "-f" "json")
         (lambda (report err)
           (let ((verdict (alist-get 'verdict report)))
             (if (member verdict '("equal" "equal_under_assumptions"))
                 (progn (message "formatted; sqldiff: same meaning")
                        (ignore-errors (delete-file old))
                        (ignore-errors (delete-file new)))
               ;; Keep the two files: *sqldiff* points into them.
               (if (not report)
                   (message "formatted; sqldiff could not compare: %s" err)
                 (kitty-sqldiff--show (format "Formatting %s: before vs after" name)
                                      report (cons old new) nil 'quiet)
                 (display-warning
                  'kittymax
                  (format "Formatting %s may have changed its meaning (sqldiff: %s): %s  See *sqldiff*."
                          name verdict
                          (or (alist-get 'witness (car (alist-get 'findings report))) ""))
                  :warning))))))))))

;;;; Wiring

(defun kitty--sqldiff-setup ()
  (add-hook 'flymake-diagnostic-functions #'kitty-sqldiff-flymake nil t)
  (add-hook 'kitty-after-format-functions #'kitty-sqldiff-verify-format nil t))
(kitty-add-hook 'sql-mode-hook #'kitty--sqldiff-setup)

(kitty-local-leader 'sql-mode
  "D" '("sqldiff with file" . kitty-sqldiff-diff)
  "k" '("sqldiff check" . kitty-sqldiff-check))

(provide 'kitty-sqldiff)
;;; kitty-sqldiff.el ends here
