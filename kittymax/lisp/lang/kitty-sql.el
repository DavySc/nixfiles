;;; kitty-sql.el --- SQL  -*- lexical-binding: t; -*-

;;; Commentary:

;; sql-mode for three dialects: T-SQL (SQL Server), PostgreSQL and Db2 for i.
;; A buffer's dialect is never guessed from its contents.  It is, in order:
;;
;;   1. `kitty-sql-dialect', from .dir-locals.el or a file-local variable:
;;        ((sql-mode . ((kitty-sql-dialect . tsql))))
;;   2. the file name: foo.tsql.sql, foo.pg.sql, foo.db2i.sql (and .pgsql ...)
;;   3. `kitty-sql-default-dialect' (nil: not known)
;;
;; The dialect picks the highlighting (`sql-product'), the formatter (pg_format
;; for PostgreSQL, sqlfluff for T-SQL, none for Db2 for i or an unknown
;; dialect: nothing is reformatted that a formatter would mangle) and what
;; sqldiff checks (kitty-sqldiff).  SPC m t sets it.
;;
;; sql-indent indents and aligns, and the built-in SQLi buffer runs queries:
;; send the paragraph, region or buffer from SPC m.  Connections are data:
;;
;;   ;; local.el
;;   (setq sql-connection-alist
;;         '((dev  (sql-product 'postgres) (sql-server "localhost")
;;                 (sql-port 5432) (sql-user "me") (sql-database "app"))))
;;
;; Passwords stay out of it: ~/.pgpass, as psql expects.  sqls (the language
;; server) is started on request with SPC m L, since it needs its own config.

;;; Code:

(require 'kitty-lib)

(defvar apheleia-formatter)
(declare-function sql-highlight-product "sql")

(setq sql-product 'postgres            ; SQLi's default; the buffer's dialect wins
      sql-postgres-login-params '(user database server)
      sql-input-ring-file-name (expand-file-name "sql-history" kitty-data-dir)
      sql-send-terminator t
      sql-ms-options nil)

(add-to-list 'auto-mode-alist '("\\.\\(psql\\|pgsql\\|tsql\\|db2i\\|ddl\\|dml\\)\\'" . sql-mode))

;;;; Dialect

(defconst kitty-sql-dialects '(tsql postgres db2i)
  "The dialects kittymax (and sqldiff) knows.")

(defvar-local kitty-sql-dialect nil
  "This buffer's SQL dialect: `tsql', `postgres', `db2i', or nil to go by the file name.
Set it in .dir-locals.el or as a file-local variable.")
(put 'kitty-sql-dialect 'safe-local-variable (lambda (v) (memq v kitty-sql-dialects)))

(defvar kitty-sql-default-dialect nil
  "The dialect of SQL files that neither a variable nor their name says anything about.
nil (the default) means not known: no formatter runs on them and sqldiff
does not lint them.  Set it in local.el, e.g. to `postgres'.")

(defconst kitty-sql-dialect-names
  '(("tsql" . tsql) ("mssql" . tsql) ("sqlserver" . tsql)
    ("pg" . postgres) ("postgres" . postgres) ("pgsql" . postgres) ("psql" . postgres)
    ("plpgsql" . postgres)
    ("db2i" . db2i) ("db2" . db2i))
  "File-name parts that name a dialect: foo.tsql.sql, foo.pgsql ...")

(defun kitty-sql-dialect-from-file-name (file)
  "The dialect FILE's name gives (foo.tsql.sql, foo.pg.sql, foo.pgsql), or nil."
  (when file
    (let* ((parts (cdr (split-string (downcase (file-name-nondirectory file)) "\\.")))
           (last (car (last parts)))
           (tag (if (equal last "sql") (car (last parts 2)) last)))
      (and tag (cdr (assoc tag kitty-sql-dialect-names))))))

(defun kitty-sql-dialect ()
  "This buffer's dialect (see `kitty-sql-dialect'), or nil if it is not known."
  (or (and (memq kitty-sql-dialect kitty-sql-dialects) kitty-sql-dialect)
      (kitty-sql-dialect-from-file-name buffer-file-name)
      kitty-sql-default-dialect))

