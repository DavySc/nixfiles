;;; kitty-lean.el --- Lean 4  -*- lexical-binding: t; -*-

;;; Commentary:

;; Lean 4 as VS Code's extension and my-nvim's lean.nvim have it, on top of
;; nael (the major mode: highlighting, \-abbreviations, Lean's LSP extensions
;; for eglot):
;;
;;   - the language server: `lake serve' in the file's project (eglot), with
;;     diagnostics (flymake, at the end of the line as everywhere), hover
;;     (K), completion, go to definition, references, rename, code actions,
;;     inlay hints and semantic highlighting;
;;   - the infoview: a window beside the code with the goals at the cursor,
;;     the expected type and the messages of the cursor's line, kept up to
;;     date as you move, type and as Lean finishes checking the file;
;;   - progress: how far Lean has checked the file, in the mode line and as a
;;     bar in the right fringe beside the lines it has not reached;
;;   - unicode input: \to → →, \N → ℕ, \< → ⟨⟩ ... as in VS Code;
;;   - Lake: build (errors as jumps), run main, Mathlib's cache, new projects;
;;   - Lean in org: babel blocks (`:project' for a Lake project's imports) and
;;     the full language server in a block's C-c ' buffer.
;;
;; The keys are my-nvim's (lua/lang/lean.lua, ftplugin/lean.lua): lean.nvim's
;; on \ in normal state (\i infoview, \r restart file, \u symbols, \l Loogle,
;; \s accept suggestion, \S sorry per goal, \\ how to type a symbol, \/ \f the
;; library's sources), and SPC m m / r / c for build, run, cache get.

;;; Code:

(require 'kitty-lib)
(require 'compile)
(require 'cl-lib)
(require 'seq)

(defvar kitty-cache-dir)
(defvar url-request-extra-headers)
(defvar url-user-agent)
(defvar org-src--beg-marker)
(defvar nael-mode-map)
(defvar nael-font-lock-defaults)
(defvar nael-abbrev-regexp)
(defvar nael-abbrev-singleton-table)
(defvar nael-abbrev-skeleton-table)
(defvar nael-abbrev-table)
(defvar eglot-server-programs)
(defvar eglot--managed-mode)
(defvar evil-normal-state-map)
(declare-function nael-mode "nael")
(declare-function nael-abbrev-help "nael-abbrev")
(declare-function nael-abbrev-configure "nael-abbrev")
(declare-function eglot-current-server "eglot")
(declare-function eglot--current-server-or-lose "eglot")
(declare-function eglot--TextDocumentPositionParams "eglot")
(declare-function eglot--TextDocumentIdentifier "eglot")
(declare-function eglot--signal-textDocument/didOpen "eglot")
(declare-function eglot--signal-textDocument/didClose "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-reconnect "eglot")
(declare-function eglot-uri-to-path "eglot")
(declare-function eglot-execute "eglot")
(declare-function eglot--range-region "eglot")
(declare-function eglot--format-markup "eglot")
(declare-function eglot-ensure "eglot")
(declare-function jsonrpc-async-request "jsonrpc")
(declare-function jsonrpc-request "jsonrpc")
(declare-function jsonrpc-notify "jsonrpc")
(declare-function kitty-eglot-ensure-for "kitty-prog")
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-end "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function consult-ripgrep "consult")
(declare-function consult-fd "consult")
(declare-function evil-define-key* "evil-core")
(declare-function evil-ex-define-cmd "evil-ex")
(declare-function org-babel-get-src-block-info "ob-core")
(declare-function org-babel-eval "ob-eval")
(declare-function org-babel-temp-file "ob-core")
(declare-function org-in-src-block-p "org")
(declare-function org-element-at-point "org-element")
(declare-function org-element-property "org-element")

(defgroup kitty-lean nil "Lean 4 in kittymax." :group 'kittymax)

;;;; The mode, the server

;; nael autoloads `nael-mode' for .lean; kittymax's own `project' markers
;; (kitty-prog.el) are set with setq, so Lake's go in here as well.
(when (locate-library "nael")
  ;; nael's autoloads, for when its package's are not loaded (no package-quickstart)
  (autoload 'nael-mode "nael" "Major mode for Lean." t)
  (autoload 'nael-abbrev-configure "nael-abbrev")
  (autoload 'nael-abbrev-help "nael-abbrev" nil t)
  (autoload 'nael-eglot-configure-when-managed "nael-eglot" nil t)
  (autoload 'nael-eglot-configure-when-initialized "nael-eglot")
  (add-to-list 'auto-mode-alist '("\\.lean\\'" . nael-mode)))
(dolist (marker '("lakefile.lean" "lakefile.toml"))
  (add-to-list 'project-vc-extra-root-markers marker))

;; abbrev-mode is how nael types \to → →; `abbrev-mode' saves nothing for it.
(setq save-abbrevs nil)

(defun kitty-lean-read-only-p (file)
  "Non-nil for FILE in a dependency or a toolchain: Mathlib under .lake/, ~/.elan.
A stray edit there breaks every project that uses it (lean.nvim's rule)."
  (and file
       (string-match-p "/\\.lake/packages/\\|/\\.elan/toolchains/\\|/nix/store/" file)))

(defun kitty--lean-setup ()
  "A Lean buffer: abbreviations, the server, dependencies read-only."
  (abbrev-mode 1)
  (when (kitty-lean-read-only-p buffer-file-name)
    (read-only-mode 1))
  ;; The org block's C-c ' buffer starts its server itself (below).
  (when buffer-file-name
    (kitty-lean--ensure-server)))
(kitty-add-hook 'nael-mode-hook #'kitty--lean-setup)

;; eglot registers a server only once it has answered `initialize'; a second
;; Lean file opened before that (two files at once, a jump to a definition
;; while `lake serve' starts) would start a second server for the project,
;; and one of the two exits, leaving its files without one.  While a start
;; is on its way, other files wait for it: eglot takes every file of the
;; project when the server is up.
(defvar kitty-lean--starting nil
  "(ROOT . TIME): projects whose server was asked to start, not yet up.")

(defconst kitty-lean--start-patience 60
  "Seconds a start is waited for; after that a file starts its own.")

(defun kitty-lean--project-key ()
  (file-truename (or (ignore-errors (project-root (project-current))) default-directory)))

(defun kitty-lean--ensure-server ()
  "eglot for this buffer, unless its project's server is already starting."
  (let* ((key (kitty-lean--project-key))
         (since (alist-get key kitty-lean--starting nil nil #'equal)))
    (cond
     ;; a server is up: eglot takes this buffer after the mode hooks
     ((and (fboundp 'eglot-current-server) (eglot-current-server))
      (kitty-eglot-ensure-for "lake"))
     ((not (and since (< (- (float-time) since) kitty-lean--start-patience)))
      (setf (alist-get key kitty-lean--starting nil nil #'equal) (float-time))
      (kitty-eglot-ensure-for "lake")))))

(declare-function eglot--project "eglot")
(defun kitty-lean--started (root)
  (setq kitty-lean--starting
        (cl-remove (file-truename root) kitty-lean--starting :key #'car :test #'equal)))
(defun kitty-lean--server-up (server)
  (when-let* ((root (ignore-errors (project-root (eglot--project server)))))
    (kitty-lean--started root)))
(kitty-add-hook 'eglot-connect-hook #'kitty-lean--server-up)

;; Lean files are long-lived proof states, not formatted by a tool.
(with-eval-after-load 'apheleia
  (defvar apheleia-mode-alist)
  (setf (alist-get 'nael-mode apheleia-mode-alist) nil))

;;;; Progress: how far Lean has checked the file

;; $/lean/fileProgress lists the ranges still being checked; it comes in
;; bursts while Lean elaborates.  The mode line says where Lean is, and the
;; right fringe (left is diff-hl's) marks the lines it has not reached, as
;; VS Code's orange bar does.  Drawing is coalesced: one redraw per burst.

(defvar-local kitty-lean--processing nil
  "Ranges ((BEG-LINE . END-LINE) ...) Lean is still checking, 0-based; nil when done.")
(defvar-local kitty-lean--progress-overlays nil)
(defvar-local kitty-lean--progress-timer nil)

(defvar kitty-lean-progress-delay 0.2
  "Seconds to wait after a progress report before redrawing the fringe.")

(define-fringe-bitmap 'kitty-lean-progress [#b11100000] nil nil '(center t))

(defface kitty-lean-progress '((t :inherit warning))
  "The right-fringe bar beside lines Lean has not checked yet.")

(defun kitty-lean-busy-p (&optional buffer)
  "Non-nil while Lean is still checking BUFFER (default: this one)."
  (buffer-local-value 'kitty-lean--processing (or buffer (current-buffer))))

(defun kitty-lean--mode-line ()
  "\"Lean ⧗ 40%\" while checking, nothing when done."
  (when kitty-lean--processing
    (let* ((first (car (car kitty-lean--processing)))
           (lines (max 1 (count-lines (point-min) (point-max)))))
      (format " ⧗ %d%%" (min 99 (/ (* 100 first) lines))))))

(defvar-local kitty-lean--mode-line-construct
    '(:eval (kitty-lean--mode-line)))
(put 'kitty-lean--mode-line-construct 'risky-local-variable t)

(defun kitty-lean--draw-progress (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kitty-lean--progress-timer nil)
      (mapc #'delete-overlay kitty-lean--progress-overlays)
      (setq kitty-lean--progress-overlays nil)
      (save-excursion
        (save-restriction
          (widen)
          (dolist (r kitty-lean--processing)
            (goto-char (point-min))
            (forward-line (car r))
            (let ((beg (point)))
              (forward-line (max 0 (- (cdr r) (car r))))
              (let ((ov (make-overlay beg (line-end-position))))
                (overlay-put ov 'line-prefix
                             (propertize " " 'display '(right-fringe kitty-lean-progress kitty-lean-progress)))
                (overlay-put ov 'kitty-lean-progress t)
                (push ov kitty-lean--progress-overlays))))))
      (force-mode-line-update))))

(defun kitty-lean--buffer-for-uri (uri)
  (when-let* ((path (ignore-errors (eglot-uri-to-path uri))))
    (or (find-buffer-visiting path)
        ;; an org block's C-c ' buffer (its file is never visited from disk)
        (seq-find (lambda (b) (equal (buffer-local-value 'buffer-file-name b) path)) (buffer-list)))))

(defun kitty-lean--on-progress (uri processing)
  "Lean reports PROCESSING (a vector of ranges) for the file at URI."
  (when-let* ((buffer (kitty-lean--buffer-for-uri uri)))
    (with-current-buffer buffer
      (let ((was kitty-lean--processing)
            (now (mapcar (lambda (p)
                           (let ((range (plist-get p :range)))
                             (cons (plist-get (plist-get range :start) :line)
                                   (plist-get (plist-get range :end) :line))))
                         processing)))
        (setq kitty-lean--processing now)
        (unless kitty-lean--progress-timer
          (setq kitty-lean--progress-timer
                (run-at-time kitty-lean-progress-delay nil #'kitty-lean--draw-progress buffer)))
        ;; Checking finished: the goals at the cursor may only now exist.
        (when (and was (null now) (kitty-lean--followed-p buffer))
          (kitty-lean-infoview-refresh buffer t))))))

(with-eval-after-load 'eglot
  (cl-defmethod eglot-handle-notification
    (_server (_method (eql $/lean/fileProgress)) &key textDocument processing &allow-other-keys)
    (kitty-lean--on-progress (plist-get textDocument :uri) processing)))

;;;; The infoview

;; VS Code's infoview, as text: the goals at the cursor (case names, each
;; hypothesis, ⊢ the target; what the last tactic changed in green, what the
;; next one will change in red; inaccessible names✝ greyed), the expected
;; type, the messages of the cursor's line (whole, with the goals inside an
;; "unsolved goals"), pinned positions, and a tally of all messages.  Beside
;; the code: right on a wide frame, below on a narrow one (lean.nvim's
;; orientation = "auto").
;;
;; Goals, expected type and messages come from Lean's RPC
;; (Lean.Widget.getInteractiveGoals ...), as VS Code's: every term in them
;; carries Lean's own information, so K on a term in the infoview shows its
;; type and documentation and gd / RET goes to its definition.  Without RPC
;; (an old Lean) the plain $/lean/plainGoal text is shown instead.
;;
;; What it shows always belongs to the most recent request: each refresh
;; takes a new generation, and answers of an older one are dropped, however
;; late they arrive (Lean answers a goal request only once it has checked the
;; file up to there, so answers come back out of order).  An answer that
;; failed (a timeout, ContentModified after an edit) leaves the infoview as
;; it was.  Refreshes come from eldoc's idle timer (nothing runs on each
;; key), from Lean finishing the file and from new diagnostics.  A refresh
;; for the same buffer, position and text as the last one is skipped unless
;; forced.  test/kitty_lean.tla models this; TLC checks that the infoview
;; never shows an older answer over a newer one and that it settles on the
;; goal at the cursor once you stop.

(defcustom kitty-lean-infoview-auto-open t
  "Open the infoview when a Lean file gets its server, as VS Code does."
  :type 'boolean)

(defcustom kitty-lean-infoview-hide-instances nil
  "Leave instance hypotheses ([inst : Monad m]) out of the goals."
  :type 'boolean)

(defcustom kitty-lean-infoview-hide-types nil
  "Leave type hypotheses (α : Type) out of the goals."
  :type 'boolean)

(defvar kitty-lean-infoview-buffer-name "*Lean Infoview*")

(defvar kitty-lean--gen 0 "Generation of the latest infoview request.")
(defvar kitty-lean--last-key nil "(BUFFER POINT TICK) of the latest infoview request.")
(defvar kitty-lean--source nil "The buffer the infoview shows.")
(defvar kitty-lean--paused nil "Non-nil: the infoview keeps what it shows.")
(defvar kitty-lean--pins nil "Markers the infoview also shows the goals of.")
(defvar kitty-lean--shown-refs nil "(BUFFER SESSION REFS) the infoview holds: released on the next render.")

(defface kitty-lean-infoview-heading '((t :inherit font-lock-function-name-face :weight bold))
  "Section headings in the infoview.")
(defface kitty-lean-infoview-case '((t :inherit font-lock-constant-face))
  "Case names of goals.")
(defface kitty-lean-infoview-hyp '((t :inherit font-lock-variable-name-face))
  "Hypothesis names.")
(defface kitty-lean-infoview-inaccessible '((t :inherit shadow))
  "Inaccessible names (x✝).")
(defface kitty-lean-infoview-inserted '((t :inherit diff-refine-added))
  "What the tactic before the cursor changed or added.")
(defface kitty-lean-infoview-removed '((t :inherit diff-refine-removed))
  "What the tactic at the cursor will change or remove.")

;;;;; Lean's RPC

;; A session per Lean buffer ($/lean/rpc/connect).  Lean drops a session
;; nobody keeps alive: while the infoview is open a timer sends keepAlive
;; every 10 s for the buffer it shows.  A call on a dropped session
;; (RpcNeedsReconnect) connects again and retries once.

(defvar-local kitty-lean--rpc-session nil "This buffer's RPC session id, or nil.")
(defvar kitty-lean--keepalive-timer nil)

(defconst kitty-lean--rpc-needs-reconnect -32900)

(defun kitty-lean--uri ()
  (plist-get (eglot--TextDocumentIdentifier) :uri))

(defun kitty-lean--rpc-connect ()
  "This buffer's RPC session, connecting when there is none."
  (or kitty-lean--rpc-session
      (setq kitty-lean--rpc-session
            (plist-get (jsonrpc-request (eglot--current-server-or-lose) :$/lean/rpc/connect
                                        (list :uri (kitty-lean--uri)))
                       :sessionId))))

(defun kitty-lean--rpc-call (buffer pos method params callback &optional retried)
  "Call Lean's RPC METHOD with PARAMS at POS of BUFFER, asynchronously.
CALLBACK gets (ok . RESULT): ok is nil on an error or a timeout."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let ((session (condition-case nil (kitty-lean--rpc-connect) (error nil))))
        (if (not session)
            (funcall callback (cons nil :no-session))
          (jsonrpc-async-request
           (eglot--current-server-or-lose) :$/lean/rpc/call
           (append (eglot--TextDocumentPositionParams)
                   (list :sessionId session :method method :params params))
           :success-fn (lambda (r) (funcall callback (cons t (if (eq r :null) nil r))))
           :error-fn (lambda (e)
                       (if (and (not retried) (eql (plist-get e :code) kitty-lean--rpc-needs-reconnect)
                                (buffer-live-p buffer))
                           (progn (with-current-buffer buffer (setq kitty-lean--rpc-session nil))
                                  (kitty-lean--rpc-call buffer pos method params callback t))
                         (funcall callback (cons nil e))))
           :timeout-fn (lambda () (funcall callback (cons nil nil)))))))))

(defun kitty-lean--rpc-call-sync (buffer pos method params)
  "Lean's RPC METHOD with PARAMS at POS of BUFFER; its result."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let ((r (jsonrpc-request (eglot--current-server-or-lose) :$/lean/rpc/call
                                (append (eglot--TextDocumentPositionParams)
                                        (list :sessionId (kitty-lean--rpc-connect) :method method :params params)))))
        (if (eq r :null) nil r)))))

(defun kitty-lean--keepalive ()
  "Keep the RPC session of the infoview's buffer alive, while it is shown."
  (if (not (kitty-lean--infoview-window))
      (progn (cancel-timer kitty-lean--keepalive-timer) (setq kitty-lean--keepalive-timer nil))
    (when-let* ((b kitty-lean--source)
                ((buffer-live-p b)))
      (with-current-buffer b
        (when (and kitty-lean--rpc-session (eglot-managed-p))
          (ignore-errors
            (jsonrpc-notify (eglot--current-server-or-lose) :$/lean/rpc/keepAlive
                            (list :uri (kitty-lean--uri) :sessionId kitty-lean--rpc-session))))))))

(defun kitty-lean--release-shown ()
  "Tell Lean the infoview no longer needs the references of what it showed."
  (pcase kitty-lean--shown-refs
    (`(,buffer ,session ,refs)
     (when (and refs (buffer-live-p buffer))
       (with-current-buffer buffer
         (when (and (eglot-managed-p) (equal session kitty-lean--rpc-session))
           (ignore-errors
             (jsonrpc-notify (eglot--current-server-or-lose) :$/lean/rpc/release
                             (list :uri (kitty-lean--uri) :sessionId session :refs (vconcat refs)))))))))
  (setq kitty-lean--shown-refs nil))

;;;;; Rendering Lean's tagged text

(defvar kitty-lean--refs nil "Info references met while rendering (to release later).")

(defun kitty-lean--diff-face (status)
  (pcase status
    ((or "wasChanged" "wasInserted") 'kitty-lean-infoview-inserted)
    ((or "willChange" "willInsert" "willDelete" "wasDeleted") 'kitty-lean-infoview-removed)))

(defun kitty-lean--insert-tagged (tt)
  "Insert Lean's TaggedText TT; terms carry their info as `kitty-lean-info'."
  (cond
   ((plist-member tt :text) (insert (plist-get tt :text)))
   ((plist-member tt :append) (seq-do #'kitty-lean--insert-tagged (plist-get tt :append)))
   ((plist-member tt :tag)
    (let* ((tag (plist-get tt :tag))
           (info (aref tag 0))
           (beg (point)))
      (kitty-lean--insert-tagged (aref tag 1))
      (cond
       ;; a term (SubexprInfo)
       ((plist-member info :info)
        (push (plist-get info :info) kitty-lean--refs)
        (put-text-property beg (point) 'kitty-lean-info (plist-get info :info))
        (when-let* ((face (kitty-lean--diff-face (plist-get info :diffStatus))))
          (put-text-property beg (point) 'kitty-lean-diff face)))
       ;; a message's embedded expression / goal (MsgEmbed)
       ((plist-member info :expr)
        (delete-region beg (point))
        (kitty-lean--insert-tagged (plist-get info :expr)))
       ((plist-member info :goal)
        (delete-region beg (point))
        (kitty-lean--insert-goal (plist-get info :goal)))
       ((plist-member info :trace)
        (delete-region beg (point))
        (let ((trace (plist-get info :trace)))
          (insert (make-string (or (plist-get trace :indent) 0) ?\s)
                  (propertize (format "[%s] " (or (plist-get trace :cls) "trace")) 'face 'shadow))
          (kitty-lean--insert-tagged (plist-get trace :msg))
          (when (plist-get trace :children) (insert (propertize " ▸" 'face 'shadow))))))))
   ((stringp tt) (insert tt))))

(defun kitty-lean--inaccessible (start end)
  "Grey the names with ✝ between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "[^ \n:,]*✝[⁰-⁹]*" end t)
      (put-text-property (match-beginning 0) (match-end 0) 'kitty-lean-face 'kitty-lean-infoview-inaccessible))))

(defun kitty-lean--insert-goal (goal)
  "Insert an InteractiveGoal (case, hypotheses, ⊢ target), or a plain goal string."
  (if (stringp goal)
      (insert goal "\n")
    (when-let* ((name (plist-get goal :userName)))
      (insert (propertize (concat "case " name) 'kitty-lean-face 'kitty-lean-infoview-case) "\n"))
    (seq-do
     (lambda (h)
       (unless (or (and kitty-lean-infoview-hide-instances (eq (plist-get h :isInstance) t))
                   (and kitty-lean-infoview-hide-types (eq (plist-get h :isType) t)))
         (let ((beg (point)))
           (insert (propertize (string-join (append (plist-get h :names) nil) " ")
                               'kitty-lean-face 'kitty-lean-infoview-hyp)
                   " : ")
           (kitty-lean--insert-tagged (plist-get h :type))
           (when-let* ((val (plist-get h :val)))
             (insert " := ")
             (kitty-lean--insert-tagged val))
           (kitty-lean--inaccessible beg (point))
           (cond ((eq (plist-get h :isInserted) t)
                  (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-inserted))
                 ((eq (plist-get h :isRemoved) t)
                  (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-removed)))
           (insert "\n"))))
     (plist-get goal :hyps))
    (let ((beg (point)))
      (insert (or (plist-get goal :goalPrefix) "⊢ "))
      (kitty-lean--insert-tagged (plist-get goal :type))
      (kitty-lean--inaccessible beg (point))
      (cond ((eq (plist-get goal :isInserted) t)
             (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-inserted))
            ((eq (plist-get goal :isRemoved) t)
             (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-removed)))
      (insert "\n"))))

(defun kitty-lean--fontify-region (beg end)
  "Lean's highlighting between BEG and END, under the infoview's own faces."
  (when (boundp 'nael-font-lock-defaults)
    (let ((text (buffer-substring-no-properties beg end)))
      (let ((faces (with-temp-buffer
                     (insert text)
                     (setq-local font-lock-defaults nael-font-lock-defaults)
                     (font-lock-ensure)
                     (let (acc (pos (point-min)))
                       (while (< pos (point-max))
                         (let ((next (next-single-property-change pos 'face nil (point-max)))
                               (face (get-text-property pos 'face)))
                           (when face (push (list (1- pos) (1- next) face) acc))
                           (setq pos next)))
                       acc))))
        (dolist (f faces)
          (put-text-property (+ beg (nth 0 f)) (+ beg (nth 1 f)) 'face (nth 2 f))))))
  ;; ours over Lean's: case names, hypotheses, ✝, then the diff
  (dolist (prop '(kitty-lean-face kitty-lean-diff))
    (let ((pos beg))
      (while (< pos end)
        (let ((next (next-single-property-change pos prop nil end))
              (face (get-text-property pos prop)))
          (when face (add-face-text-property pos next face))
          (setq pos next))))))

;;;;; Messages

(defun kitty-lean--lsp-diag (d)
  "The Lean diagnostic behind flymake's D (its LSP form)."
  (cdr (assq 'eglot-lsp-diag (flymake-diagnostic-data d))))
(declare-function flymake-diagnostic-data "flymake")

(defun kitty-lean--diagnostics-here (buffer pos)
  "Lean's diagnostics whose full range covers POS's line, as VS Code's Messages."
  (with-current-buffer buffer
    (when (bound-and-true-p flymake-mode)
      (let ((line (1- (line-number-at-pos pos))))
        (seq-filter
         (lambda (d)
           (let* ((lsp (kitty-lean--lsp-diag d))
                  (range (or (plist-get lsp :fullRange) (plist-get lsp :range))))
             (if range
                 (<= (plist-get (plist-get range :start) :line) line (plist-get (plist-get range :end) :line))
               (save-excursion (goto-char (flymake-diagnostic-beg d)) (= line (1- (line-number-at-pos)))))))
         (flymake-diagnostics))))))

(defun kitty-lean--severity (sev)
  (pcase sev (1 "error") (2 "warning") (3 "info") (_ "hint")))

(defun kitty-lean--severity-face (sev)
  (pcase sev (1 'error) (2 'warning) (_ 'success)))

(defun kitty-lean--insert-message (uri-buffer range severity message)
  "One message: where (RET jumps there), how bad, then the text."
  (let* ((start (plist-get range :start))
         (line (1+ (plist-get start :line)))
         (col (plist-get start :character))
         (beg (point)))
    (insert (propertize (format "%d:%d %s" line col (kitty-lean--severity severity))
                        'face (kitty-lean--severity-face severity)))
    (put-text-property beg (point) 'kitty-lean-location (list uri-buffer line col))
    (insert "\n")
    (let ((b (point)))
      (if (stringp message) (insert message) (kitty-lean--insert-tagged message))
      (kitty-lean--inaccessible b (point))
      (insert "\n\n"))))

(defun kitty-lean--tally (buffer)
  "\"All messages: 2 errors, 1 warning, 1 info\" for BUFFER."
  (with-current-buffer buffer
    (when (bound-and-true-p flymake-mode)
      (let ((e 0) (w 0) (i 0))
        (dolist (d (flymake-diagnostics))
          (pcase (plist-get (kitty-lean--lsp-diag d) :severity)
            (1 (cl-incf e)) (2 (cl-incf w)) (_ (cl-incf i))))
        (when (> (+ e w i) 0)
          (format "All messages: %d error%s, %d warning%s, %d info  (SPC x x)"
                  e (if (= e 1) "" "s") w (if (= w 1) "" "s") i))))))

;;;;; The infoview buffer

(defvar-keymap kitty-lean-infoview-mode-map
  :parent special-mode-map
  "RET" #'kitty-lean-infoview-goto
  "K" #'kitty-lean-infoview-hover
  "g d" #'kitty-lean-infoview-goto
  "p" #'kitty-lean-infoview-toggle-pause
  "c" #'kitty-lean-infoview-clear-pins
  "q" #'quit-window)

(define-derived-mode kitty-lean-infoview-mode special-mode "Infoview"
  "Lean's goals, expected type and messages at the cursor.
\\<kitty-lean-infoview-mode-map>\\[kitty-lean-infoview-hover] on a term: its type and documentation; \
\\[kitty-lean-infoview-goto]: its definition, or on a message: where it is."
  (setq-local truncate-lines nil
              word-wrap t
              cursor-in-non-selected-windows nil))

(defun kitty-lean--infoview-window ()
  (when-let* ((b (get-buffer kitty-lean-infoview-buffer-name)))
    (get-buffer-window b t)))

(defun kitty-lean-infoview-open ()
  "Show the infoview beside the code."
  (interactive)
  (let ((buffer (get-buffer-create kitty-lean-infoview-buffer-name))
        (source (current-buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'kitty-lean-infoview-mode) (kitty-lean-infoview-mode)))
    (display-buffer buffer
                    (if (>= (frame-width) 160)
                        '(display-buffer-in-side-window (side . right) (slot . 0) (window-width . 0.33)
                          (window-parameters (no-delete-other-windows . t)))
                      '(display-buffer-in-side-window (side . bottom) (slot . 0) (window-height . 0.33)
                        (window-parameters (no-delete-other-windows . t)))))
    (unless kitty-lean--keepalive-timer
      (setq kitty-lean--keepalive-timer (run-at-time 10 10 #'kitty-lean--keepalive)))
    (when (derived-mode-p 'nael-mode)
      (kitty-lean-infoview-refresh source t))))

(defun kitty-lean-infoview-toggle ()
  "The infoview on / off (lean.nvim's \\i)."
  (interactive)
  (if-let* ((w (kitty-lean--infoview-window)))
      (delete-window w)
    (kitty-lean-infoview-open)))

(defun kitty-lean-infoview-toggle-pause ()
  "Freeze the infoview where it is, or let it follow the cursor again (VS Code's pause)."
  (interactive)
  (setq kitty-lean--paused (not kitty-lean--paused))
  (message "Lean infoview %s" (if kitty-lean--paused "paused" "follows the cursor"))
  (unless kitty-lean--paused
    (when (buffer-live-p kitty-lean--source) (kitty-lean-infoview-refresh kitty-lean--source t))))

(defun kitty-lean-infoview-pin ()
  "Pin the goals here: the infoview keeps showing them as you move (lean.nvim's \\x)."
  (interactive)
  (push (copy-marker (point)) kitty-lean--pins)
  (kitty-lean-infoview-refresh (current-buffer) t))

(defun kitty-lean-infoview-clear-pins ()
  "Unpin every pinned position (lean.nvim's \\c)."
  (interactive)
  (setq kitty-lean--pins nil)
  (when (buffer-live-p kitty-lean--source) (kitty-lean-infoview-refresh kitty-lean--source t)))

(defun kitty-lean--info-at-point ()
  (or (get-text-property (point) 'kitty-lean-info)
      (user-error "No Lean term here")))

(defun kitty-lean-infoview-hover ()
  "The type and documentation of the term at point in the infoview (VS Code's hover there)."
  (interactive)
  (let* ((info (kitty-lean--info-at-point))
         (r (kitty-lean--rpc-call-sync kitty-lean--source (with-current-buffer kitty-lean--source (point))
                                       "Lean.Widget.InteractiveDiagnostics.infoToInteractive" info)))
    (with-help-window "*Lean term*"
      (with-current-buffer standard-output
        (let ((inhibit-read-only t) (beg (point)))
          (when-let* ((e (plist-get r :exprExplicit))) (kitty-lean--insert-tagged e))
          (when-let* ((ty (plist-get r :type))) (insert " : ") (kitty-lean--insert-tagged ty))
          (kitty-lean--fontify-region beg (point))
          (when-let* ((doc (plist-get r :doc))) (insert "\n\n" doc)))))))

(defun kitty-lean--goto-lsp-location (loc)
  (let* ((uri (or (plist-get loc :targetUri) (plist-get loc :uri)))
         (range (or (plist-get loc :targetSelectionRange) (plist-get loc :range)))
         (file (eglot-uri-to-path uri)))
    (xref-push-marker-stack)
    (pop-to-buffer (find-file-noselect file) '((display-buffer-reuse-window display-buffer-use-some-window)))
    (goto-char (point-min))
    (forward-line (plist-get (plist-get range :start) :line))
    (forward-char (plist-get (plist-get range :start) :character))))
(declare-function xref-push-marker-stack "xref")

(defun kitty-lean-infoview-goto ()
  "On a term: go to its definition (VS Code's ctrl-click).  On a message: to where it is."
  (interactive)
  (if-let* ((loc (get-text-property (point) 'kitty-lean-location)))
      (pcase-let ((`(,buffer ,line ,col) loc))
        (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)))
        (goto-char (point-min)) (forward-line (1- line)) (forward-char col))
    (let* ((info (kitty-lean--info-at-point))
           (locs (kitty-lean--rpc-call-sync kitty-lean--source (with-current-buffer kitty-lean--source (point))
                                            "Lean.Widget.getGoToLocation" (list :kind "definition" :info info))))
      (if (seq-empty-p locs)
          (message "Lean: no definition for this term")
        (kitty-lean--goto-lsp-location (seq-first locs))))))

(defun kitty-lean--render (buffer pos parts)
  "Fill the infoview with PARTS, Lean's answers for POS in BUFFER.
PARTS: plist :goals (interactive goals, or plain strings) :term :messages :pins."
  (when-let* ((iv (get-buffer kitty-lean-infoview-buffer-name)))
    (kitty-lean--release-shown)
    (let* ((kitty-lean--refs nil)
           (name (buffer-name buffer))
           (line-col (with-current-buffer buffer
                       (save-excursion (goto-char pos)
                                       (format "%d:%d" (line-number-at-pos) (current-column)))))
           (busy (kitty-lean-busy-p buffer))
           (goals (plist-get parts :goals))
           (term (plist-get parts :term))
           (messages (plist-get parts :messages)))
      (with-current-buffer iv
        (let ((inhibit-read-only t)
              (wstart (when-let* ((w (get-buffer-window iv t))) (window-start w))))
          (erase-buffer)
          (insert (propertize (format "%s:%s" name line-col) 'face 'shadow)
                  (if busy (propertize "  ⧗ checking…" 'face 'warning) "")
                  (if kitty-lean--paused (propertize "  ⏸ paused (p)" 'face 'warning) "")
                  "\n\n")
          (dolist (pin (plist-get parts :pins))
            (insert (propertize (format "Pinned at %s" (car pin)) 'face 'kitty-lean-infoview-heading) "\n")
            (let ((b (point)))
              (if (seq-empty-p (cdr pin)) (insert "No goals\n")
                (seq-do (lambda (g) (kitty-lean--insert-goal g) (insert "\n")) (cdr pin)))
              (kitty-lean--fontify-region b (point)))
            (insert "\n"))
          (cond
           ((eq goals :none))
           ((seq-empty-p goals)
            (insert (propertize "Tactic state" 'face 'kitty-lean-infoview-heading) "\n"
                    (propertize "No goals" 'face 'success) "\n\n"))
           (t
            (insert (propertize "Tactic state" 'face 'kitty-lean-infoview-heading)
                    (propertize (format "  %d goal%s" (length goals) (if (= 1 (length goals)) "" "s")) 'face 'shadow)
                    "\n")
            (let ((b (point)))
              (seq-do (lambda (g) (kitty-lean--insert-goal g) (insert "\n")) goals)
              (kitty-lean--fontify-region b (point)))))
          (when term
            (insert (propertize "Expected type" 'face 'kitty-lean-infoview-heading) "\n")
            (let ((b (point)))
              (kitty-lean--insert-goal term)
              (kitty-lean--fontify-region b (point)))
            (insert "\n"))
          (when messages
            (insert (propertize (format "Messages (%d)" (length messages)) 'face 'kitty-lean-infoview-heading) "\n")
            (dolist (m messages)
              (let ((b (point)))
                (kitty-lean--insert-message buffer (car m) (nth 1 m) (nth 2 m))
                (kitty-lean--fontify-region b (point)))))
          (unless (or (not (eq goals :none)) term messages)
            (insert (propertize (if busy "Lean is checking the file…" "Nothing here.") 'face 'shadow) "\n\n"))
          (when-let* ((tally (kitty-lean--tally buffer)))
            (insert (propertize tally 'face 'shadow) "\n"))
          (goto-char (point-min))
          (when-let* ((w (get-buffer-window iv t)))
            (set-window-start w (min (or wstart 1) (point-max))))))
      (setq kitty-lean--shown-refs
            (list buffer (buffer-local-value 'kitty-lean--rpc-session buffer) kitty-lean--refs)))))

;;;;; Asking Lean

(defun kitty-lean--request (method buffer pos callback)
  "Ask the server METHOD for POS in BUFFER; CALLBACK gets (ok . answer)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (jsonrpc-async-request
       (eglot--current-server-or-lose) method (eglot--TextDocumentPositionParams)
       :success-fn (lambda (r) (funcall callback (cons t (if (eq r :null) nil r))))
       :error-fn (lambda (e) (funcall callback (cons nil e)))
       :timeout-fn (lambda () (funcall callback (cons nil nil)))))))

(defun kitty-lean--no-rpc-p (answer)
  "Non-nil when ANSWER says Lean has no RPC here (an old Lean, no session)."
  (and (not (car answer))
       (or (eq (cdr answer) :no-session)
           (and (consp (cdr answer)) (memq (plist-get (cdr answer) :code) '(-32601 -32602))))))

(defun kitty-lean--ask-goals (buffer pos callback)
  "Goals at POS: interactive ones over RPC, else plain.  CALLBACK gets (ok . goals).
The goals are a list, or :none outside a proof."
  (kitty-lean--rpc-call
   buffer pos "Lean.Widget.getInteractiveGoals"
   (with-current-buffer buffer (save-excursion (goto-char pos) (eglot--TextDocumentPositionParams)))
   (lambda (a)
     (cond
      ((car a) (funcall callback (cons t (if (cdr a) (append (plist-get (cdr a) :goals) nil) :none))))
      ((kitty-lean--no-rpc-p a)
       (kitty-lean--request :$/lean/plainGoal buffer pos
                            (lambda (p) (funcall callback
                                                 (cons (car p) (if (cdr p) (append (plist-get (cdr p) :goals) nil) :none))))))
      (t (funcall callback (cons nil nil)))))))

(defun kitty-lean--ask-term (buffer pos callback)
  "The expected type at POS.  CALLBACK gets (ok . goal-or-nil)."
  (kitty-lean--rpc-call
   buffer pos "Lean.Widget.getInteractiveTermGoal"
   (with-current-buffer buffer (save-excursion (goto-char pos) (eglot--TextDocumentPositionParams)))
   (lambda (a)
     (if (kitty-lean--no-rpc-p a)
         (kitty-lean--request :$/lean/plainTermGoal buffer pos
                              (lambda (p) (funcall callback
                                                   (cons (car p) (and (cdr p) (plist-get (cdr p) :goal))))))
       (funcall callback a)))))

(defun kitty-lean--ask-messages (buffer pos callback)
  "Messages of POS's line, interactive when Lean can.  CALLBACK gets (t . ((range sev msg) ...))."
  (let ((here (kitty-lean--diagnostics-here buffer pos)))
    (if (null here)
        (funcall callback (cons t nil))
      (let ((line (with-current-buffer buffer (1- (line-number-at-pos pos)))))
        (kitty-lean--rpc-call
         buffer pos "Lean.Widget.getInteractiveDiagnostics"
         (list :lineRange (list :start line :end (1+ line)))
         (lambda (a)
           (funcall callback
                    (cons t
                          (if (and (car a) (not (seq-empty-p (cdr a))))
                              (mapcar (lambda (d) (list (or (plist-get d :fullRange) (plist-get d :range))
                                                        (plist-get d :severity) (plist-get d :message)))
                                      (cdr a))
                            ;; flymake's copy, as plain text
                            (mapcar (lambda (d)
                                      (let ((lsp (kitty-lean--lsp-diag d)))
                                        (list (or (plist-get lsp :fullRange) (plist-get lsp :range))
                                              (plist-get lsp :severity)
                                              (or (plist-get lsp :message) (flymake-diagnostic-text d)))))
                                    here))))))))))

(defun kitty-lean--refresh-target (buffer)
  "The point of BUFFER the infoview should follow: its selected window's, if any."
  (let ((w (if (eq (window-buffer (selected-window)) buffer)
               (selected-window)
             (get-buffer-window buffer t))))
    (if w (window-point w) (with-current-buffer buffer (point)))))

(defun kitty-lean-infoview-refresh (&optional buffer force)
  "Ask Lean for the goals at the cursor of BUFFER and show them.
Skipped when the infoview is closed or paused, or (unless FORCE) when nothing moved."
  (let ((buffer (or buffer (current-buffer))))
    (when (and (kitty-lean--infoview-window)
               (not kitty-lean--paused)
               (buffer-live-p buffer)
               (with-current-buffer buffer
                 (and (derived-mode-p 'nael-mode)
                      (fboundp 'eglot-managed-p) (eglot-managed-p))))
      (let* ((pos (kitty-lean--refresh-target buffer))
             (key (list buffer pos (buffer-chars-modified-tick buffer))))
        (when (or force (not (equal key kitty-lean--last-key)))
          (setq kitty-lean--last-key key
                kitty-lean--source buffer)
          (let* ((gen (cl-incf kitty-lean--gen))
                 (pins (seq-filter (lambda (m) (eq (marker-buffer m) buffer)) kitty-lean--pins))
                 (want (+ 3 (length pins)))
                 (parts nil)
                 (failed nil)
                 (done (lambda (key answer)
                         (if (not (car answer)) (setq failed t)
                           (if (eq key :pins)
                               (setq parts (plist-put parts :pins (cons (cdr answer) (plist-get parts :pins))))
                             (setq parts (plist-put parts key (cdr answer)))))
                         (when (and (zerop (cl-decf want)) (= gen kitty-lean--gen) (not failed))
                           (kitty-lean--render buffer pos parts)))))
            (kitty-lean--ask-goals buffer pos (lambda (a) (funcall done :goals a)))
            (kitty-lean--ask-term buffer pos (lambda (a) (funcall done :term a)))
            (kitty-lean--ask-messages buffer pos (lambda (a) (funcall done :messages a)))
            (dolist (m pins)
              (let ((where (with-current-buffer buffer
                             (save-excursion (goto-char m) (format "%d:%d" (line-number-at-pos) (current-column))))))
                (kitty-lean--ask-goals buffer (marker-position m)
                                       (lambda (a) (funcall done :pins
                                                            (cons (car a) (cons where (if (eq (cdr a) :none) nil (cdr a)))))))))))))))

(defun kitty-lean--eldoc-refresh (_callback &rest _)
  "An eldoc function that shows nothing itself: it refreshes the infoview.
eldoc runs it when the cursor has rested, so moving costs nothing per key."
  (kitty-lean-infoview-refresh (current-buffer))
  nil)

(defun kitty-lean--followed-p (buffer)
  "Whether news from BUFFER's server (checked, diagnostics) is for the infoview.
Only for the file it shows, or the one in the selected window: a file Lean
checks in the background (a definition you looked at) does not take it over."
  (or (eq buffer kitty-lean--source)
      (eq buffer (window-buffer (selected-window)))))

(defun kitty-lean--after-diagnostics (&rest _)
  "New diagnostics: the infoview's messages may have changed."
  (when (and (derived-mode-p 'nael-mode) (kitty-lean--followed-p (current-buffer)))
    (kitty-lean-infoview-refresh (current-buffer) t)))

(defun kitty--lean-managed ()
  "eglot took this Lean buffer: the infoview follows it."
  (when (derived-mode-p 'nael-mode)
    (setq kitty-lean--rpc-session nil)
    (if (not (eglot-managed-p))
        (remove-hook 'eldoc-documentation-functions #'kitty-lean--eldoc-refresh t)
      (kitty-lean--started (kitty-lean--project-key))
      (add-hook 'eldoc-documentation-functions #'kitty-lean--eldoc-refresh nil t)
      (unless (memq 'kitty-lean--mode-line-construct mode-line-misc-info)
        (setq-local mode-line-misc-info (cons 'kitty-lean--mode-line-construct mode-line-misc-info)))
      (when (and kitty-lean-infoview-auto-open (not (kitty-lean--infoview-window))
                 (get-buffer-window (current-buffer)))
        (kitty-lean-infoview-open)))))
(kitty-add-hook 'eglot-managed-mode-hook #'kitty--lean-managed)

(declare-function eglot--major-modes "eglot")
(defun kitty-lean--quiet-shutdown (shutdown server &rest args)
  "Lean's server exits as soon as it has answered `shutdown'.
eglot then sends it `exit' and gets an error, which, from closing the last
Lean file, is an error out of `kill-buffer'.  The server is gone either way."
  (if (not (memq 'nael-mode (ignore-errors (eglot--major-modes server))))
      (apply shutdown server args)
    (condition-case err
        (apply shutdown server args)
      (error (when (jsonrpc-running-p server)
               (signal (car err) (cdr err)))))))
(with-eval-after-load 'eglot
  (advice-add 'eglot-shutdown :around #'kitty-lean--quiet-shutdown))

(with-eval-after-load 'flymake
  (advice-add 'flymake--handle-report :after
              (lambda (&rest _)
                (when (derived-mode-p 'nael-mode) (kitty-lean--after-diagnostics)))
              '((name . kitty-lean-after-diagnostics))))

(with-eval-after-load 'evil
  (evil-define-key* 'normal kitty-lean-infoview-mode-map
    (kbd "RET") #'kitty-lean-infoview-goto
    (kbd "K") #'kitty-lean-infoview-hover
    (kbd "gd") #'kitty-lean-infoview-goto
    (kbd "p") #'kitty-lean-infoview-toggle-pause
    (kbd "c") #'kitty-lean-infoview-clear-pins
    (kbd "q") #'quit-window))

;;;; Commands

(defun kitty-lean-restart-file ()
  "Check this file again from the start, with freshly built imports (\\r).
VS Code's Restart File: close and reopen the document on the server."
  (interactive)
  (unless (eglot-managed-p) (user-error "Lean: no server for this buffer"))
  (eglot--signal-textDocument/didClose)
  (eglot--signal-textDocument/didOpen)
  (message "Lean: checking %s again" (buffer-name)))

(defun kitty-lean-restart-server ()
  "Restart the Lean server (VS Code's Restart Server)."
  (interactive)
  (call-interactively #'eglot-reconnect))

(defun kitty-lean--goals-at (pos)
  "Lean's goals at POS, synchronously (a list of strings)."
  (save-excursion
    (goto-char pos)
    (let ((r (jsonrpc-request (eglot--current-server-or-lose) :$/lean/plainGoal
                              (eglot--TextDocumentPositionParams))))
      (and (listp r) (append (plist-get r :goals) nil)))))

(defun kitty-lean-sorry-fill ()
  "A `· sorry' for each open goal, below this line (lean.nvim's :LeanSorryFill)."
  (interactive)
  (let* ((goals (kitty-lean--goals-at (line-end-position)))
         (n (length goals)))
    (if (zerop n)
        (message "Lean: no goals here")
      (let ((indent (save-excursion
                      (back-to-indentation)
                      (current-column))))
        (save-excursion
          (end-of-line)
          (dotimes (_ n)
            (insert "\n" (make-string indent ?\s) (if (> n 1) "· sorry" "sorry"))))
        (forward-line 1)
        (back-to-indentation)))))

(defun kitty-lean--code-actions ()
  "The server's code actions on this line."
  (let ((params (list :textDocument (eglot--TextDocumentIdentifier)
                      :range (eglot-region-range (line-beginning-position) (line-end-position))
                      :context (list :diagnostics []))))
    (append (jsonrpc-request (eglot--current-server-or-lose) :textDocument/codeAction params) nil)))
(declare-function eglot-region-range "eglot")

(defun kitty-lean-accept-suggestion ()
  "Apply Lean's first `Try this' on this line: exact?, apply?, simp? (lean.nvim's \\s)."
  (interactive)
  (let ((action (seq-find (lambda (a) (string-match-p "\\`Try this" (or (plist-get a :title) "")))
                          (kitty-lean--code-actions))))
    (if action
        (eglot-execute (eglot--current-server-or-lose) action)
      (message "Lean: no suggestion on this line"))))

;;;;; Unicode

(defun kitty-lean--abbrevs ()
  "Alist (ABBREV . EXPANSION) of every \\-abbreviation, shortest first."
  (require 'nael-abbrev)
  (let (all)
    (dolist (table (list nael-abbrev-singleton-table nael-abbrev-skeleton-table))
      (mapatoms
       (lambda (sym)
         (let ((name (symbol-name sym)))
           (unless (string-empty-p name)
             (let ((exp (cond ((and (boundp sym) (stringp (symbol-value sym))
                                    (not (string-empty-p (symbol-value sym))))
                               (symbol-value sym))
                              ((functionp (symbol-function sym))
                               (with-temp-buffer
                                 (funcall (symbol-function sym))
                                 (concat (buffer-substring-no-properties (point-min) (point))
                                         (buffer-substring-no-properties (point) (point-max))))))))
               (when (and exp (not (string-empty-p exp)))
                 (push (cons name exp) all))))))
       table))
    (sort all (lambda (a b) (or (< (length (car a)) (length (car b)))
                                (and (= (length (car a)) (length (car b))) (string< (car a) (car b))))))))

(defun kitty-lean-insert-symbol ()
  "Pick a symbol by its abbreviation or by itself, and insert it (lean.nvim's \\u)."
  (interactive)
  (let* ((all (kitty-lean--abbrevs))
         (cands (mapcar (lambda (a) (cons (format "%s  %s" (cdr a) (car a)) a)) all))
         (pick (completing-read "Lean symbol: " cands nil t))
         (abbrev (car (cdr (assoc pick cands)))))
    (when abbrev
      ;; the abbrev's own expansion: skeletons put point between ⟨ and ⟩
      (insert abbrev)
      (require 'nael-abbrev)
      (let ((local-abbrev-table nael-abbrev-table))
        (expand-abbrev)))))

(defun kitty-lean-describe-symbol ()
  "How to type the symbol under the cursor (lean.nvim's \\\\, VS Code's hover on it)."
  (interactive)
  (require 'nael-abbrev)
  (let ((local-abbrev-table nael-abbrev-table))
    (call-interactively #'nael-abbrev-help)))

(defvar kitty-lean--abbrev-names nil "Every \\-abbreviation, for eager replacement.")

(defun kitty-lean--abbrev-names ()
  (or kitty-lean--abbrev-names
      (setq kitty-lean--abbrev-names (mapcar #'car (kitty-lean--abbrevs)))))

(defun kitty-lean--eager-expand ()
  "VS Code's eager replacement, after each character typed.
An abbreviation is replaced as soon as it is complete and no longer one
starts with it (\\forall → ∀ at the l), or once the next character makes
it the start of none (\\<x → ⟨x⟩).  nael itself replaces the rest when a
space or punctuation follows (\\to SPC → → )."
  (when-let* ((start (save-excursion
                       (skip-chars-backward "^\\\\ \t\n" (max (line-beginning-position) (- (point) 40)))
                       (and (eq (char-before) ?\\) (1- (point)))))
              ((> (- (point) start) 1)))
    (let* ((typed (buffer-substring-no-properties start (point)))
           (names (kitty-lean--abbrev-names))
           (done (try-completion typed names)))
      (cond
       ((eq done t) (expand-abbrev))
       ((and (null done) (> (length typed) 2) (member (substring typed 0 -1) names))
        (save-excursion (backward-char) (expand-abbrev)))))))

(defun kitty--lean-eager ()
  (add-hook 'post-self-insert-hook #'kitty-lean--eager-expand 90 t))
(kitty-add-hook 'nael-mode-hook #'kitty--lean-eager)

(defun kitty-lean-expand-before-point ()
  "Turn a \\-abbreviation just typed into its symbol (on leaving insert state).
VS Code and lean.nvim do this when the cursor leaves the abbreviation."
  (when (and (derived-mode-p 'nael-mode) (bound-and-true-p abbrev-mode)
             (boundp 'nael-abbrev-regexp)
             (looking-back nael-abbrev-regexp (line-beginning-position)))
    (expand-abbrev)))

;;;;; Loogle and the library's sources

(defvar kitty-lean-loogle-url "https://loogle.lean-lang.org/json?q="
  "Loogle's JSON API.")

(defun kitty-lean--loogle-fetch (query)
  "Loogle's answer for QUERY, as a plist (:hits ... :error ...)."
  (require 'url)
  (let ((url-request-extra-headers '(("Accept" . "application/json")))
        (url-user-agent "kittymax"))
    (with-current-buffer (url-retrieve-synchronously (concat kitty-lean-loogle-url (url-hexify-string query)) t t 20)
      (goto-char (point-min))
      (re-search-forward "\n\n" nil t)
      (prog1 (json-parse-buffer :object-type 'plist :array-type 'list :null-object nil)
        (kill-buffer)))))

(defun kitty-lean-loogle (query)
  "Search Mathlib with Loogle: a name, `Real.sqrt', or a shape, `(?a + ?b) * ?c' (\\l).
The picked name is inserted at point."
  (interactive (list (read-string "Loogle: ")))
  (let* ((answer (kitty-lean--loogle-fetch query))
         (hits (plist-get answer :hits)))
    (cond
     ((plist-get answer :error)
      (user-error "Loogle: %s%s" (plist-get answer :error)
                  (if-let* ((s (plist-get answer :suggestions)))
                      (concat "; did you mean " (string-join s ", ")) "")))
     ((null hits) (user-error "Loogle: nothing for %s" query))
     (t
      (let* ((table (mapcar (lambda (h) (cons (plist-get h :name) h)) hits))
             (completion-extra-properties
              (list :annotation-function
                    (lambda (c)
                      (let ((h (cdr (assoc c table))))
                        (format "  : %s   %s"
                                (truncate-string-to-width (or (plist-get h :type) "") 70 nil nil "…")
                                (propertize (or (plist-get h :module) "") 'face 'shadow))))))
             (pick (completing-read (format "Loogle %s: " query) table nil t)))
        (insert pick))))))

(defun kitty-lean-root (&optional dir)
  "The Lake project above DIR (default: this buffer's directory), or nil."
  (let ((dir (or dir default-directory)))
    (or (locate-dominating-file dir "lakefile.toml")
        (locate-dominating-file dir "lakefile.lean")
        (locate-dominating-file dir "lean-toolchain"))))

(defun kitty-lean-library-dirs ()
  "Core Lean's sources and those of the project's dependencies (Mathlib ...)."
  (let* ((root (kitty-lean-root))
         (default-directory (or root default-directory))
         (prefix (string-trim (shell-command-to-string "lean --print-prefix 2>/dev/null")))
         (core (and (not (string-empty-p prefix)) (expand-file-name "src/lean" prefix)))
         (deps (and root (file-directory-p (expand-file-name ".lake/packages" root))
                    (directory-files (expand-file-name ".lake/packages" root) t "\\`[^.]"))))
    (seq-filter #'file-directory-p (delq nil (cons core deps)))))

(defun kitty-lean-grep-library ()
  "Grep core Lean and the project's dependencies (lean.nvim's \\/)."
  (interactive)
  (let ((dirs (or (kitty-lean-library-dirs) (user-error "Lean: no library sources found"))))
    (consult-ripgrep dirs)))

(defun kitty-lean-find-library-file ()
  "Find a file in core Lean and the project's dependencies (\\f)."
  (interactive)
  (let ((dirs (or (kitty-lean-library-dirs) (user-error "Lean: no library sources found"))))
    (consult-fd dirs)))

;;;;; Lake

;; Lake: "error: Demo/Bad.lean:1:15: Type mismatch", relative to the project,
;; 0-based column.  `lean file' alone: "file:1:15: error: ...".
(defconst kitty-lean-lake-error-regexp
  "^\\(?:\\(?4:warning\\)\\|\\(?5:info\\)\\|error\\): \\(?:\\./\\)?\\(?1:[^:\n]+\\.lean\\):\\(?2:[0-9]+\\):\\(?3:[0-9]+\\):"
  "A message from `lake build'.")

(defun kitty-lean--column ()
  (1+ (string-to-number (match-string 3))))

(with-eval-after-load 'compile
  (setf (alist-get 'kitty-lake compilation-error-regexp-alist-alist)
        (list kitty-lean-lake-error-regexp 1 2 #'kitty-lean--column '(4 . 5)))
  (add-to-list 'compilation-error-regexp-alist 'kitty-lake))

(defvar compilation-arguments)
(declare-function ansi-color-compilation-filter "ansi-color")

(defun kitty-lean--ansi-colours ()
  "Lake colours its output when it sees a terminal, and compile gives it one."
  (when (and (stringp (car-safe compilation-arguments))
             (string-match-p "\\`\\(?:lake\\|lean\\) " (car compilation-arguments)))
    (ansi-color-compilation-filter)))

(with-eval-after-load 'compile
  (require 'ansi-color)
  (add-hook 'compilation-filter-hook #'kitty-lean--ansi-colours))

(defun kitty-lean--project-or-lose ()
  (or (kitty-lean-root) (user-error "Lean: no lakefile above this file")))

(defun kitty-lean-build (&optional target)
  "`lake build' in this project: errors and warnings as jumps (SPC m m).
With C-u, asks for a TARGET."
  (interactive (list (and current-prefix-arg (read-string "lake build target: "))))
  (let ((default-directory (kitty-lean--project-or-lose)))
    (save-some-buffers t (lambda () (derived-mode-p 'nael-mode)))
    (compile (string-join (delq nil (list "lake build" (and target (shell-quote-argument target)))) " "))))

(defun kitty-lean-run-file (&optional args)
  "Run this file's `main' (`lake env lean --run'), C-u asks for ARGS (SPC m r)."
  (interactive (list (and current-prefix-arg (read-string "args: "))))
  (let* ((file (or buffer-file-name (user-error "Lean: this buffer is not a file")))
         (root (kitty-lean-root))
         (default-directory (or root (file-name-directory file))))
    (when (buffer-modified-p) (save-buffer))
    (compile (concat (if root "lake env lean --run " "lean --run ")
                     (shell-quote-argument (file-local-name file))
                     (if (and args (not (string-empty-p args))) (concat " " args) ""))
             t)))

(defun kitty-lean-lake (args)
  "`lake ARGS' at the project root (my-nvim's :Lake): update, test, exe ..."
  (interactive (list (read-string "lake " nil nil "build")))
  (let ((default-directory (or (kitty-lean-root) default-directory)))
    (compile (concat "lake " args) t)))

(defun kitty-lean-cache-get ()
  "`lake exe cache get': Mathlib prebuilt, so nothing compiles here (SPC m c)."
  (interactive)
  (kitty-lean-lake "exe cache get"))

(defun kitty-lean-new-project (name &optional math)
  "A new Lake project NAME in this directory; MATH (C-u): with Mathlib, prebuilt.
my-nvim's :LeanNew name [math]."
  (interactive (list (read-string "New Lean project: ") current-prefix-arg))
  (let* ((cwd default-directory)
         (dir (expand-file-name name cwd))
         (lib (concat (upcase (substring name 0 1)) (substring name 1))))
    (when (file-exists-p dir) (user-error "Lean: %s already exists" dir))
    (let ((cmd (if math
                   (format "lake +leanprover-community/mathlib4:lean-toolchain new %s math && cd %s && lake exe cache get"
                           (shell-quote-argument name) (shell-quote-argument name))
                 (format "lake new %s" (shell-quote-argument name)))))
      (let ((buf (compile cmd t)))
        (with-current-buffer buf
          (add-hook 'compilation-finish-functions
                    (lambda (_b status)
                      (when (string-prefix-p "finished" status)
                        (let ((basic (expand-file-name (concat lib "/Basic.lean") dir)))
                          (find-file (if (file-exists-p basic) basic (expand-file-name (concat lib ".lean") dir))))))
                    nil t))))))

(defun kitty-lean-ex-lake (args)
  "`:Lake ARGS'."
  (interactive "<a>")
  (kitty-lean-lake (or args "build")))

(defun kitty-lean-ex-new (args)
  "`:LeanNew name [math]'."
  (interactive "<a>")
  (let ((words (split-string (or args "") " " t)))
    (unless words (user-error "LeanNew: a name, then `math' or nothing"))
    (when (and (cadr words) (not (equal (cadr words) "math")))
      (user-error "LeanNew: the second word is `math' or nothing"))
    (kitty-lean-new-project (car words) (cadr words))))

;;;; Keys

(defvar-keymap kitty-lean-local-map
  :doc "lean.nvim's <LocalLeader> keys, on \\ in normal state."
  "i" '("infoview" . kitty-lean-infoview-toggle)
  "x" '("pin the goals here" . kitty-lean-infoview-pin)
  "c" '("clear the pins" . kitty-lean-infoview-clear-pins)
  "p" '("pause the infoview" . kitty-lean-infoview-toggle-pause)
  "r" '("restart file" . kitty-lean-restart-file)
  "R" '("restart server" . kitty-lean-restart-server)
  "s" '("accept suggestion" . kitty-lean-accept-suggestion)
  "S" '("a sorry per goal" . kitty-lean-sorry-fill)
  "u" '("unicode symbols" . kitty-lean-insert-symbol)
  "l" '("Loogle" . kitty-lean-loogle)
  "/" '("grep the library" . kitty-lean-grep-library)
  "f" '("library files" . kitty-lean-find-library-file)
  "\\" '("how to type this" . kitty-lean-describe-symbol))

(kitty-local-leader 'nael-mode
  "m" '("lake build" . kitty-lean-build)
  "r" '("run main" . kitty-lean-run-file)
  "c" '("Mathlib cache get" . kitty-lean-cache-get)
  "i" '("infoview" . kitty-lean-infoview-toggle)
  "l" '("lake ..." . kitty-lean-lake)
  "n" '("new project" . kitty-lean-new-project)
  "R" '("restart file" . kitty-lean-restart-file))

(with-eval-after-load 'nael
  (keymap-set nael-mode-map "C-c C-i" #'kitty-lean-infoview-toggle)
  (keymap-set nael-mode-map "C-c C-r" #'kitty-lean-restart-file))

(with-eval-after-load 'evil
  (with-eval-after-load 'nael
    (evil-define-key* 'normal nael-mode-map (kbd "\\") kitty-lean-local-map))
  (evil-ex-define-cmd "Lake" #'kitty-lean-ex-lake)
  (evil-ex-define-cmd "LeanNew" #'kitty-lean-ex-new)
  (add-hook 'evil-insert-state-exit-hook #'kitty-lean-expand-before-point))

;;;; Lean in org

;; Babel: a lean block is checked as a file of its own and its messages
;; (#eval, #check, errors) are the result.  `:project DIR' runs it in a Lake
;; project (`lake env lean'), so `import Mathlib' works; so does putting the
;; org file inside the project.  Set it for a whole file with
;;   #+PROPERTY: header-args:lean :project ~/math/notes
;; or everywhere with `kitty-lean-org-project' in local.el.
;;
;; C-c ' on a lean block gets the whole language server (goals, infoview,
;; diagnostics, completion): the block is a file under the project's .lake/
;; (git ignores it) or kittymax's cache, for the time it is being edited.

(defcustom kitty-lean-org-project nil
  "The Lake project lean blocks run in when they name none (a directory), or nil."
  :type '(choice (const nil) directory))

(defvar org-babel-default-header-args:lean '((:results . "output")))
(defvar org-babel-header-args:lean '((project . :any)))

(defun kitty-lean--org-project (params)
  "The Lake project for a block with header PARAMS, or nil."
  (let ((p (or (cdr (assq :project params)) kitty-lean-org-project
               (and buffer-file-name (kitty-lean-root (file-name-directory buffer-file-name))))))
    (and p (not (equal p "no")) (file-name-as-directory (expand-file-name p)))))

(defun kitty-lean--scratch-dir (project)
  "Where a block's file goes: PROJECT's .lake/kittymax-org/, or the cache."
  (let ((dir (if project
                 (expand-file-name ".lake/kittymax-org/" project)
               (expand-file-name "lean-org/" (if (boundp 'kitty-cache-dir) kitty-cache-dir temporary-file-directory)))))
    (make-directory dir t)
    dir))

(defun kitty-lean--strip-locations (output file)
  "Lean's messages in OUTPUT without FILE's name: \"3:4: error: ...\"."
  (replace-regexp-in-string (concat "^" (regexp-quote file) ":") "" output t t))

(defun org-babel-execute:lean (body params)
  "Check BODY with Lean and return its messages (#eval, #check, errors)."
  (require 'ob-eval)
  (let* ((project (kitty-lean--org-project params))
         (dir (kitty-lean--scratch-dir project))
         (file (make-temp-file (expand-file-name "Block" dir) nil ".lean" body))
         (default-directory (or project dir)))
    (unwind-protect
        (let ((out (with-temp-buffer
                     (call-process-shell-command
                      (concat (if project "lake env lean " "lean ") (shell-quote-argument (file-local-name file)))
                      nil t)
                     (buffer-string))))
          (string-trim-right (kitty-lean--strip-locations out (file-local-name file))))
      (delete-file file))))

(defun org-babel-prep-session:lean (_session _params)
  (user-error "Lean blocks have no sessions"))

(with-eval-after-load 'org
  (defvar org-babel-tangle-lang-exts)
  (defvar org-src-lang-modes)
  (defvar org-structure-template-alist)
  (add-to-list 'org-babel-tangle-lang-exts '("lean" . "lean"))
  (add-to-list 'org-src-lang-modes '("lean" . nael))
  (add-to-list 'org-src-lang-modes '("lean4" . nael))
  (add-to-list 'org-structure-template-alist '("le" . "src lean")))

;; C-c ' : the edit buffer as a file the server can check.
(defvar-local kitty-lean--org-file nil "The file standing in for this org block's edit buffer.")

(defvar eglot-autoshutdown)
(defvar eglot--managed-mode)
(declare-function eglot--maybe-activate-editing-mode "eglot")
(declare-function eglot--managed-buffers "eglot")
(declare-function eglot-shutdown "eglot")

(defun kitty-lean--org-edit-setup ()
  "In a lean block's C-c ' buffer: a file under the project, and the server."
  (when (and (derived-mode-p 'nael-mode) (not buffer-file-name)
             (bound-and-true-p org-src--beg-marker))
    (let* ((beg org-src--beg-marker)    ; buffer-local here, not in the org buffer
           (org-buffer (marker-buffer beg))
           (params (with-current-buffer org-buffer
                     (save-excursion
                       (goto-char beg)
                       (nth 2 (org-babel-get-src-block-info 'no-eval)))))
           (project (with-current-buffer org-buffer (kitty-lean--org-project params)))
           (file (make-temp-file (expand-file-name "Edit" (kitty-lean--scratch-dir project)) nil ".lean"
                                 (buffer-substring-no-properties (point-min) (point-max)))))
      (setq kitty-lean--org-file file
            buffer-file-name file
            default-directory (or project (file-name-directory file)))
      ;; it is not a file to save: org writes the block back
      (set-buffer-modified-p nil)
      ;; Leaving the block (C-c ') kills this buffer; eglot would shut the
      ;; server down right there, inside org's write-back, and an error from
      ;; that (Lean exits 1 when asked to stop while still starting) would
      ;; lose the edit.  The shutdown happens after, below.
      (setq-local eglot-autoshutdown nil)
      (add-hook 'kill-buffer-hook #'kitty-lean--org-edit-cleanup 90 t)
      ;; The project's server when it is running: eglot looked for one when
      ;; nael-mode started, before this buffer had a file, and eglot-ensure
      ;; would start a second server for the same project.
      (when (fboundp 'eglot--maybe-activate-editing-mode)
        (eglot--maybe-activate-editing-mode))
      (unless (bound-and-true-p eglot--managed-mode)
        (kitty-lean--ensure-server)))))

(defun kitty-lean--org-edit-cleanup ()
  "The block's C-c ' buffer goes: its file goes, and its server if nothing else uses it."
  ;; eglot's own kill-buffer-hook (before this one) closes the document on
  ;; the server; a second didClose would make Lean's server exit.
  (when kitty-lean--org-file
    (ignore-errors (delete-file kitty-lean--org-file))
    ;; no "buffer modified, kill anyway?" for a file nobody saves
    (set-buffer-modified-p nil)
    (setq buffer-file-name nil)
    (when-let* (((default-value 'eglot-autoshutdown))
                (server (ignore-errors (eglot-current-server))))
      ;; once org has written the block back (the command is over)
      (run-at-time 0 nil (lambda ()
                           (when (and (jsonrpc-running-p server) (null (eglot--managed-buffers server)))
                             (ignore-errors (eglot-shutdown server))))))))
(declare-function jsonrpc-running-p "jsonrpc")

(with-eval-after-load 'org-src
  (kitty-add-hook 'org-src-mode-hook #'kitty--lean-org-src))

(defun kitty--lean-org-src ()
  (when (derived-mode-p 'nael-mode)
    (kitty-lean--org-edit-setup)))

;; Typing a lean block in the org buffer itself: \to → → there too (only in
;; lean blocks; LaTeX's \to elsewhere in the note stays as it is).
(defun kitty-lean--org-expand ()
  "After a character typed in org: expand a \\-abbreviation in a lean block."
  (when (and (boundp 'nael-abbrev-regexp)
             (string-match-p "[^]-~!-#&-+.-:<-?A-[-]" (char-to-string last-command-event))
             (save-excursion
               (backward-char)
               (looking-back nael-abbrev-regexp (line-beginning-position)))
             (let ((el (org-element-at-point)))
               (and (eq (car el) 'src-block)
                    (member (org-element-property :language el) '("lean" "lean4")))))
    (let ((local-abbrev-table nael-abbrev-table))
      (save-excursion (backward-char) (expand-abbrev)))))

(defun kitty-lean--org-eager ()
  "Eager replacement (`kitty-lean--eager-expand') in an org file's lean blocks."
  (when (and (boundp 'nael-abbrev-table)
             (save-excursion (skip-chars-backward "^\\\\ \t\n" (max (line-beginning-position) (- (point) 40)))
                             (eq (char-before) ?\\))
             (let ((el (org-element-at-point)))
               (and (eq (car el) 'src-block)
                    (member (org-element-property :language el) '("lean" "lean4")))))
    (let ((local-abbrev-table nael-abbrev-table))
      (kitty-lean--eager-expand))))

(defun kitty--lean-org-abbrevs ()
  (when (require 'nael-abbrev nil t)
    (add-hook 'post-self-insert-hook #'kitty-lean--org-expand nil t)
    (add-hook 'post-self-insert-hook #'kitty-lean--org-eager 90 t)))
(kitty-add-hook 'org-mode-hook #'kitty--lean-org-abbrevs)

(provide 'kitty-lean)
;;; kitty-lean.el ends here
