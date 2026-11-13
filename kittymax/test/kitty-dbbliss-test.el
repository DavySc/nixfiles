;;; kitty-dbbliss-test.el --- the dbbliss client, against a fake backend  -*- lexical-binding: t; -*-

;; The backend is replaced by a function that answers each request as
;; dbbliss-backend does (the messages are the ones in its Backend.cs and
;; ResultStreamer.cs): responses first, then the query's notifications.
;; One test runs a stub process over a real pipe, for the framing.
;;   emacs --batch -L lisp -L lisp/lang -l test/kitty-dbbliss-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'sql)
(require 'kitty-sql)
(require 'kitty-dbbliss)

;;;; A fake backend

(defvar kdt--sent nil "Requests sent, newest first, as plists.")
(defvar kdt--handlers nil "Method -> (lambda (params id)) overriding the defaults.")
(defvar kdt--result nil "(COLUMNS . ROWS) the default execute answers with.")

(defun kdt--deliver (&rest msgs)
  "Feed MSGS to the client as the backend's output (through the line reader)."
  (kitty-dbbliss--filter nil (mapconcat (lambda (m) (concat (json-serialize m) "\n")) msgs "")))

(defun kdt--reply (id result) (kdt--deliver (list :id id :result (or result (make-hash-table)))))
(defun kdt--error (id code message &optional data)
  (kdt--deliver (list :id id :error (append (list :code code :message message) (and data (list :data data))))))

(defun kdt--split (text)
  "script/split for the tests: statements end at ; (no strings with ; in them)."
  (let ((pos 0) (line 0) (col 0) statements start text-start)
    (cl-flet ((advance (ch) (if (eq ch ?\n) (setq line (1+ line) col 0) (setq col (1+ col)))))
      (while (< pos (length text))
        (let ((ch (aref text pos)))
          (cond ((and (not start) (memq ch '(?\s ?\t ?\n))))
                ((not start) (setq start (list line col) text-start pos))
                ((eq ch ?\;)
                 (let ((stmt (substring text text-start pos)))
                   (push (list :text stmt :start (list :line (car start) :col (cadr start))
                               :end (list :line line :col col) :repeat 1
                               :kind (if (string-match-p "\\`\\(?:select\\|with\\)" (downcase stmt)) "read" "write")
                               :ddl (if (string-match-p "\\`\\(?:create\\|alter\\|drop\\)" (downcase stmt)) t :false))
                         statements)
                   (setq start nil))))
          (advance ch)
          (setq pos (1+ pos))))
      (when start
        (let ((stmt (string-trim-right (substring text text-start))))
          (push (list :text stmt :start (list :line (car start) :col (cadr start)) :end (list :line line :col col)
                      :repeat 1 :kind (if (string-match-p "\\`select" (downcase stmt)) "read" "write") :ddl :false)
                statements))))
    (vconcat (nreverse statements))))

(defun kdt--execute-default (params _id)
  "Answer execute with `kdt--result' as one result set, then completed."
  (let ((qid (plist-get params :query_id)))
    (if kdt--result
        (kdt--deliver
         (list :method "query/resultset" :params (list :query_id qid :result_set 0
                                                       :columns (vconcat (mapcar (lambda (c) (list :name c :type "int"))
                                                                                 (car kdt--result)))))
         (list :method "query/rows" :params (list :query_id qid :result_set 0 :rows (vconcat (cdr kdt--result))))
         (list :method "query/resultset_done" :params (list :query_id qid :result_set 0 :rows (length (cdr kdt--result))))
         (list :method "query/done" :params (list :query_id qid :status "completed" :elapsed_ms 3
                                                  :rows_affected :null :transaction "none")))
      (kdt--deliver (list :method "query/done" :params (list :query_id qid :status "completed" :elapsed_ms 1
                                                             :rows_affected 2 :transaction "none"))))))

(defun kdt--send (string)
  (should (string-suffix-p "\n" string))
  (should-not (string-match-p "\n." string))   ; one line per message
  (let* ((msg (kitty-dbbliss--json-read (string-trim-right string)))
         (method (plist-get msg :method)) (params (plist-get msg :params)) (id (plist-get msg :id)))
    (push msg kdt--sent)
    (let ((h (alist-get method kdt--handlers nil nil #'equal)))
      (cond
       (h (funcall h params id))
       ((equal method "initialize") (kdt--reply id '(:protocol 1 :version "test")))
       ((equal method "connect")
        (kdt--reply id (list :connection_id "c1" :engine (plist-get params :engine) :server_session_id 55)))
       ((equal method "script/split") (kdt--reply id (list :statements (kdt--split (plist-get params :text)))))
       ((equal method "execute")
        (kdt--reply id (list :query_id (plist-get params :query_id)))
        (kdt--execute-default params id))
       ((member method '("fetch" "cancel"))
        (kdt--reply id (list :query_id (plist-get params :query_id) :state "granted")))
       ((string-prefix-p "transaction/" method)
        (kdt--reply id (list :transaction (if (equal method "transaction/begin") "active" "none"))))
       ((equal method "disconnect") (kdt--reply id '(:rolled_back :false)))
       (t (kdt--reply id nil))))))

(defun kdt--requests (method)
  "Params of the requests of METHOD sent, oldest first."
  (mapcar (lambda (m) (plist-get m :params))
          (seq-filter (lambda (m) (equal (plist-get m :method) method)) (reverse kdt--sent))))

(defmacro kdt--with-backend (&rest body)
  "BODY with the fake backend, fresh client state and a connection \"work\"."
  (declare (indent 0))
  `(let ((kitty-dbbliss--send-function #'kdt--send)
         (kitty-dbbliss--pending (make-hash-table :test #'eql))
         (kitty-dbbliss--connections (make-hash-table :test #'equal))
         (kitty-dbbliss--queries (make-hash-table :test #'equal))
         (kitty-dbbliss--scripts (make-hash-table :test #'equal))
         (kitty-dbbliss--caches (make-hash-table :test #'equal))
         (kitty-dbbliss--open (make-hash-table :test #'equal))
         (kitty-dbbliss--current nil) (kitty-dbbliss--recent nil) (kitty-dbbliss--sets nil)
         (kitty-dbbliss--paused nil) (kitty-dbbliss--partial "")
         (kitty-dbbliss-connections
          '(("work" :engine "sqlserver" :env "dev"
             :connection-string "Server=sql01;Integrated Security=true")
            ("prod" :engine "sqlserver" :env "prod" :connection-string "Server=sql02;Integrated Security=true")
            ("pg" :engine "postgres" :connection-string "Host=x" :password (:env "PGPASS"))))
         (kdt--sent nil) (kdt--handlers nil) (kdt--result nil))
     (dolist (b (list kitty-dbbliss-results-buffer kitty-dbbliss-messages-buffer))
       (when (get-buffer b) (kill-buffer b)))
     ,@body))

(defun kdt--sql-buffer (text)
  "A sql-mode buffer holding TEXT (| marks point)."
  (let ((buf (generate-new-buffer "q.sql")))
    (with-current-buffer buf
      (insert (string-replace "|" "" text))
      (sql-mode)
      (goto-char (1+ (or (string-search "|" text) 0))))
    buf))

(defun kdt--results ()
  (with-current-buffer kitty-dbbliss-results-buffer (buffer-substring-no-properties (point-min) (point-max))))

;;;; Transport

(ert-deftest kitty-dbbliss-reads-lines-in-pieces ()
  "Messages split across reads, two in one read, CRLF endings: all arrive whole."
  (kdt--with-backend
    (let (got)
      (kitty-dbbliss--request "initialize" nil (lambda (_ r) (push r got)))
      (should (equal '((:protocol 1 :version "test")) got))
      (puthash 7 (lambda (_ r) (push r got)) kitty-dbbliss--pending)
      (puthash 8 (lambda (_ r) (push r got)) kitty-dbbliss--pending)
      (kitty-dbbliss--filter nil "{\"id\":7,\"res")
      (should (= 1 (length got)))
      (kitty-dbbliss--filter nil "ult\":{\"a\":\"é😀\"}}\r\n{\"id\":8,\"result\":{\"b\":null}}\n")
      (should (equal '((:b nil) (:a "é😀")) (seq-take got 2)))
      (should (string-empty-p kitty-dbbliss--partial)))))

(ert-deftest kitty-dbbliss-params-drop-nil ()
  "nil would be sent as {}: parameters without a value are left out."
  (should (equal '(:a 1 :c "x") (kitty-dbbliss--params :a 1 :b nil :c "x")))
  (kdt--with-backend
    (kitty-dbbliss--request "fetch" nil #'ignore)
    (should (equal "{}" (substring (json-serialize (list :params (make-hash-table))) 10 12)))))

;;;; Connections

(ert-deftest kitty-dbbliss-connect-windows-auth ()
  "connect sends the connection string and no password; the buffer binds and is T-SQL."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "select 1;|")
      (kitty-dbbliss-connect "work")
      (let ((p (car (kdt--requests "connect"))))
        (should (equal "sqlserver" (plist-get p :engine)))
        (should (equal "Server=sql01;Integrated Security=true" (plist-get p :connection_string)))
        (should-not (plist-member p :password))
        (should (equal "dev" (plist-get p :env))))
      (should (equal "work" kitty-dbbliss-buffer-connection))
      (should (equal "work" kitty-dbbliss--current))
      (should (eq 'tsql (kitty-sql-dialect)))
      (should (string-match-p "work" (kitty-dbbliss-mode-line))))))

(ert-deftest kitty-dbbliss-password-references-only ()
  "A password is a reference; a literal one is refused before anything is sent."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "|")
      (kitty-dbbliss-connect "pg")
      (should (equal '(:env "PGPASS") (plist-get (car (kdt--requests "connect")) :password)))
      (let ((kitty-dbbliss-connections '(("bad" :engine "postgres" :connection-string "x" :password "hunter2"))))
        (should-error (kitty-dbbliss-connect "bad") :type 'user-error)))))

(ert-deftest kitty-dbbliss-connect-twice-reuses ()
  "Connecting to an open connection reuses it: a second session would orphan the first."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-connect "work")
      (should (= 1 (length (kdt--requests "connect")))))))

;;;; Running statements

(ert-deftest kitty-dbbliss-runs-the-statement-under-the-cursor ()
  "e runs the statement the cursor is in, with its line, and draws the table."
  (kdt--with-backend
    (setq kdt--result '(("id" "name") . ([1 "Ada"] [2 :null] [10 "Grace Hopper"])))
    (with-current-buffer (kdt--sql-buffer "select 1;\nselect id, name\n  from |dbo.people;\nselect 3;")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec)
      (let ((ex (kdt--requests "execute")))
        (should (= 1 (length ex)))
        (should (equal "select id, name\n  from dbo.people" (plist-get (car ex) :sql)))
        (should (= 1 (plist-get (car ex) :line_offset)))
        (should (= kitty-dbbliss-window-rows (plist-get (car ex) :window))))
      (let ((out (kdt--results)))
        (should (string-match-p "^id │ name        $" out))
        (should (string-match-p "^───┼─────────────$" out))
        (should (string-match-p "^ 1 │ Ada         $" out))
        (should (string-match-p "^ 2 │ NULL        $" out))
        (should (string-match-p "^10 │ Grace Hopper$" out))
        (should (string-match-p "^(3 rows)$" out))
        (should (string-match-p "^-- completed in 3 ms$" out)))
      (should (= 0 (hash-table-count kitty-dbbliss--scripts))))))

(ert-deftest kitty-dbbliss-script-stops-at-the-first-error ()
  "A failing statement stops the script, says where, and marks its line."
  (kdt--with-backend
    (setf (alist-get "execute" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (kdt--reply id (list :query_id (plist-get params :query_id)))
            (if (string-match-p "boom" (plist-get params :sql))
                (kdt--deliver (list :method "query/done"
                                    :params (list :query_id (plist-get params :query_id) :status "error"
                                                  :elapsed_ms 2 :transaction "none"
                                                  :error (list :message "Invalid object name 'boom'." :line 1
                                                               :buffer_line (1+ (plist-get params :line_offset))))))
              (kdt--execute-default params id))))
    (with-current-buffer (kdt--sql-buffer "update a set x = 1;\n\nselect * from boom;\nupdate c set y = 2;|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec-buffer)
      (should (= 2 (length (kdt--requests "execute"))))
      (should (string-match-p "stopped: batch 2 of 3 (buffer line 3) error; 1 not run" (kdt--results)))
      (should (equal '((3 . "Invalid object name 'boom'.")) kitty-dbbliss--errors))
      (should (= 0 (hash-table-count kitty-dbbliss--scripts))))))

(ert-deftest kitty-dbbliss-go-count-repeats ()
  "GO 3 runs its batch three times."
  (kdt--with-backend
    (setf (alist-get "script/split" kdt--handlers nil nil #'equal)
          (lambda (_ id)
            (kdt--reply id (list :statements (vector (list :text "insert t default values" :start '(:line 0 :col 0)
                                                           :end '(:line 0 :col 23) :repeat 3 :kind "write" :ddl :false))))))
    (with-current-buffer (kdt--sql-buffer "insert t default values\nGO 3|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec-buffer)
      (should (= 3 (length (kdt--requests "execute")))))))

(ert-deftest kitty-dbbliss-prod-confirms-writes ()
  "On prod, statements that can change data are confirmed; No runs nothing."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "select 1;\ndelete from t;|")
      (kitty-dbbliss-connect "prod")
      (let (asked)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (q) (setq asked q) nil)))
          (kitty-dbbliss-exec-buffer))
        (should (string-match-p "PROD prod: 1 of 2 statement(s) can change data" asked))
        (should (string-match-p "line 2: delete from t" asked))
        (should (null (kdt--requests "execute"))))
      ;; a read goes without asking
      (goto-char (point-min))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) (error "Asked"))))
        (kitty-dbbliss-exec))
      (should (= 1 (length (kdt--requests "execute")))))))

(ert-deftest kitty-dbbliss-paging-and-wider-pages ()
  "A paused query shows a hint; gm fetches; a wider later page redraws the table."
  (kdt--with-backend
    (setf (alist-get "execute" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (let ((qid (plist-get params :query_id)))
              (kdt--reply id (list :query_id qid))
              (kdt--deliver (list :method "query/resultset" :params (list :query_id qid :result_set 0
                                                                          :columns [(:name "n" :type "int")]))
                            (list :method "query/rows" :params (list :query_id qid :result_set 0 :rows [[1] [2]]))
                            (list :method "query/paused" :params (list :query_id qid :rows_sent 2))))))
    (with-current-buffer (kdt--sql-buffer "select n from t;|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec)
      (should (string-match-p "-- 2 rows shown; more are available" (kdt--results)))
      (kitty-dbbliss-fetch-more)
      (let ((f (car (kdt--requests "fetch"))))
        (should (= kitty-dbbliss-window-rows (plist-get f :rows))))
      (should-not (string-match-p "more are available" (kdt--results)))
      (let ((qid (car (hash-table-keys kitty-dbbliss--queries))))
        (kdt--deliver (list :method "query/rows" :params (list :query_id qid :result_set 0 :rows [[123456]]))
                      (list :method "query/resultset_done" :params (list :query_id qid :result_set 0 :rows 3))
                      (list :method "query/done" :params (list :query_id qid :status "completed" :elapsed_ms 9
                                                               :transaction "none"))))
      (let ((out (kdt--results)))
        ;; every row is drawn at the new width: no number is cut
        (should (string-match-p "^n     \n──────\n     1\n     2\n123456\n(3 rows)" out))))))

(ert-deftest kitty-dbbliss-cancel-sends-the-query-id ()
  "x cancels the running query of this buffer's connection."
  (kdt--with-backend
    (setf (alist-get "execute" kdt--handlers nil nil #'equal)
          (lambda (params id) (kdt--reply id (list :query_id (plist-get params :query_id)))))
    (with-current-buffer (kdt--sql-buffer "waitfor delay '00:01';|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec)
      (let ((qid (car (hash-table-keys kitty-dbbliss--queries))))
        (should qid)
        (kitty-dbbliss-cancel)
        (should (equal qid (plist-get (car (kdt--requests "cancel")) :query_id)))))))

(ert-deftest kitty-dbbliss-yank-full-values ()
  "yc / yr / yC copy full values; NULL is empty."
  (kdt--with-backend
    (let ((kitty-dbbliss-max-col-width 5))
      (setq kdt--result '(("a" "b") . ([1 "a long value"] [2 :null])))
      (with-current-buffer (kdt--sql-buffer "select a, b from t;|")
        (kitty-dbbliss-connect "work")
        (kitty-dbbliss-exec))
      (with-current-buffer kitty-dbbliss-results-buffer
        (goto-char (point-min))
        (search-forward "a lo")
        (should (string-match-p "a lo…" (buffer-substring (line-beginning-position) (line-end-position))))
        (kitty-dbbliss-yank 'cell)
        (should (equal "a long value" (current-kill 0)))
        (kitty-dbbliss-yank 'row)
        (should (equal "1\ta long value" (current-kill 0)))
        (kitty-dbbliss-yank 'column)
        (should (equal "a long value\n" (current-kill 0)))
        (beginning-of-line)
        (kitty-dbbliss-next-cell)
        (should (= (current-column) (aref (kitty-dbbliss--set-starts (car kitty-dbbliss--sets)) 1)))))))

(ert-deftest kitty-dbbliss-messages-and-rows-affected ()
  "PRINT goes to the messages; rows affected and the transaction state are reported."
  (kdt--with-backend
    (setf (alist-get "execute" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (let ((qid (plist-get params :query_id)))
              (kdt--reply id (list :query_id qid))
              (kdt--deliver (list :method "query/message" :params (list :query_id qid :severity "info" :text "hello"
                                                                        :number 0 :line 1))
                            (list :method "query/done" :params (list :query_id qid :status "completed" :elapsed_ms 1
                                                                     :rows_affected 4 :transaction "active"))))))
    (with-current-buffer (kdt--sql-buffer "begin tran; update t set x = 1;|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec)
      (should (string-match-p "4 rows affected" (kdt--results)))
      (should (string-match-p "-- message: hello" (kdt--results)))
      (with-current-buffer kitty-dbbliss-messages-buffer
        (should (string-match-p "\\[info\\] line 1: hello" (buffer-string))))
      (should (equal "active" (plist-get (gethash "work" kitty-dbbliss--connections) :transaction)))
      (should (string-match-p "TX:active" (kitty-dbbliss-mode-line))))))

(ert-deftest kitty-dbbliss-disconnect-asks-about-a-transaction ()
  "The server reports an open transaction: rollback is asked for, then sent."
  (kdt--with-backend
    (setf (alist-get "disconnect" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (if (eq (plist-get params :rollback) t)
                (kdt--reply id '(:rolled_back t))
              (kdt--error id 1003 "The connection has an open transaction (active)."))))
    (with-current-buffer (kdt--sql-buffer "|")
      (kitty-dbbliss-connect "work")
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (kitty-dbbliss-disconnect))
      (should (equal '(nil t) (mapcar (lambda (p) (plist-get p :rollback)) (kdt--requests "disconnect"))))
      (should (= 0 (hash-table-count kitty-dbbliss--connections)))
      (should-not kitty-dbbliss-buffer-connection))))

(ert-deftest kitty-dbbliss-backend-exit-loses-everything-loudly ()
  "The backend exits: pending requests fail, running queries are reported lost."
  (kdt--with-backend
    (setf (alist-get "execute" kdt--handlers nil nil #'equal)
          (lambda (params id) (kdt--reply id (list :query_id (plist-get params :query_id)))))
    (with-current-buffer (kdt--sql-buffer "select 1;|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-exec)
      (let (failed)
        (puthash 999 (lambda (err _) (setq failed err)) kitty-dbbliss--pending)
        (kitty-dbbliss--backend-gone 137)
        (should (string-match-p "exited (code 137)" (plist-get failed :message))))
      (should (string-match-p "LOST: backend exited (code 137)" (kdt--results)))
      (should (= 0 (hash-table-count kitty-dbbliss--connections)))
      (should (= 0 (hash-table-count kitty-dbbliss--scripts))))))

;;;; Catalog, plans, completion

(ert-deftest kitty-dbbliss-info-renders-sections ()
  "Object info: a table per section, text sections as lines."
  (let ((text (kitty-dbbliss-render-info
               '(:title "dbo.people (table)" :kind "table"
                 :sections [(:title "Columns" :columns ["name" "type" "null"] :rows [["id" "int" "NO"] ["name" "nvarchar(50)" :null]] :text :false)
                            (:title "Indexes" :columns ["name"] :rows [] :text :false)
                            (:title "Definition" :columns ["line"] :rows [["CREATE VIEW v AS"] ["SELECT 1"]] :text t)]))))
    (should (string-match-p "── Columns (2) ──" text))
    (should (string-match-p "  name │ type         │ null" text))
    (should (string-match-p "  id   │ int          │ NO  " text))
    (should (string-match-p "── Indexes (0) ──\n  (none)" text))
    (should (string-match-p "── Definition ──\n  CREATE VIEW v AS\n  SELECT 1" text))))

(ert-deftest kitty-dbbliss-plan-lines ()
  "A plan node: operator, cost, estimated → actual rows with the factor, hottest."
  (should (equal "  ▾ Hash Match  Inner Join   cost 12.5 · rows 10 → 500 ×50 · loops 1 · 3.2 ms (self 1.5 ms)   ◀ hottest"
                 (kitty-dbbliss-plan-node-line
                  '(:id 1 :operator "Hash Match" :detail "Inner Join" :cost 12.5 :estimated_rows 10 :actual_rows 500
                    :loops 1 :time_ms 3.2 :self_time_ms 1.5 :children [(:id 2 :operator "Scan" :children [])])
                  1 nil t)))
  (should (equal "  Scan   rows 100" (kitty-dbbliss-plan-node-line '(:id 2 :operator "Scan" :estimated_rows 100 :children []) 0 nil nil))))

(ert-deftest kitty-dbbliss-plan-runs-through-the-backend ()
  "p starts an estimated plan without asking; P asks before running a write."
  (kdt--with-backend
    (setf (alist-get "plan/start" kdt--handlers nil nil #'equal)
          (lambda (_ id) (kdt--reply id '(:plan_id "p1"))))
    (with-current-buffer (kdt--sql-buffer "update t set x = 1;|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-plan)
      (should (equal "estimated" (plist-get (car (kdt--requests "plan/start")) :mode)))
      (should-not (plist-member (car (kdt--requests "plan/start")) :confirm_execute))
      (kdt--deliver (list :method "plan/done"
                          :params (list :plan_id "p1" :status "completed"
                                        :plans (vector (list :engine "sqlserver" :mode "estimated" :hottest 1
                                                             :totals '(:cost 1.5) :notes [] :raw "<x/>"
                                                             :root '(:id 1 :operator "Table Scan" :estimated_rows 3 :children []))))))
      (with-current-buffer "*dbbliss plan work*"
        (should (string-match-p "Table Scan   rows 3   ◀ hottest" (buffer-string)))
        (should (string-match-p "estimated plan · sqlserver · cost 1.5" (buffer-string))))
      (let (asked)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (q) (setq asked q) nil)))
          (kitty-dbbliss-plan-actual))
        (should (string-match-p "RUNS this statement" asked))
        (should (= 1 (length (kdt--requests "plan/start"))))))))

(ert-deftest kitty-dbbliss-tree-children-and-select-top ()
  "The explorer asks for children by path (no empty parts) and selects rows as SSMS does."
  (kdt--with-backend
    (setf (alist-get "catalog/children" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (kdt--reply id (list :nodes
                                 (cond ((plist-get params :folder)
                                        [(:name "Order Lines" :kind "table" :expandable :false)])
                                       ((plist-get params :schema)
                                        [(:name "Tables" :kind "folder" :folder "tables" :expandable t)])
                                       ((plist-get params :database)
                                        [(:name "dbo" :kind "schema" :expandable t)])
                                       (t [(:name "App" :kind "database" :expandable t)
                                           (:name "master" :kind "database" :expandable t :system t)]))))))
    (with-current-buffer (kdt--sql-buffer "|")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-tree))
    (with-current-buffer "*dbbliss tree work*"
      (should (string-match-p "▸ App" (buffer-string)))
      (should-not (string-match-p "master" (buffer-string)))
      (goto-char (point-min)) (search-forward "App") (kitty-dbbliss-tree-toggle)
      (search-forward "dbo") (kitty-dbbliss-tree-toggle)
      (search-forward "Tables") (kitty-dbbliss-tree-toggle)
      (should (equal '(:database "App" :schema "dbo" :folder "tables")
                     (cl-loop for (k v) on (car (last (kdt--requests "catalog/children"))) by #'cddr
                              unless (eq k :connection_id) append (list k v))))
      (should (string-match-p "      Order Lines" (buffer-string)))
      (search-forward "Order Lines")
      (should (equal '(:database "App" :schema "dbo" :object "Order Lines" :kind "table")
                     (kitty-dbbliss--node-object-params (kitty-dbbliss--tree-node))))
      (kitty-dbbliss-tree-select-top))
    ;; (the test splitter leaves the ; out, as the statement's own text)
    (should (equal "SELECT TOP (1000) *\nFROM App.dbo.[Order Lines]"
                   (plist-get (car (kdt--requests "execute")) :sql)))))

(ert-deftest kitty-dbbliss-completion-names-and-columns ()
  "Object names after FROM; an alias's columns after alias.; nothing waits."
  (kdt--with-backend
    (setf (alist-get "catalog/names" kdt--handlers nil nil #'equal)
          (lambda (_ id) (kdt--reply id '(:names [(:schema "dbo" :name "Orders" :kind "table")
                                                  (:schema "sales" :name "Order Lines" :kind "view")]
                                          :truncated :false :limit 20000))))
    (setf (alist-get "catalog/columns" kdt--handlers nil nil #'equal)
          (lambda (params id)
            (should (equal "dbo.Orders" (plist-get params :name)))
            (kdt--reply id '(:schema "dbo" :name "Orders" :columns [(:name "Id" :type "int") (:name "Total Due" :type "money")]))))
    (with-current-buffer (kdt--sql-buffer "select * from |")
      (kitty-dbbliss-connect "work")
      (let ((c (kitty-dbbliss-completion-at-point)))
        (should (equal '("dbo.Orders" "sales.[Order Lines]") (nth 2 c))))
      (erase-buffer)
      (insert "select o. from dbo.Orders o")
      (goto-char (point-min)) (search-forward "o.")
      (should-not (nth 2 (kitty-dbbliss-completion-at-point)))     ; the first request starts the load
      (should (equal '("Id" "[Total Due]") (nth 2 (kitty-dbbliss-completion-at-point))))
      (erase-buffer)
      (insert "select * from sales.")
      (should (equal '("[Order Lines]") (nth 2 (kitty-dbbliss-completion-at-point)))))))

(ert-deftest kitty-dbbliss-no-catalog-requests-in-a-transaction ()
  "In a transaction the catalog is not asked (SQL Server would wait for its locks)."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "select * from |")
      (kitty-dbbliss-connect "work")
      (kitty-dbbliss-begin)
      (kitty-dbbliss-completion-at-point)
      (should (null (kdt--requests "catalog/names"))))))

(ert-deftest kitty-dbbliss-cell-text ()
  "Values as shown: NULL, booleans, exact numbers."
  (should (equal '("NULL" . t) (kitty-dbbliss-cell-text nil)))
  (should (equal "false" (car (kitty-dbbliss-cell-text :false))))
  (should (equal "0.1" (car (kitty-dbbliss-cell-text 0.1))))
  (should (equal "123456789012345" (car (kitty-dbbliss-cell-text 123456789012345))))
  (should (equal "a↵b c·" (kitty-dbbliss--one-line "a\r\nb\tc\x01"))))

(ert-deftest kitty-dbbliss-quote-names ()
  "Names that need quotes get the engine's."
  (should (equal "Orders" (kitty-dbbliss-quote "Orders" "sqlserver")))
  (should (equal "[a]]b]" (kitty-dbbliss-quote "a]b" "sqlserver")))
  (should (equal "\"Order Lines\"" (kitty-dbbliss-quote "Order Lines" "postgres"))))

(ert-deftest kitty-dbbliss-finds-my-nvims-backend ()
  "The backend my-nvim built (vim.pack's directory) is found."
  (let* ((home (make-temp-file "kdt-home" t))
         (process-environment (append (list (concat "XDG_DATA_HOME=" home) (concat "LOCALAPPDATA=" home)
                                            "DBBLISS_BACKEND=")
                                      process-environment))
         (kitty-dbbliss-backend nil)
         (dir (expand-file-name (concat (if (eq system-type 'windows-nt) "nvim-data" "nvim")
                                        "/site/pack/core/opt/dbbliss.nvim/bin/" (kitty-dbbliss--rid))
                                home))
         (exe (expand-file-name (kitty-dbbliss--exe-name) dir)))
    (make-directory dir t)
    (with-temp-file exe (insert "#!/bin/sh\n"))
    (set-file-modes exe #o755)
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) nil)))
      (should (equal exe (kitty-dbbliss-backend-path))))))

;;;; Org babel

(ert-deftest kitty-dbbliss-babel-block-returns-a-table ()
  "#+begin_src sql :dbbliss work runs on the connection and returns its rows."
  (require 'ob-sql)
  (kdt--with-backend
    (setq kdt--result '(("id" "name") . ([1 "Ada"] [2 :null])))
    (with-temp-buffer
      (org-mode)
      (insert "#+begin_src sql :dbbliss work\nselect id, name from people\n#+end_src\n")
      (goto-char (point-min))
      (let ((org-confirm-babel-evaluate nil))
        (should (equal '(("id" "name") hline ("1" "Ada") ("2" ""))
                       (org-babel-execute-src-block nil nil '((:results . "value raw silent")))))))
    (should (equal "select id, name from people" (plist-get (car (kdt--requests "execute")) :sql)))
    (should-not (plist-member (car (kdt--requests "execute")) :window))))

;;;; :Dbbliss

(ert-deftest kitty-dbbliss-ex-subcommands ()
  ":Dbbliss <subcommand> runs the same command as in my-nvim."
  (kdt--with-backend
    (with-current-buffer (kdt--sql-buffer "select 1;|")
      (kitty-dbbliss-command "connect" "work")
      (should (gethash "work" kitty-dbbliss--connections))
      (kitty-dbbliss-command "exec")
      (should (= 1 (length (kdt--requests "execute"))))
      (should-error (kitty-dbbliss-command "nope") :type 'user-error))))

;;;; Over a real pipe

(ert-deftest kitty-dbbliss-real-process ()
  "A stub backend process: the framing works over a pipe, both ways."
  (skip-unless (executable-find "python3"))
  (let* ((dir (make-temp-file "kdt-stub" t))
         (stub (expand-file-name "dbbliss-backend" dir))
         (kitty-dbbliss-backend stub)
         (kitty-dbbliss--process nil)
         (kitty-dbbliss--pending (make-hash-table :test #'eql))
         (kitty-dbbliss--connections (make-hash-table :test #'equal))
         (kitty-dbbliss--queries (make-hash-table :test #'equal))
         (kitty-dbbliss--scripts (make-hash-table :test #'equal))
         (kitty-dbbliss--open (make-hash-table :test #'equal))
         (kitty-dbbliss--current nil) (kitty-dbbliss--recent nil) (kitty-dbbliss--sets nil)
         (kitty-dbbliss-connections '(("work" :engine "sqlserver" :connection-string "Server=x;Integrated Security=true"))))
    (with-temp-file stub
      (insert "#!/usr/bin/env python3
import json, sys
for line in sys.stdin:
    m = json.loads(line); i = m.get('id'); p = m.get('params') or {}
    def send(o): sys.stdout.write(json.dumps(o, ensure_ascii=False) + '\\r\\n'); sys.stdout.flush()
    meth = m['method']
    if meth == 'initialize': send({'id': i, 'result': {'protocol': 1}})
    elif meth == 'connect': send({'id': i, 'result': {'connection_id': 'c1', 'engine': p['engine'], 'server_session_id': 60}})
    elif meth == 'script/split': send({'id': i, 'result': {'statements': [{'text': p['text'], 'start': {'line': 0, 'col': 0}, 'end': {'line': 0, 'col': 1}, 'repeat': 1, 'kind': 'read', 'ddl': False}]}})
    elif meth == 'execute':
        q = p['query_id']
        send({'id': i, 'result': {'query_id': q}})
        send({'method': 'query/resultset', 'params': {'query_id': q, 'result_set': 0, 'columns': [{'name': 'naïve', 'type': 'nvarchar'}]}})
        send({'method': 'query/rows', 'params': {'query_id': q, 'result_set': 0, 'rows': [['日本'], [None]]}})
        send({'method': 'query/resultset_done', 'params': {'query_id': q, 'result_set': 0, 'rows': 2}})
        send({'method': 'query/done', 'params': {'query_id': q, 'status': 'completed', 'elapsed_ms': 1, 'transaction': 'none'}})
    elif meth == 'shutdown': send({'id': i, 'result': {}}); break
"))
    (set-file-modes stub #o755)
    (when (get-buffer kitty-dbbliss-results-buffer) (kill-buffer kitty-dbbliss-results-buffer))
    (unwind-protect
        (with-current-buffer (kdt--sql-buffer "select 1|")
          (let (opened)
            (kitty-dbbliss-connect "work" (lambda (_ c) (setq opened c)))
            (with-timeout (10 (error "No answer from the stub"))
              (while (not opened) (accept-process-output kitty-dbbliss--process 0.05))))
          (kitty-dbbliss-exec)
          (with-timeout (10 (error "No result from the stub"))
            (while (not (and (get-buffer kitty-dbbliss-results-buffer)
                             (string-match-p "completed" (kdt--results))))
              (accept-process-output kitty-dbbliss--process 0.05)))
          ;; 日本 is four columns wide: one space pads it to naïve's five
          (should (string-match-p "^naïve\n─────\n日本 \nNULL \n" (kdt--results))))
      (kitty-dbbliss-shutdown)
      (should-not (process-live-p kitty-dbbliss--process)))))

(provide 'kitty-dbbliss-test)
;;; kitty-dbbliss-test.el ends here