(defun kitty-sql-formatter (dialect)
  "The apheleia formatter for DIALECT, or nil for none."
  (pcase dialect
    ('postgres 'pgformatter)
    ('tsql 'sqlfluff-tsql)))

(defun kitty-sql-apply-dialect ()
  "Make highlighting, formatting and the mode line follow this buffer's dialect."
  (when (derived-mode-p 'sql-mode)
    (let* ((dialect (kitty-sql-dialect))
           (formatter (kitty-sql-formatter dialect)))
      (when dialect
        (setq-local sql-product (alist-get dialect '((tsql . ms) (postgres . postgres) (db2i . db2))))
        (when (fboundp 'sql-highlight-product) (sql-highlight-product))
        (setq mode-name (format "SQL[%s]" dialect)))
      (setq-local apheleia-formatter formatter)
      (when (fboundp 'apheleia-mode)
        (apheleia-mode (if formatter 1 -1))))))

(defun kitty-sql-set-dialect (dialect)
  "Set this buffer's DIALECT; offer to save it for the directory in .dir-locals.el."
  (interactive
   (list (intern (completing-read "Dialect: " (mapcar #'symbol-name kitty-sql-dialects)
                                  nil t nil nil
                                  (and (kitty-sql-dialect) (symbol-name (kitty-sql-dialect)))))))
  (setq-local kitty-sql-dialect dialect)
  (kitty-sql-apply-dialect)
  (when (and (called-interactively-p 'interactive)
             (y-or-n-p (format "Use %s for every SQL file under this directory (.dir-locals.el)? " dialect)))
    (add-dir-local-variable 'sql-mode 'kitty-sql-dialect dialect)))

;;;; Buffers

(defun kitty--sql-setup ()
  (when (fboundp 'sqlind-minor-mode) (sqlind-minor-mode 1))
  (setq-local tab-width 2
              indent-tabs-mode nil
              completion-ignore-case t)
  (kitty-sql-apply-dialect)
  ;; .dir-locals.el and file-local variables arrive after the mode hook.
  (add-hook 'hack-local-variables-hook #'kitty-sql-apply-dialect nil t))
(kitty-add-hook 'sql-mode-hook #'kitty--sql-setup)

(defun kitty--sql-repl-setup ()
  (toggle-truncate-lines 1)
  (setq-local comint-scroll-to-bottom-on-output t))
(kitty-add-hook 'sql-interactive-mode-hook #'kitty--sql-repl-setup)

(with-eval-after-load 'sql-indent
  (setq sqlind-basic-offset 4))

(defun kitty-sql-connect ()
  "Connect to one of `sql-connection-alist' (or ask for a product)."
  (interactive)
  (if sql-connection-alist
      (call-interactively #'sql-connect)
    (call-interactively #'sql-product-interactive)))

(defun kitty-sql-eglot ()
  "Start the sqls language server for this buffer."
  (interactive)
  (call-interactively #'eglot))

(defun kitty-sql-send-dwim ()
  "Send the region, else the paragraph at point, to the SQLi buffer."
  (interactive)
  (if (use-region-p)
      (sql-send-region (region-beginning) (region-end))
    (sql-send-paragraph)))

(kitty-local-leader 'sql-mode
  "c" '("connect" . kitty-sql-connect)
  "s" '("set SQLi buffer" . sql-set-sqli-buffer)
  "e" '("send paragraph / region" . kitty-sql-send-dwim)
  "r" '("send region" . sql-send-region)
  "b" '("send buffer" . sql-send-buffer)
  "l" '("list tables" . sql-list-all)
  "d" '("describe table" . sql-list-table)
  "f" '("format" . kitty-format)
  "t" '("set dialect" . kitty-sql-set-dialect)
  "L" '("language server" . kitty-sql-eglot)
  "i" '("show SQLi" . sql-show-sqli-buffer))

(provide 'kitty-sql)
;;; kitty-sql.el ends here
