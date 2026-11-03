;;; kitty-sql.el --- SQL  -*- lexical-binding: t; -*-

;;; Commentary:

;; sql-mode with PostgreSQL as the default dialect, sql-indent for
;; indentation and alignment, pg_format for formatting (on request), and the
;; built-in SQLi buffer for running queries: send the paragraph, region or
;; buffer from SPC m.  Connections are data:
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

(setq sql-product 'postgres
      sql-postgres-login-params '(user database server)
      sql-input-ring-file-name (expand-file-name "sql-history" kitty-data-dir)
      sql-send-terminator t
      sql-ms-options nil)

(add-to-list 'auto-mode-alist '("\\.\\(psql\\|pgsql\\|ddl\\|dml\\)\\'" . sql-mode))

(defun kitty--sql-setup ()
  (when (fboundp 'sqlind-minor-mode) (sqlind-minor-mode 1))
  (setq-local tab-width 2
              indent-tabs-mode nil
              completion-ignore-case t))
(add-hook 'sql-mode-hook #'kitty--sql-setup)

(defun kitty--sql-repl-setup ()
  (toggle-truncate-lines 1)
  (setq-local comint-scroll-to-bottom-on-output t))
(add-hook 'sql-interactive-mode-hook #'kitty--sql-repl-setup)

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
  "L" '("language server" . kitty-sql-eglot)
  "i" '("show SQLi" . sql-show-sqli-buffer))

(provide 'kitty-sql)
;;; kitty-sql.el ends here
