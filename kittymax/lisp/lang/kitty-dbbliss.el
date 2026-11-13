;;; kitty-dbbliss.el --- SQL Server and PostgreSQL: my-nvim's dbbliss, from Emacs  -*- lexical-binding: t; -*-

;;; Commentary:

;; The database client of kittymax, in place of SQL Server Management
;; Studio.  It is a second front end for dbbliss.nvim's backend, the one
;; my-nvim uses: a .NET process that holds the connections and speaks
;; line-delimited JSON-RPC on stdio.  Both editors share one build of it,
;; its connection rules and its safety rules: protocol-level cancel, paged
;; results that never lose rows, prod connections that confirm writes, open
;; transactions that are never committed or rolled back behind your back.
;;
;; Connections, in local.el (as in my-nvim's lua/local.lua):
;;
;;   (setq kitty-dbbliss-connections
;;         '(("work" :engine "sqlserver" :env "dev"
;;            :connection-string "Server=sql01;Database=App;Integrated Security=true;TrustServerCertificate=true")
;;           ("prod" :engine "sqlserver" :env "prod"
;;            :connection-string "Server=sql02;Database=App;Integrated Security=true")))
;;
;; Integrated Security=true is Windows authentication (SSPI): no password.
;; Otherwise :password names where to find one, never the password itself:
;; (:env "NAME"), (:credman "target") on Windows, (:pass "path"),
;; (:libsecret (:service "x" :account "y")).
;;
;; In SQL buffers (SPC m, and :Dbbliss as in my-nvim):
;;   c connect   u use another   C disconnect   s status
;;   e run the statement under the cursor (the GO batch), or the selection
;;   a run the whole buffer      x cancel        R show the results
;;   E export the statement's result to CSV
;;   T b / T c / T r   begin / commit / roll back
;;   d (and K) object info   S script the object   l object explorer
;;   p estimated plan   P actual plan (run and rolled back)
;; F5 runs the selection or the buffer, as in SSMS; C-RET the statement.
;;
;; The backend comes from my-nvim's install (:Dbbliss build there), or from
;; `kitty-dbbliss-build' here; see `kitty-dbbliss-backend'.

;;; Code:

(require 'kitty-lib)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)

(defvar kitty-sql-dialect)
(declare-function kitty-sql-apply-dialect "kitty-sql")
(declare-function kitty-lookup "kitty-evil")
(declare-function flymake-make-diagnostic "flymake")
(declare-function flymake-start "flymake")
(declare-function evil-define-key* "evil-core")
(declare-function evil-ex-define-cmd "evil-ex")
(declare-function evil-normal-state "evil-states")
(declare-function evil-set-initial-state "evil-core")
(defvar sql-mode-map)

;;;; Settings

(defvar kitty-dbbliss-connections nil
  "The connections, as in my-nvim's dbbliss setup: a list of (NAME . PLIST).
PLIST: :engine \"sqlserver\" or \"postgres\", :connection-string,
:env \"dev\", \"test\" or \"prod\" (prod confirms every statement that can
change data), :password (a reference, see the commentary; leave it out for
Windows authentication) and :options (an alist, passed on as is).")

(defvar kitty-dbbliss-backend nil
  "The dbbliss backend executable, or nil to look for it.
It is looked for in $DBBLISS_BACKEND, in my-nvim's copy of dbbliss.nvim
\(vim.pack's site/pack/core/opt), in `kitty-dbbliss-checkout' and on PATH.")

(defvar kitty-dbbliss-checkout (expand-file-name "dbbliss.nvim" kitty-data-dir)
  "Where `kitty-dbbliss-build' clones dbbliss.nvim when my-nvim has none.")

(defvar kitty-dbbliss-window-rows 1000
  "Rows a query shows before it pauses; more are fetched on request.")

(defvar kitty-dbbliss-max-col-width 40
  "The widest a result column is drawn; longer values are shortened (yanked in full).")

(defvar kitty-dbbliss-shutdown-timeout 5
  "Seconds to give the backend to cancel queries and close connections on exit.")

;;;; State

(defvar kitty-dbbliss--backend-info nil)
(defvar kitty-dbbliss--connections (make-hash-table :test #'equal)
  "Name -> plist (:id :engine :server-session :transaction).")
(defvar kitty-dbbliss--current nil "The default connection: the one made current last.")
(defvar kitty-dbbliss--recent nil "Connection names, most recent first.")
(defvar kitty-dbbliss--connecting nil)
(defvar kitty-dbbliss--queries (make-hash-table :test #'equal)
  "Query id -> plist (:connection :conn-id :sql :rows :on-done :paused ...).")
(defvar kitty-dbbliss--scripts (make-hash-table :test #'equal)
  "Connection id -> t while a script runs on it.")
(defvar kitty-dbbliss--seq 0)
(defvar kitty-dbbliss--caches (make-hash-table :test #'equal)
  "Connection id -> plist (:names LIST :loading B :columns HASH).")

(defvar kitty-dbbliss--handlers)

;;;; Finding the backend

(defun kitty-dbbliss--rid ()
  "The .NET runtime identifier the backend is published for."
  (concat (if (eq system-type 'windows-nt) "win-" "linux-")
          (if (string-match-p "\\`\\(aarch64\\|arm64\\)" system-configuration) "arm64" "x64")))

(defun kitty-dbbliss--exe-name ()
  (if (eq system-type 'windows-nt) "dbbliss-backend.exe" "dbbliss-backend"))

(defun kitty-dbbliss--nvim-data-dir ()
  "Neovim's stdpath(\"data\")."
  (if (eq system-type 'windows-nt)
      (expand-file-name "nvim-data" (or (getenv "LOCALAPPDATA") "~/AppData/Local"))
    (expand-file-name "nvim" (or (getenv "XDG_DATA_HOME") "~/.local/share"))))

(defun kitty-dbbliss--plugin-dirs ()
  "Checkouts of dbbliss.nvim, my-nvim's first."
  (list (expand-file-name "site/pack/core/opt/dbbliss.nvim" (kitty-dbbliss--nvim-data-dir))
        kitty-dbbliss-checkout))

(defun kitty-dbbliss-backend-path ()
  "The backend executable to start, or nil when there is none."
  (seq-find
   (lambda (f) (and f (not (string-empty-p f)) (file-executable-p f) (not (file-directory-p f))))
   (append (list kitty-dbbliss-backend (getenv "DBBLISS_BACKEND"))
           (mapcar (lambda (dir)
                     (expand-file-name (concat "bin/" (kitty-dbbliss--rid) "/" (kitty-dbbliss--exe-name)) dir))
                   (kitty-dbbliss--plugin-dirs))
           (list (executable-find "dbbliss-backend")))))

(defun kitty-dbbliss-build ()
  "Build the backend (needs the .NET 10 SDK); clones dbbliss.nvim first when there is none."
  (interactive)
  (let ((dir (or (seq-find (lambda (d) (file-directory-p (expand-file-name "backend" d)))
                           (kitty-dbbliss--plugin-dirs))
                 kitty-dbbliss-checkout)))
    (unless (executable-find "dotnet")
      (user-error "dbbliss: building the backend needs the .NET 10 SDK (dotnet) on PATH"))
    (let ((default-directory (file-name-directory (directory-file-name dir)))
          ;; plain lines: restore errors are printed, not only counted
          (compilation-environment (cons "MSBUILDTERMINALLOGGER=off" compilation-environment))
          (build (if (eq system-type 'windows-nt)
                     (format "powershell -NoProfile -ExecutionPolicy Bypass -File %s"
                             (shell-quote-argument (expand-file-name "scripts/build.ps1" dir)))
                   (shell-quote-argument (expand-file-name "scripts/build.sh" dir)))))
      (compile (if (file-directory-p dir)
                   build
                 (format "git clone https://github.com/DavySc/dbbliss.nvim %s && %s"
                         (shell-quote-argument dir) build))))))

;;;; Transport: one backend process, line-delimited JSON-RPC

(defvar kitty-dbbliss--process nil)
(defvar kitty-dbbliss--partial "")
(defvar kitty-dbbliss--next-id 0)
(defvar kitty-dbbliss--pending (make-hash-table :test #'eql)
  "Request id -> callback (ERR RESULT).")
(defvar kitty-dbbliss--send-function #'kitty-dbbliss--send-to-process
  "Writes one encoded message.  Tests replace it.")

(defun kitty-dbbliss--json-read (line)
  (json-parse-string line :object-type 'plist :null-object nil :false-object :false))

(defun kitty-dbbliss--params (&rest plist)
  "PLIST without its nil values (JSON has no nil; an empty object is not absent)."
  (let (out)
    (while plist
      (let ((k (pop plist)) (v (pop plist)))
        (unless (null v) (setq out (cons v (cons k out))))))
    (nreverse out)))

(defun kitty-dbbliss--send-to-process (string)
  (process-send-string kitty-dbbliss--process string))

(defun kitty-dbbliss-running-p ()
  "Non-nil while the backend process is up (or a test stands in for it)."
  (or (not (eq kitty-dbbliss--send-function #'kitty-dbbliss--send-to-process))
      (process-live-p kitty-dbbliss--process)))

(defun kitty-dbbliss--request (method params &optional callback)
  "Send METHOD with PARAMS (a plist); CALLBACK gets (ERR RESULT) when it is answered."
  (if (not (kitty-dbbliss-running-p))
      (when callback (funcall callback (list :code -1 :message "backend is not running") nil))
    (let ((id (cl-incf kitty-dbbliss--next-id)))
      (puthash id (or callback
                      (lambda (err _)
                        (when err (kitty-dbbliss--notify "%s failed: %s" method (plist-get err :message)))))
               kitty-dbbliss--pending)
      (funcall kitty-dbbliss--send-function
               (concat (json-serialize (list :jsonrpc "2.0" :id id :method method
                                             :params (or params (make-hash-table))))
                       "\n"))
      id)))

(defun kitty-dbbliss--filter (_proc output)
  (let ((text (concat kitty-dbbliss--partial output))
        (start 0))
    (while (string-match "\n" text start)
      (let ((line (string-trim-right (substring text start (match-beginning 0)) "\r")))
        (setq start (match-end 0))
        (unless (string-empty-p line)
          (condition-case err
              (kitty-dbbliss--dispatch (kitty-dbbliss--json-read line))
            (json-error
             (kitty-dbbliss--notify "invalid message from the backend: %s" (truncate-string-to-width line 200)))
            (error
             (kitty-dbbliss--notify "handling %s failed: %s"
                                    (truncate-string-to-width line 80) (error-message-string err)))))))
    (setq kitty-dbbliss--partial (substring text start))))

(defun kitty-dbbliss--dispatch (msg)
  "Route one message from the backend: a response or a notification."
  (let ((id (plist-get msg :id)))
    (cond
     ((and id (or (plist-member msg :result) (plist-member msg :error)))
      (let ((cb (gethash id kitty-dbbliss--pending)))
        (remhash id kitty-dbbliss--pending)
        (when cb (funcall cb (plist-get msg :error) (plist-get msg :result)))))
     ((plist-get msg :error)
      (kitty-dbbliss--notify "backend error: %s" (plist-get (plist-get msg :error) :message)))
     ((plist-get msg :method)
      (let ((handler (alist-get (plist-get msg :method) kitty-dbbliss--handlers nil nil #'equal)))
        (if handler
            (funcall handler (plist-get msg :params))
          (kitty-dbbliss--notify "unhandled backend notification %s" (plist-get msg :method))))))))

(defun kitty-dbbliss--log-file ()
  (expand-file-name "dbbliss-backend.log" kitty-cache-dir))

(defun kitty-dbbliss--start ()
  "Start the backend unless it runs."
  (unless (kitty-dbbliss-running-p)
    (let ((exe (or (kitty-dbbliss-backend-path)
                   (user-error "dbbliss: no backend found.  Build it: :Dbbliss build in Neovim, or M-x kitty-dbbliss-build (needs the .NET 10 SDK)")))
          (stderr (get-buffer-create " *dbbliss-backend stderr*")))
      (setq kitty-dbbliss--partial "")
      (setq kitty-dbbliss--process
            (make-process :name "dbbliss-backend"
                          :command (list exe)
                          :connection-type 'pipe
                          :coding 'utf-8-unix
                          :noquery t
                          :stderr stderr
                          :filter #'kitty-dbbliss--filter
                          :sentinel #'kitty-dbbliss--sentinel))
      (kitty-dbbliss--request "initialize" nil
                              (lambda (err result)
                                (if err
                                    (kitty-dbbliss--notify "initialize failed: %s" (plist-get err :message))
                                  (setq kitty-dbbliss--backend-info result))))))
  t)


(defun kitty-dbbliss--sentinel (proc _event)
  (unless (process-live-p proc)
    (when (eq proc kitty-dbbliss--process)
      (kitty-dbbliss--backend-gone (process-exit-status proc)))))

(defun kitty-dbbliss--backend-gone (code)
  "The backend exited with CODE: every request, query and connection is gone."
  (let ((pending kitty-dbbliss--pending)
        (had (> (hash-table-count kitty-dbbliss--connections) 0)))
    (setq kitty-dbbliss--pending (make-hash-table :test #'eql))
    (maphash (lambda (_ cb)
               (funcall cb (list :code -1 :message (format "backend exited (code %s)" code)) nil))
             pending)
    (maphash (lambda (id q)
               (kitty-dbbliss--note (format "-- query %s LOST: backend exited (code %s)" id code) 'error)
               (when-let* ((done (plist-get q :on-done)))
                 (funcall done (list :query_id id :status "lost"))))
             kitty-dbbliss--queries)
    (clrhash kitty-dbbliss--queries)
    (clrhash kitty-dbbliss--scripts)
    (clrhash kitty-dbbliss--connections)
    (clrhash kitty-dbbliss--caches)
    (setq kitty-dbbliss--current nil kitty-dbbliss--recent nil)
    (kitty-dbbliss--unbind nil)
    (force-mode-line-update t)
    (when (or had (not (eql code 0)))
      (kitty-dbbliss--notify "backend exited (code %s); all connections are gone" code))))

(defun kitty-dbbliss--notify (format-string &rest args)
  (message "dbbliss: %s" (apply #'format format-string args)))

;;;; Connections and the buffers bound to them


(defvar-local kitty-dbbliss-buffer-connection nil
  "The connection this buffer's statements run on (a name), once bound.")

(defun kitty-dbbliss--config (name)
  (cdr (assoc name kitty-dbbliss-connections)))

(defun kitty-dbbliss--check-config (name cfg)
  "Signal an error unless CFG, connection NAME's settings, is usable."
  (unless (and (plist-get cfg :engine) (plist-get cfg :connection-string))
    (user-error "dbbliss: connection %s needs :engine and :connection-string" name))
  (when-let* ((pw (plist-get cfg :password)))
    (unless (and (consp pw) (= (length pw) 2) (memq (car pw) '(:env :credman :pass :libsecret)))
      (user-error "dbbliss: connection %s: :password must be a reference like (:env \"NAME\") or (:credman \"target\"), not a password"
                  name))))

(defun kitty-dbbliss--connection-by-id (id)
  "(NAME . PLIST) of the open connection with backend id ID."
  (catch 'found
    (maphash (lambda (name c) (when (equal (plist-get c :id) id) (throw 'found (cons name c))))
             kitty-dbbliss--connections)
    nil))

(defun kitty-dbbliss--set (name prop value)
  (when-let* ((c (gethash name kitty-dbbliss--connections)))
    (puthash name (plist-put c prop value) kitty-dbbliss--connections)))

(defun kitty-dbbliss--make-current (name)
  (setq kitty-dbbliss--recent (cons name (delete name kitty-dbbliss--recent))
        kitty-dbbliss--current name))

(defun kitty-dbbliss--bind (buffer name)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (derived-mode-p 'sql-mode)
        (setq kitty-dbbliss-buffer-connection name)
        (when (fboundp 'kitty-sql-apply-dialect) (kitty-sql-apply-dialect))))))

(defun kitty-dbbliss--unbind (name)
  "Unbind the buffers bound to NAME (nil: to any).  Return how many there were."
  (let ((n 0))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and kitty-dbbliss-buffer-connection
                   (or (null name) (equal kitty-dbbliss-buffer-connection name)))
          (setq kitty-dbbliss-buffer-connection nil n (1+ n)))))
    n))

(defun kitty-dbbliss--target (&optional buffer)
  "(NAME PLIST BOUND) of the connection BUFFER runs on: its own, else the default."
  (with-current-buffer (or buffer (current-buffer))
    (let ((own (and kitty-dbbliss-buffer-connection
                     (gethash kitty-dbbliss-buffer-connection kitty-dbbliss--connections))))
      (cond (own (list kitty-dbbliss-buffer-connection own t))
            ((and kitty-dbbliss--current (gethash kitty-dbbliss--current kitty-dbbliss--connections))
             (list kitty-dbbliss--current (gethash kitty-dbbliss--current kitty-dbbliss--connections) nil))))))

(defun kitty-dbbliss-engine (&optional buffer)
  "The engine (\"sqlserver\", \"postgres\") BUFFER's statements run on, or nil."
  (plist-get (nth 1 (kitty-dbbliss--target buffer)) :engine))

(defun kitty-dbbliss--current-connection (&optional bind)
  "(NAME . PLIST) this buffer acts on, or nil with a message.
BIND: binds an unbound buffer to the default (asking first on prod)."
  (pcase (kitty-dbbliss--target)
    ('nil (kitty-dbbliss--notify "not connected; SPC m c (or :Dbbliss connect) first") nil)
    (`(,name ,conn ,bound)
     (if (or bound (not bind) (not (derived-mode-p 'sql-mode)))
         (cons name conn)
       (when (or (not (equal (plist-get (kitty-dbbliss--config name) :env) "prod"))
                 (yes-or-no-p (format "This buffer has no connection.  Use %s (PROD)? " name)))
         (kitty-dbbliss--bind (current-buffer) name)
         (kitty-dbbliss--notify "this buffer now uses %s" name)
         (cons name conn))))))

(defun kitty-dbbliss--read-connection (prompt &optional open-only)
  (let ((names (if open-only (hash-table-keys kitty-dbbliss--connections)
                 (mapcar #'car kitty-dbbliss-connections))))
    (unless names
      (user-error (if open-only "dbbliss: nothing is connected"
                    "dbbliss: no connections configured (kitty-dbbliss-connections in local.el)")))
    (completing-read prompt names nil t)))

(defun kitty-dbbliss-connect (name &optional callback)
  "Open connection NAME (from `kitty-dbbliss-connections') and bind this buffer to it.
CALLBACK gets (ERR PLIST) when the connection is open or failed."
  (interactive (list (kitty-dbbliss--read-connection "Connect to: ")))
  (let ((cfg (kitty-dbbliss--config name))
        (from (current-buffer)))
    (unless cfg (user-error "dbbliss: unknown connection %s" name))
    (kitty-dbbliss--check-config name cfg)
    (cond
     ((gethash name kitty-dbbliss--connections)
      ;; A second session under the same name would orphan the first, with its
      ;; transaction and locks: the open one becomes current instead.
      (kitty-dbbliss-use name)
      (when callback (funcall callback nil (gethash name kitty-dbbliss--connections))))
     ((member name kitty-dbbliss--connecting)
      (kitty-dbbliss--notify "%s is already connecting" name))
     (t
      (kitty-dbbliss--start)
      (push name kitty-dbbliss--connecting)
      (kitty-dbbliss--notify "connecting to %s ..." name)
      (kitty-dbbliss--request
       "connect"
       (kitty-dbbliss--params :engine (plist-get cfg :engine)
                              :connection_string (plist-get cfg :connection-string)
                              :password (kitty-dbbliss--password (plist-get cfg :password))
                              :options (kitty-dbbliss--alist-to-plist (plist-get cfg :options))
                              :env (plist-get cfg :env))
       (lambda (err result)
         (setq kitty-dbbliss--connecting (delete name kitty-dbbliss--connecting))
         (if err
             (kitty-dbbliss--notify "connect %s failed: %s" name (plist-get err :message))
           (puthash name (list :id (plist-get result :connection_id)
                               :engine (plist-get result :engine)
                               :server-session (plist-get result :server_session_id)
                               :transaction "none")
                    kitty-dbbliss--connections)
           (kitty-dbbliss--make-current name)
           (kitty-dbbliss--bind from name)
           (force-mode-line-update t)
           (kitty-dbbliss--notify "connected to %s (%s, session %s)" name
                                  (plist-get result :engine) (plist-get result :server_session_id)))
         (when callback (funcall callback err (gethash name kitty-dbbliss--connections)))))))))

(defun kitty-dbbliss--password (ref)
  "REF, a password reference, as the backend reads it."
  (pcase ref
    ('nil nil)
    (`(:libsecret ,spec) (list :libsecret (kitty-dbbliss--alist-to-plist spec)))
    (`(,key ,value) (list key value))))

(defun kitty-dbbliss--alist-to-plist (x)
  "X as a plist for JSON: an alist ((\"A\" . 1)) or a plist (:a 1) as given."
  (cond ((null x) nil)
        ((keywordp (car-safe x)) x)
        ((consp (car-safe x))
         (cl-loop for (k . v) in x
                  append (list (intern (concat ":" (if (symbolp k) (symbol-name k) k)))
                               (if (consp v) (kitty-dbbliss--alist-to-plist v) v))))
        (t x)))

(defun kitty-dbbliss-use (name)
  "Bind this buffer to the open connection NAME and make it the default."
  (interactive (list (kitty-dbbliss--read-connection "Use: " t)))
  (unless (gethash name kitty-dbbliss--connections)
    (user-error "dbbliss: %s is not connected" name))
  (kitty-dbbliss--make-current name)
  (kitty-dbbliss--bind (current-buffer) name)
  (force-mode-line-update t)
  (kitty-dbbliss--notify "using %s" name))

(defun kitty-dbbliss-disconnect (&optional name)
  "Close connection NAME (default: this buffer's); asks before rolling back a transaction."
  (interactive (list (and current-prefix-arg (kitty-dbbliss--read-connection "Disconnect: " t))))
  (let* ((name (or name (car (kitty-dbbliss--current-connection)) (user-error "Nothing to disconnect")))
         (conn (or (gethash name kitty-dbbliss--connections) (user-error "dbbliss: %s is not connected" name)))
         (id (plist-get conn :id)))
    (cl-labels
        ((ask () (yes-or-no-p (format "%s has an open transaction.  Roll it back and disconnect? " name)))
         (close (rollback)
           (kitty-dbbliss--request
            "disconnect" (kitty-dbbliss--params :connection_id id :rollback (and rollback t))
            (lambda (err _)
              (cond
               ((and err (eql (plist-get err :code) 1003) (not rollback))
                ;; The server knows of a transaction this client has not heard of.
                (when (ask) (close t)))
               (err (kitty-dbbliss--notify "disconnect failed: %s" (plist-get err :message)))
               (t
                (remhash name kitty-dbbliss--connections)
                (remhash id kitty-dbbliss--caches)
                (setq kitty-dbbliss--recent (delete name kitty-dbbliss--recent))
                (let ((n (kitty-dbbliss--unbind name)) (hint ""))
                  (when (> n 0) (setq hint (format "; %d buffer(s) unbound" n)))
                  (when (equal kitty-dbbliss--current name)
                    (setq kitty-dbbliss--current (car kitty-dbbliss--recent))
                    (when kitty-dbbliss--current
                      (setq hint (concat hint "; the default is now " kitty-dbbliss--current))))
                  (force-mode-line-update t)
                  (kitty-dbbliss--notify "disconnected from %s%s" name hint))))))))
      (if (equal (plist-get conn :transaction) "none")
          (close nil)
        (when (ask) (close t))))))

(defun kitty-dbbliss-status ()
  "Open connections (> this buffer's, * the default) and running queries."
  (interactive)
  (let ((here (car (kitty-dbbliss--target))) lines)
    (dolist (name (append kitty-dbbliss--recent
                          (seq-difference (sort (hash-table-keys kitty-dbbliss--connections) #'string<)
                                          kitty-dbbliss--recent)))
      (when-let* ((c (gethash name kitty-dbbliss--connections)))
        (push (format "%s%s %s [%s/%s] session %s, transaction %s"
                      (if (equal name here) ">" " ") (if (equal name kitty-dbbliss--current) "*" " ")
                      name (plist-get c :engine) (or (plist-get (kitty-dbbliss--config name) :env) "?")
                      (plist-get c :server-session) (plist-get c :transaction))
              lines)))
    (maphash (lambda (id q) (push (format "  running %s on %s (%d rows so far)" id
                                          (plist-get q :connection) (plist-get q :rows))
                                  lines))
             kitty-dbbliss--queries)
    (message "%s" (if lines (string-join (nreverse lines) "\n") "dbbliss: no connections"))))

;;;; Running statements


(defun kitty-dbbliss--utf16-col (line-text column)
  "COLUMN (characters) of LINE-TEXT in UTF-16 code units, as the backend counts."
  (let ((n 0))
    (dotimes (i (min column (length line-text)))
      (setq n (+ n (if (> (aref line-text i) #xFFFF) 2 1))))
    n))

(defun kitty-dbbliss-pick (statements line col)
  "The statement of STATEMENTS (from script/split) under LINE, COL (0-based, UTF-16).
The last one that starts at or before it, else the first."
  (let (picked)
    (catch 'done
      (seq-doseq (s statements)
        (let ((sl (plist-get (plist-get s :start) :line))
              (sc (plist-get (plist-get s :start) :col)))
          (if (or (< sl line) (and (= sl line) (<= sc col)))
              (setq picked s)
            (throw 'done nil)))))
    (or picked (and (> (length statements) 0) (aref statements 0)))))

(defun kitty-dbbliss-expand (statements base-line)
  "The queue to run: STATEMENTS in order, each repeated by its GO count.
BASE-LINE is the 0-based buffer line of the split text's first line."
  (let ((count (length statements)) (i 0) queue)
    (seq-doseq (s statements)
      (setq i (1+ i))
      (dotimes (_ (max 1 (or (plist-get s :repeat) 1)))
        (push (list :text (plist-get s :text)
                    :line-offset (+ base-line (plist-get (plist-get s :start) :line))
                    :index i :count count
                    :ddl (eq (plist-get s :ddl) t))
              queue)))
    (nreverse queue)))

(defun kitty-dbbliss--confirm-writes (name statements)
  "On a prod connection, confirm STATEMENTS that can change data, all at once."
  (let ((writes (seq-remove (lambda (s) (equal (plist-get s :kind) "read")) statements)))
    (or (not (equal (plist-get (kitty-dbbliss--config name) :env) "prod"))
        (null writes)
        (yes-or-no-p
         (format "PROD %s: %d of %d statement(s) can change data:\n%s\nRun? "
                 name (length writes) (length statements)
                 (mapconcat (lambda (s)
                              (format "  line %d: %s" (1+ (plist-get (plist-get s :start) :line))
                                      (truncate-string-to-width
                                       (replace-regexp-in-string "[ \t\n\r]+" " " (plist-get s :text)) 70 nil nil "...")))
                            (seq-take writes 5) "\n"))))))

(defun kitty-dbbliss--with-statements (scope callback &optional skip-confirm)
  "Split this buffer's SCOPE (`statement', `buffer' or `region') and call CALLBACK.
CALLBACK gets (NAME CONN-ID BUFFER STATEMENTS BASE-LINE); the connection is
marked as running a script until CALLBACK's work clears it."
  (when-let* ((target (kitty-dbbliss--current-connection t)))
    (let* ((name (car target)) (conn (cdr target)) (conn-id (plist-get conn :id))
           (buffer (current-buffer))
           (first (if (eq scope 'region)
                      (line-number-at-pos (region-beginning))
                    1))
           (last (if (eq scope 'region)
                     (line-number-at-pos (if (and (> (region-end) (region-beginning))
                                                  (save-excursion (goto-char (region-end)) (bolp)))
                                             (1- (region-end))
                                           (region-end)))
                   (line-number-at-pos (point-max))))
           (text (save-restriction
                   (widen)
                   (save-excursion
                     (buffer-substring-no-properties
                      (progn (goto-char (point-min)) (forward-line (1- first)) (point))
                      (progn (goto-char (point-min)) (forward-line (1- last)) (line-end-position))))))
           (cursor-line (- (line-number-at-pos) first))
           (cursor-col (kitty-dbbliss--utf16-col (buffer-substring-no-properties (line-beginning-position) (line-end-position))
                                                 (current-column))))
      (when (eq scope 'region) (deactivate-mark))
      (if (gethash conn-id kitty-dbbliss--scripts)
          (kitty-dbbliss--notify "a script is already running on %s; cancel it first" name)
        (kitty-dbbliss--clear-errors buffer)
        (puthash conn-id t kitty-dbbliss--scripts)
        (kitty-dbbliss--request
         "script/split" (list :engine (plist-get conn :engine) :text text)
         (lambda (err result)
           (let ((statements (and result (plist-get result :statements))))
             (when (and statements (eq scope 'statement))
               (setq statements (if (> (length statements) 0)
                                    (vector (kitty-dbbliss-pick statements cursor-line cursor-col))
                                  [])))
             (cond
              (err (remhash conn-id kitty-dbbliss--scripts)
                   (kitty-dbbliss--notify "could not split the script: %s" (plist-get err :message)))
              ((= (length statements) 0)
               (remhash conn-id kitty-dbbliss--scripts)
               (kitty-dbbliss--notify "nothing to run"))
              ((and (not skip-confirm)
                    (not (with-current-buffer buffer
                           (kitty-dbbliss--confirm-writes name (append statements nil)))))
               (remhash conn-id kitty-dbbliss--scripts)
               (kitty-dbbliss--notify "cancelled: nothing was run on %s" name))
              (t
               (kitty-dbbliss--bind buffer name)
               (funcall callback name conn-id buffer statements (1- first)))))))))))

(defun kitty-dbbliss-execute (sql &rest opts)
  "Run SQL on the current connection, or OPTS' :connection.
OPTS: :line-offset (0-based buffer line SQL starts on, for errors),
:window (rows per page, default `kitty-dbbliss-window-rows'; :none for all),
:export (:path P :overwrite B), :on-done (called with the query/done
params, or a :status \"not_started\" plist when refused), :quiet (no
results buffer).  Return the query id."
  (let* ((name (or (plist-get opts :connection) (car (kitty-dbbliss--current-connection))))
         (conn (and name (gethash name kitty-dbbliss--connections))))
    (if (not conn)
        (progn (when name (kitty-dbbliss--notify "%s is no longer connected" name)) nil)
      (let* ((query-id (format "q%d-%d" (emacs-pid) (cl-incf kitty-dbbliss--seq)))
             (window (plist-get opts :window))
             (window (cond ((plist-get opts :export) nil)
                           ((eq window :none) nil)
                           (t (or window kitty-dbbliss-window-rows))))
             (on-done (plist-get opts :on-done)))
        (puthash query-id (list :connection name :conn-id (plist-get conn :id) :sql sql
                                :rows 0 :on-done on-done :quiet (plist-get opts :quiet)
                                :sink (plist-get opts :sink))
                 kitty-dbbliss--queries)
        (force-mode-line-update t)
        (unless (plist-get opts :quiet)
          (kitty-dbbliss--show-results)
          (kitty-dbbliss--note "")
          (kitty-dbbliss--note (format "-- %s on %s" query-id name) 'info))
        (kitty-dbbliss--request
         "execute"
         (kitty-dbbliss--params :connection_id (plist-get conn :id) :query_id query-id :sql sql
                                :line_offset (plist-get opts :line-offset)
                                :window window :export (plist-get opts :export))
         (lambda (err _)
           (when err
             (remhash query-id kitty-dbbliss--queries)
             (unless (plist-get opts :quiet)
               (kitty-dbbliss--note (concat "-- not started: " (plist-get err :message)) 'error))
             (let ((exists (plist-get (plist-get err :data) :exists)))
               (unless (and (plist-get opts :export) exists)
                 (kitty-dbbliss--notify "execute failed: %s" (plist-get err :message))))
             (when on-done
               (funcall on-done (list :query_id query-id :status "not_started"
                                      :error (list :message (plist-get err :message))
                                      :request-error err))))))
        query-id))))

(defun kitty-dbbliss--run-queue (name conn-id buffer queue)
  "Run QUEUE one statement at a time on NAME; stop at the first that does not complete."
  (let ((noun (if (equal (kitty-dbbliss-engine buffer) "sqlserver") "batch" "statement")))
    (cl-labels
        ((finish () (remhash conn-id kitty-dbbliss--scripts))
         (step (rest)
           (if (null rest)
               (finish)
             (let* ((unit (car rest))
                    (qid (kitty-dbbliss-execute
                          (plist-get unit :text)
                          :connection name :line-offset (plist-get unit :line-offset)
                          :on-done
                          (lambda (p)
                            (if (equal (plist-get p :status) "completed")
                                (progn (when (plist-get unit :ddl) (kitty-dbbliss--schema-changed name))
                                       (step (cdr rest)))
                              (let ((e (plist-get p :error))
                                    (left (1- (length rest))))
                                (when-let* ((line (plist-get e :buffer_line)))
                                  (kitty-dbbliss--set-error buffer line (plist-get e :message)))
                                (kitty-dbbliss--note
                                 (format "-- stopped: %s %d of %d (buffer line %d) %s%s"
                                         noun (plist-get unit :index) (plist-get unit :count)
                                         (1+ (plist-get unit :line-offset))
                                         (if (equal (plist-get p :status) "not_started")
                                             "was not started" (plist-get p :status))
                                         (if (> left 0) (format "; %d not run" left) ""))
                                 'error)
                                (finish)))))))
               (unless qid (finish))))))
      (step queue))))

(defun kitty-dbbliss-run (scope)
  "Run SCOPE of this buffer: `statement' (under the cursor), `region' or `buffer'."
  (kitty-dbbliss--with-statements
   scope
   (lambda (name conn-id buffer statements base-line)
     (kitty-dbbliss--clear-results)
     (kitty-dbbliss--run-queue name conn-id buffer (kitty-dbbliss-expand statements base-line)))))

(defun kitty-dbbliss-exec ()
  "Run the statement under the cursor (SQL Server: the GO batch), or the selected lines."
  (interactive)
  (kitty-dbbliss-run (if (use-region-p) 'region 'statement)))

(defun kitty-dbbliss-exec-buffer ()
  "Run the whole buffer, one statement (batch) at a time."
  (interactive)
  (kitty-dbbliss-run 'buffer))

(defun kitty-dbbliss-exec-ssms ()
  "F5, as in SSMS: the selection, else the whole buffer."
  (interactive)
  (kitty-dbbliss-run (if (use-region-p) 'region 'buffer)))

(defun kitty-dbbliss-cancel (&optional query-id)
  "Cancel the running query of this buffer's connection (or QUERY-ID)."
  (interactive)
  (let ((name (car (kitty-dbbliss--target))))
    (unless query-id
      (maphash (lambda (id q) (when (equal (plist-get q :connection) name) (setq query-id id)))
               kitty-dbbliss--queries))
    (if (not query-id)
        (kitty-dbbliss--notify "no running query")
      (when-let* ((q (gethash query-id kitty-dbbliss--queries)))
        (when (plist-get q :paused)
          (puthash query-id (plist-put q :discard t) kitty-dbbliss--queries)))
      (kitty-dbbliss--request
       "cancel" (list :query_id query-id)
       (lambda (err result)
         (cond (err (kitty-dbbliss--notify "cancel failed: %s" (plist-get err :message)))
               ((equal (plist-get result :state) "not_running")
                (kitty-dbbliss--notify "query %s was no longer running" query-id))
               (t (kitty-dbbliss--notify "cancel sent for %s" query-id))))))))

(defun kitty-dbbliss-fetch (query-id rows)
  "Let the paused QUERY-ID send ROWS more rows."
  (when-let* ((q (gethash query-id kitty-dbbliss--queries)))
    (puthash query-id (plist-put q :paused nil) kitty-dbbliss--queries))
  (kitty-dbbliss--request
   "fetch" (list :query_id query-id :rows rows)
   (lambda (err result)
     (cond (err (kitty-dbbliss--notify "fetch failed: %s" (plist-get err :message)))
           ((equal (plist-get result :state) "not_running")
            (kitty-dbbliss--notify "the query had already ended"))))))

(defun kitty-dbbliss-export (path)
  "Write the result of the statement under the cursor to the CSV file PATH.
The backend writes it; the rows never pass through Emacs."
  (interactive (list (expand-file-name (read-file-name "Export to CSV: " nil nil nil "result.csv"))))
  (kitty-dbbliss--with-statements
   (if (use-region-p) 'region 'statement)
   (lambda (name conn-id _buffer statements base-line)
     (if (/= (length statements) 1)
         (progn (remhash conn-id kitty-dbbliss--scripts)
                (kitty-dbbliss--notify "export takes one statement, got %d" (length statements)))
       (let ((unit (car (kitty-dbbliss-expand statements base-line))))
         (cl-labels
             ((go (overwrite)
                (kitty-dbbliss-execute
                 (plist-get unit :text) :connection name :line-offset (plist-get unit :line-offset)
                 :export (kitty-dbbliss--params :path path :overwrite (and overwrite t))
                 :on-done
                 (lambda (p)
                   (if (and (plist-get (plist-get (plist-get p :request-error) :data) :exists)
                            (not overwrite)
                            (yes-or-no-p (format "%s exists.  Replace it? " path)))
                       (go t)
                     (remhash conn-id kitty-dbbliss--scripts))))))
           (go nil)))))))

;;;; Transactions

(defun kitty-dbbliss--transaction (method)
  (when-let* ((target (kitty-dbbliss--current-connection t)))
    (let ((id (plist-get (cdr target) :id)))
      (kitty-dbbliss--request
       (concat "transaction/" method) (list :connection_id id)
       (lambda (err result)
         (if err
             (kitty-dbbliss--notify "%s failed: %s" method (plist-get err :message))
           (when-let* ((found (kitty-dbbliss--connection-by-id id)))
             (kitty-dbbliss--transaction-state (car found) (plist-get result :transaction))
             (kitty-dbbliss--notify "%s on %s: transaction %s" method (car found)
                                    (plist-get result :transaction)))))))))

(defun kitty-dbbliss--transaction-state (name state)
  "Connection NAME's transaction is now STATE (none, active, aborted, unknown)."
  (let* ((conn (gethash name kitty-dbbliss--connections))
         (was (plist-get conn :transaction)))
    (kitty-dbbliss--set name :transaction state)
    (when (and (not (equal was "none")) (equal state "none"))
      (kitty-dbbliss--set name :ddl-in-tx nil))
    (force-mode-line-update t)))

(defun kitty-dbbliss-begin () "Begin a transaction." (interactive) (kitty-dbbliss--transaction "begin"))
(defun kitty-dbbliss-commit () "Commit." (interactive) (kitty-dbbliss--transaction "commit"))
(defun kitty-dbbliss-rollback () "Roll back." (interactive) (kitty-dbbliss--transaction "rollback"))

(defun kitty-dbbliss--schema-changed (name)
  "A statement changed the schema on NAME: names are reloaded (after the transaction)."
  (when-let* ((conn (gethash name kitty-dbbliss--connections)))
    (if (equal (plist-get conn :transaction) "none")
        (remhash (plist-get conn :id) kitty-dbbliss--caches)
      (kitty-dbbliss--set name :ddl-in-tx t))))

;;;; Notifications

(defun kitty-dbbliss--on-resultset (p)
  (let ((q (gethash (plist-get p :query_id) kitty-dbbliss--queries)))
    (if-let* ((sink (plist-get q :sink)))
        (funcall sink 'resultset p)
      (kitty-dbbliss--results-resultset p))))

(defun kitty-dbbliss--on-rows (p)
  (let* ((qid (plist-get p :query_id))
         (q (gethash qid kitty-dbbliss--queries))
         (n (length (plist-get p :rows))))
    (when q
      (setq q (plist-put q :rows (+ n (plist-get q :rows))))
      (when (plist-get q :discard)
        ;; Cancelled while paused: rows already on their way are counted, not drawn.
        (setq q (plist-put q :discarded (+ n (or (plist-get q :discarded) 0)))))
      (puthash qid q kitty-dbbliss--queries))
    (cond ((and q (plist-get q :discard)))
          ((plist-get q :sink) (funcall (plist-get q :sink) 'rows p))
          (t (kitty-dbbliss--results-rows p)))))

(defun kitty-dbbliss--on-resultset-done (p)
  (let ((q (gethash (plist-get p :query_id) kitty-dbbliss--queries)))
    (if-let* ((sink (plist-get q :sink)))
        (funcall sink 'resultset_done p)
      (kitty-dbbliss--results-resultset-done p))))

(defun kitty-dbbliss--on-paused (p)
  (let* ((qid (plist-get p :query_id)) (q (gethash qid kitty-dbbliss--queries)))
    (when q (puthash qid (plist-put q :paused t) kitty-dbbliss--queries))
    (if (plist-get q :sink)
        (kitty-dbbliss-fetch qid kitty-dbbliss-window-rows)
      (kitty-dbbliss--results-paused p))))

(defun kitty-dbbliss--on-message (p)
  (let ((q (gethash (plist-get p :query_id) kitty-dbbliss--queries)))
    (if (plist-get q :sink)
        (funcall (plist-get q :sink) 'message p)
      (kitty-dbbliss--messages-add p)))
  (when (member (plist-get p :severity) '("warning" "error"))
    (kitty-dbbliss--notify "%s" (plist-get p :text))))

(defun kitty-dbbliss--on-done (p)
  (let* ((qid (plist-get p :query_id))
         (q (gethash qid kitty-dbbliss--queries))
         (quiet (or (plist-get q :quiet) (plist-get q :sink)))
         (e (plist-get p :error)))
    (remhash qid kitty-dbbliss--queries)
    (force-mode-line-update t)
    (unless quiet
      (kitty-dbbliss--results-query-ended qid)
      (kitty-dbbliss--note
       (concat (format "-- %s in %d ms" (plist-get p :status) (plist-get p :elapsed_ms))
               (if-let* ((c (plist-get p :cancel)))
                   (format " (cancel acknowledged after %d ms)" (plist-get c :ack_ms))
                 "")
               (if-let* ((n (plist-get p :rows_affected)))
                   (format "; %d row%s affected" n (if (= n 1) "" "s"))
                 ""))
       'info)
      (when (and q (plist-get q :discarded))
        (kitty-dbbliss--note (format "-- %d more rows had already arrived when the cancel was sent; they are not shown"
                                     (plist-get q :discarded))
                             'warning))
      (when-let* ((n (plist-get p :truncated_rows)))
        (kitty-dbbliss--note (format "-- %d rows were not shown (cancelled while more were arriving)" n) 'warning))
      (when-let* ((x (plist-get p :export)))
        (kitty-dbbliss--note (format "-- exported %d rows to %s%s" (plist-get x :rows) (plist-get x :path)
                                     (if (eq (plist-get x :complete) t) ""
                                       " (INCOMPLETE: the file ends where the query stopped)"))
                             (if (eq (plist-get x :complete) t) 'info 'error))
        (when (> (or (plist-get x :ignored_result_sets) 0) 0)
          (kitty-dbbliss--note (format "-- %d further result set(s) were not exported"
                                       (plist-get x :ignored_result_sets))
                               'warning)))
      (when e
        (let ((line (or (plist-get e :buffer_line) (plist-get e :line))))
          (kitty-dbbliss--note (format "-- error%s: %s" (if line (format " (line %s)" line) "")
                                       (plist-get e :message))
                               'error))
        (when (equal (plist-get p :status) "error")
          (kitty-dbbliss--notify "%s" (plist-get e :message)))))
    (when q
      (when-let* ((found (kitty-dbbliss--connection-by-id (plist-get q :conn-id)))
                  (state (plist-get p :transaction)))
        (let ((name (car found)) (was (plist-get (cdr found) :transaction)))
          (cond ((and (not (equal was "none")) (equal state "none"))
                 (if (equal (plist-get p :status) "completed")
                     (kitty-dbbliss--notify "the transaction on %s ended" name)
                   (kitty-dbbliss--notify "the server rolled back the transaction on %s" name)))
                ((equal state "aborted")
                 (kitty-dbbliss--notify "the transaction on %s is aborted: only rollback is possible" name)))
          (kitty-dbbliss--transaction-state name state)))
      (when-let* ((done (plist-get q :on-done)))
        (funcall done p)))))

(defun kitty-dbbliss--on-connection-message (p)
  (kitty-dbbliss--notify "[%s] %s" (plist-get p :severity) (plist-get p :text)))

(defvar kitty-dbbliss--handlers
  '(("query/resultset" . kitty-dbbliss--on-resultset)
    ("query/rows" . kitty-dbbliss--on-rows)
    ("query/resultset_done" . kitty-dbbliss--on-resultset-done)
    ("query/paused" . kitty-dbbliss--on-paused)
    ("query/message" . kitty-dbbliss--on-message)
    ("query/done" . kitty-dbbliss--on-done)
    ("connection/message" . kitty-dbbliss--on-connection-message)
    ("plan/done" . kitty-dbbliss--on-plan-done)
    ("backup/progress" . ignore)
    ("backup/done" . ignore))
  "Notification method -> handler.")

;;;; Rendering values and tables

(defconst kitty-dbbliss-separator " │ ")

(defun kitty-dbbliss-cell-text (v)
  "(TEXT . NULLP): value V from the backend, as shown."
  (cond ((null v) (cons "NULL" t))
        ((stringp v) (cons v nil))
        ((eq v t) (cons "true" nil))
        ((eq v :false) (cons "false" nil))
        ((integerp v) (cons (number-to-string v) nil))
        ((floatp v)
         (let ((s (format "%.15g" v)))
           (cons (if (= (string-to-number s) v) s (format "%.17g" v)) nil)))
        (t (cons (json-serialize v) nil))))

(defun kitty-dbbliss-raw-text (v)
  "Value V as yanked: NULL is empty, nothing is shortened."
  (let ((c (kitty-dbbliss-cell-text v))) (if (cdr c) "" (car c))))

(defun kitty-dbbliss--one-line (text)
  "TEXT on one line: line breaks as ↵, tabs as spaces, control characters as ·."
  (let ((s (replace-regexp-in-string "\r\n\\|[\r\n]" "↵" text t t)))
    (setq s (replace-regexp-in-string "\t" " " s t t))
    (replace-regexp-in-string "[\0-\x08\x0b\x0c\x0e-\x1f\x7f]" "·" s t t)))

(defun kitty-dbbliss-fit (text width &optional right)
  "TEXT padded or shortened (with …) to WIDTH columns; RIGHT aligns it right."
  (let* ((text (kitty-dbbliss--one-line text))
         (text (if (> (string-width text) width) (truncate-string-to-width text width nil nil "…") text))
         (pad (make-string (max 0 (- width (string-width text))) ?\s)))
    (if right (concat pad text) (concat text pad))))

(defun kitty-dbbliss-widths (names rows cap)
  "Column widths for column NAMES and ROWS (vectors), at most CAP each."
  (let ((widths (vconcat (mapcar (lambda (n) (max 1 (string-width (kitty-dbbliss--one-line n)))) names))))
    (dolist (row rows)
      (dotimes (i (length widths))
        (let* ((text (car (kitty-dbbliss-cell-text (and (< i (length row)) (aref row i)))))
               (w (if (> (length text) (* cap 4)) cap (string-width (kitty-dbbliss--one-line text)))))
          (when (> w (aref widths i)) (aset widths i w)))))
    (dotimes (i (length widths))
      (aset widths i (min (aref widths i) cap)))
    widths))

(defun kitty-dbbliss-format-row (row widths)
  "ROW (a vector) as one line of cells WIDTHS wide, NULLs dimmed."
  (let (parts)
    (dotimes (i (length widths))
      (let* ((v (and (< i (length row)) (aref row i)))
             (c (kitty-dbbliss-cell-text v))
             (cell (kitty-dbbliss-fit (car c) (aref widths i) (numberp v))))
        (push (if (cdr c) (propertize cell 'face 'shadow) cell) parts)))
    (mapconcat #'identity (nreverse parts) kitty-dbbliss-separator)))

(defun kitty-dbbliss-format-header (names widths)
  "(HEADER . RULE) lines for column NAMES."
  (let (cells rule (i 0))
    (dolist (n names)
      (push (kitty-dbbliss-fit n (aref widths i)) cells)
      (push (make-string (aref widths i) ?─) rule)
      (setq i (1+ i)))
    (cons (mapconcat #'identity (nreverse cells) kitty-dbbliss-separator)
          (mapconcat #'identity (nreverse rule) "─┼─"))))

(defun kitty-dbbliss-cell-starts (widths)
  "Column (0-based) each cell starts at."
  (let ((at 0) starts)
    (seq-doseq (w widths)
      (push at starts)
      (setq at (+ at w (length kitty-dbbliss-separator))))
    (vconcat (nreverse starts))))

;;;; The results buffer

(cl-defstruct (kitty-dbbliss--set (:constructor kitty-dbbliss--make-set))
  qid index columns widths starts header rows count)

(defvar kitty-dbbliss--sets nil "The result sets shown, in order.")
(defvar kitty-dbbliss--open (make-hash-table :test #'equal) "Query id -> the set being filled.")
(defvar kitty-dbbliss--paused nil "(QID . SET) of the query paused in the results buffer.")

(defconst kitty-dbbliss-results-buffer "*dbbliss results*")
(defconst kitty-dbbliss-messages-buffer "*dbbliss messages*")

(defvar-keymap kitty-dbbliss-results-mode-map
  "TAB" #'kitty-dbbliss-next-cell
  "<backtab>" #'kitty-dbbliss-previous-cell
  "g m" #'kitty-dbbliss-fetch-more
  "] ]" #'kitty-dbbliss-next-set
  "[ [" #'kitty-dbbliss-previous-set
  "m" #'kitty-dbbliss-show-messages
  "q" #'quit-window)

(define-derived-mode kitty-dbbliss-results-mode special-mode "dbbliss"
  "Query results: TAB / S-TAB cells, yc / yr / yC yank cell / row / column,
]] / [[ result sets, gm fetch more of a paused query, m messages, q close."
  (setq truncate-lines t
        buffer-undo-list t)
  (setq-local show-trailing-whitespace nil)
  (add-hook 'post-command-hook #'kitty-dbbliss--maybe-fetch nil t))

(defun kitty-dbbliss--results-buffer ()
  (or (get-buffer kitty-dbbliss-results-buffer)
      (with-current-buffer (get-buffer-create kitty-dbbliss-results-buffer)
        (kitty-dbbliss-results-mode)
        (current-buffer))))

(defun kitty-dbbliss--show-results ()
  "Show the results at the bottom, without selecting them."
  (let ((buf (kitty-dbbliss--results-buffer)))
    (unless (get-buffer-window buf)
      (display-buffer buf '((display-buffer-reuse-window display-buffer-at-bottom)
                            (window-height . 14)
                            (inhibit-same-window . t))))))

(defun kitty-dbbliss-show-results ()
  "Show and select the results."
  (interactive)
  (kitty-dbbliss--show-results)
  (select-window (get-buffer-window (kitty-dbbliss--results-buffer))))

(defun kitty-dbbliss--drop-paused-line ()
  (with-current-buffer (kitty-dbbliss--results-buffer)
    (let ((inhibit-read-only t))
      (save-excursion
        (goto-char (point-max))
        (forward-line -1)
        (when (get-text-property (point) 'kitty-dbbliss-paused)
          (delete-region (point) (point-max)))))))

(defun kitty-dbbliss--append (text)
  "Append TEXT (lines, with properties) to the results; return where it starts."
  (with-current-buffer (kitty-dbbliss--results-buffer)
    (kitty-dbbliss--drop-paused-line)
    (let* ((inhibit-read-only t)
           (follow (seq-filter (lambda (w) (= (window-point w) (point-max)))
                               (get-buffer-window-list (current-buffer) nil t)))
           (start (point-max)))
      (save-excursion
        (goto-char start)
        (insert text))
      (dolist (w follow) (set-window-point w (point-max)))
      start)))

(defun kitty-dbbliss--note (line &optional kind)
  "Append LINE (which may hold line breaks) to the results, in the face of KIND."
  (let ((face (pcase kind ('info 'shadow) ('error 'error) ('warning 'warning))))
    (kitty-dbbliss--append
     (concat (mapconcat (lambda (l) (if (and face (not (string-empty-p l))) (propertize l 'face face) l))
                        (split-string (string-replace "\r" "" line) "\n")
                        "\n")
             "\n"))))

(defun kitty-dbbliss--clear-results ()
  "A fresh run: the results and messages are emptied."
  (setq kitty-dbbliss--sets nil kitty-dbbliss--paused nil)
  (clrhash kitty-dbbliss--open)
  (dolist (b (list (get-buffer kitty-dbbliss-results-buffer) (get-buffer kitty-dbbliss-messages-buffer)))
    (when b (with-current-buffer b (let ((inhibit-read-only t)) (erase-buffer))))))

(defun kitty-dbbliss--results-resultset (p)
  (let ((set (kitty-dbbliss--make-set
              :qid (plist-get p :query_id) :index (plist-get p :result_set)
              :columns (mapcar (lambda (c) (plist-get c :name)) (plist-get p :columns)))))
    (setq kitty-dbbliss--sets (append kitty-dbbliss--sets (list set)))
    (puthash (plist-get p :query_id) set kitty-dbbliss--open)))

(defun kitty-dbbliss--block (set rows &optional header)
  "The text of SET's ROWS (with the HEADER and rule first), each line tagged."
  (let ((widths (kitty-dbbliss--set-widths set)) parts)
    (when header
      (let ((hr (kitty-dbbliss-format-header (kitty-dbbliss--set-columns set) widths)))
        (push (propertize (concat (car hr) "\n") 'face 'bold 'kitty-dbbliss-set set 'kitty-dbbliss-row :header)
              parts)
        (push (propertize (concat (cdr hr) "\n") 'face 'shadow) parts)))
    (dolist (row rows)
      (push (propertize (concat (kitty-dbbliss-format-row row widths) "\n")
                        'kitty-dbbliss-set set 'kitty-dbbliss-row row)
            parts))
    (apply #'concat (nreverse parts))))

(defun kitty-dbbliss--start-table (set first-page)
  (setf (kitty-dbbliss--set-widths set)
        (kitty-dbbliss-widths (kitty-dbbliss--set-columns set) first-page kitty-dbbliss-max-col-width))
  (setf (kitty-dbbliss--set-starts set) (kitty-dbbliss-cell-starts (kitty-dbbliss--set-widths set)))
  (let ((start (kitty-dbbliss--append (kitty-dbbliss--block set nil t))))
    (setf (kitty-dbbliss--set-header set)
          (with-current-buffer (kitty-dbbliss--results-buffer) (copy-marker start)))))

(defun kitty-dbbliss--widen (set page)
  "A later PAGE holds wider values: widths grow (to the cap) and SET is drawn again.
Return non-nil when it was.  (A number cut to \"24…\" would be wrong on screen.)"
  (let ((wanted (kitty-dbbliss-widths (kitty-dbbliss--set-columns set) page kitty-dbbliss-max-col-width))
        (widths (kitty-dbbliss--set-widths set))
        grew)
    (dotimes (i (length wanted))
      (when (> (aref wanted i) (aref widths i))
        (aset widths i (aref wanted i))
        (setq grew t)))
    (when grew
      (setf (kitty-dbbliss--set-starts set) (kitty-dbbliss-cell-starts widths))
      (setf (kitty-dbbliss--set-rows set) (append (reverse page) (kitty-dbbliss--set-rows set)))
      (with-current-buffer (kitty-dbbliss--results-buffer)
        (kitty-dbbliss--drop-paused-line)
        (let ((inhibit-read-only t)
              (at (marker-position (kitty-dbbliss--set-header set))))
          (save-excursion
            ;; The set being filled is the last thing in the buffer.
            (delete-region at (point-max))
            (goto-char at)
            (insert (kitty-dbbliss--block set (reverse (kitty-dbbliss--set-rows set)) t))))))
    grew))

(defun kitty-dbbliss--results-rows (p)
  (let ((set (gethash (plist-get p :query_id) kitty-dbbliss--open))
        (rows (append (plist-get p :rows) nil)))
    (when (and set rows)
      (cond ((null (kitty-dbbliss--set-widths set))
             (kitty-dbbliss--start-table set rows)
             (kitty-dbbliss--append-rows set rows))
            ((kitty-dbbliss--widen set rows))
            (t (kitty-dbbliss--append-rows set rows))))))

(defun kitty-dbbliss--append-rows (set rows)
  (setf (kitty-dbbliss--set-rows set) (append (reverse rows) (kitty-dbbliss--set-rows set)))
  (kitty-dbbliss--append (kitty-dbbliss--block set rows)))

(defun kitty-dbbliss--results-resultset-done (p)
  (when-let* ((set (gethash (plist-get p :query_id) kitty-dbbliss--open)))
    (unless (kitty-dbbliss--set-widths set) (kitty-dbbliss--start-table set nil))
    (setf (kitty-dbbliss--set-count set) (plist-get p :rows))
    (remhash (plist-get p :query_id) kitty-dbbliss--open)
    (kitty-dbbliss--append (propertize (format "(%d row%s)\n\n" (plist-get p :rows)
                                               (if (eql (plist-get p :rows) 1) "" "s"))
                                       'face 'shadow))))

(defun kitty-dbbliss--results-paused (p)
  (kitty-dbbliss--append
   (propertize (format "-- %d rows shown; more are available. Go to the end or press gm to fetch %d more.\n"
                       (plist-get p :rows_sent) kitty-dbbliss-window-rows)
               'face 'success 'kitty-dbbliss-paused t))
  (setq kitty-dbbliss--paused (cons (plist-get p :query_id)
                                    (gethash (plist-get p :query_id) kitty-dbbliss--open))))

(defun kitty-dbbliss--results-query-ended (qid)
  (remhash qid kitty-dbbliss--open)
  (when (equal (car kitty-dbbliss--paused) qid)
    (kitty-dbbliss--drop-paused-line)
    (setq kitty-dbbliss--paused nil)))

(defun kitty-dbbliss-fetch-more ()
  "Fetch the next window of rows of the paused query."
  (interactive)
  (if-let* ((paused kitty-dbbliss--paused))
      (progn (kitty-dbbliss--drop-paused-line)
             (setq kitty-dbbliss--paused nil)
             (kitty-dbbliss-fetch (car paused) kitty-dbbliss-window-rows))
    (kitty-dbbliss--notify "no paused result to fetch more of")))

(defun kitty-dbbliss--maybe-fetch ()
  "Going to the end of a paused result asks for the next rows."
  (when (and kitty-dbbliss--paused
             (>= (point) (save-excursion (goto-char (point-max)) (forward-line -2) (point))))
    (kitty-dbbliss-fetch-more)))

(defun kitty-dbbliss--cell-at-point ()
  "(SET ROW K) under point: ROW the row vector or :header, K the column index."
  (when-let* ((set (get-text-property (line-beginning-position) 'kitty-dbbliss-set))
              (row (get-text-property (line-beginning-position) 'kitty-dbbliss-row)))
    (let ((col (current-column)) (k 0) (i 0))
      (seq-doseq (start (kitty-dbbliss--set-starts set))
        (when (<= start col) (setq k i))
        (setq i (1+ i)))
      (list set row k))))

(defun kitty-dbbliss--goto-cell (k)
  (let ((set (get-text-property (line-beginning-position) 'kitty-dbbliss-set)))
    (move-to-column (aref (kitty-dbbliss--set-starts set) k))))

(defun kitty-dbbliss-next-cell (&optional dir)
  "To the next cell (DIR -1: the previous one), wrapping to the next row."
  (interactive)
  (let ((dir (or dir 1)))
    (pcase (kitty-dbbliss--cell-at-point)
      (`(,set ,_ ,k)
       (let ((n (length (kitty-dbbliss--set-columns set)))
             (k (+ k dir)))
         (cond ((< -1 k n) (kitty-dbbliss--goto-cell k))
               ((progn (forward-line dir)
                       (eq (get-text-property (line-beginning-position) 'kitty-dbbliss-set) set))
                (kitty-dbbliss--goto-cell (if (> dir 0) 0 (1- n))))
               (t (forward-line (- dir))))))
      (_ (kitty-dbbliss-next-set dir)))))

(defun kitty-dbbliss-previous-cell ()
  "To the previous cell."
  (interactive)
  (kitty-dbbliss-next-cell -1))

(defun kitty-dbbliss-next-set (&optional dir)
  "To the header of the next result set (DIR -1: the previous one)."
  (interactive)
  (let ((dir (or dir 1)) found)
    (save-excursion
      (forward-line dir)
      (while (and (not found) (not (if (> dir 0) (eobp) (bobp))))
        (if (eq (get-text-property (point) 'kitty-dbbliss-row) :header)
            (setq found (point))
          (forward-line dir))))
    (if found (goto-char found) (message "No more result sets"))))

(defun kitty-dbbliss-previous-set ()
  "To the header of the previous result set."
  (interactive)
  (kitty-dbbliss-next-set -1))

(defun kitty-dbbliss-yank (what)
  "Copy WHAT under point: `cell', `row' (tab-separated) or `column' (one per line).
Values are full, NULL is empty."
  (pcase (kitty-dbbliss--cell-at-point)
    (`(,set ,row ,k)
     (let ((text
            (pcase what
              ('cell (if (eq row :header) (nth k (kitty-dbbliss--set-columns set))
                       (kitty-dbbliss-raw-text (aref row k))))
              ('row (if (eq row :header) (string-join (kitty-dbbliss--set-columns set) "\t")
                      (mapconcat #'kitty-dbbliss-raw-text row "\t")))
              ('column (mapconcat (lambda (r) (kitty-dbbliss-raw-text (aref r k)))
                                  (reverse (kitty-dbbliss--set-rows set)) "\n")))))
       (kill-new text)
       (message "Copied %s (%d characters)" what (length text))))
    (_ (user-error "Not on a result row"))))

(defun kitty-dbbliss-yank-cell () "Copy the cell." (interactive) (kitty-dbbliss-yank 'cell))
(defun kitty-dbbliss-yank-row () "Copy the row." (interactive) (kitty-dbbliss-yank 'row))
(defun kitty-dbbliss-yank-column () "Copy the column." (interactive) (kitty-dbbliss-yank 'column))

;;;; Messages (PRINT, RAISERROR, NOTICE)

(defun kitty-dbbliss--messages-add (p)
  (with-current-buffer (get-buffer-create kitty-dbbliss-messages-buffer)
    (unless (derived-mode-p 'special-mode) (special-mode))
    (let ((inhibit-read-only t)
          (face (pcase (plist-get p :severity) ("error" 'error) ("warning" 'warning) (_ nil))))
      (goto-char (point-max))
      (insert (propertize (format "[%s]%s %s\n" (plist-get p :severity)
                                  (if (plist-get p :line) (format " line %s:" (plist-get p :line)) "")
                                  (plist-get p :text))
                          'face face))))
  (kitty-dbbliss--note (concat "-- message: " (plist-get p :text))
                       (if (member (plist-get p :severity) '("warning" "error")) 'warning 'info)))

(defun kitty-dbbliss-show-messages ()
  "Show the server's messages of the last run."
  (interactive)
  (pop-to-buffer (get-buffer-create kitty-dbbliss-messages-buffer)))

;;;; Errors on their lines (flymake)

(defvar-local kitty-dbbliss--errors nil "((LINE . MESSAGE) ...) from the last run.")

(defun kitty-dbbliss--clear-errors (buffer)
  (with-current-buffer buffer
    (when kitty-dbbliss--errors
      (setq kitty-dbbliss--errors nil)
      (when (bound-and-true-p flymake-mode) (flymake-start)))))

(defun kitty-dbbliss--set-error (buffer line message)
  "Show MESSAGE on BUFFER's LINE (1-based) as an error."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (push (cons line message) kitty-dbbliss--errors)
      (when (bound-and-true-p flymake-mode) (flymake-start)))))

(defun kitty-dbbliss-flymake (report-fn &rest _)
  "Flymake backend: the database's errors of the last run, on their lines."
  (funcall report-fn
           (mapcar (lambda (e)
                     (save-excursion
                       (goto-char (point-min))
                       (forward-line (1- (car e)))
                       (flymake-make-diagnostic (current-buffer) (line-beginning-position)
                                                (max (1+ (line-beginning-position)) (line-end-position))
                                                :error (concat "dbbliss: " (cdr e)))))
                   kitty-dbbliss--errors)))

;;;; Object info, CREATE scripts, the object explorer

(defun kitty-dbbliss--catalog (conn-id method params callback)
  (kitty-dbbliss--request method (append (list :connection_id conn-id) params)
                          (lambda (err result)
                            (if err
                                (kitty-dbbliss--notify "%s" (plist-get err :message))
                              (funcall callback result)))))

(defun kitty-dbbliss-name-at-point ()
  "The (schema-qualified) object name under the cursor: a.b, [a b].c, \"x\".y."
  (save-excursion
    (let ((part "\\(?:\\[[^]]*\\]\\|\"[^\"]*\"\\|[[:alnum:]_$#@]+\\)"))
      (skip-chars-backward "[:alnum:]_$#@.[]\"")
      (when (looking-at (concat part "\\(?:\\." part "\\)*"))
        (match-string-no-properties 0)))))

(defun kitty-dbbliss-info (&optional name)
  "Object info: columns, indexes, constraints, keys, triggers, definition (NAME or the one at point)."
  (interactive)
  (when-let* ((target (kitty-dbbliss--current-connection))
              (name (or name (kitty-dbbliss-name-at-point) (user-error "No object name under the cursor"))))
    (kitty-dbbliss--describe (car target) (list :name name))))

(defun kitty-dbbliss-script-object (&optional name)
  "The CREATE script of NAME (or the object at point), in a new SQL buffer."
  (interactive)
  (when-let* ((target (kitty-dbbliss--current-connection))
              (name (or name (kitty-dbbliss-name-at-point) (user-error "No object name under the cursor"))))
    (kitty-dbbliss--script (car target) (list :name name))))

(defvar-local kitty-dbbliss--info-context nil "(CONNECTION PARAMS) of an info buffer.")

(defun kitty-dbbliss--describe (conn-name params)
  (let ((conn (or (gethash conn-name kitty-dbbliss--connections) (user-error "%s is not connected" conn-name))))
    (kitty-dbbliss--catalog
     (plist-get conn :id) "catalog/describe" params
     (lambda (info)
       (let ((buf (get-buffer-create (format "*dbbliss info %s/%s*" conn-name (plist-get info :title)))))
         (with-current-buffer buf
           (kitty-dbbliss-info-mode)
           (setq kitty-dbbliss--info-context (list conn-name params))
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (kitty-dbbliss-render-info info))
             (goto-char (point-min))))
         (pop-to-buffer buf '((display-buffer-reuse-window display-buffer-at-bottom) (window-height . 20))))))))

(defun kitty-dbbliss-render-info (info)
  "The text of INFO, a catalog/describe result: its sections as tables or text."
  (let ((parts (list (propertize (plist-get info :title) 'face 'bold) "\n")))
    (seq-doseq (s (plist-get info :sections))
      (let ((rows (append (plist-get s :rows) nil)))
        (push "\n" parts)
        (if (eq (plist-get s :text) t)
            (progn (push (propertize (format "── %s ──\n" (plist-get s :title)) 'face 'shadow) parts)
                   (dolist (r rows) (push (format "  %s\n" (or (and (> (length r) 0) (aref r 0)) "")) parts)))
          (push (propertize (format "── %s (%d) ──\n" (plist-get s :title) (length rows)) 'face 'shadow) parts)
          (if (null rows)
              (push (propertize "  (none)\n" 'face 'shadow) parts)
            (let* ((names (append (plist-get s :columns) nil))
                   (widths (kitty-dbbliss-widths names rows 200))
                   (hr (kitty-dbbliss-format-header names widths)))
              (push (propertize (concat "  " (car hr) "\n") 'face 'bold) parts)
              (push (propertize (concat "  " (cdr hr) "\n") 'face 'shadow) parts)
              (dolist (r rows) (push (concat "  " (kitty-dbbliss-format-row r widths) "\n") parts)))))))
    (apply #'concat (nreverse parts))))


(defvar-keymap kitty-dbbliss-info-mode-map
  "r" #'kitty-dbbliss-info-refresh
  "s" #'kitty-dbbliss-info-script
  "q" #'quit-window)

(define-derived-mode kitty-dbbliss-info-mode special-mode "dbbliss-info"
  "An object's info: r refresh, s its CREATE script, q close."
  (setq truncate-lines t))

(defun kitty-dbbliss-info-refresh ()
  "Read the object's info again."
  (interactive)
  (apply #'kitty-dbbliss--describe kitty-dbbliss--info-context))

(defun kitty-dbbliss-info-script ()
  "The CREATE script of the object shown."
  (interactive)
  (apply #'kitty-dbbliss--script kitty-dbbliss--info-context))

(defun kitty-dbbliss--script (conn-name params)
  (let ((conn (or (gethash conn-name kitty-dbbliss--connections) (user-error "%s is not connected" conn-name))))
    (kitty-dbbliss--catalog
     (plist-get conn :id) "catalog/script" params
     (lambda (result)
       (kitty-dbbliss--sql-buffer conn-name (string-trim-right (plist-get result :text) "\n")
                                  (or (plist-get params :name) (plist-get params :object)))))))

(defun kitty-dbbliss--sql-buffer (conn-name text title)
  "A new SQL buffer holding TEXT, bound to CONN-NAME."
  (let ((buf (generate-new-buffer (format "*%s: %s*" conn-name title))))
    (with-current-buffer buf
      (insert text)
      (sql-mode)
      (kitty-dbbliss--bind buf conn-name)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    buf))

;; The object explorer: databases → schemas → folders → objects.

(cl-defstruct (kitty-dbbliss--node (:constructor kitty-dbbliss--make-node))
  name kind expandable folder identity system browsable detail path parent children loaded open)

(defvar-local kitty-dbbliss--tree-root nil)
(defvar-local kitty-dbbliss--tree-conn nil "(NAME . CONNECTION-ID) the tree browses.")
(defvar-local kitty-dbbliss--tree-show-system nil)

(defvar-keymap kitty-dbbliss-tree-mode-map
  "RET" #'kitty-dbbliss-tree-toggle
  "o" #'kitty-dbbliss-tree-toggle
  "TAB" #'kitty-dbbliss-tree-toggle
  "i" #'kitty-dbbliss-tree-info
  "s" #'kitty-dbbliss-tree-script
  "t" #'kitty-dbbliss-tree-select-top
  "r" #'kitty-dbbliss-tree-refresh
  "R" #'kitty-dbbliss-tree-refresh-all
  "S" #'kitty-dbbliss-tree-toggle-system
  "q" #'quit-window)

(define-derived-mode kitty-dbbliss-tree-mode special-mode "dbbliss-tree"
  "The object explorer: RET / o open or close, i info, s script, t select the
first 1000 rows, r refresh the node, R everything, S system objects, q close."
  (setq truncate-lines t buffer-undo-list t))

(defun kitty-dbbliss--node-from (raw parent)
  (let* ((kind (plist-get raw :kind))
         (pp (and parent (kitty-dbbliss--node-path parent)))
         (path (pcase kind
                 ("database" (list :database (plist-get raw :name)))
                 ("schema" (list :database (plist-get pp :database) :schema (plist-get raw :name)))
                 ("folder" (list :database (plist-get pp :database) :schema (plist-get pp :schema)
                                 :folder (plist-get raw :folder)))
                 (_ (list :database (plist-get pp :database) :schema (plist-get pp :schema)
                          :folder (plist-get pp :folder))))))
    (kitty-dbbliss--make-node
     :name (plist-get raw :name) :kind kind :expandable (eq (plist-get raw :expandable) t)
     :folder (plist-get raw :folder) :identity (plist-get raw :identity)
     :system (eq (plist-get raw :system) t) :browsable (not (eq (plist-get raw :browsable) :false))
     :detail (plist-get raw :detail) :path path :parent parent)))

(defun kitty-dbbliss--node-object-params (node)
  "The request parameters that name NODE exactly."
  (kitty-dbbliss--params :database (plist-get (kitty-dbbliss--node-path node) :database)
                         :schema (plist-get (kitty-dbbliss--node-path node) :schema)
                         :object (kitty-dbbliss--node-name node)
                         :kind (kitty-dbbliss--node-kind node)
                         :identity (kitty-dbbliss--node-identity node)))

(defun kitty-dbbliss-tree ()
  "The object explorer of this buffer's connection, on the left."
  (interactive)
  (when-let* ((target (kitty-dbbliss--current-connection)))
    (let* ((name (car target)) (id (plist-get (cdr target) :id))
           (buf (get-buffer-create (format "*dbbliss tree %s*" name))))
      (with-current-buffer buf
        (unless (and (derived-mode-p 'kitty-dbbliss-tree-mode) (equal (cdr kitty-dbbliss--tree-conn) id))
          (kitty-dbbliss-tree-mode)
          (setq kitty-dbbliss--tree-conn (cons name id)
                kitty-dbbliss--tree-root (kitty-dbbliss--make-node :name name :kind "root" :expandable t :open t))
          (kitty-dbbliss--tree-load kitty-dbbliss--tree-root)))
      (select-window (display-buffer-in-side-window buf '((side . left) (window-width . 40)))))))

(defun kitty-dbbliss--tree-load (node &optional then)
  "Load NODE's children (catalog/children), then draw; THEN runs after."
  (let ((buf (current-buffer))
        (params (if (equal (kitty-dbbliss--node-kind node) "root") nil
                  (apply #'kitty-dbbliss--params (kitty-dbbliss--node-path node)))))
    (kitty-dbbliss--catalog
     (cdr kitty-dbbliss--tree-conn) "catalog/children" params
     (lambda (result)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (setf (kitty-dbbliss--node-children node)
                 (mapcar (lambda (raw) (kitty-dbbliss--node-from raw node)) (plist-get result :nodes))
                 (kitty-dbbliss--node-loaded node) t
                 (kitty-dbbliss--node-open node) t)
           (kitty-dbbliss--tree-draw)
           (when then (funcall then))))))))

(defun kitty-dbbliss--tree-draw ()
  (let ((inhibit-read-only t) (line (line-number-at-pos)) (col (current-column)))
    (erase-buffer)
    (insert (propertize (format "%s  (? for keys)\n" (car kitty-dbbliss--tree-conn)) 'face 'bold))
    (cl-labels ((walk (node depth)
                  (dolist (c (kitty-dbbliss--node-children node))
                    (unless (and (kitty-dbbliss--node-system c) (not kitty-dbbliss--tree-show-system))
                      (insert (propertize
                               (concat (make-string (* 2 depth) ?\s)
                                       (cond ((not (kitty-dbbliss--node-expandable c)) "  ")
                                             ((kitty-dbbliss--node-open c) "▾ ")
                                             (t "▸ "))
                                       (propertize (kitty-dbbliss--node-name c)
                                                   'face (if (equal (kitty-dbbliss--node-kind c) "folder")
                                                             'font-lock-keyword-face 'default))
                                       (if (kitty-dbbliss--node-detail c)
                                           (propertize (concat "  " (kitty-dbbliss--node-detail c)) 'face 'shadow)
                                         "")
                                       "\n")
                               'kitty-dbbliss-node c))
                      (when (kitty-dbbliss--node-open c) (walk c (1+ depth)))))))
      (walk kitty-dbbliss--tree-root 0))
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column col)))

(defun kitty-dbbliss--tree-node ()
  (or (get-text-property (line-beginning-position) 'kitty-dbbliss-node) (user-error "No object here")))

(defun kitty-dbbliss-tree-toggle ()
  "Open or close the node under the cursor (children load the first time)."
  (interactive)
  (let ((node (kitty-dbbliss--tree-node)))
    (cond ((not (kitty-dbbliss--node-expandable node)) (kitty-dbbliss-tree-info))
          ((not (kitty-dbbliss--node-browsable node))
           (message "This connection cannot look into %s" (kitty-dbbliss--node-name node)))
          ((kitty-dbbliss--node-open node)
           (setf (kitty-dbbliss--node-open node) nil)
           (kitty-dbbliss--tree-draw))
          ((kitty-dbbliss--node-loaded node)
           (setf (kitty-dbbliss--node-open node) t)
           (kitty-dbbliss--tree-draw))
          (t (kitty-dbbliss--tree-load node)))))

(defun kitty-dbbliss-tree-info ()
  "Info of the object under the cursor."
  (interactive)
  (let ((node (kitty-dbbliss--tree-node)))
    (when (member (kitty-dbbliss--node-kind node) '("database" "schema" "folder"))
      (user-error "Info is for tables, views, functions and procedures"))
    (kitty-dbbliss--describe (car kitty-dbbliss--tree-conn) (kitty-dbbliss--node-object-params node))))

(defun kitty-dbbliss-tree-script ()
  "The CREATE script of the object under the cursor."
  (interactive)
  (let ((node (kitty-dbbliss--tree-node)))
    (when (member (kitty-dbbliss--node-kind node) '("schema" "folder"))
      (user-error "Scripts are for databases and objects"))
    (kitty-dbbliss--script (car kitty-dbbliss--tree-conn) (kitty-dbbliss--node-object-params node))))

(defun kitty-dbbliss-quote (name engine)
  "NAME quoted for ENGINE when it needs quotes."
  (if (string-match-p "\\`[[:alpha:]_][[:alnum:]_$#@]*\\'" name)
      name
    (if (equal engine "sqlserver")
        (concat "[" (string-replace "]" "]]" name) "]")
      (concat "\"" (string-replace "\"" "\"\"" name) "\""))))

(defun kitty-dbbliss-select-top-sql (engine database schema name)
  "SSMS's \"Select Top 1000 Rows\" of SCHEMA.NAME in DATABASE, for ENGINE."
  (if (equal engine "sqlserver")
      (format "SELECT TOP (1000) *\nFROM %s.%s.%s;"
              (kitty-dbbliss-quote database engine) (kitty-dbbliss-quote schema engine)
              (kitty-dbbliss-quote name engine))
    (format "SELECT *\nFROM %s.%s\nLIMIT 1000;"
            (kitty-dbbliss-quote schema engine) (kitty-dbbliss-quote name engine))))

(defun kitty-dbbliss-tree-select-top ()
  "Select the first 1000 rows of the table or view under the cursor, in a new buffer."
  (interactive)
  (let* ((node (kitty-dbbliss--tree-node))
         (conn-name (car kitty-dbbliss--tree-conn))
         (engine (plist-get (gethash conn-name kitty-dbbliss--connections) :engine))
         (path (kitty-dbbliss--node-path node)))
    (unless (member (kitty-dbbliss--node-kind node) '("table" "view"))
      (user-error "Select rows of a table or a view"))
    (with-current-buffer
        (kitty-dbbliss--sql-buffer conn-name
                                   (kitty-dbbliss-select-top-sql engine (plist-get path :database)
                                                                 (plist-get path :schema)
                                                                 (kitty-dbbliss--node-name node))
                                   (kitty-dbbliss--node-name node))
      (kitty-dbbliss-exec-buffer))))

(defun kitty-dbbliss-tree-refresh ()
  "Load the children of the node under the cursor again."
  (interactive)
  (let ((node (get-text-property (line-beginning-position) 'kitty-dbbliss-node)))
    (kitty-dbbliss--tree-load (if (and node (kitty-dbbliss--node-expandable node))
                                  node
                                (or (and node (kitty-dbbliss--node-parent node)) kitty-dbbliss--tree-root)))))

(defun kitty-dbbliss-tree-refresh-all ()
  "Load the tree again from the top (and the completion names)."
  (interactive)
  (remhash (cdr kitty-dbbliss--tree-conn) kitty-dbbliss--caches)
  (setf (kitty-dbbliss--node-children kitty-dbbliss--tree-root) nil)
  (kitty-dbbliss--tree-load kitty-dbbliss--tree-root))

(defun kitty-dbbliss-tree-toggle-system ()
  "Show or hide system databases and schemas."
  (interactive)
  (setq kitty-dbbliss--tree-show-system (not kitty-dbbliss--tree-show-system))
  (kitty-dbbliss--tree-draw))

;;;; Plans

(defvar kitty-dbbliss--plans (make-hash-table :test #'equal) "Plan id -> buffer.")

(defvar-local kitty-dbbliss--plan nil
  "The plan of this buffer: plist (:id :conn-id :sql :mode :status :plans :error :collapsed).")

(defvar-keymap kitty-dbbliss-plan-mode-map
  "RET" #'kitty-dbbliss-plan-toggle
  "o" #'kitty-dbbliss-plan-toggle
  "TAB" #'kitty-dbbliss-plan-toggle
  "z R" #'kitty-dbbliss-plan-expand-all
  "z M" #'kitty-dbbliss-plan-collapse-all
  "x" #'kitty-dbbliss-plan-raw
  "c" #'kitty-dbbliss-plan-cancel
  "q" #'quit-window)

(define-derived-mode kitty-dbbliss-plan-mode special-mode "dbbliss-plan"
  "A query plan: RET / o fold a node, zR / zM all, x the raw plan, c cancel, q close."
  (setq truncate-lines t buffer-undo-list t))

(defun kitty-dbbliss-plan (&optional actual)
  "The estimated plan of the statement under the cursor (nothing is run).
With ACTUAL (prefix argument), the actual plan: the statement runs on a
session of its own, in a transaction that is rolled back."
  (interactive "P")
  (kitty-dbbliss--with-statements
   (if (use-region-p) 'region 'statement)
   (lambda (name conn-id _buffer statements _base)
     (remhash conn-id kitty-dbbliss--scripts)
     (if (/= (length statements) 1)
         (kitty-dbbliss--notify "plan takes one statement, got %d" (length statements))
       (let* ((st (aref statements 0))
              (sql (plist-get st :text))
              (mode (if actual "actual" "estimated"))
              (confirm (and actual (not (equal (plist-get st :kind) "read")))))
         (if (and confirm
                  (not (yes-or-no-p
                        (format "An actual plan RUNS this statement (on a separate session, in a transaction that is rolled back):\n%s\nSequences and calls to the outside are not undone.  Run it? "
                                (truncate-string-to-width (replace-regexp-in-string "[ \t\n\r]+" " " sql) 80 nil nil "...")))))
             (kitty-dbbliss--notify "plan not started: nothing was run")
           (kitty-dbbliss--request
            "plan/start" (kitty-dbbliss--params :connection_id conn-id :sql sql :mode mode
                                                :confirm_execute (and confirm t))
            (lambda (err result)
              (if err
                  (kitty-dbbliss--notify "%s" (plist-get err :message))
                (let ((buf (get-buffer-create (format "*dbbliss plan %s*" name))))
                  (with-current-buffer buf
                    (kitty-dbbliss-plan-mode)
                    (setq kitty-dbbliss--plan (list :id (plist-get result :plan_id) :conn-id conn-id
                                                    :sql sql :mode mode :status "running" :collapsed nil))
                    (kitty-dbbliss--plan-draw))
                  (puthash (plist-get result :plan_id) buf kitty-dbbliss--plans)
                  (display-buffer buf '((display-buffer-reuse-window display-buffer-at-bottom)
                                        (window-height . 16)))))))))))
   t))

(defun kitty-dbbliss-plan-actual ()
  "The actual plan of the statement under the cursor (it is run and rolled back)."
  (interactive)
  (kitty-dbbliss-plan t))

(defun kitty-dbbliss--on-plan-done (p)
  (when-let* ((buf (gethash (plist-get p :plan_id) kitty-dbbliss--plans)))
    (remhash (plist-get p :plan_id) kitty-dbbliss--plans)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq kitty-dbbliss--plan (plist-put (plist-put (plist-put kitty-dbbliss--plan :status (plist-get p :status))
                                                        :plans (append (plist-get p :plans) nil))
                                             :error (plist-get p :error)))
        (kitty-dbbliss--plan-draw)))
    (pcase (plist-get p :status)
      ("completed" (kitty-dbbliss--notify "plan ready"))
      ("cancelled" (kitty-dbbliss--notify "plan cancelled"))
      (_ (kitty-dbbliss--notify "plan FAILED: %s" (plist-get p :error))))))

(defun kitty-dbbliss--num (v)
  "V as a plan shows it: whole numbers without decimals, else at most two."
  (if (or (integerp v) (and (= v (ffloor v)) (< (abs v) 1e15)))
      (format "%d" (truncate v))
    (string-trim-right (string-trim-right (format "%.2f" v) "0+") "\\.")))

(defun kitty-dbbliss-plan-node-line (n depth collapsed hottest)
  "The line of plan node N at DEPTH."
  (let* ((children (plist-get n :children))
         (text (concat (make-string (* 2 depth) ?\s)
                       (cond ((= (length children) 0) " ") (collapsed "▸") (t "▾"))
                       " " (plist-get n :operator)
                       (if (and (plist-get n :detail) (not (string-empty-p (plist-get n :detail))))
                           (concat "  " (plist-get n :detail))
                         "")))
         parts)
    (when (plist-get n :cost) (push (concat "cost " (kitty-dbbliss--num (plist-get n :cost))) parts))
    (let ((est (plist-get n :estimated_rows)) (act (plist-get n :actual_rows)))
      (cond (act (push (concat (if est (format "rows %s → %s" (kitty-dbbliss--num est) (kitty-dbbliss--num act))
                                 (format "rows %s" (kitty-dbbliss--num act)))
                               (if (and est (> est 0) (not (< 0.95 (/ (float act) est) 1.05)))
                                   (let ((r (/ (float act) est)))
                                     (format " ×%s" (if (>= r 10) (format "%d" (round r))
                                                      (kitty-dbbliss--num (/ (fround (* r 10)) 10)))))
                                 ""))
                       parts))
            (est (push (concat "rows " (kitty-dbbliss--num est)) parts))))
    (when (plist-get n :loops) (push (concat "loops " (kitty-dbbliss--num (plist-get n :loops))) parts))
    (when (plist-get n :time_ms)
      (push (concat (kitty-dbbliss--num (plist-get n :time_ms)) " ms"
                    (if (and (plist-get n :self_time_ms) (> (length children) 0))
                        (format " (self %s ms)" (kitty-dbbliss--num (plist-get n :self_time_ms)))
                      ""))
            parts))
    (concat text
            (if parts (concat "   " (string-join (nreverse parts) " · ")) "")
            (if hottest "   ◀ hottest" ""))))

(defun kitty-dbbliss--plan-draw ()
  (let* ((op kitty-dbbliss--plan)
         (inhibit-read-only t)
         (line (line-number-at-pos)))
    (erase-buffer)
    (insert (propertize (format "Plan · %s · %s\n" (plist-get op :mode)
                                (truncate-string-to-width (replace-regexp-in-string "[ \t\n\r]+" " " (plist-get op :sql))
                                                          80 nil nil "..."))
                        'face 'bold))
    (insert (pcase (plist-get op :status)
              ("running" (propertize "Running…   c cancel · q close\n" 'face 'shadow))
              ("failed" (propertize (format "FAILED: %s\n" (plist-get op :error)) 'face 'error))
              ("cancelled" (propertize "cancelled: no plan\n" 'face 'error))
              (_ (propertize "RET/o fold · zR/zM all · x raw plan · q close\n" 'face 'shadow))))
    (let ((pi 0) (plans (plist-get op :plans)))
      (dolist (doc plans)
        (setq pi (1+ pi))
        (let ((totals (plist-get doc :totals)) head)
          (dolist (tt '((:cost "cost %s") (:statement_cost "cost %s") (:planning_ms "planning %s ms")
                        (:compile_ms "compile %s ms") (:execution_ms "execution %s ms")
                        (:dop "parallelism %s") (:memory_grant_kb "memory grant %s KB")))
            (when-let* ((v (plist-get totals (car tt))))
              (push (format (cadr tt) (kitty-dbbliss--num v)) head)))
          (insert "\n" (propertize (format "%s%s plan · %s%s\n"
                                           (if (> (length plans) 1) (format "Statement %d of %d · " pi (length plans)) "")
                                           (plist-get doc :mode) (plist-get doc :engine)
                                           (if head (concat " · " (string-join (nreverse head) " · ")) ""))
                                   'face 'shadow)))
        (cl-labels ((walk (n depth)
                      (let* ((key (format "%d:%s" pi (plist-get n :id)))
                             (collapsed (and (member key (plist-get op :collapsed))
                                             (> (length (plist-get n :children)) 0)))
                             (hot (equal (plist-get doc :hottest) (plist-get n :id)))
                             (pad (concat (make-string (* 2 depth) ?\s) "    ")))
                        (insert (propertize (concat (kitty-dbbliss-plan-node-line n depth collapsed hot) "\n")
                                            'face (and hot 'warning) 'kitty-dbbliss-plan-key key
                                            'kitty-dbbliss-plan-doc doc))
                        (when (plist-get n :buffers)
                          (insert (propertize (format "%sbuffers %s\n" pad (plist-get n :buffers)) 'face 'shadow)))
                        (seq-doseq (w (plist-get n :warnings))
                          (insert (propertize (format "%s⚠ %s\n" pad w) 'face 'error)))
                        (unless collapsed
                          (seq-doseq (c (plist-get n :children)) (walk c (1+ depth)))))))
          (walk (plist-get doc :root) 0))
        (seq-doseq (note (plist-get doc :notes))
          (insert (propertize (format "note: %s\n" note) 'face 'shadow)))))
    (goto-char (point-min))
    (forward-line (1- line))))

(defun kitty-dbbliss-plan-toggle ()
  "Fold or unfold the plan node under the cursor."
  (interactive)
  (when-let* ((key (get-text-property (line-beginning-position) 'kitty-dbbliss-plan-key)))
    (let ((collapsed (plist-get kitty-dbbliss--plan :collapsed)))
      (setq kitty-dbbliss--plan (plist-put kitty-dbbliss--plan :collapsed
                                           (if (member key collapsed) (delete key collapsed) (cons key collapsed))))
      (kitty-dbbliss--plan-draw))))

(defun kitty-dbbliss-plan-expand-all ()
  "Unfold every node."
  (interactive)
  (setq kitty-dbbliss--plan (plist-put kitty-dbbliss--plan :collapsed nil))
  (kitty-dbbliss--plan-draw))

(defun kitty-dbbliss-plan-collapse-all ()
  "Fold every node that has children."
  (interactive)
  (let ((keys nil) (pi 0))
    (dolist (doc (plist-get kitty-dbbliss--plan :plans))
      (setq pi (1+ pi))
      (cl-labels ((walk (n)
                    (when (> (length (plist-get n :children)) 0)
                      (push (format "%d:%s" pi (plist-get n :id)) keys))
                    (seq-doseq (c (plist-get n :children)) (walk c))))
        (walk (plist-get doc :root))))
    (setq kitty-dbbliss--plan (plist-put kitty-dbbliss--plan :collapsed keys))
    (kitty-dbbliss--plan-draw)))

(defun kitty-dbbliss-plan-raw ()
  "The engine's own plan (SQL Server XML, PostgreSQL JSON), in a buffer."
  (interactive)
  (let ((doc (or (get-text-property (line-beginning-position) 'kitty-dbbliss-plan-doc)
                 (car (plist-get kitty-dbbliss--plan :plans))
                 (user-error "No plan to show"))))
    (with-current-buffer (get-buffer-create "*dbbliss raw plan*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (plist-get doc :raw))
        (if (equal (plist-get doc :engine) "sqlserver") (nxml-mode) (js-json-mode))
        (goto-char (point-min)))
      (pop-to-buffer (current-buffer)))))

(defun kitty-dbbliss-plan-cancel ()
  "Cancel the running plan."
  (interactive)
  (when (equal (plist-get kitty-dbbliss--plan :status) "running")
    (kitty-dbbliss--request "plan/cancel" (list :plan_id (plist-get kitty-dbbliss--plan :id)))))

;;;; Completion: names from the connection's catalog, never waiting for it


(defconst kitty-dbbliss--object-context
  (concat "\\_<\\(?:from\\|join\\|update\\|into\\|table\\|exec\\|execute\\|call\\|describe\\)"
          "[ \t\n]+\\(?:[^ \t\n,;()]*\\)\\'")
  "Text before point that wants an object name.")

(defun kitty-dbbliss--cache (conn)
  (let ((id (plist-get conn :id)))
    (or (gethash id kitty-dbbliss--caches)
        (puthash id (list :names nil :columns (make-hash-table :test #'equal)) kitty-dbbliss--caches))))

(defun kitty-dbbliss--catalog-allowed-p (conn)
  "Only outside a transaction: the catalog session cannot see uncommitted
changes, and on SQL Server would wait for their locks."
  (equal (plist-get conn :transaction) "none"))

(defun kitty-dbbliss--load-names (conn)
  (let ((cache (kitty-dbbliss--cache conn)) (id (plist-get conn :id)))
    (unless (or (plist-get cache :loading) (not (kitty-dbbliss--catalog-allowed-p conn)))
      (plist-put cache :loading t)
      (kitty-dbbliss--request
       "catalog/names" (list :connection_id id)
       (lambda (err result)
         (when-let* ((c (gethash id kitty-dbbliss--caches)))
           (plist-put c :loading nil)
           (unless err
             (plist-put c :names (append (plist-get result :names) nil)))))))))

(defun kitty-dbbliss--load-columns (conn table)
  (let* ((cache (kitty-dbbliss--cache conn)) (columns (plist-get cache :columns)) (id (plist-get conn :id)))
    (unless (or (gethash (downcase table) columns) (not (kitty-dbbliss--catalog-allowed-p conn)))
      (puthash (downcase table) :loading columns)
      (kitty-dbbliss--request
       "catalog/columns" (list :connection_id id :name table)
       (lambda (err result)
         (puthash (downcase table)
                  (if err :failed (mapcar (lambda (c) (plist-get c :name)) (plist-get result :columns)))
                  columns))))))

(defun kitty-dbbliss--statement-text (&optional whole)
  "The text of the statement around point, up to point (WHOLE: all of it)."
  (let* ((bounds (and (fboundp 'kitty-sql-statement-bounds) (kitty-sql-statement-bounds)))
         (beg (min (point) (if bounds (car bounds) (line-beginning-position)))))
    (buffer-substring-no-properties beg (if whole (max (point) (if bounds (nth 1 bounds) (line-end-position)))
                                          (point)))))

(defun kitty-dbbliss--alias-table (alias text)
  "The table ALIAS stands for in TEXT (FROM t a, JOIN t AS a), or ALIAS itself."
  (let ((case-fold-search t))
    (if (string-match (concat "\\_<\\(?:from\\|join\\)[ \t\n]+\\([^ \t\n,;()]+\\)[ \t\n]+\\(?:as[ \t\n]+\\)?"
                              (regexp-quote alias) "\\_>")
                      text)
        (match-string 1 text)
      alias)))

(defun kitty-dbbliss-completion-at-point ()
  "Object names after FROM, JOIN, UPDATE ...; columns after alias. or table."
  (when-let* ((target (kitty-dbbliss--target))
              (conn (nth 1 target)))
    (let* ((engine (plist-get conn :engine))
           (beg (save-excursion (skip-chars-backward "[:alnum:]_$#@") (point)))
           (end (point))
           (cache (kitty-dbbliss--cache conn))
           (text (kitty-dbbliss--statement-text))
           (case-fold-search t))
      (unless (plist-get cache :names) (kitty-dbbliss--load-names conn))
      (cond
       ;; qualifier. : the objects of a schema, else the columns of a table or alias
       ((eq (char-before beg) ?.)
        (let* ((qual (save-excursion (goto-char (1- beg))
                                     (buffer-substring-no-properties
                                      (progn (skip-chars-backward "[:alnum:]_$#@[]\"") (point)) (1- beg))))
               (bare (string-trim qual "[[\"]" "[]\"]"))
               (in-schema (seq-filter (lambda (n) (string-equal-ignore-case (plist-get n :schema) bare))
                                      (plist-get cache :names))))
          (if in-schema
              (list beg end (mapcar (lambda (n) (kitty-dbbliss-quote (plist-get n :name) engine)) in-schema)
                    :exclusive 'no :annotation-function (lambda (_) " object"))
            (let* ((table (kitty-dbbliss--alias-table qual (kitty-dbbliss--statement-text t)))
                   (cols (gethash (downcase table) (plist-get cache :columns))))
              (unless cols (kitty-dbbliss--load-columns conn table))
              (when (consp cols)
                (list beg end (mapcar (lambda (c) (kitty-dbbliss-quote c engine)) cols)
                      :exclusive 'no :annotation-function (lambda (_) " column")))))))
       ((string-match-p kitty-dbbliss--object-context text)
        (list beg end
              (mapcar (lambda (n) (concat (kitty-dbbliss-quote (plist-get n :schema) engine) "."
                                          (kitty-dbbliss-quote (plist-get n :name) engine)))
                      (plist-get cache :names))
              :exclusive 'no
              :annotation-function (lambda (_) " table")))))))

;;;; Org babel: SQL blocks on a dbbliss connection
;;
;;   #+begin_src sql :dbbliss work
;;   select top 10 * from dbo.Orders
;;   #+end_src
;;
;; The block runs on the named connection (connected first if need be) and
;; its first result set comes back as a table.  Without :dbbliss, ob-sql's
;; own engines run as before.

(defvar kitty-dbbliss-babel-timeout 600
  "Seconds a babel block may run; C-g cancels it sooner.")

(defun kitty-dbbliss-query-sync (connection sql &optional timeout)
  "Run SQL on CONNECTION (a name; connected first if need be) and wait.
Return (COLUMNS ROWS MESSAGES STATUS ERROR) of its first result set.
C-g or TIMEOUT seconds cancel it."
  (unless (gethash connection kitty-dbbliss--connections)
    (let (done err)
      (kitty-dbbliss-connect connection (lambda (e _) (setq done t err e)))
      (with-timeout ((or timeout 60) (user-error "dbbliss: connecting to %s timed out" connection))
        (while (not done) (accept-process-output kitty-dbbliss--process 0.05)))
      (when err (user-error "dbbliss: %s" (plist-get err :message)))))
  (let (columns rows messages done-params qid
        (set-index nil))
    (setq qid (kitty-dbbliss-execute
               sql :connection connection :window :none :quiet t
               :sink (lambda (kind p)
                       (pcase kind
                         ('resultset (unless set-index
                                       (setq set-index (plist-get p :result_set)
                                             columns (mapcar (lambda (c) (plist-get c :name))
                                                             (plist-get p :columns)))))
                         ('rows (when (eql (plist-get p :result_set) set-index)
                                  (setq rows (nconc rows (append (plist-get p :rows) nil)))))
                         ('message (push (plist-get p :text) messages))))
               :on-done (lambda (p) (setq done-params p))))
    (unless qid (user-error "dbbliss: %s is not connected" connection))
    (condition-case nil
        (with-timeout ((or timeout kitty-dbbliss-babel-timeout)
                       (kitty-dbbliss-cancel qid)
                       (user-error "dbbliss: the query took longer than %ss and was cancelled" timeout))
          (while (not done-params)
            (if kitty-dbbliss--process
                (accept-process-output kitty-dbbliss--process 0.05)
              (accept-process-output nil 0.05))))
      (quit (kitty-dbbliss-cancel qid)
            (signal 'quit nil)))
    (list columns rows (nreverse messages) (plist-get done-params :status) (plist-get done-params :error))))

(defun kitty-dbbliss--babel-execute (orig body params)
  "Run a sql block on its :dbbliss connection; others go to ORIG (ob-sql)."
  (let ((conn (cdr (assq :dbbliss params))))
    (if (not conn)
        (funcall orig body params)
      (pcase-let ((`(,columns ,rows ,messages ,status ,err)
                   (kitty-dbbliss-query-sync (format "%s" conn) (string-trim (org-babel-expand-body:sql body params)))))
        (cond
         ((not (equal status "completed"))
          (user-error "dbbliss: %s" (or (plist-get err :message) status)))
         (columns
          (cons (mapcar #'identity columns)
                (cons 'hline (mapcar (lambda (r) (mapcar #'kitty-dbbliss-raw-text r)) rows))))
         (t (string-join messages "\n")))))))

(defvar org-babel-header-args:sql)
(declare-function org-babel-expand-body:sql "ob-sql")
(with-eval-after-load 'ob-sql
  (advice-add 'org-babel-execute:sql :around #'kitty-dbbliss--babel-execute)
  (add-to-list 'org-babel-header-args:sql '(dbbliss . :any)))

;;;; Exit: let the backend cancel queries and close connections

(defun kitty-dbbliss--open-transactions ()
  (let (open)
    (maphash (lambda (name c) (unless (equal (plist-get c :transaction) "none") (push name open)))
             kitty-dbbliss--connections)
    open))

(defun kitty-dbbliss--query-exit ()
  "Ask before quitting with open transactions or running queries."
  (let ((open (kitty-dbbliss--open-transactions))
        (running (hash-table-count kitty-dbbliss--queries)))
    (or (and (null open) (zerop running))
        (yes-or-no-p (format "dbbliss: %s%s.  Quit anyway (the backend rolls back and cancels)? "
                             (if open (format "open transaction on %s" (string-join open ", ")) "")
                             (if (> running 0) (format "%s%d running quer%s" (if open "; " "") running
                                                       (if (= running 1) "y" "ies"))
                               ""))))))

(defun kitty-dbbliss-shutdown ()
  "Ask the backend to cancel its queries and close its connections, and wait for it."
  (when (process-live-p kitty-dbbliss--process)
    (ignore-errors (kitty-dbbliss--request "shutdown" nil #'ignore))
    (ignore-errors (process-send-eof kitty-dbbliss--process))
    (with-timeout (kitty-dbbliss-shutdown-timeout nil)
      (while (process-live-p kitty-dbbliss--process)
        (accept-process-output kitty-dbbliss--process 0.05)))))

(add-hook 'kill-emacs-query-functions #'kitty-dbbliss--query-exit)
(add-hook 'kill-emacs-hook #'kitty-dbbliss-shutdown)

;;;; Mode line: connection, PROD, transaction, running query

(defun kitty-dbbliss-mode-line ()
  "Where this buffer's statements run, for the mode line."
  (when-let* ((target (kitty-dbbliss--target)))
    (let* ((name (car target)) (conn (nth 1 target))
           (prod (equal (plist-get (kitty-dbbliss--config name) :env) "prod"))
           (tx (plist-get conn :transaction))
           (running (seq-some (lambda (q) (equal (plist-get q :connection) name))
                              (hash-table-values kitty-dbbliss--queries))))
      (concat " "
              (propertize (concat "⛁ " name (if (nth 2 target) "" "?"))
                          'face (if prod '(:inherit error :weight bold) 'success))
              (if prod (propertize " PROD" 'face '(:inherit error :weight bold)) "")
              (unless (equal tx "none") (propertize (concat " TX:" tx) 'face 'warning))
              (if running (propertize " ⟳" 'face 'warning) "")))))

;;;; SQL buffers

(defun kitty--dbbliss-sql-setup ()
  (add-hook 'completion-at-point-functions #'kitty-dbbliss-completion-at-point nil t)
  (add-hook 'flymake-diagnostic-functions #'kitty-dbbliss-flymake nil t)
  (setq-local mode-line-process '(:eval (kitty-dbbliss-mode-line))))
(kitty-add-hook 'sql-mode-hook #'kitty--dbbliss-sql-setup)

(with-eval-after-load 'sql
  (define-key sql-mode-map (kbd "<f5>") #'kitty-dbbliss-exec-ssms)
  (define-key sql-mode-map (kbd "C-<return>") #'kitty-dbbliss-exec)
  (define-key sql-mode-map (kbd "C-c C-c") #'kitty-dbbliss-exec))

(kitty-local-leader 'sql-mode
  "c" '("connect" . kitty-dbbliss-connect)
  "u" '("use another connection" . kitty-dbbliss-use)
  "C" '("disconnect" . kitty-dbbliss-disconnect)
  "s" '("status" . kitty-dbbliss-status)
  "e" '("run statement / selection" . kitty-dbbliss-exec)
  "a" '("run all" . kitty-dbbliss-exec-buffer)
  "x" '("cancel" . kitty-dbbliss-cancel)
  "R" '("results" . kitty-dbbliss-show-results)
  "M" '("messages" . kitty-dbbliss-show-messages)
  "E" '("export to CSV" . kitty-dbbliss-export)
  "T" (kitty-prefix "transaction"
        "b" '("begin" . kitty-dbbliss-begin)
        "c" '("commit" . kitty-dbbliss-commit)
        "r" '("roll back" . kitty-dbbliss-rollback))
  "d" '("object info" . kitty-dbbliss-info)
  "S" '("script object" . kitty-dbbliss-script-object)
  "l" '("object explorer" . kitty-dbbliss-tree)
  "p" '("estimated plan" . kitty-dbbliss-plan)
  "P" '("actual plan" . kitty-dbbliss-plan-actual))

;;;; :Dbbliss, as in my-nvim

(defconst kitty-dbbliss-subcommands
  '(("connect" . kitty-dbbliss-connect) ("use" . kitty-dbbliss-use)
    ("disconnect" . kitty-dbbliss-disconnect) ("status" . kitty-dbbliss-status)
    ("exec" . kitty-dbbliss-exec) ("exec_all" . kitty-dbbliss-exec-buffer)
    ("fetch" . kitty-dbbliss-fetch-more) ("cancel" . kitty-dbbliss-cancel)
    ("export" . kitty-dbbliss-export)
    ("begin" . kitty-dbbliss-begin) ("commit" . kitty-dbbliss-commit) ("rollback" . kitty-dbbliss-rollback)
    ("info" . kitty-dbbliss-info) ("script" . kitty-dbbliss-script-object) ("tree" . kitty-dbbliss-tree)
    ("plan" . kitty-dbbliss-plan) ("build" . kitty-dbbliss-build))
  ":Dbbliss subcommand -> command.")

(defun kitty-dbbliss-command (subcommand &optional arg beg end)
  "Run :Dbbliss SUBCOMMAND [ARG]; BEG..END is an ex range (for exec, plan, export)."
  (let ((cmd (or (cdr (assoc subcommand kitty-dbbliss-subcommands))
                 (user-error "dbbliss: unknown command %s (known: %s)" subcommand
                             (mapconcat #'car kitty-dbbliss-subcommands ", ")))))
    (save-mark-and-excursion
      (when (and beg end (member subcommand '("exec" "plan" "export")))
        (goto-char beg) (push-mark end t t))
      (pcase subcommand
        ((or "connect" "use") (funcall cmd (or arg (kitty-dbbliss--read-connection "Connection: "
                                                                                 (equal subcommand "use")))))
        ("disconnect" (funcall cmd arg))
        ((or "info" "script") (funcall cmd arg))
        ("export" (funcall cmd (expand-file-name (or arg (read-file-name "Export to CSV: ")))))
        ("plan" (funcall cmd (equal arg "actual")))
        (_ (call-interactively cmd))))))

(with-eval-after-load 'evil
  (eval '(evil-define-command kitty-dbbliss-ex (args)
           "dbbliss.nvim's :Dbbliss: :Dbbliss connect work, :'<,'>Dbbliss exec ..."
           (interactive "<a>")
           (let ((words (split-string (or args "") " " t))
                 (range (bound-and-true-p evil-ex-range)))
             (kitty-dbbliss-command (or (car words) "status") (cadr words)
                                    (car range) (cadr range))))
        t)
  (evil-ex-define-cmd "Dbbliss" 'kitty-dbbliss-ex)
  (dolist (mode '(kitty-dbbliss-results-mode kitty-dbbliss-tree-mode kitty-dbbliss-plan-mode
                                             kitty-dbbliss-info-mode))
    (evil-set-initial-state mode 'normal))
  (evil-define-key* 'normal kitty-dbbliss-results-mode-map
    (kbd "TAB") #'kitty-dbbliss-next-cell
    (kbd "<backtab>") #'kitty-dbbliss-previous-cell
    (kbd "yc") #'kitty-dbbliss-yank-cell
    (kbd "yr") #'kitty-dbbliss-yank-row
    (kbd "yC") #'kitty-dbbliss-yank-column
    (kbd "gm") #'kitty-dbbliss-fetch-more
    (kbd "]]") #'kitty-dbbliss-next-set
    (kbd "[[") #'kitty-dbbliss-previous-set
    (kbd "m") #'kitty-dbbliss-show-messages
    (kbd "q") #'quit-window)
  (evil-define-key* 'normal kitty-dbbliss-tree-mode-map
    (kbd "RET") #'kitty-dbbliss-tree-toggle (kbd "o") #'kitty-dbbliss-tree-toggle
    (kbd "TAB") #'kitty-dbbliss-tree-toggle (kbd "i") #'kitty-dbbliss-tree-info
    (kbd "s") #'kitty-dbbliss-tree-script (kbd "t") #'kitty-dbbliss-tree-select-top
    (kbd "r") #'kitty-dbbliss-tree-refresh (kbd "R") #'kitty-dbbliss-tree-refresh-all
    (kbd "S") #'kitty-dbbliss-tree-toggle-system (kbd "q") #'quit-window)
  (evil-define-key* 'normal kitty-dbbliss-plan-mode-map
    (kbd "RET") #'kitty-dbbliss-plan-toggle (kbd "o") #'kitty-dbbliss-plan-toggle
    (kbd "TAB") #'kitty-dbbliss-plan-toggle (kbd "zR") #'kitty-dbbliss-plan-expand-all
    (kbd "zM") #'kitty-dbbliss-plan-collapse-all (kbd "x") #'kitty-dbbliss-plan-raw
    (kbd "c") #'kitty-dbbliss-plan-cancel (kbd "q") #'quit-window)
  (evil-define-key* 'normal kitty-dbbliss-info-mode-map
    (kbd "r") #'kitty-dbbliss-info-refresh (kbd "s") #'kitty-dbbliss-info-script (kbd "q") #'quit-window)
  (with-eval-after-load 'sql
    (evil-define-key* '(normal insert visual) sql-mode-map
      (kbd "<f5>") #'kitty-dbbliss-exec-ssms
      (kbd "C-<return>") #'kitty-dbbliss-exec)))

(provide 'kitty-dbbliss)
;;; kitty-dbbliss.el ends here
