;;; kitty-sqldiff-test.el --- tests for SQL dialects and sqldiff  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'flymake)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-sql)
(require 'kitty-sqldiff)

;;;; Helpers

(defconst kitty-test--rethrow
  "CREATE PROCEDURE dbo.Archive @Id int AS
BEGIN
  BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK
    THROW;
  END CATCH
END
"
  "T-SQL with a missing ; before THROW (line 4).")

(defconst kitty-test--check-json
  "{\"tool_version\":\"0.1.0\",\"verdict\":\"unknown\",
\"a\":{\"path\":\"x.tsql.sql\",\"dialect\":\"tsql\",\"dialect_version\":\"2022\",\"object\":\"dbo.Archive\",\"content_hash\":\"0\"},
\"b\":null,
\"findings\":[{\"fingerprint\":\"da9fe33d14d6b428\",\"rule\":\"hazard.terminator-before-throw\",\"class\":\"semantic\",
 \"severity\":\"high\",\"verdict\":\"unknown\",
 \"witness\":\"`ROLLBACK` is not terminated before THROW.\",
 \"a\":{\"side\":\"a\",\"path\":\"x.tsql.sql\",\"start_line\":4,\"start_col\":24,\"end_line\":5,\"end_col\":11,
       \"byte_start\":0,\"byte_end\":0,\"excerpt\":[\"ROLLBACK\",\"    THROW;\"]},
 \"b\":null,\"assumptions\":[]},
 {\"fingerprint\":\"1\",\"rule\":\"residue.x\",\"class\":\"residue\",\"severity\":\"medium\",\"verdict\":\"unknown\",
 \"witness\":\"residue\",\"a\":{\"side\":\"a\",\"path\":\"x\",\"start_line\":1,\"start_col\":1,\"end_line\":1,\"end_col\":7,
 \"byte_start\":0,\"byte_end\":0,\"excerpt\":[]},\"b\":null,\"assumptions\":[]}],
\"noise\":{\"cosmetic\":0,\"structural\":0},\"normalizations\":[],\"assumptions\":[],\"unknown_reasons\":[],
\"diagnostics\":[{\"side\":\"a\",\"line\":2,\"col\":1,\"message\":\"unexpected token\"}]}"
  "A `sqldiff check -f json' report, shaped as the real one.")

(defun kitty-test--fake-sqldiff (body)
  "A directory holding a `sqldiff' that runs shell BODY; its arguments are in $@."
  (let* ((dir (make-temp-file "fakebin" t))
         (exe (expand-file-name "sqldiff" dir)))
    (with-temp-file exe (insert "#!/bin/sh\n" body "\n"))
    (set-file-modes exe #o755)
    dir))

(defmacro kitty-test--with-path (dir &rest body)
  (declare (indent 1))
  `(let ((exec-path (cons ,dir exec-path))
         (process-environment (cons (concat "PATH=" ,dir ":" (getenv "PATH")) process-environment)))
     ,@body))

(defun kitty-test--wait (pred)
  (let ((n 0))
    (while (and (not (funcall pred)) (< n 100))
      (accept-process-output nil 0.05)
      (cl-incf n))))

(defun kitty-test--flymake (text file body)
  "Run the flymake backend on TEXT in a buffer visiting FILE with a fake sqldiff."
  (let ((bin (kitty-test--fake-sqldiff body)) result)
    (kitty-test--with-path bin
      (with-temp-buffer
        (insert text)
        (setq buffer-file-name (expand-file-name file (make-temp-file "sql" t)))
        (set-buffer-modified-p nil)
        (kitty-sqldiff-flymake (lambda (diags &rest _) (setq result (or diags 'none))))
        (kitty-test--wait (lambda () result))
        (when (consp result)
          (setq result (mapcar (lambda (d)
                                 (list (flymake-diagnostic-type d)
                                       (line-number-at-pos (flymake-diagnostic-beg d))
                                       (buffer-substring (flymake-diagnostic-beg d)
                                                         (flymake-diagnostic-end d))
                                       (flymake-diagnostic-text d)))
                               result)))
        (set-buffer-modified-p nil)))
    result))

;;;; Dialects

(ert-deftest kitty-sql-dialect-from-file-names ()
  (should (eq 'tsql (kitty-sql-dialect-from-file-name "/x/movestock.tsql.sql")))
  (should (eq 'postgres (kitty-sql-dialect-from-file-name "movestock.pg.sql")))
  (should (eq 'postgres (kitty-sql-dialect-from-file-name "f.pgsql")))
  (should (eq 'db2i (kitty-sql-dialect-from-file-name "MOVESTOCK.DB2I.SQL")))
  (should (eq 'db2i (kitty-sql-dialect-from-file-name "a.db2.sql")))
  (should-not (kitty-sql-dialect-from-file-name "plain.sql"))
  (should-not (kitty-sql-dialect-from-file-name "noext"))
  (should-not (kitty-sql-dialect-from-file-name nil)))

(ert-deftest kitty-sql-dialect-variable-wins-then-name-then-default ()
  (with-temp-buffer
    (setq buffer-file-name "/tmp/a.tsql.sql")
    (should (eq 'tsql (kitty-sql-dialect)))
    (setq-local kitty-sql-dialect 'db2i)
    (should (eq 'db2i (kitty-sql-dialect)))
    (setq-local kitty-sql-dialect 'nonsense)
    (should (eq 'tsql (kitty-sql-dialect)))
    (setq buffer-file-name "/tmp/a.sql")
    (should-not (kitty-sql-dialect))
    (let ((kitty-sql-default-dialect 'postgres))
      (should (eq 'postgres (kitty-sql-dialect))))
    (set-buffer-modified-p nil)))

(ert-deftest kitty-sql-dialect-is-a-safe-local-variable ()
  (should (safe-local-variable-p 'kitty-sql-dialect 'tsql))
  (should-not (safe-local-variable-p 'kitty-sql-dialect '(eval boom))))

(ert-deftest kitty-sql-formatter-per-dialect ()
  (should (eq 'pgformatter (kitty-sql-formatter 'postgres)))
  (should (eq 'sqlfluff-tsql (kitty-sql-formatter 'tsql)))
  (should-not (kitty-sql-formatter 'db2i))
  (should-not (kitty-sql-formatter nil)))

(ert-deftest kitty-sql-mode-follows-the-dialect ()
  (let ((dir (make-temp-file "sql" t)))
    (dolist (probe '(("a.tsql.sql" ms sqlfluff-tsql "SQL[tsql]")
                     ("a.pg.sql" postgres pgformatter "SQL[postgres]")
                     ("a.db2i.sql" db2 nil "SQL[db2i]")))
      (with-current-buffer (find-file-noselect (expand-file-name (nth 0 probe) dir))
        (sql-mode)
        (kitty-sql-apply-dialect)
        (should (eq (nth 1 probe) sql-product))
        (should (eq (nth 2 probe) apheleia-formatter))
        (should (equal (nth 3 probe) mode-name))
        (kill-buffer)))))

;;;; flymake

(ert-deftest kitty-sqldiff-flymake-maps-findings-and-parse-diagnostics ()
  (let ((diags (kitty-test--flymake
                kitty-test--rethrow "proc.tsql.sql"
                (format "case \"$*\" in *'check '*'-d tsql -f json'*) ;; *) exit 2;; esac
cat <<'JSON'\n%s\nJSON\nexit 1" kitty-test--check-json))))
    (should (= 3 (length diags)))
    ;; line 4, byte column 24: ROLLBACK, up to line 5 column 11
    (should (equal '(:error 4) (seq-take (nth 0 diags) 2)))
    (should (string-prefix-p "ROLLBACK" (nth 2 (nth 0 diags))))
    (should (string-match-p "\\[hazard.terminator-before-throw\\]" (nth 3 (nth 0 diags))))
    (should (eq :warning (car (nth 1 diags))))
    (should (equal "CREATE" (nth 2 (nth 1 diags))))
    (should (equal '(:warning 2) (seq-take (nth 2 diags) 2)))
    (should (string-match-p "unexpected token \\[parse\\]" (nth 3 (nth 2 diags))))))

(ert-deftest kitty-sqldiff-flymake-byte-columns-after-non-ascii ()
  ;; "é" is two bytes: byte column 9 is the X after "-- é é "
  (let ((diags (kitty-test--flymake
                "-- é é X\n" "u.pg.sql"
                "cat <<'JSON'
{\"verdict\":\"unknown\",\"a\":{},\"findings\":[{\"rule\":\"r\",\"severity\":\"low\",\"witness\":\"w\",
\"a\":{\"start_line\":1,\"start_col\":10,\"end_line\":1,\"end_col\":11}}],\"diagnostics\":[]}
JSON
exit 1")))
    (should (equal '(:note 1 "X") (seq-take (car diags) 3)))))

(ert-deftest kitty-sqldiff-flymake-clean ()
  (should (eq 'none (kitty-test--flymake
                     "SELECT 1;\n" "a.pg.sql"
                     "echo '{\"verdict\":\"equal\",\"findings\":[],\"diagnostics\":[]}'"))))

(ert-deftest kitty-sqldiff-flymake-usage-error-panics ()
  (let ((bin (kitty-test--fake-sqldiff "echo 'sqldiff: bad' >&2; exit 2")) args)
    (kitty-test--with-path bin
      (with-temp-buffer
        (insert "SELECT 1;\n")
        (setq buffer-file-name "/tmp/kitty-x.pg.sql")
        (kitty-sqldiff-flymake (lambda (&rest a) (setq args a)))
        (kitty-test--wait (lambda () args))
        (set-buffer-modified-p nil)))
    (should (eq :panic (car args)))
    (should (equal "sqldiff: bad" (plist-get (cdr args) :explanation)))))

(ert-deftest kitty-sqldiff-flymake-off-without-dialect-or-binary ()
  (let ((bin (kitty-test--fake-sqldiff "touch \"$0.ran\"; exit 0")) called)
    (kitty-test--with-path bin
      (with-temp-buffer
        (setq buffer-file-name "/tmp/kitty-plain.sql")
        (kitty-sqldiff-flymake (lambda (diags &rest _) (setq called (list diags))))
        (set-buffer-modified-p nil)))
    (should (equal '(nil) called))
    (should-not (file-exists-p (expand-file-name "sqldiff.ran" bin))))
  (let ((exec-path nil) (process-environment (cons "PATH=/nonexistent" process-environment)) called)
    (with-temp-buffer
      (setq buffer-file-name "/tmp/kitty-a.tsql.sql")
      (kitty-sqldiff-flymake (lambda (diags &rest _) (setq called (list diags))))
      (set-buffer-modified-p nil))
    (should (equal '(nil) called))))

;;;; *sqldiff*

(ert-deftest kitty-sqldiff-render-locations-are-visitable ()
  (let* ((dir (make-temp-file "sql" t))
         (a (expand-file-name "x.tsql.sql" dir))
         (report (json-parse-string
                  (replace-regexp-in-string "\"x.tsql.sql\"" (format "%S" a) kitty-test--check-json)
                  :object-type 'alist :array-type 'list :null-object nil :false-object nil)))
    (with-temp-file a (insert kitty-test--rethrow))
    (with-current-buffer (kitty-sqldiff--show "t" report (cons a nil) nil 'quiet)
      (should (string-match-p "^Verdict: UNKNOWN$" (buffer-string)))
      (should (string-match-p "^2 findings (1 semantic, 1 residue)" (buffer-string)))
      (should (string-match-p (concat "^    A  " (regexp-quote a) ":4:24  high$") (buffer-string)))
      (should (string-match-p "Parse diagnostics" (buffer-string)))
      (goto-char (point-min))
      (let ((display-buffer-overriding-action '(display-buffer-same-window)))
        (compilation-next-error 1)
        (compile-goto-error))
      (should (equal a buffer-file-name))
      (should (= 4 (line-number-at-pos)))
      (kill-buffer))))

(ert-deftest kitty-sqldiff-siblings-pair-by-name ()
  (let ((dir (make-temp-file "sql" t)))
    (dolist (f '("move_stock.tsql.sql" "movestock.db2i.sql" "Move-Stock.pg.sql" "other.sql"))
      (with-temp-file (expand-file-name f dir)))
    (should (equal '("Move-Stock.pg.sql" "movestock.db2i.sql")
                   (sort (mapcar #'file-name-nondirectory
                                 (kitty-sqldiff-siblings (expand-file-name "move_stock.tsql.sql" dir)))
                         #'string<)))))

(ert-deftest kitty-sqldiff-format-guard-warns-when-the-meaning-changed ()
  (let ((bin (kitty-test--fake-sqldiff
              "case \"$*\" in diff*'-d tsql -f json') ;; *) exit 2;; esac
echo '{\"verdict\":\"different\",\"a\":{},\"b\":{},\"findings\":[{\"rule\":\"r\",\"class\":\"semantic\",\"severity\":\"high\",\"verdict\":\"different\",\"witness\":\"THROW lost\"}],\"diagnostics\":[]}'
exit 1"))
        warned)
    (kitty-test--with-path bin
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type msg &rest _) (setq warned msg))))
        (with-temp-buffer
          (setq buffer-file-name "/tmp/kitty-f.tsql.sql")
          (insert "SELECT 1;\n")
          (kitty-sqldiff-verify-format "select 1\n")
          (kitty-test--wait (lambda () warned))
          (set-buffer-modified-p nil))))
    (should (string-match-p "may have changed its meaning (sqldiff: different): THROW lost" warned))))

(ert-deftest kitty-sqldiff-format-guard-is-quiet-when-equal ()
  (let ((bin (kitty-test--fake-sqldiff "echo '{\"verdict\":\"equal\",\"findings\":[]}'"))
        (warned nil) (msg nil))
    (kitty-test--with-path bin
      (cl-letf (((symbol-function 'display-warning) (lambda (&rest _) (setq warned t)))
                ((symbol-function 'message) (lambda (fmt &rest args) (setq msg (apply #'format fmt args)))))
        (with-temp-buffer
          (setq buffer-file-name "/tmp/kitty-f.pg.sql")
          (insert "SELECT 1;\n")
          (kitty-sqldiff-verify-format "select 1;\n")
          (kitty-test--wait (lambda () msg))
          (set-buffer-modified-p nil))))
    (should-not warned)
    (should (equal "formatted; sqldiff: same meaning" msg))))

;;;; The real sqldiff, when it is installed

(ert-deftest kitty-sqldiff-real-binary-finds-the-missing-terminator ()
  (skip-unless (executable-find "sqldiff"))
  (let (result)
    (with-temp-buffer
      (insert kitty-test--rethrow)
      (setq buffer-file-name (expand-file-name "real.tsql.sql" (make-temp-file "sql" t)))
      (kitty-sqldiff-flymake (lambda (diags &rest _) (setq result (or diags 'none))))
      (kitty-test--wait (lambda () result))
      (should (consp result))
      (let ((d (seq-find (lambda (d) (string-match-p "terminator-before-throw" (flymake-diagnostic-text d)))
                         result)))
        (should d)
        (should (eq :error (flymake-diagnostic-type d)))
        (should (= 4 (line-number-at-pos (flymake-diagnostic-beg d))))
        (should (equal "ROLLBACK" (buffer-substring (flymake-diagnostic-beg d) (+ 8 (flymake-diagnostic-beg d))))))
      (set-buffer-modified-p nil))))

(provide 'kitty-sqldiff-test)
;;; kitty-sqldiff-test.el ends here
