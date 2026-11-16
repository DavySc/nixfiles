;;; kitty-lean-webview.el --- VS Code's own infoview, beside Emacs  -*- lexical-binding: t; -*-

;; The infoview VS Code shows is a React page, vscode-lean4's
;; `@leanprover/infoview' package.  It talks to its editor through a small
;; interface (EditorApi one way, InfoviewApi the other): send this request
;; to Lean, tell me Lean's notifications, the cursor moved, apply this edit.
;; This file is that editor, for eglot: Emacs serves the page on
;; 127.0.0.1 and relays between it and the `lake serve' eglot already runs.
;; The page runs in a webview inside Emacs (an Emacs built with xwidgets,
;; such as nixpkgs' emacs-pgtk) or in any browser, so a terminal Emacs gets
;; it too, in a window beside the terminal.
;;
;; With it, everything VS Code's infoview draws is drawn the same way,
;; because it is the same code: Penrose diagrams, plots, `conv?'s subterm
;; selection, hovers inside hovers, any widget's own JavaScript.
;;
;; The wire, all of it plain HTTP/1.1 on one port:
;;   GET  /TOKEN/...               the page and the package's files
;;   GET  /TOKEN/events?page=P     Server-Sent Events: InfoviewApi calls and
;;                                 answers, Emacs to page
;;   POST /TOKEN/call?page=P       an EditorApi call {id, m, a}, page to Emacs;
;;                                 answered at once with 204, the result
;;                                 later on the page's events
;; Results go back on the event stream rather than as the POST's answer, so
;; that requests Lean is slow to answer (it waits for the file to be
;; checked) never hold the browser's six connections to one host.  Each page
;; has its own id: answers go to the page that asked, and wait for it if
;; its event stream is reconnecting.  A page gone for
;; `kitty-lean-webview-page-timeout' seconds is forgotten, with its RPC
;; sessions.  test/kitty_lean_webview.tla models this.
;;
;; Lean's answers and notifications reach the page as the exact JSON Lean
;; sent (jsonrpc keeps it in each message as :jsonrpc-json): Emacs never
;; parses and prints them again, which would be slow for a large goal and
;; would lose the difference between {} and null.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'eglot)
(require 'jsonrpc)

(declare-function kitty-lean--buffer-for-uri "kitty-lean")
(declare-function kitty-lean--diagnostics-all "kitty-lean")
(declare-function kitty-lean--flush "kitty-lean")
(defvar kitty-lean--diagnostics)
(declare-function kitty-lean-restart-file "kitty-lean")
(declare-function xwidget-webkit-browse-url "xwidget")
(declare-function xwidget-webkit-last-session "xwidget")
(declare-function xwidget-buffer "xwidget.c")

(defgroup kitty-lean-webview nil
  "VS Code's Lean infoview, served to a webview or a browser."
  :group 'kitty-lean)

(defcustom kitty-lean-webview-dist (getenv "KITTYMAX_LEAN_INFOVIEW")
  "The dist/ directory of the npm package `@leanprover/infoview'.
kittymax's Nix build sets it (KITTYMAX_LEAN_INFOVIEW); nil without it."
  :type '(choice (const nil) directory))

(defcustom kitty-lean-webview-display 'auto
  "Where the page is shown: `xwidget' (a webview in Emacs), `browser'
\(`browse-url'), or `auto': xwidget in a graphical Emacs that has it,
a browser otherwise."
  :type '(choice (const auto) (const xwidget) (const browser)))

(defcustom kitty-lean-webview-page-timeout 60
  "Seconds a page may be away (its event stream closed) before it is forgotten."
  :type 'number)

(defcustom kitty-lean-webview-config
  '(:allErrorsOnLine t :autoOpenShowsGoal t :debounceTime 50
    :expectedTypeVisibility "Expanded by default" :showGoalNames t
    :emphasizeFirstGoal :json-false :reverseTacticState :json-false
    :hideTypeAssumptions :json-false :hideInstanceAssumptions :json-false
    :hideInaccessibleAssumptions :json-false :hideLetValues :json-false
    :showTooltipOnHover t :messageOrder "Sort by proximity to text cursor")
  "The infoview's settings (VS Code's lean4.infoview.*)."
  :type 'plist)

;;;; State

(defvar kitty-lean-webview--server nil "The listening process.")
(defvar kitty-lean-webview--token nil "The secret first part of every path.")
(defvar kitty-lean-webview--pages (make-hash-table :test #'equal)
  "Page id -> its `kitty-lean-webview--page'.")
(defvar kitty-lean-webview--last (make-hash-table :test #'equal)
  "(METHOD . URI) -> the raw JSON of Lean's last file progress, for a new page.")
(defvar kitty-lean-webview--forgotten nil
  "Ids of pages forgotten while perhaps still loaded (newest first, a few):
one that comes back is told to reload, its subscriptions and answers gone.")
(defvar kitty-lean-webview--cursor nil "The last cursor location sent, as JSON.")
(defvar kitty-lean-webview--raw nil
  "While jsonrpc hands over a message: the exact JSON Lean sent.")
(defvar kitty-lean-webview--wanted (make-hash-table :test #'equal)
  "(CONNECTION . ID) of the pages' requests -> Lean's answer as it sent it, once in.
jsonrpc runs an answer's continuation later, outside the delivery, while a
synchronous request is waiting: the JSON is kept here for it.")
(defvar kitty-lean-webview--keepalive nil)
(defvar kitty-lean-webview--buffer nil "The xwidget buffer showing the page.")
(defvar kitty-lean-webview--files (make-hash-table :test #'equal)
  "Served file -> its bytes, read once.")

(cl-defstruct (kitty-lean-webview--page (:constructor kitty-lean-webview--page-make))
  id stream outbox gone-since sessions greeted (subs (make-hash-table :test #'equal)))

;;;; HTTP

(defun kitty-lean-webview--start ()
  "Listen on 127.0.0.1, once."
  (unless (process-live-p kitty-lean-webview--server)
    (setq kitty-lean-webview--token
          (secure-hash 'sha256 (format "%s%s%s" (random) (float-time) (emacs-pid))))
    (setq kitty-lean-webview--server
          (make-network-process
           :name "kitty-lean-webview" :server t :host 'local :service t
           :family 'ipv4 :coding 'binary :noquery t
           :filter #'kitty-lean-webview--filter
           :sentinel #'kitty-lean-webview--sentinel))
    (setq kitty-lean-webview--keepalive
          (run-at-time 10 10 #'kitty-lean-webview--tick)))
  (format "http://127.0.0.1:%d/%s/"
          (process-contact kitty-lean-webview--server :service)
          kitty-lean-webview--token))

(defun kitty-lean-webview-stop ()
  "Stop serving the infoview."
  (interactive)
  (when kitty-lean-webview--keepalive (cancel-timer kitty-lean-webview--keepalive))
  (maphash (lambda (_ p) (kitty-lean-webview--forget p)) kitty-lean-webview--pages)
  (dolist (p (process-list))
    (when (eq (process-get p 'kitty-lean-webview) t) (delete-process p)))
  (when kitty-lean-webview--server (delete-process kitty-lean-webview--server))
  (when (buffer-live-p kitty-lean-webview--buffer)
    (let ((kill-buffer-query-functions nil)) (kill-buffer kitty-lean-webview--buffer)))
  (setq kitty-lean-webview--server nil kitty-lean-webview--keepalive nil
        kitty-lean-webview--buffer nil))

(defun kitty-lean-webview--sentinel (proc _event)
  (unless (process-live-p proc)
    (when-let* ((page (process-get proc 'page)))
      (kitty-lean-webview--stream-down page proc))))

(defun kitty-lean-webview--filter (proc string)
  "Collect a request on PROC; answer each complete one."
  (process-put proc 'kitty-lean-webview t)
  (let ((data (concat (or (process-get proc 'data) "") string)))
    (catch 'more
      (while t
        (let ((head-end (string-search "\r\n\r\n" data)))
          (unless head-end (throw 'more nil))
          (let* ((head (substring data 0 head-end))
                 (len (if (string-match "^content-length: *\\([0-9]+\\)" (downcase head))
                          (string-to-number (match-string 1 (downcase head)))
                        0))
                 (end (+ head-end 4 len)))
            (when (< (length data) end) (throw 'more nil))
            (let ((body (substring data (+ head-end 4) end)))
              (setq data (substring data end))
              (kitty-lean-webview--request proc head body))))))
    (process-put proc 'data data)))

(defun kitty-lean-webview--respond (proc status type body)
  (process-send-string
   proc (concat (format "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\n\r\n"
                        status type (string-bytes body))
                body)))

(defun kitty-lean-webview--query (path key)
  (when (string-match (concat "[?&]" key "=\\([^&]*\\)") path)
    (url-unhex-string (match-string 1 path))))

(defun kitty-lean-webview--request (proc head body)
  (let* ((line (car (split-string head "\r\n")))
         (parts (split-string line " "))
         (verb (nth 0 parts))
         (path (nth 1 parts))
         (prefix (concat "/" kitty-lean-webview--token "/")))
    (if (not (string-prefix-p prefix path))
        (kitty-lean-webview--respond proc "404 Not Found" "text/plain" "")
      (let* ((rest (substring path (length prefix)))
             (name (car (split-string rest "?"))))
        (cond
         ((and (equal verb "GET") (equal name "events"))
          (kitty-lean-webview--open-stream proc (kitty-lean-webview--query rest "page")))
         ((and (equal verb "POST") (equal name "call"))
          (kitty-lean-webview--respond proc "204 No Content" "text/plain" "")
          (kitty-lean-webview--call (kitty-lean-webview--query rest "page") body))
         ((equal verb "GET")
          (kitty-lean-webview--serve proc (if (equal name "") "index.html" name)))
         (t (kitty-lean-webview--respond proc "405 Method Not Allowed" "text/plain" "")))))))

(defconst kitty-lean-webview--types
  '(("js" . "text/javascript; charset=utf-8") ("css" . "text/css; charset=utf-8")
    ("html" . "text/html; charset=utf-8") ("ttf" . "font/ttf")))

(defconst kitty-lean-webview--host-dir
  (expand-file-name "webview" (file-name-directory (or load-file-name buffer-file-name))))

(defun kitty-lean-webview--serve (proc name)
  "Send the file NAME: the host page, the theme, or one of the package's."
  (let ((file (cond ((member name '("index.html" "host.js"))
                     (expand-file-name name kitty-lean-webview--host-dir))
                    ;; the package's files only: plain relative names, inside dist/
                    ((and kitty-lean-webview-dist
                          (string-match-p "\\`dist/[A-Za-z0-9_-][A-Za-z0-9._/-]*\\'" name)
                          (not (string-search ".." name)))
                     (let ((f (expand-file-name (substring name 5) kitty-lean-webview-dist)))
                       (and (file-in-directory-p f kitty-lean-webview-dist) f))))))
    (cond
     ((equal name "theme.css")
      (kitty-lean-webview--respond proc "200 OK" "text/css; charset=utf-8"
                                   (encode-coding-string (kitty-lean-webview--theme) 'utf-8)))
     ((and file (file-regular-p file))
      (kitty-lean-webview--respond
       proc "200 OK"
       (alist-get (file-name-extension file) kitty-lean-webview--types "application/octet-stream" nil #'equal)
       (or (gethash file kitty-lean-webview--files)
           (puthash file (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally file)
                           (buffer-string))
                    kitty-lean-webview--files))))
     (t (kitty-lean-webview--respond proc "404 Not Found" "text/plain" "")))))

;;;; Pages and their event streams

(defun kitty-lean-webview--page (id)
  (or (gethash id kitty-lean-webview--pages)
      (puthash id (kitty-lean-webview--page-make :id id :gone-since (float-time))
               kitty-lean-webview--pages)))

(defun kitty-lean-webview--open-stream (proc id)
  "PROC is page ID's event stream from now on: send what waited for it."
  (if (member id kitty-lean-webview--forgotten)
      (progn
        (process-send-string proc "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\n\r\n")
        (kitty-lean-webview--chunk proc "data: {\"reload\":true}\n\n"))
    (kitty-lean-webview--open-stream-1 proc id)))

(defun kitty-lean-webview--open-stream-1 (proc id)
  (let* ((page (kitty-lean-webview--page id))
         (old (kitty-lean-webview--page-stream page)))
    (when (and old (not (eq old proc))) (delete-process old))
    (process-put proc 'page page)
    (setf (kitty-lean-webview--page-stream page) proc
          (kitty-lean-webview--page-gone-since page) nil)
    ;; chunked: WebKit (libsoup) holds back a stream that has neither a
    ;; length nor chunks
    (process-send-string proc "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\n\r\n")
    (kitty-lean-webview--chunk proc ":\n\n")
    (let ((waiting (reverse (kitty-lean-webview--page-outbox page))))
      (setf (kitty-lean-webview--page-outbox page) nil)
      (dolist (event waiting) (kitty-lean-webview--send page event)))
    (kitty-lean-webview--greet page)))

(defun kitty-lean-webview--greet (page)
  "Send PAGE the hello, once, as soon as it has a stream and there is a Lean server."
  (unless (kitty-lean-webview--page-greeted page)
    (when (and (kitty-lean-webview--page-stream page)
               (kitty-lean-webview--hello page))
      (setf (kitty-lean-webview--page-greeted page) t))))

(defun kitty-lean-webview--send (page event)
  "Send EVENT (a unibyte JSON string) to PAGE, or keep it until PAGE is back."
  (let ((proc (kitty-lean-webview--page-stream page)))
    (unless (and proc (process-live-p proc)
                 (condition-case nil
                     (progn (kitty-lean-webview--chunk
                             proc (concat "data: " (replace-regexp-in-string "[\r\n]" " " event t t) "\n\n"))
                            t)
                   ;; the page closed it and Emacs has not read that yet
                   (error (kitty-lean-webview--stream-down page proc) nil)))
      (push event (kitty-lean-webview--page-outbox page)))))

(defun kitty-lean-webview--stream-down (page proc)
  (when (eq (kitty-lean-webview--page-stream page) proc)
    (setf (kitty-lean-webview--page-stream page) nil
          (kitty-lean-webview--page-gone-since page) (float-time)))
  (ignore-errors (delete-process proc)))

(defun kitty-lean-webview--chunk (proc bytes)
  "Send BYTES (unibyte) on the event stream PROC, as one HTTP chunk."
  (process-send-string proc (concat (format "%x\r\n" (length bytes)) bytes "\r\n")))

(defun kitty-lean-webview--json (value)
  (encode-coding-string (json-serialize value :false-object :json-false :null-object nil) 'utf-8))

(defun kitty-lean-webview--event (method &rest args)
  "An InfoviewApi call as an event: METHOD with ARGS (Lisp values)."
  (kitty-lean-webview--json (list :m method :a (vconcat args))))

(defun kitty-lean-webview--event-raw (method name raw)
  "An InfoviewApi call carrying Lean's own message RAW (its params)."
  (concat "{\"m\":\"" method "\",\"n\":" (kitty-lean-webview--json name) ",\"raw\":" raw "}"))

(defun kitty-lean-webview--broadcast (event)
  (maphash (lambda (_ page) (kitty-lean-webview--send page event)) kitty-lean-webview--pages))

(defun kitty-lean-webview--answer (page id kind value)
  "Answer PAGE's call ID: KIND is \"val\" (VALUE a Lisp value), \"raw\" (Lean's
own response message, a JSON string) or \"err\"."
  (kitty-lean-webview--send
   page (concat "{\"id\":" (number-to-string id) ",\"k\":\"" kind "\",\"v\":"
                (if (equal kind "raw") value (kitty-lean-webview--json value))
                "}")))

(defun kitty-lean-webview--forget (page)
  "PAGE is gone: close its RPC sessions, drop what waited for it."
  (when-let* ((proc (kitty-lean-webview--page-stream page)))
    (delete-process proc))
  (dolist (s (kitty-lean-webview--page-sessions page))
    (kitty-lean-webview--release-session s))
  (remhash (kitty-lean-webview--page-id page) kitty-lean-webview--pages)
  (push (kitty-lean-webview--page-id page) kitty-lean-webview--forgotten)
  (when (nthcdr 32 kitty-lean-webview--forgotten)
    (setcdr (nthcdr 31 kitty-lean-webview--forgotten) nil)))

(defun kitty-lean-webview--tick ()
  "Every 10 s: keep the pages' RPC sessions alive; forget pages long gone."
  (let (gone)
    (maphash (lambda (_ page)
               (let ((since (kitty-lean-webview--page-gone-since page)))
                 (if (and since (> (- (float-time) since) kitty-lean-webview-page-timeout))
                     (push page gone)
                   (dolist (s (kitty-lean-webview--page-sessions page))
                     (pcase-let ((`(,server ,uri ,id) s))
                       (when (jsonrpc-running-p server)
                         (jsonrpc-notify server :$/lean/rpc/keepAlive (list :uri uri :sessionId id))))))))
             kitty-lean-webview--pages)
    (mapc #'kitty-lean-webview--forget gone)))

;;;; Lean to the page

(defun kitty-lean-webview--keep-raw (fn conn msg)
  "Around jsonrpc's delivery of MSG: Lean's exact JSON, while its handlers run,
and kept for a page's request whose answer it is."
  (let ((kitty-lean-webview--raw (plist-get msg :jsonrpc-json))
        (key (cons conn (plist-get msg :id))))
    (when (and kitty-lean-webview--raw (plist-get msg :id) (not (plist-get msg :method))
               (eq (gethash key kitty-lean-webview--wanted 'none) nil))
      (puthash key kitty-lean-webview--raw kitty-lean-webview--wanted))
    (funcall fn conn msg)))

(defun kitty-lean-webview--hello (page)
  "What a new page needs before it can show anything: VS Code's initInfoView.
Nil, sending nothing, while no Lean buffer has a server."
  (when-let* ((buffer (kitty-lean-webview--source))
              (server (with-current-buffer buffer (eglot-current-server))))
    (when-let* ((loc (kitty-lean-webview--location buffer)))
      ;; every page now has this position: a move is one away from it
      (setq kitty-lean-webview--cursor loc)
      (kitty-lean-webview--broadcast (kitty-lean-webview--event "changedCursorLocation" loc))
      (kitty-lean-webview--send page (kitty-lean-webview--event "initialize" loc)))
    (kitty-lean-webview--send page (kitty-lean-webview--event "changedInfoviewConfig" kitty-lean-webview-config))
    (progn
      (kitty-lean-webview--send page (kitty-lean-webview--event "serverStopped" nil))
      (kitty-lean-webview--send
       page (kitty-lean-webview--event
             "serverRestarted"
             (list :capabilities (eglot--capabilities server)
                   :serverInfo (eglot--server-info server))))
      ;; the diagnostics kitty-lean holds (this file may load late), the
      ;; latest progress seen since it loaded
      (maphash (lambda (uri entry)
                 (kitty-lean-webview--send
                  page (kitty-lean-webview--event-raw
                        "gotServerNotification" "textDocument/publishDiagnostics"
                        (kitty-lean-webview--diagnostics-message uri (car entry) (kitty-lean--diagnostics-all uri)))))
               kitty-lean--diagnostics)
      (maphash (lambda (key raw)
                 (kitty-lean-webview--send
                  page (kitty-lean-webview--event-raw "gotServerNotification" (car key) raw)))
               kitty-lean-webview--last))
    t))

(defvar kitty-lean-webview--source nil "The Lean buffer the cursor was last in.")

(defun kitty-lean-webview--lean-p (buffer)
  (and (buffer-live-p buffer)
       (with-current-buffer buffer (and (derived-mode-p 'nael-mode) (eglot-managed-p)))))

(defun kitty-lean-webview--source ()
  "The Lean buffer the infoview is about: where the cursor last was in one."
  (seq-find #'kitty-lean-webview--lean-p
            (cons kitty-lean-webview--source
                  (cons (window-buffer (selected-window)) (buffer-list)))))

(defun kitty-lean-webview--location (buffer)
  (with-current-buffer buffer
    (let* ((beg (if (use-region-p) (region-beginning) (point)))
           (end (if (use-region-p) (region-end) (point))))
      (list :uri (plist-get (eglot--TextDocumentIdentifier) :uri)
            :range (list :start (eglot--pos-to-lsp-position beg)
                         :end (eglot--pos-to-lsp-position end))))))

(defun kitty-lean-webview--notify (name raw)
  "Tell the pages subscribed to NAME Lean's notification RAW (a JSON message)."
  (when (string-prefix-p "$/lean/fileProgress" name)
    (puthash (cons name (kitty-lean-webview--uri-of raw)) raw kitty-lean-webview--last))
  (maphash (lambda (_ page)
             (when (gethash name (kitty-lean-webview--page-subs page))
               (kitty-lean-webview--send
                page (kitty-lean-webview--event-raw "gotServerNotification" name raw))))
           kitty-lean-webview--pages))

(defun kitty-lean-webview--uri-of (raw)
  (and (string-match "\"uri\":\"\\([^\"]*\\)\"" raw) (match-string 1 raw)))

(defun kitty-lean-webview--on-notification (method _params)
  "Lean's notification METHOD, as Lean sent it, to the pages.
Not diagnostics: those come whole from `kitty-lean-diagnostics-functions'."
  (when (and kitty-lean-webview--raw (not (eq method 'textDocument/publishDiagnostics)))
    (kitty-lean-webview--notify (symbol-name method) kitty-lean-webview--raw)))

(defun kitty-lean-webview--diagnostics-message (uri version diagnostics)
  (kitty-lean-webview--json
   (list :method "textDocument/publishDiagnostics"
         :params (list :uri uri :version version :diagnostics diagnostics))))

(defun kitty-lean-webview--on-diagnostics (uri version diagnostics)
  "All of URI's DIAGNOSTICS, as the page wants them (one message, replacing)."
  (when (> (hash-table-count kitty-lean-webview--pages) 0)
    (kitty-lean-webview--notify "textDocument/publishDiagnostics"
                                (kitty-lean-webview--diagnostics-message uri version diagnostics))))

(defun kitty-lean-webview--on-client-notification (_conn method &optional params)
  "Emacs tells Lean METHOD (didChange, didClose): tell the subscribed pages."
  (when (and (> (hash-table-count kitty-lean-webview--pages) 0)
             (memq method '(:textDocument/didChange :textDocument/didClose)))
    (let ((name (substring (symbol-name method) 1)))
      (maphash (lambda (_ page)
                 (when (gethash name (kitty-lean-webview--page-subs page))
                   (kitty-lean-webview--send page (kitty-lean-webview--event "sentClientNotification" name params))))
               kitty-lean-webview--pages))))

(defun kitty-lean-webview--on-move ()
  "The cursor moved in a Lean buffer: tell the pages, if it moved."
  (when (and (> (hash-table-count kitty-lean-webview--pages) 0)
             (derived-mode-p 'nael-mode) (eglot-managed-p))
    (setq kitty-lean-webview--source (current-buffer))
    (maphash (lambda (_ page) (kitty-lean-webview--greet page)) kitty-lean-webview--pages)
    (let ((loc (kitty-lean-webview--location (current-buffer))))
      (unless (equal loc kitty-lean-webview--cursor)
        (setq kitty-lean-webview--cursor loc)
        (kitty-lean-webview--broadcast (kitty-lean-webview--event "changedCursorLocation" loc))))))

;;;; The page to Lean and Emacs (EditorApi)

(defun kitty-lean-webview--server-for (uri)
  (when-let* ((buffer (kitty-lean--buffer-for-uri uri)))
    (with-current-buffer buffer (eglot-current-server))))

(defun kitty-lean-webview--plist (value)
  "VALUE (parsed as hash tables) again as eglot's plists."
  (json-parse-string (json-serialize value :false-object :json-false :null-object nil)
                     :object-type 'plist :null-object nil :false-object :json-false))

(defun kitty-lean-webview--release-session (s)
  "Lean has no close for a session: it ends when its keep-alives stop."
  (ignore s))

(defun kitty-lean-webview--call (page-id body)
  "The page PAGE-ID calls an EditorApi method: BODY is {id, m, a}.
A forgotten page's calls are dropped: it reloads when its stream is back."
  (unless (member page-id kitty-lean-webview--forgotten)
    (kitty-lean-webview--call-1 page-id body)))

(defun kitty-lean-webview--call-1 (page-id body)
  (let* ((page (kitty-lean-webview--page page-id))
         (call (json-parse-string (decode-coding-string body 'utf-8)
                                  :object-type 'hash-table :null-object nil :false-object :json-false))
         (id (gethash "id" call))
         (m (gethash "m" call))
         (a (gethash "a" call)))
    (condition-case err
        (kitty-lean-webview--dispatch page id m a)
      (error (kitty-lean-webview--answer
              page id "err" (list :message (error-message-string err)))))))

(defun kitty-lean-webview--dispatch (page id m a)
  (let ((arg (lambda (n) (and (> (length a) n) (aref a n))))
        (ok (lambda (&optional v) (kitty-lean-webview--answer page id "val" v))))
    (pcase m
      ("sendClientRequest"
       (let* ((buffer (kitty-lean--buffer-for-uri (funcall arg 0)))
              (server (and buffer (with-current-buffer buffer (eglot-current-server))))
              key)
         (unless server (error "No Lean server for %s" (funcall arg 0)))
         ;; the edits eglot holds back first, as kitty-lean's own requests do:
         ;; else Lean answers about the text before them
         (with-current-buffer buffer (kitty-lean--flush))
         (cl-flet ((done (kind value)
                     (let ((raw (gethash key kitty-lean-webview--wanted)))
                       (remhash key kitty-lean-webview--wanted)
                       (if raw (kitty-lean-webview--answer page id "raw" raw)
                         (kitty-lean-webview--answer page id kind value)))))
           (setq key
                 (cons server
                       (car (jsonrpc-async-request
                             server (intern (concat ":" (funcall arg 1))) (funcall arg 2)
                             :success-fn (lambda (result) (done "val" result))
                             :error-fn (lambda (e) (done "err" e))
                             :timeout-fn (lambda () (done "err" '(:message "timeout")))
                             :timeout 600))))
           (puthash key nil kitty-lean-webview--wanted))))
      ("sendClientNotification"
       (when-let* ((server (kitty-lean-webview--server-for (funcall arg 0))))
         (jsonrpc-notify server (intern (concat ":" (funcall arg 1))) (funcall arg 2)))
       (funcall ok))
      ((or "subscribeServerNotifications" "subscribeClientNotifications")
       (let ((method (funcall arg 0)) (subs (kitty-lean-webview--page-subs page)))
         (puthash method (1+ (gethash method subs 0)) subs))
       (funcall ok))
      ((or "unsubscribeServerNotifications" "unsubscribeClientNotifications")
       (let* ((method (funcall arg 0)) (subs (kitty-lean-webview--page-subs page))
              (n (gethash method subs 0)))
         (when (> n 0)
           (if (> n 1) (puthash method (1- n) subs) (remhash method subs))))
       (funcall ok))
      ("createRpcSession"
       (let* ((uri (funcall arg 0)) (server (kitty-lean-webview--server-for uri)))
         (unless server (error "No Lean server for %s" uri))
         (jsonrpc-async-request
          server :$/lean/rpc/connect (list :uri uri)
          :success-fn (lambda (r)
                        (let ((sid (plist-get r :sessionId)))
                          (push (list server uri sid) (kitty-lean-webview--page-sessions page))
                          (funcall ok sid)))
          :error-fn (lambda (e) (kitty-lean-webview--answer page id "err" e)))))
      ("closeRpcSession"
       (let ((sid (funcall arg 0)))
         (setf (kitty-lean-webview--page-sessions page)
               (cl-remove-if (lambda (s) (equal (nth 2 s) sid)) (kitty-lean-webview--page-sessions page))))
       (funcall ok))
      ("saveConfig" (funcall ok))
      ("copyToClipboard" (kill-new (funcall arg 0)) (message "Copied: %s" (funcall arg 0)) (funcall ok))
      ("insertText"
       (kitty-lean-webview--insert-text (funcall arg 0) (funcall arg 1)
                                        (and (funcall arg 2) (kitty-lean-webview--plist (funcall arg 2))))
       (funcall ok))
      ("applyEdit"
       (let* ((edit (kitty-lean-webview--plist (funcall arg 0)))
              (uri (car (append (map-keys (plist-get edit :changes)) nil)))
              (server (or (and uri (kitty-lean-webview--server-for
                                    (if (keywordp uri) (substring (symbol-name uri) 1) uri)))
                          (eglot-current-server)))
              (eglot-confirm-server-edits nil))
         (eglot--apply-workspace-edit server edit 'infoview))
       (funcall ok))
      ("showDocument"
       (kitty-lean-webview--show (kitty-lean-webview--plist (funcall arg 0)))
       (funcall ok))
      ("restartFile"
       (when-let* ((buffer (kitty-lean--buffer-for-uri (funcall arg 0))))
         (with-current-buffer buffer (kitty-lean-restart-file)))
       (funcall ok))
      (_ (error "Unknown EditorApi call %s" m)))))

(defun kitty-lean-webview--goto (params)
  "Visit the file and position of PARAMS ({textDocument, position}); its buffer."
  (let* ((uri (plist-get (plist-get params :textDocument) :uri))
         (buffer (or (kitty-lean--buffer-for-uri uri) (find-file-noselect (eglot-uri-to-path uri)))))
    (pop-to-buffer buffer)
    (goto-char (eglot--lsp-position-to-point (plist-get params :position)))
    buffer))

(defun kitty-lean-webview--show (show)
  "VS Code's showDocument: go to SHOW's file, select its range."
  (let* ((range (plist-get show :selection))
         (buffer (or (kitty-lean--buffer-for-uri (plist-get show :uri))
                     (find-file-noselect (eglot-uri-to-path (plist-get show :uri))))))
    (select-window (or (get-buffer-window buffer) (display-buffer buffer)))
    (when range
      (goto-char (eglot--lsp-position-to-point (plist-get range :start))))))

(defun kitty-lean-webview--insert-text (text kind pos)
  "Insert TEXT at POS (or point): KIND \"above\" puts it on a line of its own above."
  (with-current-buffer (if pos (kitty-lean-webview--goto pos) (or (kitty-lean-webview--source) (current-buffer)))
    (if (equal kind "above")
        (let ((indent (current-indentation)))
          (forward-line 0)
          (insert (make-string indent ?\s) text "\n"))
      (insert text))))

;;;; The theme: Emacs' faces as the VS Code colours the page uses

(defun kitty-lean-webview--color (face attr &optional fallback)
  (let ((c (face-attribute face attr nil 'default)))
    (if (or (not (stringp c)) (string-prefix-p "unspecified" c))
        (or fallback "inherit")
      (apply #'format "#%02x%02x%02x" (mapcar (lambda (x) (/ x 257)) (color-values c))))))

(defun kitty-lean-webview--theme ()
  (let* ((fg (kitty-lean-webview--color 'default :foreground "#000000"))
         (bg (kitty-lean-webview--color 'default :background "#ffffff"))
         (family (let ((f (face-attribute 'default :family nil 'default)))
                   (if (and (stringp f) (not (member f '("default" "unspecified"))))
                       (format "\"%s\", monospace" f)
                     "monospace")))
         (height (face-attribute 'default :height nil 'default))
         ;; :height is in 1/10 pt; a terminal's is 1
         (size (if (and (integerp height) (> height 50)) (format "%dpx" (round (* height 0.1333))) "14px"))
         (added (kitty-lean-webview--color 'diff-refine-added :background "#2ea04340"))
         (removed (kitty-lean-webview--color 'diff-refine-removed :background "#f8514940"))
         (region (kitty-lean-webview--color 'region :background "#add6ff"))
         (tip (kitty-lean-webview--color 'tooltip :background bg))
         (border (kitty-lean-webview--color 'shadow :foreground "#888888")))
    (concat
     ":root {\n"
     (mapconcat
      (lambda (kv) (format "  --vscode-%s: %s;\n" (car kv) (cdr kv)))
      `(("editor-foreground" . ,fg) ("editor-background" . ,bg)
        ("foreground" . ,fg) ("font-family" . ,family)
        ("font-size" . ,size) ("font-weight" . "normal")
        ("editor-font-family" . ,family)
        ("editor-font-size" . ,size) ("editor-font-weight" . "normal")
        ("editor-line-height" . "1.4") ("editor-font-feature-settings" . "normal")
        ("diffEditor-insertedTextBackground" . ,added) ("diffEditor-removedTextBackground" . ,removed)
        ("diffEditor-insertedTextBorder" . "transparent") ("diffEditor-removedTextBorder" . "transparent")
        ("editor-selectionBackground" . ,region) ("editor-findMatchBackground" . ,region)
        ("editorHoverWidget-background" . ,tip) ("editorHoverWidget-foreground" . ,fg)
        ("editorHoverWidget-border" . ,border) ("widget-shadow" . "rgba(0,0,0,0.3)")
        ("textCodeBlock-background" . ,tip) ("textLink-foreground" . ,(kitty-lean-webview--color 'link :foreground "#0066cc"))
        ("dropdown-background" . ,bg) ("dropdown-foreground" . ,fg) ("dropdown-border" . ,border)
        ("editorOverviewRuler-rangeHighlightForeground" . ,region))
      "")
     "}\n"
     (format "body { background: %s; color: %s; font-family: var(--vscode-font-family); font-size: var(--vscode-font-size); }\n" bg fg))))

;;;; Showing it

;;;###autoload
(defun kitty-lean-webview ()
  "Show VS Code's own infoview for the Lean files: in a webview, or a browser."
  (interactive)
  (unless (and kitty-lean-webview-dist (file-directory-p kitty-lean-webview-dist))
    (user-error "VS Code's infoview is not installed (`kitty-lean-webview-dist')"))
  (let ((url (kitty-lean-webview--start)))
    (if (pcase kitty-lean-webview-display
          ('xwidget t)
          ('browser nil)
          (_ (and (display-graphic-p) (featurep 'xwidget-internal))))
        (progn
          (require 'xwidget)
          (unless (buffer-live-p kitty-lean-webview--buffer)
            (save-window-excursion
              (xwidget-webkit-browse-url url t)
              (setq kitty-lean-webview--buffer (xwidget-buffer (xwidget-webkit-last-session)))))
          (display-buffer kitty-lean-webview--buffer
                          '(display-buffer-in-side-window (side . right) (window-width . 0.42))))
      ;; through a private file that sends the browser on: the address
      ;; holds the secret, and a browser's command line is public
      (browse-url (concat "file://" (make-temp-file
                                     "kitty-lean-infoview" nil ".html"
                                     (format "<!DOCTYPE html><meta http-equiv=\"refresh\" content=\"0; url=%s\">" url)))))
    url))

(defmacro kitty-lean-webview--quietly (&rest body)
  "BODY, its errors only messages: it runs inside eglot, jsonrpc or the command loop."
  `(with-demoted-errors "kitty-lean-webview: %S" ,@body))

(defun kitty-lean-webview--on-client-notification-safe (&rest args)
  (kitty-lean-webview--quietly (apply #'kitty-lean-webview--on-client-notification args)))
(defun kitty-lean-webview--on-move-safe ()
  (kitty-lean-webview--quietly (kitty-lean-webview--on-move)))
(defun kitty-lean-webview--on-diagnostics-safe (&rest args)
  (kitty-lean-webview--quietly (apply #'kitty-lean-webview--on-diagnostics args)))

(advice-add 'jsonrpc-connection-receive :around #'kitty-lean-webview--keep-raw)
(advice-add 'jsonrpc-notify :before #'kitty-lean-webview--on-client-notification-safe)
(cl-defmethod eglot-handle-notification :before (_server method &rest params)
  (kitty-lean-webview--quietly (kitty-lean-webview--on-notification method params)))
(add-hook 'post-command-hook #'kitty-lean-webview--on-move-safe)
(add-hook 'kitty-lean-diagnostics-functions #'kitty-lean-webview--on-diagnostics-safe)

(defun kitty-lean-webview--on-server ()
  "A Lean server came up, or up again: pages greet it (VS Code's serverRestarted)."
  (kitty-lean-webview--quietly
   (maphash (lambda (_ page)
              (setf (kitty-lean-webview--page-greeted page) nil)
              (kitty-lean-webview--greet page))
            kitty-lean-webview--pages)))
(add-hook 'eglot-managed-mode-hook #'kitty-lean-webview--on-server)

(provide 'kitty-lean-webview)
;;; kitty-lean-webview.el ends here
