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
(require 'hideshow)

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
  (kitty-lean--fold-setup)
  (when (kitty-lean-read-only-p buffer-file-name)
    (read-only-mode 1))
  ;; revert-buffer starts the mode again, forgetting the progress marks
  (add-hook 'change-major-mode-hook #'kitty-lean--remove-marks nil t)
  ;; The org block's C-c ' buffer starts its server itself (below).
  (kitty-lean--show-start)
  (add-hook 'kill-buffer-hook #'kitty-lean--source-closed nil t)
  (when buffer-file-name
    (kitty-lean--ensure-server)))
(kitty-add-hook 'nael-mode-hook #'kitty--lean-setup)

;; eglot registers a server only once it has answered `initialize'; a Lean
;; file whose eglot-ensure runs before that (two files at once, a jump to a
;; definition while `lake serve' starts) would launch a second server for
;; the project, and one of the two exits, leaving its files without one.
;; So every Lean buffer keeps its own eglot-ensure, and a launch is skipped
;; while one is on its way: eglot takes every buffer of the project when
;; the server is up.  If the start fails, the buffers that skipped theirs
;; try again after their next command.  test/kitty_lean_start.tla is its
;; model.
(defvar kitty-lean--starts (make-hash-table :test #'equal)
  "Project root -> plist of a server launch on its way: :server once eglot
made it, :waiting the Lean buffers that skipped their own launch for it.")

(defcustom kitty-lean-connect-timeout nil
  "Seconds to wait for `lake serve' to answer, or nil to wait as long as it takes.
eglot's own default, 30 s, kills a first start that is still fetching the
toolchain (elan) or cloning the dependencies (lake)."
  :type '(choice (const :tag "As long as it takes" nil) number)
  :group 'kittymax)

(defvar kitty-lean--told-no-lake nil)
(defvar kitty-lean--start-timer nil)
(defvar eglot-connect-timeout)

(defun kitty-lean--project-key ()
  (file-truename (or (ignore-errors (project-root (project-current))) default-directory)))

(defun kitty-lean--ensure-server ()
  "eglot for this buffer, after its next command, as for any language;
`kitty-lean--launch' sees that the project gets one server."
  (if (executable-find "lake")
      (kitty-eglot-ensure-for "lake")
    (unless kitty-lean--told-no-lake
      (setq kitty-lean--told-no-lake t)
      (message "Lean: `lake' is not on PATH, so Lean files get no server; install elan (https://github.com/leanprover/elan)"))))

(defun kitty-lean--starting (key)
  "The launch on its way for the project KEY, if its server still runs."
  (when-let* ((start (gethash key kitty-lean--starts)))
    (let ((server (plist-get start :server)))
      (if (or (null server) (jsonrpc-running-p server))
          start
        (remhash key kitty-lean--starts)
        nil))))

(defun kitty-lean--launch (connect &rest args)
  "eglot's connect, from a Lean buffer: skipped while the project's server
is starting (this buffer is taken when it is up); with Lean's patience."
  (if (not (derived-mode-p 'nael-mode))
      (apply connect args)
    (let* ((key (kitty-lean--project-key))
           (start (kitty-lean--starting key)))
      (if start
          (puthash key (plist-put start :waiting (cons (current-buffer) (plist-get start :waiting)))
                   kitty-lean--starts)
        (puthash key (list :server nil :waiting nil) kitty-lean--starts)
        (unless kitty-lean--start-timer
          (setq kitty-lean--start-timer (run-at-time 1 1 #'kitty-lean--start-tick)))
        (condition-case err
            (let ((eglot-connect-timeout kitty-lean-connect-timeout))
              (apply connect args))
          (error
           ;; no `lake', a broken contact, or it exited during the first seconds
           (kitty-lean--start-failed key)
           (signal (car err) (cdr err))))))))

(defun kitty-lean--start-failed (key)
  "The launch for KEY came to nothing: the buffers that waited try again."
  (when-let* ((start (gethash key kitty-lean--starts)))
    (remhash key kitty-lean--starts)
    (dolist (b (plist-get start :waiting))
      (when (buffer-live-p b)
        (with-current-buffer b
          (unless (bound-and-true-p eglot--managed-mode)
            (kitty-lean--ensure-server)))))))

(declare-function eglot--project "eglot")
(declare-function jsonrpc-running-p "jsonrpc")
(defun kitty-lean--server-key (server)
  (when-let* ((root (ignore-errors (project-root (eglot--project server)))))
    (file-truename root)))

(defun kitty-lean--server-launched (server)
  (when-let* ((key (kitty-lean--server-key server))
              (start (gethash key kitty-lean--starts)))
    (unless (plist-get start :server)
      (puthash key (plist-put start :server server) kitty-lean--starts))))

(defun kitty-lean--server-up (server)
  (when-let* ((key (kitty-lean--server-key server)))
    (when (eq (plist-get (gethash key kitty-lean--starts) :server) server)
      (remhash key kitty-lean--starts))))

(defun kitty-lean--server-ended (server)
  "SERVER exited; if it never answered `initialize', its start failed."
  (when-let* ((key (kitty-lean--server-key server)))
    (when (eq (plist-get (gethash key kitty-lean--starts) :server) server)
      ;; not from inside the process sentinel this runs in
      (run-at-time 0 nil #'kitty-lean--start-failed key))))

;; While it starts: what lake and elan say (downloading a toolchain, cloning
;; the dependencies), as VS Code shows it, instead of a file that looks dead.
(declare-function jsonrpc-stderr-buffer "jsonrpc")
(defun kitty-lean--start-status ()
  "\" Lean starting: <last line lake printed>\" while this project's server starts."
  (when-let* ((start (kitty-lean--starting (kitty-lean--project-key))))
    (let* ((server (plist-get start :server))
           (err (and server (ignore-errors (jsonrpc-stderr-buffer server))))
           (line (and (buffer-live-p err)
                      (with-current-buffer err
                        (save-excursion
                          (goto-char (point-max))
                          (skip-chars-backward " \t\n\r")
                          (string-trim (buffer-substring (line-beginning-position) (point))))))))
      (format " Lean starting%s"
              (if (and line (not (string-empty-p line)))
                  (concat ": " (truncate-string-to-width (replace-regexp-in-string "\r" "" line) 50 nil nil "…"))
                "…")))))

(defconst kitty-lean--mode-line-element
  '(:eval (string-replace "%" "%%" (concat (kitty-lean--start-status) (kitty-lean--mode-line))))
  "In mode-line-misc-info (doom-modeline's misc-info): the start, the checking.
An element, not a symbol: a list that starts with a symbol is a conditional.
%, as in \"⧗ 40%\" or elan's download, is a mode-line construct: doubled.")

(defun kitty-lean--start-tick ()
  "Redraw the mode lines while a server starts, so its progress shows."
  (if (zerop (hash-table-count kitty-lean--starts))
      (progn (cancel-timer kitty-lean--start-timer) (setq kitty-lean--start-timer nil))
    (force-mode-line-update t)))

(defun kitty-lean--show-start ()
  (unless (memq kitty-lean--mode-line-element mode-line-misc-info)
    (setq-local mode-line-misc-info (cons kitty-lean--mode-line-element mode-line-misc-info))))

;; What VS Code tells Lean it can show, and eglot does not: widgets (without
;; `hasWidgets' Lean flattens every message to plain text: no terms to hover,
;; `Try this' as \"[apply]\", traces expanded in full) and silent diagnostics
;; (the \"Goals accomplished\" ones behind the ✓ at the end of a proof).
(defun kitty-lean--server-p (server)
  (memq 'nael-mode (ignore-errors (eglot--major-modes server))))

(defun kitty-lean--initialization-options (options server)
  "OPTIONS (eglot's) with Lean's `hasWidgets' for a Lean SERVER."
  (if (not (kitty-lean--server-p server))
      options
    (append (and (consp options) options) (list :hasWidgets t))))

(defun kitty-lean--client-capabilities (capabilities server)
  "CAPABILITIES (eglot's) with Lean's own for a Lean SERVER."
  (if (not (kitty-lean--server-p server))
      capabilities
    (append capabilities (list :lean (list :silentDiagnosticSupport t
                                           :incrementalDiagnosticSupport t)))))

(with-eval-after-load 'eglot
  (cl-defmethod eglot-initialization-options :around (server)
    (kitty-lean--initialization-options (cl-call-next-method) server))
  (cl-defmethod eglot-client-capabilities :around (server)
    (kitty-lean--client-capabilities (cl-call-next-method) server)))

(kitty-add-hook 'eglot-server-initialized-hook #'kitty-lean--server-launched)
(kitty-add-hook 'eglot-connect-hook #'kitty-lean--server-up)
(with-eval-after-load 'eglot
  ;; before: eglot--on-shutdown ends with an error when the server died
  (advice-add 'eglot--on-shutdown :before #'kitty-lean--server-ended)
  (advice-add 'eglot--connect :around #'kitty-lean--launch))

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


(defun kitty-lean--remove-progress ()
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'kitty-lean-progress t)))

(defun kitty-lean--remove-marks ()
  "No progress bars or proof marks: revert-buffer starts the mode again."
  (kitty-lean--remove-progress)
  (save-restriction
    (widen)
    (remove-overlays (point-min) (point-max) 'kitty-lean-mark 'done)
    (remove-overlays (point-min) (point-max) 'kitty-lean-mark 'unsolved)))

(defun kitty-lean--draw-progress (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq kitty-lean--progress-timer nil)
      (setq kitty-lean--progress-overlays nil)
      (save-excursion
        (save-restriction
          (widen)
          ;; all of them, also those a revert-buffer made us forget
          (kitty-lean--remove-progress)
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
        (when (null now)
          (unless (eql kitty-lean--fold-tick (buffer-chars-modified-tick))
            (kitty-lean--fold-request)))
        (when (and was (null now) (kitty-lean--followed-p buffer))
          (kitty-lean-infoview-refresh buffer t))))))

(with-eval-after-load 'eglot
  (cl-defmethod eglot-handle-notification
    (_server (_method (eql $/lean/fileProgress)) &key textDocument processing &allow-other-keys)
    (kitty-lean--on-progress (plist-get textDocument :uri) processing)))

;;;; Proof marks: ✓ where a proof is done, 🛠 where goals are left
;;
;; VS Code's gutter decorations (Lean ≥ 4.20).  Lean tags its diagnostics:
;; an \"unsolved goals\" error (leanTag 1) gets 🛠 after its last line, and a
;; silent \"Goals accomplished!\" (leanTag 2, sent because kittymax says it
;; takes silent diagnostics) a ✓ in the right fringe (at the end of the line
;; in a terminal).  Silent diagnostics are not messages: flymake never sees
;; them, as VS Code's Problems never does.

(defcustom kitty-lean-proof-marks t
  "Mark finished proofs (✓) and proofs with goals left (🛠), as VS Code does."
  :type 'boolean)

(defcustom kitty-lean-unsolved-mark " 🛠"
  "What follows the last line of a proof with goals left (VS Code's 🛠)."
  :type 'string)

(defvar-local kitty-lean--marks nil
  "(DONE-LINES . UNSOLVED-LINES), 0-based, from Lean's latest diagnostics.")
(defvar-local kitty-lean--mark-overlays nil)

(define-fringe-bitmap 'kitty-lean-done
  [#b00000000 #b00000011 #b00000110 #b10001100 #b11011000 #b01110000 #b00100000 #b00000000]
  nil nil 'center)

(defface kitty-lean-done '((t :inherit success))
  "The ✓ beside a proof Lean accepts.")
(defface kitty-lean-unsolved '((t :inherit font-lock-comment-face))
  "The 🛠 after a proof with goals left.")

(defun kitty-lean--tagged-p (diag tag)
  (seq-contains-p (or (plist-get diag :leanTags) []) tag))

(defun kitty-lean--end-line (range)
  "The last line RANGE covers, 0-based: an end at column 0 is the line before."
  (let ((start (plist-get range :start)) (end (plist-get range :end)))
    (if (and (zerop (plist-get end :character)) (> (plist-get end :line) (plist-get start :line)))
        (1- (plist-get end :line))
      (plist-get end :line))))

(defun kitty-lean--split-diagnostics (diagnostics)
  "DIAGNOSTICS (Lean's) as (KEPT DONE-LINES UNSOLVED-LINES): KEPT without the silent ones."
  (let (kept done unsolved)
    (seq-doseq (d diagnostics)
      (when (kitty-lean--tagged-p d 2)
        (push (plist-get (plist-get (plist-get d :range) :start) :line) done))
      (when (kitty-lean--tagged-p d 1)
        (push (kitty-lean--end-line (or (plist-get d :fullRange) (plist-get d :range))) unsolved))
      (unless (eq (plist-get d :isSilent) t)
        ;; with widgets on, Lean's plain text of a trace is just "(trace)"
        ;; (as VS Code's Problems shows it): say where the trace is
        (push (if (equal (plist-get d :message) "(trace)")
                  (plist-put (copy-sequence d) :message "(trace: unfold it in the infoview, \\ TAB)")
                d)
              kept)))
    (list (vconcat (nreverse kept)) done unsolved)))

(defun kitty-lean--draw-marks ()
  (mapc #'delete-overlay kitty-lean--mark-overlays)
  (setq kitty-lean--mark-overlays nil)
  (when kitty-lean-proof-marks
    (save-excursion
      (save-restriction
        (widen)
        (let ((lines (count-lines (point-min) (point-max)))
              (gui (display-graphic-p)))
          ;; one pass down the buffer, however many marks
          (let ((here 0) (lines-at (make-hash-table)))
            (goto-char (point-min))
            (dolist (line (sort (delete-dups (append (car kitty-lean--marks) (cdr kitty-lean--marks) nil)) #'<))
              (when (< line (max 1 lines))
                (forward-line (- line here))
                (setq here line)
                (puthash line (line-end-position) lines-at)))
          (cl-flet ((at (line)
                      (when-let* ((pos (gethash line lines-at)))
                        (let ((ov (make-overlay pos pos)))
                          (overlay-put ov 'kitty-lean-mark t)
                          (push ov kitty-lean--mark-overlays)
                          ov))))
            (dolist (line (car kitty-lean--marks))
              (when-let* ((ov (at line)))
                (overlay-put ov 'kitty-lean-mark 'done)
                (overlay-put ov 'before-string
                             (if gui
                                 (propertize " " 'display '(right-fringe kitty-lean-done kitty-lean-done))
                               (propertize " ✓" 'face 'kitty-lean-done)))))
            (dolist (line (cdr kitty-lean--marks))
              (when-let* ((ov (at line)))
                (overlay-put ov 'kitty-lean-mark 'unsolved)
                ;; before eol diagnostics (an after-string at the same place)
                (overlay-put ov 'priority 10)
                (overlay-put ov 'before-string (propertize kitty-lean-unsolved-mark 'face 'kitty-lean-unsolved
                                                           'help-echo "Lean: goals left here")))))))))))

(defun kitty-lean--on-diagnostics (uri diagnostics)
  "Lean's DIAGNOSTICS for URI: the marks drawn, the silent ones taken out (returned)."
  (pcase-let ((`(,kept ,done ,unsolved) (kitty-lean--split-diagnostics diagnostics)))
    (when-let* ((buffer (kitty-lean--buffer-for-uri uri)))
      (with-current-buffer buffer
        (setq kitty-lean--marks (cons done unsolved))
        (kitty-lean--draw-marks)))
    kept))

;;;; Folding: Lean's folding ranges, through hideshow
;;
;; VS Code folds what Lean's textDocument/foldingRange says: declarations,
;; namespaces and sections, imports, comments, and (Lean ≥ 4.37) proofs.
;; eglot does not ask for them, so kittymax does, each time Lean finishes
;; checking, and hands them to hideshow: evil's za zc zo zM zR fold them.
;; Markers carry the ranges through edits until the next answer; an answer
;; to an older text than the buffer's is dropped (the next check asks
;; again).  test/kitty_lean_folding.tla is its model.

(defvar-local kitty-lean--fold-ranges []
  "Lean's folding ranges, by start, outermost first: [(START END PROOF-P) ...].
START is a marker at the start of the first line, END at the end of the last.")
(defvar-local kitty-lean--fold-tick nil "The text (chars-modified-tick) Lean's ranges are for.")

(defun kitty-lean--fold-request ()
  "Ask Lean for this buffer's folding ranges."
  (when-let* ((server (eglot-current-server)))
    (kitty-lean--flush)
    (let ((buffer (current-buffer)) (tick (buffer-chars-modified-tick)))
      (jsonrpc-async-request
       server :textDocument/foldingRange (list :textDocument (eglot--TextDocumentIdentifier))
       :success-fn (lambda (ranges)
                     (when (and (buffer-live-p buffer)
                                (= tick (buffer-chars-modified-tick buffer)))
                       (with-current-buffer buffer
                         (setq kitty-lean--fold-tick tick)
                         (kitty-lean--folding-ranges ranges))))
       :error-fn #'ignore :timeout-fn #'ignore))))

(defun kitty-lean--folding-ranges (ranges)
  "Take Lean's folding RANGES (a vector) for this buffer."
  (seq-doseq (r kitty-lean--fold-ranges)
    (set-marker (nth 0 r) nil) (set-marker (nth 1 r) nil))
  (let ((bol (make-hash-table)) (here 0))
    ;; one pass down the buffer, however many ranges
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (dolist (line (sort (delete-dups (seq-mapcat (lambda (r) (list (plist-get r :startLine)
                                                                       (plist-get r :endLine)))
                                                     ranges))
                            #'<))
          (forward-line (- line here))
          (setq here line)
          (puthash line (point) bol))
        (setq kitty-lean--fold-ranges
              (vconcat
               (sort (mapcar (lambda (r)
                               (list (copy-marker (gethash (plist-get r :startLine) bol) t)
                                     (copy-marker (progn (goto-char (gethash (plist-get r :endLine) bol))
                                                         (pos-eol))
                                                  t)
                                     (equal (plist-get r :kind) "proof")))
                             ranges)
                     (lambda (a b) (or (< (car a) (car b))
                                       (and (= (car a) (car b)) (> (cadr a) (cadr b))))))))))))

;; hideshow's questions, answered from the ranges

(defun kitty-lean--fold-from (pos)
  "The index of the first range starting at POS or after it."
  (let ((lo 0) (hi (length kitty-lean--fold-ranges)))
    (while (< lo hi)
      (let ((mid (/ (+ lo hi) 2)))
        (if (< (car (aref kitty-lean--fold-ranges mid)) pos) (setq lo (1+ mid)) (setq hi mid))))
    lo))

(defun kitty-lean--fold-at (pos)
  (let ((i (kitty-lean--fold-from pos)))
    (and (< i (length kitty-lean--fold-ranges))
         (= (car (aref kitty-lean--fold-ranges i)) pos)
         (aref kitty-lean--fold-ranges i))))

(defun kitty-lean--hs-looking-at-block-start ()
  (when (kitty-lean--fold-at (point))
    (set-match-data (list (point) (1+ (point))))
    t))

(defun kitty-lean--hs-forward (&rest _)
  (goto-char (nth 1 (kitty-lean--fold-at (point)))))

(defun kitty-lean--hs-find-block-beginning ()
  (when-let* ((r (seq-find (lambda (r) (<= (car r) (point) (nth 1 r)))
                           (reverse (seq-subseq kitty-lean--fold-ranges 0 (kitty-lean--fold-from (1+ (point))))))))
    (goto-char (car r))))

(defun kitty-lean--hs-find-next-block (_regexp bound _comments)
  (let ((i (kitty-lean--fold-from (point))))
    (when (and (< i (length kitty-lean--fold-ranges))
               (<= (car (aref kitty-lean--fold-ranges i)) bound))
      (let ((start (car (aref kitty-lean--fold-ranges i))))
        (goto-char (min (1+ start) (point-max)))
        (set-match-data (list start (point)))
        t))))

(defun kitty-lean--fold-proofs (fold)
  "Fold (FOLD non-nil) or unfold every proof."
  (save-excursion
    (seq-doseq (r kitty-lean--fold-ranges)
      (when (nth 2 r)
        (goto-char (car r))
        (if fold (hs-hide-block-at-point)
          (hs-discard-overlays (car r) (nth 1 r)))))))

(defun kitty-lean-fold-proofs ()
  "Fold every proof (VS Code's Fold All Proofs; Lean ≥ 4.37)."
  (interactive)
  (kitty-lean--fold-proofs t))

(defun kitty-lean-unfold-proofs ()
  "Unfold every proof (VS Code's Unfold All Proofs)."
  (interactive)
  (kitty-lean--fold-proofs nil))

(defun kitty-lean--fold-setup ()
  (setq-local hs-block-start-regexp nil
              hs-block-end-regexp nil
              hs-forward-sexp-function #'kitty-lean--hs-forward
              hs-find-block-beginning-function #'kitty-lean--hs-find-block-beginning
              hs-find-next-block-function #'kitty-lean--hs-find-next-block
              hs-looking-at-block-start-predicate #'kitty-lean--hs-looking-at-block-start
              hs-inside-comment-predicate #'ignore)
  (hs-minor-mode 1))

;; Lean reports a file's diagnostics while it checks it, each time all of
;; them unless the client takes them in pieces: a file with 2000 messages
;; sent 420 MB of JSON, 3000 times a growing list, and kept Emacs busy for
;; 30 s.  So kittymax takes them in pieces, as VS Code does
;; (`incrementalDiagnosticSupport': a report with isIncremental adds to the
;; ones of the same version), and hands flymake, the marks and
;; `kitty-lean-diagnostics-functions' the whole list at most every
;; `kitty-lean-diagnostics-interval' seconds: the first report at once, the
;; latest when the interval is over.

(defcustom kitty-lean-diagnostics-interval 0.1
  "Seconds between two deliveries of a file's diagnostics while Lean checks it."
  :type 'number)

(defvar kitty-lean-diagnostics-functions nil
  "Called with URI, VERSION and all of Lean's diagnostics (a vector, silent ones too)
each time they are delivered.")

(defvar kitty-lean--diagnostics (make-hash-table :test #'equal)
  "URI -> (VERSION CHUNKS DIRTY TIMER): Lean's reports since its last full one,
CHUNKS the vectors newest first.")

(defvar kitty-lean--delivering nil
  "Non-nil while kittymax hands eglot a file's whole list of diagnostics.")

(defun kitty-lean--diagnostics-add (uri version incremental diagnostics)
  "Lean's report for URI; non-nil when nothing is waiting to be delivered."
  (let ((entry (or (gethash uri kitty-lean--diagnostics)
                   (puthash uri (list version nil nil nil) kitty-lean--diagnostics))))
    (cond
     ((and incremental (equal (nth 0 entry) version))
      (push diagnostics (nth 1 entry)))
     ;; a late piece of a version already replaced: Lean's old checker
     ;; can still report after an edit
     ((and incremental (numberp version) (numberp (nth 0 entry)) (< version (nth 0 entry)))
      nil)
     (t (setf (nth 0 entry) version (nth 1 entry) (list diagnostics))))
    (setf (nth 2 entry) t)
    (not (nth 3 entry))))

(defun kitty-lean--diagnostics-forget (&rest _)
  "The buffer's file is closed on the server: its diagnostics go."
  (let ((buffer (current-buffer)) gone)
    (maphash (lambda (uri _) (when (eq (kitty-lean--buffer-for-uri uri) buffer) (push uri gone)))
             kitty-lean--diagnostics)
    (dolist (uri gone) (remhash uri kitty-lean--diagnostics))))

(defun kitty-lean--diagnostics-all (uri)
  "All of URI's diagnostics, as one vector (kept as one from now on)."
  (when-let* ((entry (gethash uri kitty-lean--diagnostics)))
    (let ((all (if (cdr (nth 1 entry)) (apply #'vconcat (reverse (nth 1 entry))) (car (nth 1 entry)))))
      (setf (nth 1 entry) (list all))
      all)))

(defun kitty-lean--diagnostics-deliver (server uri)
  "Give URI's diagnostics to the marks, the hooks and eglot (flymake), if new;
then wait an interval before the next delivery."
  (let ((entry (gethash uri kitty-lean--diagnostics)))
    (when (and entry (nth 2 entry))
      (setf (nth 2 entry) nil)
      (let ((all (kitty-lean--diagnostics-all uri)) (version (nth 0 entry)))
        (run-hook-with-args 'kitty-lean-diagnostics-functions uri version all)
        (when (jsonrpc-running-p server)
          (let ((kitty-lean--delivering t))
            (eglot-handle-notification server 'textDocument/publishDiagnostics
                                       :uri uri :version version
                                       :diagnostics (kitty-lean--on-diagnostics uri all))))
        (setf (nth 3 entry)
              (run-at-time kitty-lean-diagnostics-interval nil
                           (lambda ()
                             (setf (nth 3 entry) nil)
                             (kitty-lean--diagnostics-deliver server uri))))))))

(with-eval-after-load 'eglot
  (advice-add 'eglot--signal-textDocument/didClose :after #'kitty-lean--diagnostics-forget)
  (cl-defmethod eglot-handle-notification :around
    (server (_method (eql textDocument/publishDiagnostics)) &key uri version diagnostics isIncremental &allow-other-keys)
    (if (or kitty-lean--delivering (not (kitty-lean--server-p server)))
        (cl-call-next-method)
      (when (kitty-lean--diagnostics-add uri version (eq isIncremental t) diagnostics)
        (kitty-lean--diagnostics-deliver server uri)))))

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

(defcustom kitty-lean-infoview-diffs t
  "Colour what the tactic before the cursor changed in the goals (\\dd toggles)."
  :type 'boolean)

(defcustom kitty-lean-infoview-hide-types nil
  "Leave type hypotheses (α : Type) out of the goals."
  :type 'boolean)

(defcustom kitty-lean-infoview-hide-let-values nil
  "Leave out the values of let hypotheses (x : Nat := 5 shows as x : Nat)."
  :type 'boolean)

(defcustom kitty-lean-infoview-reverse nil
  "Show each goal's target first, then its hypotheses nearest first (VS Code's reverseTacticState)."
  :type 'boolean)

(defcustom kitty-lean-infoview-emphasize-first-goal nil
  "Show only the first goal; the others are folded under \"Other goals\" (VS Code's emphasizeFirstGoal)."
  :type 'boolean)

(defvar kitty-lean-infoview-buffer-name "*Lean Infoview*")

(defvar kitty-lean--gen 0 "Generation of the latest infoview request.")
(defvar kitty-lean--last-key nil "(BUFFER POINT TICK) of the latest infoview request.")
(defvar kitty-lean--source nil "The buffer the infoview shows.")
(defvar kitty-lean--rendered nil "The buffer whose answers the infoview shows.")
(defvar kitty-lean--rendered-tick nil "The text of that buffer they are for (its chars-modified-tick).")
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

(declare-function eglot--signal-textDocument/didChange "eglot")
(defun kitty-lean--flush ()
  "Send the edits eglot holds back (it waits for an idle moment) before asking:
a goal asked for before Lean has the new text is the goal of the old one."
  (when (eglot-managed-p) (eglot--signal-textDocument/didChange)))

(defun kitty-lean--rpc-connect ()
  "This buffer's RPC session, connecting when there is none."
  (kitty-lean--flush)
  (or kitty-lean--rpc-session
      (setq kitty-lean--rpc-session
            (plist-get (jsonrpc-request (eglot--current-server-or-lose) :$/lean/rpc/connect
                                        (list :uri (kitty-lean--uri)))
                       :sessionId))))

(defun kitty-lean--session-lost (buffer session)
  "Lean dropped SESSION of BUFFER.
Of the calls that find out at once, the first forgets it and asks the
infoview again, on one new session: what the infoview shows must all come
from the same session, or its references mean nothing to Lean."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (equal kitty-lean--rpc-session session)
        (setq kitty-lean--rpc-session nil)
        (when (eq buffer kitty-lean--source)
          (run-at-time 0 nil #'kitty-lean-infoview-refresh buffer t))))))

(defun kitty-lean--rpc-call (buffer pos method params callback)
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
                       (when (eql (plist-get e :code) kitty-lean--rpc-needs-reconnect)
                         (kitty-lean--session-lost buffer session))
                       (funcall callback (cons nil e)))
           :timeout-fn (lambda () (funcall callback (cons nil nil)))))))))

(defun kitty-lean--rpc-call-sync (buffer pos method params)
  "Lean's RPC METHOD with PARAMS at POS of BUFFER; its result.
PARAMS hold references from the infoview: when Lean has dropped their
session they are gone with it, so the infoview is asked again instead."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (let ((session (kitty-lean--rpc-connect)))
        (condition-case err
            (let ((r (jsonrpc-request (eglot--current-server-or-lose) :$/lean/rpc/call
                                      (append (eglot--TextDocumentPositionParams)
                                              (list :sessionId session :method method :params params)))))
              (if (eq r :null) nil r))
          (jsonrpc-error
           (if (eql (alist-get 'jsonrpc-error-code (cdr err)) kitty-lean--rpc-needs-reconnect)
               (progn (kitty-lean--session-lost buffer session)
                      (user-error "Lean: the infoview was out of date, it is updated now; try again"))
             (signal (car err) (cdr err)))))))))

(defun kitty-lean--keepalive ()
  "Keep the RPC session of the infoview's buffer alive, while it is shown."
  (if (not (kitty-lean--infoview-window))
      (progn (cancel-timer kitty-lean--keepalive-timer) (setq kitty-lean--keepalive-timer nil))
    ;; every Lean buffer with a session, not only the one shown: going back
    ;; to another file finds its session (and the pins) still there
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and kitty-lean--rpc-session (derived-mode-p 'nael-mode) (eglot-managed-p))
          (ignore-errors
            (jsonrpc-notify (eglot--current-server-or-lose) :$/lean/rpc/keepAlive
                            (list :uri (kitty-lean--uri) :sessionId kitty-lean--rpc-session))))))))

(defun kitty-lean--json-refs (json)
  "The RPC references ({\"p\": id}) anywhere in Lean's answer JSON."
  (let (refs)
    (cl-labels ((walk (x)
                  (cond ((and (consp x) (keywordp (car x)))
                         (if (and (eq (car x) :p) (stringp (cadr x)) (null (cddr x)))
                             (push x refs)
                           (let ((l x)) (while l (walk (cadr l)) (setq l (cddr l))))))
                        ((vectorp x) (seq-do #'walk x))
                        ((consp x) (mapc #'walk x)))))
      (walk json))
    refs))

(defun kitty-lean--answer-refs (parts)
  "The references in the answers PARTS of a refresh (a vector, so that an
answer of :none is not taken for a plist key)."
  (kitty-lean--json-refs
   (vector (plist-get parts :goals) (plist-get parts :term)
           (vconcat (mapcar #'cddr (plist-get parts :pins)))
           (vconcat (plist-get parts :messages))
           (vconcat (plist-get parts :widgets)))))

(defun kitty-lean--release (buffer session refs)
  "Tell Lean the references REFS of BUFFER's SESSION are no longer needed."
  (when (and refs (buffer-live-p buffer))
    (with-current-buffer buffer
      (when (and (eglot-managed-p) (equal session kitty-lean--rpc-session))
        (ignore-errors
          (jsonrpc-notify (eglot--current-server-or-lose) :$/lean/rpc/release
                          (list :uri (kitty-lean--uri) :sessionId session :refs (vconcat refs))))))))

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
(defvar kitty-lean--fold-path nil "The keys of the folds around the one being inserted.")
(defvar kitty-lean--pending-fills nil "Open lazy folds of the render being made.")
(defvar kitty-lean--render-id 0 "Counts the infoview's renders.")

(defun kitty-lean--diff-face (status)
  (pcase status
    ((or "wasChanged" "wasInserted") 'kitty-lean-infoview-inserted)
    ((or "willChange" "willInsert" "willDelete" "wasDeleted") 'kitty-lean-infoview-removed)))

(defun kitty-lean--put-unset (beg end prop value)
  "Give the text from BEG to END PROP = VALUE where it has no PROP yet."
  (while (< beg end)
    (let ((next (next-single-property-change beg prop nil end)))
      (unless (get-text-property beg prop)
        (put-text-property beg next prop value))
      (setq beg next))))

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
        ;; the subterms inside were tagged first: the innermost term wins
        (kitty-lean--put-unset beg (point) 'kitty-lean-info (plist-get info :info))
        (when-let* ((face (kitty-lean--diff-face (plist-get info :diffStatus))))
          (kitty-lean--put-unset beg (point) 'kitty-lean-diff face)))
       ;; a message's embedded expression / goal (MsgEmbed)
       ((plist-member info :expr)
        (delete-region beg (point))
        (kitty-lean--insert-tagged (plist-get info :expr)))
       ((plist-member info :goal)
        (delete-region beg (point))
        (kitty-lean--insert-goal (plist-get info :goal)))
       ((plist-member info :trace)
        (delete-region beg (point))
        (kitty-lean--insert-trace (plist-get info :trace)))
       ;; a widget inside a message: `Try this' [apply], an error's explanation...
       ((plist-member info :widget)
        (delete-region beg (point))
        (let ((w (plist-get info :widget)))
          (unless (and (fboundp 'kitty-lean-widgets-insert)
                       (kitty-lean-widgets-insert (plist-get w :wi) t))
            (kitty-lean--insert-tagged (plist-get w :alt))))))))
   ((stringp tt) (insert tt))))

(defun kitty-lean--tagged-plain (tt)
  "TaggedText TT as a plain string."
  (with-temp-buffer
    (let ((kitty-lean--refs nil) (kitty-lean--fold-path nil))
      (cl-letf (((symbol-function 'kitty-lean--fold)
                 (lambda (_key _default title &rest _) (funcall title))))
        (kitty-lean--insert-tagged tt)))
    (buffer-substring-no-properties (point-min) (point-max))))

;;;;; Folds: collapsible sections, goals, traces, <details>
;;
;; VS Code's infoview folds everything: its sections, each goal, each trace
;; node, a widget's <details>.  Here a fold is a title (▾ open, ▸ closed:
;; TAB or a click toggles it) and an overlay over its body that is invisible
;; while closed.  How each fold was left is remembered by its key (the
;; section, the goal's case, the trace's class and text), so the next
;; refresh shows it the same way.  A body can be filled the first time it
;; is opened: a trace's children are asked from Lean only then, as in VS
;; Code (Lean.Widget.lazyTraceChildrenToInteractive).  Lean's answer is put
;; in only if the infoview still shows the render it was asked for
;; (`kitty-lean--render-id'); test/kitty_lean_folds.tla is its model.

(defvar kitty-lean--folds (make-hash-table :test #'equal)
  "Fold key -> `open' or `closed', as it was left.")

(defface kitty-lean-infoview-fold '((t :inherit shadow))
  "The ▾ / ▸ before a fold's title.")

(defun kitty-lean--fold-open-p (key default)
  (pcase (gethash key kitty-lean--folds) ('open t) ('closed nil) (_ default)))

(defvar-keymap kitty-lean--fold-title-map
  "<mouse-1>" #'kitty-lean-infoview-toggle-fold
  "<mouse-2>" #'kitty-lean-infoview-toggle-fold)

(defun kitty-lean--fold (key default title &optional body fill)
  "Insert a fold named KEY, open at first if DEFAULT.
TITLE inserts its title (one line), BODY its body (starting with a newline).
Or FILL, instead of BODY: a function of the body's overlay, called the first
time the fold is open, that fills it (now, or later from an answer, with
`kitty-lean--fold-fill')."
  (let* ((key (cons key kitty-lean--fold-path))
         (open (kitty-lean--fold-open-p key default))
         (tbeg (point)))
    (insert (propertize (if open "▾ " "▸ ") 'kitty-lean-face 'kitty-lean-infoview-fold))
    (funcall title)
    (let* ((bbeg (point))
           (_ (let ((kitty-lean--fold-path key)) (when body (funcall body))))
           (ov (make-overlay bbeg (point))))
      (put-text-property tbeg bbeg 'kitty-lean-fold ov)
      (kitty-lean--put-unset tbeg bbeg 'mouse-face 'highlight)
      (kitty-lean--put-unset tbeg bbeg 'keymap kitty-lean--fold-title-map)
      (kitty-lean--put-unset tbeg bbeg 'help-echo "TAB, mouse-1: fold / unfold")
      (overlay-put ov 'kitty-lean-fold-body t)
      (overlay-put ov 'kitty-lean-key key)
      (overlay-put ov 'kitty-lean-title (copy-marker tbeg))
      (overlay-put ov 'kitty-lean-render kitty-lean--render-id)
      (overlay-put ov 'kitty-lean-fill fill)
      (overlay-put ov 'invisible (not open))
      (when (and open fill)
        ;; after the render: its buffer, refs and render id are set then
        (push ov kitty-lean--pending-fills))
      ov)))


(defun kitty-lean--fold-set (ov open)
  "Open (OPEN non-nil) or close the fold whose body is OV."
  (let ((inhibit-read-only t)
        (title (overlay-get ov 'kitty-lean-title)))
    ;; how folds were left is a convenience, not a record: kept small
    (when (> (hash-table-count kitty-lean--folds) 500) (clrhash kitty-lean--folds))
    (overlay-put ov 'invisible (not open))
    (puthash (overlay-get ov 'kitty-lean-key) (if open 'open 'closed) kitty-lean--folds)
    (when (and (marker-buffer title) (memq (char-after title) '(?▾ ?▸)))
      (save-excursion
        (goto-char title)
        (let ((props (text-properties-at (point))))
          (delete-char 1)
          (insert (apply #'propertize (if open "▾" "▸") props)))))
    (when-let* ((fill (and open (overlay-get ov 'kitty-lean-fill))))
      (overlay-put ov 'kitty-lean-fill nil)
      (funcall fill ov))))

(defun kitty-lean--fold-fill (ov insert)
  "Put what INSERT inserts at the end of the fold body OV, if it is still shown.
Returns non-nil if it was put in.  Lean's references in it are released with
the rest of the render."
  (when (and (overlay-buffer ov) (eql (overlay-get ov 'kitty-lean-render) kitty-lean--render-id))
    (with-current-buffer (overlay-buffer ov)
      (let* ((inhibit-read-only t)
             (old-end (overlay-end ov))
             (kitty-lean--refs nil)
             (kitty-lean--fold-path (overlay-get ov 'kitty-lean-key))
             (kitty-lean--pending-fills nil)
             ;; the folds around it, that end where it ends, take it in too
             (outer (seq-filter (lambda (o) (and (overlay-get o 'kitty-lean-fold-body)
                                                 (not (eq o ov))
                                                 (= (overlay-end o) old-end)
                                                 (< (overlay-start o) old-end)))
                                (overlays-in (point-min) (point-max)))))
        (save-excursion
          (goto-char old-end)
          (funcall insert)
          (move-overlay ov (overlay-start ov) (point))
          (dolist (o outer) (move-overlay o (overlay-start o) (point)))
          (kitty-lean--fontify-region old-end (point)))
        (kitty-lean--run-fills)
        t))))

(defun kitty-lean--run-fills ()
  "Fill the open lazy folds just inserted."
  (let ((fills (nreverse kitty-lean--pending-fills)))
    (setq kitty-lean--pending-fills nil)
    (dolist (ov fills)
      (when-let* ((fill (overlay-get ov 'kitty-lean-fill)))
        (overlay-put ov 'kitty-lean-fill nil)
        (funcall fill ov)))))

(defun kitty-lean--fold-at-point ()
  "The fold body overlay of the title on this line, or of the fold point is in.
Point in hidden text (the end of a closed fold's line) counts as on its title."
  (save-excursion
    (while (and (> (point) (point-min)) (invisible-p (point)) (invisible-p (1- (point))))
      (backward-char))
    (when (and (> (point) (point-min)) (invisible-p (point))) (backward-char))
    (let ((bol (save-excursion (beginning-of-line) (point)))
          (eol (save-excursion (skip-chars-forward "^\n") (point))))
      (or (get-text-property (point) 'kitty-lean-fold)
          ;; the title on this line, wherever point is on it
          (cl-loop for pos = bol then (next-single-property-change pos 'kitty-lean-fold nil eol)
                   while (and pos (< pos eol))
                   thereis (get-text-property pos 'kitty-lean-fold))
          (car (sort (seq-filter (lambda (o) (and (overlay-get o 'kitty-lean-fold-body)
                                                  (< (overlay-start o) (point) (1+ (overlay-end o)))))
                                 (overlays-in (max (point-min) (1- (point))) (min (point-max) (1+ (point)))))
                     (lambda (a b) (< (- (overlay-end a) (overlay-start a)) (- (overlay-end b) (overlay-start b))))))))))

(defun kitty-lean-infoview-toggle-fold (&optional event)
  "Fold or unfold the section, goal or trace here (VS Code's ▾ ▸)."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((ov (or (kitty-lean--fold-at-point) (user-error "Nothing to fold here"))))
    (let ((open (overlay-get ov 'invisible)))
      (kitty-lean--fold-set ov open)
      (unless open
        ;; closed from inside its body: to its title
        (when (> (point) (overlay-start ov))
          (goto-char (overlay-get ov 'kitty-lean-title)))))))

;;;;; Traces

(defun kitty-lean--abbrev-cls (parent cls)
  "CLS without the part it shares with its PARENT's (Meta.synthInstance.apply under Meta.synthInstance: apply)."
  (if (and parent (string-prefix-p (concat parent ".") cls))
      (substring cls (1+ (length parent)))
    cls))

(defvar kitty-lean--trace-cls nil "The class of the trace node around the one being inserted.")

(defvar kitty-lean--trace-index nil "Which child of its parent the trace being inserted is.")

(defun kitty-lean--insert-trace-children (children cls)
  (let ((kitty-lean--trace-cls cls) (i 0))
    (seq-do (lambda (c)
              (insert "\n")
              (let ((kitty-lean--trace-index (cl-incf i))) (kitty-lean--insert-tagged c)))
            children)))

(defun kitty-lean--insert-trace (trace)
  "A trace node: [class] message, its children folded under it (fetched when opened)."
  (let* ((cls (or (plist-get trace :cls) "trace"))
         (children (plist-get trace :children))
         (strict (plist-get children :strict))
         (lazy (plist-get children :lazy))
         (parent kitty-lean--trace-cls)
         (title (lambda ()
                  (insert (propertize (format "[%s] " (kitty-lean--abbrev-cls parent cls))
                                      'kitty-lean-face 'kitty-lean-infoview-trace))
                  (let ((kitty-lean--trace-cls nil))
                    (kitty-lean--insert-tagged (plist-get trace :msg))))))
    (insert (make-string (or (plist-get trace :indent) 0) ?\s))
    (if (and (not lazy) (seq-empty-p strict))
        (progn (insert "  ") (funcall title))
      (kitty-lean--fold
       ;; two alike under one parent are two folds: where it is is part of its name
       (list 'trace kitty-lean--trace-index cls
             (truncate-string-to-width (kitty-lean--tagged-plain (plist-get trace :msg)) 200))
       (not (eq (plist-get trace :collapsed) t))
       title
       (and (not lazy) (lambda () (kitty-lean--insert-trace-children strict cls)))
       (and lazy (lambda (ov) (kitty-lean--trace-fetch ov lazy cls)))))))

(defface kitty-lean-infoview-trace '((t :inherit font-lock-comment-face))
  "A trace node's class, [Meta.synthInstance].")

(defun kitty-lean--trace-fetch (ov lazy cls)
  "Ask Lean for the children LAZY of the trace node whose body is OV."
  (let ((buffer kitty-lean--rendered)
        (session (nth 1 kitty-lean--shown-refs)))
    (when (buffer-live-p buffer)
      (kitty-lean--fold-fill ov (lambda () (insert "\n" (propertize "  …" 'kitty-lean-face 'shadow))))
      (kitty-lean--rpc-call
       buffer (with-current-buffer buffer (point)) "Lean.Widget.lazyTraceChildrenToInteractive" lazy
       (lambda (a)
         ;; the "…" goes, the children come (or why they did not); too
         ;; late for the render they were asked in: Lean can forget them
         (if (not (and (overlay-buffer ov) (eql (overlay-get ov 'kitty-lean-render) kitty-lean--render-id)))
             (when (car a)
               (kitty-lean--release buffer session (kitty-lean--json-refs (cdr a))))
           (with-current-buffer (overlay-buffer ov)
             (let ((inhibit-read-only t))
               (delete-region (overlay-start ov) (overlay-end ov))))
           (kitty-lean--fold-fill
            ov (lambda ()
                 (if (car a)
                     (kitty-lean--insert-trace-children (cdr a) cls)
                   (insert "\n" (propertize "  (Lean did not answer; refresh the infoview)" 'kitty-lean-face 'warning)))))
           ;; released with the rest of the render
           (when (and (car a) (eq (car kitty-lean--shown-refs) buffer))
             (setf (nth 2 kitty-lean--shown-refs)
                   (append (kitty-lean--json-refs (cdr a)) (nth 2 kitty-lean--shown-refs))))))))))

(defun kitty-lean--inaccessible (start end)
  "Grey the names with ✝ between START and END."
  (save-excursion
    (goto-char start)
    (while (re-search-forward "[^ \n:,]*✝[⁰-⁹]*" end t)
      (put-text-property (match-beginning 0) (match-end 0) 'kitty-lean-face 'kitty-lean-infoview-inaccessible))))

(defun kitty-lean--insert-hyp (h)
  "One hypothesis: names : type (:= value), coloured by what changed."
  (let ((beg (point)))
    (insert (propertize (string-join (append (plist-get h :names) nil) " ")
                        'kitty-lean-face 'kitty-lean-infoview-hyp)
            " : ")
    (kitty-lean--insert-tagged (plist-get h :type))
    (when-let* ((val (and (not kitty-lean-infoview-hide-let-values) (plist-get h :val))))
      (insert " := ")
      (kitty-lean--insert-tagged val))
    (kitty-lean--inaccessible beg (point))
    (cond ((eq (plist-get h :isInserted) t)
           (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-inserted))
          ((eq (plist-get h :isRemoved) t)
           (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-removed)))
    (insert "\n")))

(defun kitty-lean--insert-target (goal)
  (let ((beg (point)))
    (insert (or (plist-get goal :goalPrefix) "⊢ "))
    (kitty-lean--insert-tagged (plist-get goal :type))
    (kitty-lean--inaccessible beg (point))
    (cond ((eq (plist-get goal :isInserted) t)
           (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-inserted))
          ((eq (plist-get goal :isRemoved) t)
           (put-text-property beg (point) 'kitty-lean-diff 'kitty-lean-infoview-removed)))
    (insert "\n")))

(defun kitty-lean--insert-goal (goal)
  "Insert an InteractiveGoal (case, hypotheses, ⊢ target), or a plain goal string.
With `kitty-lean-infoview-reverse', the target comes first and the
hypotheses after it, the nearest first (VS Code's reverseTacticState)."
  (if (stringp goal)
      (insert goal "\n")
    (when-let* ((name (plist-get goal :userName)))
      (insert (propertize (concat "case " name) 'kitty-lean-face 'kitty-lean-infoview-case) "\n"))
    (let ((hyps (seq-remove
                 (lambda (h) (or (and kitty-lean-infoview-hide-instances (eq (plist-get h :isInstance) t))
                                 (and kitty-lean-infoview-hide-types (eq (plist-get h :isType) t))))
                 (plist-get goal :hyps))))
      (if kitty-lean-infoview-reverse
          (progn (kitty-lean--insert-target goal)
                 (mapc #'kitty-lean--insert-hyp (reverse hyps)))
        (mapc #'kitty-lean--insert-hyp hyps)
        (kitty-lean--insert-target goal)))))

(defun kitty-lean--plist-without (plist prop)
  (let (out)
    (while plist
      (unless (eq (car plist) prop) (setq out (cl-list* (cadr plist) (car plist) out)))
      (setq plist (cddr plist)))
    (nreverse out)))

(defun kitty-lean--goal-title (goal i n)
  "The title of goal I of N, for its fold: its case, or its number."
  (or (and (consp goal) (plist-get goal :userName) (concat "case " (plist-get goal :userName)))
      (format "goal %d of %d" (1+ i) n)))

(defun kitty-lean--insert-goals (goals key)
  "GOALS, one under the other.  Several: each a fold, titled by its case
\(VS Code's), and with `kitty-lean-infoview-emphasize-first-goal' the
others folded away under \"Other goals\"."
  (let ((n (length goals)) (i 0))
    (cl-flet ((one (g)
                (let ((i i))
                  (if (= n 1)
                      (kitty-lean--insert-goal g)
                    (kitty-lean--fold
                     ;; this goal (its metavariable), not every `case right' anywhere
                     (list 'goal key i (and (consp g) (or (plist-get g :mvarId) (plist-get g :userName)))) t
                     (lambda () (insert (propertize (kitty-lean--goal-title g i n)
                                                    'kitty-lean-face 'kitty-lean-infoview-case)))
                     (lambda ()
                       (insert "\n")
                       (kitty-lean--insert-goal
                        ;; the title says the case already
                        (if (consp g) (kitty-lean--plist-without g :userName) g)))))
                  (insert "\n"))
                (cl-incf i)))
      (if (and kitty-lean-infoview-emphasize-first-goal (> n 1))
          (progn
            (one (seq-first goals))
            (kitty-lean--fold (list 'other-goals key) nil
                              (lambda () (insert (propertize (format "Other goals (%d)" (1- n))
                                                             'kitty-lean-face 'kitty-lean-infoview-case)))
                              (lambda () (insert "\n") (seq-do #'one (seq-drop goals 1))))
            (insert "\n"))
        (seq-do #'one goals)))))

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
        ;; under the faces already there (a widget's link, a severity)
        (dolist (f faces)
          (add-face-text-property (+ beg (nth 0 f)) (+ beg (nth 1 f)) (nth 2 f) t)))))
  ;; ours over Lean's: case names, hypotheses, ✝, then the diff
  (dolist (prop (if kitty-lean-infoview-diffs '(kitty-lean-face kitty-lean-diff) '(kitty-lean-face)))
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
      (let ((line (1- (line-number-at-pos pos t))))
        (seq-filter
         (lambda (d)
           (let* ((lsp (kitty-lean--lsp-diag d))
                  (range (or (plist-get lsp :fullRange) (plist-get lsp :range))))
             (if range
                 (<= (plist-get (plist-get range :start) :line) line (plist-get (plist-get range :end) :line))
               (save-excursion (goto-char (flymake-diagnostic-beg d)) (= line (1- (line-number-at-pos nil t)))))))
         (flymake-diagnostics))))))

(defun kitty-lean--severity (sev)
  (pcase sev (1 "error") (2 "warning") (3 "info") (_ "hint")))

(defun kitty-lean--severity-face (sev)
  (pcase sev (1 'error) (2 'warning) (_ 'success)))

(defun kitty-lean--lsp-point (buffer position)
  "POSITION, an LSP line and character (UTF-16 for Lean), as a point in BUFFER."
  (with-current-buffer buffer
    (save-excursion (eglot--lsp-position-to-point position))))
(declare-function eglot--lsp-position-to-point "eglot")

(defun kitty-lean--insert-message (uri-buffer range severity message)
  "One message: where (RET jumps there), how bad, then the text."
  (let* ((start (plist-get range :start))
         (line (1+ (plist-get start :line)))
         (col (if (buffer-live-p uri-buffer)
                  (with-current-buffer uri-buffer
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (kitty-lean--lsp-point uri-buffer start))
                        (current-column))))
                (plist-get start :character)))
         (beg (point)))
    (insert (propertize (format "%d:%d %s" line col (kitty-lean--severity severity))
                        'face (kitty-lean--severity-face severity)))
    (put-text-property beg (point) 'kitty-lean-location (list uri-buffer start))
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
  "TAB" #'kitty-lean-infoview-toggle-fold
  "<tab>" #'kitty-lean-infoview-toggle-fold
  "K" #'kitty-lean-infoview-hover
  "g d" #'kitty-lean-infoview-goto
  "p" #'kitty-lean-infoview-toggle-pause
  "c" #'kitty-lean-infoview-clear-pins
  "u" #'kitty-lean-infoview-unpin
  "q" #'quit-window)

(define-derived-mode kitty-lean-infoview-mode special-mode "Infoview"
  "Lean's goals, expected type and messages at the cursor.
\\<kitty-lean-infoview-mode-map>\\[kitty-lean-infoview-hover] on a term: its type and documentation; \
\\[kitty-lean-infoview-goto]: its definition, or on a message or pin: where it is; \
\\[kitty-lean-infoview-unpin] on a pin: unpin it."
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

(defun kitty-lean--infoview-option (var)
  (set var (not (symbol-value var)))
  (when (buffer-live-p kitty-lean--source) (kitty-lean-infoview-refresh kitty-lean--source t))
  (message "Lean infoview: %s %s" var (if (symbol-value var) "on" "off")))

(defun kitty-lean-infoview-toggle-diffs ()
  "Colour the goals' changes, or not (lean.nvim's \\dd)."
  (interactive)
  (kitty-lean--infoview-option 'kitty-lean-infoview-diffs))

(defun kitty-lean-infoview-options ()
  "Turn an infoview option on or off (lean.nvim's \\v, VS Code's infoview settings)."
  (interactive)
  (let* ((options '(("colour the changes" . kitty-lean-infoview-diffs)
                    ("hide type hypotheses" . kitty-lean-infoview-hide-types)
                    ("hide instance hypotheses" . kitty-lean-infoview-hide-instances)
                    ("hide let values" . kitty-lean-infoview-hide-let-values)
                    ("target first, hypotheses reversed" . kitty-lean-infoview-reverse)
                    ("only the first goal unfolded" . kitty-lean-infoview-emphasize-first-goal)))
         (pick (completing-read "Infoview option: "
                                (mapcar (lambda (o) (format "%s (%s)" (car o) (if (symbol-value (cdr o)) "on" "off")))
                                        options)
                                nil t)))
    (kitty-lean--infoview-option
     (cdr (seq-find (lambda (o) (string-prefix-p (car o) pick)) options)))))

(defun kitty-lean-infoview-select ()
  "Go to the infoview window, opening it if needed (lean.nvim's \\<Tab>)."
  (interactive)
  (unless (kitty-lean--infoview-window) (kitty-lean-infoview-open))
  (select-window (kitty-lean--infoview-window)))

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

(defun kitty-lean-infoview-unpin ()
  "Unpin the pin whose heading point is on, in the infoview (VS Code's Unpin)."
  (interactive)
  (let ((m (get-text-property (point) 'kitty-lean-pin)))
    (unless m (user-error "Lean: no pin here (on its \"Pinned at\" line)"))
    (setq kitty-lean--pins (delq m kitty-lean--pins))
    (set-marker m nil)
    (when (buffer-live-p kitty-lean--source) (kitty-lean-infoview-refresh kitty-lean--source t))))

(defun kitty-lean-infoview-clear-pins ()
  "Unpin every pinned position (lean.nvim's \\c)."
  (interactive)
  (setq kitty-lean--pins nil)
  (when (buffer-live-p kitty-lean--source) (kitty-lean-infoview-refresh kitty-lean--source t)))

(defun kitty-lean--source-closed ()
  "This Lean buffer is closed: the infoview no longer shows its goals."
  (when (memq (current-buffer) (list kitty-lean--source kitty-lean--rendered))
    (when (eq kitty-lean--rendered (current-buffer)) (kitty-lean--release-shown))
    (setq kitty-lean--source nil kitty-lean--rendered nil kitty-lean--last-key nil)
    (cl-incf kitty-lean--gen)           ; its answers on their way are not shown
    (when-let* ((iv (get-buffer kitty-lean-infoview-buffer-name)))
      (with-current-buffer iv
        (let ((inhibit-read-only t))
          (cl-incf kitty-lean--render-id)
          (erase-buffer)
          (delete-all-overlays)
          (insert (propertize "No Lean file." 'face 'shadow) "\n"))))))

(defun kitty-lean--source-or-lose ()
  (unless (and (buffer-live-p kitty-lean--source)
               (with-current-buffer kitty-lean--source (eglot-managed-p)))
    (user-error "Lean: the file these goals are from is closed")))

(defun kitty-lean--info-at-point ()
  (or (get-text-property (point) 'kitty-lean-info)
      (user-error "No Lean term here")))

(defun kitty-lean-infoview-hover ()
  "The type and documentation of the term at point in the infoview (VS Code's hover there)."
  (interactive)
  (kitty-lean--source-or-lose)
  (let* ((info (kitty-lean--info-at-point))
         (r (kitty-lean--rpc-call-sync kitty-lean--source (with-current-buffer kitty-lean--source (point))
                                       "Lean.Widget.InteractiveDiagnostics.infoToInteractive" info)))
    (with-help-window "*Lean term*"
      (with-current-buffer standard-output
        (let ((inhibit-read-only t) (beg (point)))
          (when-let* ((e (plist-get r :exprExplicit))) (kitty-lean--insert-tagged e))
          (when-let* ((ty (plist-get r :type))) (insert " : ") (kitty-lean--insert-tagged ty))
          (kitty-lean--fontify-region beg (point))
          ;; the docstring as Markdown, as eldoc shows a hover
          (when-let* ((doc (plist-get r :doc)))
            (insert "\n\n" (or (ignore-errors (eglot--format-markup (list :kind "markdown" :value doc)))
                               doc))))))))

(defun kitty-lean--goto-lsp-location (loc)
  (let* ((uri (or (plist-get loc :targetUri) (plist-get loc :uri)))
         (range (or (plist-get loc :targetSelectionRange) (plist-get loc :range)))
         (file (eglot-uri-to-path uri)))
    (xref-push-marker-stack)
    (pop-to-buffer (find-file-noselect file) '((display-buffer-reuse-window display-buffer-use-some-window)))
    (kitty-lean--goto-point (kitty-lean--lsp-point (current-buffer) (plist-get range :start)))))

(defun kitty-lean--goto-point (pos)
  "Go to POS, widening if a narrowing hides it."
  (unless (<= (point-min) pos (point-max)) (widen))
  (goto-char pos))
(declare-function xref-push-marker-stack "xref")

(defun kitty-lean-infoview-goto ()
  "On a term: go to its definition (VS Code's ctrl-click).
On a message: to where it is.  On a pin: to the pinned place.  On a
widget's button ([apply], a link): press it.  On a fold's title: fold it."
  (interactive)
  (cond
   ((get-text-property (point) 'kitty-lean-action)
    (funcall (get-text-property (point) 'kitty-lean-action)))
   ((and (get-text-property (point) 'kitty-lean-fold)
         (not (get-text-property (point) 'kitty-lean-pin))
         (not (get-text-property (point) 'kitty-lean-info)))
    (kitty-lean-infoview-toggle-fold))
   (t (kitty-lean--infoview-goto))))

(defun kitty-lean--infoview-goto ()
  (if-let* ((pin (get-text-property (point) 'kitty-lean-pin)))
      (progn (unless (marker-buffer pin) (user-error "Lean: that file is closed"))
             (pop-to-buffer (marker-buffer pin) '((display-buffer-reuse-window display-buffer-use-some-window)))
             (kitty-lean--goto-point (marker-position pin)))
   (if-let* ((loc (get-text-property (point) 'kitty-lean-location)))
      (pcase-let ((`(,buffer ,position) loc))
        (unless (buffer-live-p buffer) (user-error "Lean: that file is closed"))
        (pop-to-buffer buffer '((display-buffer-reuse-window display-buffer-use-some-window)))
        (kitty-lean--goto-point (kitty-lean--lsp-point buffer position)))
    (kitty-lean--source-or-lose)
    (let* ((info (kitty-lean--info-at-point))
           (locs (kitty-lean--rpc-call-sync kitty-lean--source (with-current-buffer kitty-lean--source (point))
                                            "Lean.Widget.getGoToLocation" (list :kind "definition" :info info))))
      (if (seq-empty-p locs)
          (message "Lean: no definition for this term")
        (kitty-lean--goto-lsp-location (seq-first locs)))))))

(defun kitty-lean--placeholder (buffer)
  "While Lean builds the imports or checks up to the cursor, no answer comes:
say so, instead of an empty infoview or another file's goals."
  (when-let* ((iv (get-buffer kitty-lean-infoview-buffer-name)))
    (unless (and (eq kitty-lean--rendered buffer) (> (buffer-size iv) 0))
      (kitty-lean--release-shown)
      (setq kitty-lean--rendered buffer)
      (cl-incf kitty-lean--render-id)
      (with-current-buffer iv
        (let ((inhibit-read-only t))
          (erase-buffer)
          (delete-all-overlays)
          (insert (propertize (buffer-name buffer) 'face 'shadow)
                  (propertize "  ⧗ checking…" 'face 'warning) "\n\n"
                  (propertize "Lean is checking the file…" 'face 'shadow) "\n"))))))

(defun kitty-lean--section (key title body &optional default-closed)
  "A section of the infoview: a fold with a heading TITLE, BODY under it, a blank line after."
  (kitty-lean--fold (list 'section key) (not default-closed)
                    (lambda () (if (stringp title) (insert (propertize title 'face 'kitty-lean-infoview-heading))
                                 (funcall title)))
                    (lambda () (insert "\n") (funcall body)))
  (insert "\n\n"))

(defun kitty-lean--insert-all-messages (buffer)
  "Every message of BUFFER, the first line of each, in order (VS Code's All Messages)."
  (with-current-buffer buffer
    (let ((diags (sort (copy-sequence (flymake-diagnostics))
                       (lambda (a b) (< (flymake-diagnostic-beg a) (flymake-diagnostic-beg b))))))
      (dolist (d diags)
        (let* ((lsp (kitty-lean--lsp-diag d))
               (range (or (plist-get lsp :fullRange) (plist-get lsp :range)))
               (text (or (plist-get lsp :message) (flymake-diagnostic-text d))))
          (when range
            (with-current-buffer (get-buffer kitty-lean-infoview-buffer-name)
              (let ((b (point)))
                (insert (propertize (format "%d:%d %s" (1+ (plist-get (plist-get range :start) :line))
                                            ;; the column as the Messages section and Emacs count it
                                            (with-current-buffer buffer
                                              (save-excursion
                                                (save-restriction
                                                  (widen)
                                                  (goto-char (kitty-lean--lsp-point buffer (plist-get range :start)))
                                                  (current-column))))
                                            (kitty-lean--severity (plist-get lsp :severity)))
                                    'face (kitty-lean--severity-face (plist-get lsp :severity)))
                        " " (car (split-string text "\n")) "\n")
                (put-text-property b (point) 'kitty-lean-location (list buffer (plist-get range :start)))))))))))

(defun kitty-lean--render (buffer pos parts)
  "Fill the infoview with PARTS, Lean's answers for POS in BUFFER.
PARTS: plist :goals (interactive goals, or plain strings) :term :messages
:widgets :pins :tick (BUFFER's text they are for)."
  (when-let* ((iv (get-buffer kitty-lean-infoview-buffer-name)))
    (kitty-lean--release-shown)
    (let* ((kitty-lean--refs nil)
           (kitty-lean--pending-fills nil)
           (kitty-lean--fold-path nil)
           (name (buffer-name buffer))
           (line-col (with-current-buffer buffer
                       (save-excursion (goto-char pos)
                                       (format "%d:%d" (line-number-at-pos nil t) (current-column)))))
           (busy (kitty-lean-busy-p buffer))
           (goals (plist-get parts :goals))
           (term (plist-get parts :term))
           (widgets (plist-get parts :widgets))
           (messages (plist-get parts :messages))
           fills)
      (setq kitty-lean--rendered buffer
            kitty-lean--rendered-tick (plist-get parts :tick))
      (cl-incf kitty-lean--render-id)
      (with-current-buffer iv
        (let ((inhibit-read-only t)
              (wstart (when-let* ((w (get-buffer-window iv t))) (window-start w)))
              (wpoint (when-let* ((w (get-buffer-window iv t))) (window-point w))))
          (erase-buffer)
          (delete-all-overlays)
          (insert (propertize (format "%s:%s" name line-col) 'face 'shadow)
                  (if busy (propertize "  ⧗ checking…" 'face 'warning) "")
                  (if kitty-lean--paused (propertize "  ⏸ paused (p)" 'face 'warning) "")
                  "\n\n")
          (dolist (pin (plist-get parts :pins))
            (kitty-lean--fold
             (list 'pin (cadr pin)) t
             (lambda ()
               (insert (propertize (format "Pinned at %s" (cadr pin)) 'face 'kitty-lean-infoview-heading
                                   'kitty-lean-pin (car pin)
                                   'help-echo "RET: go there, u: unpin")))
             (lambda ()
               (insert "\n")
               (let ((b (point)))
                 (if (seq-empty-p (cddr pin)) (insert "No goals\n")
                   (kitty-lean--insert-goals (cddr pin) (cadr pin)))
                 (kitty-lean--fontify-region b (point)))))
            (insert "\n"))
          (cond
           ((eq goals :none))
           ((seq-empty-p goals)
            (kitty-lean--section 'goals "Tactic state"
                                 (lambda () (insert (propertize "No goals" 'face 'success)))))
           (t
            (kitty-lean--section
             'goals (lambda ()
                      (insert (propertize "Tactic state" 'face 'kitty-lean-infoview-heading)
                              (propertize (format "  %d goal%s" (length goals) (if (= 1 (length goals)) "" "s")) 'face 'shadow)))
             (lambda ()
               (let ((b (point)))
                 (kitty-lean--insert-goals goals 'here)
                 (kitty-lean--fontify-region b (point))
                 ;; the blank line after the last goal is the section's
                 (when (eq (char-before) ?\n) (delete-char -1))
                 (when (eq (char-before) ?\n) (delete-char -1)))))))
          (when term
            (kitty-lean--section 'term "Expected type"
                                 (lambda ()
                                   (let ((b (point)))
                                     (kitty-lean--insert-goal term)
                                     (kitty-lean--fontify-region b (point))
                                     (when (eq (char-before) ?\n) (delete-char -1))))))
          (when widgets
            (kitty-lean--section 'widgets "Widgets"
                                 (lambda ()
                                   (seq-do (lambda (w)
                                             (if (fboundp 'kitty-lean-widgets-insert)
                                                 (kitty-lean-widgets-insert w nil)
                                               (insert (plist-get w :id)))
                                             (insert "\n"))
                                           widgets)
                                   (when (eq (char-before) ?\n) (delete-char -1)))))
          (when messages
            (kitty-lean--section 'messages (format "Messages (%d)" (length messages))
                                 (lambda ()
                                   (dolist (m messages)
                                     (let ((b (point)))
                                       (kitty-lean--insert-message buffer (car m) (nth 1 m) (nth 2 m))
                                       (kitty-lean--fontify-region b (point))))
                                   (while (eq (char-before) ?\n) (delete-char -1)))))
          (unless (or (not (eq goals :none)) term messages widgets)
            (insert (propertize (if busy "Lean is checking the file…" "Nothing here.") 'face 'shadow) "\n\n"))
          (when-let* ((tally (kitty-lean--tally buffer)))
            (kitty-lean--fold (list 'section 'all-messages) nil
                              (lambda () (insert (propertize tally 'face 'shadow)))
                              nil
                              (lambda (ov)
                                (kitty-lean--fold-fill
                                 ov (lambda () (insert "\n") (kitty-lean--insert-all-messages buffer)
                                      (when (eq (char-before) ?\n) (delete-char -1))))))
            (insert "\n"))
          (setq fills kitty-lean--pending-fills kitty-lean--pending-fills nil)
          (goto-char (min (or wpoint 1) (point-max)))
          (when-let* ((w (get-buffer-window iv t)))
            (set-window-start w (min (or wstart 1) (point-max)))
            (set-window-point w (point)))))
      ;; every reference in Lean's answers, not only the terms': a lazy
      ;; trace's children, a widget's props hold some too
      (setq kitty-lean--shown-refs
            (list buffer (buffer-local-value 'kitty-lean--rpc-session buffer)
                  ;; each occurrence: Lean counts a reference once per time it sends it
                  (kitty-lean--answer-refs parts)))
      ;; the open lazy folds: a trace's children, all messages
      (with-current-buffer iv
        (let ((kitty-lean--pending-fills fills)) (kitty-lean--run-fills))))))

;;;;; Asking Lean

(defun kitty-lean--request (method buffer pos callback)
  "Ask the server METHOD for POS in BUFFER; CALLBACK gets (ok . answer)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char pos)
      (kitty-lean--flush)
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
      (let ((line (with-current-buffer buffer (1- (line-number-at-pos pos t)))))
        (kitty-lean--rpc-call
         buffer pos "Lean.Widget.getInteractiveDiagnostics"
         (list :lineRange (list :start line :end (1+ line)))
         (lambda (a)
           (funcall callback
                    (cons t
                          (if (and (car a) (seq-some (lambda (d) (not (eq (plist-get d :isSilent) t))) (cdr a)))
                              (delq nil
                                    (mapcar (lambda (d)
                                              ;; "Goals accomplished!" is the ✓, not a message
                                              (unless (eq (plist-get d :isSilent) t)
                                                (list (or (plist-get d :fullRange) (plist-get d :range))
                                                      (plist-get d :severity) (plist-get d :message))))
                                            (cdr a)))
                            ;; flymake's copy, as plain text
                            (mapcar (lambda (d)
                                      (let ((lsp (kitty-lean--lsp-diag d)))
                                        (list (or (plist-get lsp :fullRange) (plist-get lsp :range))
                                              (plist-get lsp :severity)
                                              (or (plist-get lsp :message) (flymake-diagnostic-text d)))))
                                    here))))))))))

(defun kitty-lean--ask-widgets (buffer pos callback)
  "The panel widgets at POS (Lean.Widget.getWidgets: ProofWidgets, #widget ...).
CALLBACK gets (t . widgets); a Lean without them, or an error, is no widgets."
  (kitty-lean--rpc-call
   buffer pos "Lean.Widget.getWidgets"
   (with-current-buffer buffer
     (save-excursion (goto-char pos) (plist-get (eglot--TextDocumentPositionParams) :position)))
   (lambda (a)
     (funcall callback
              (cons t (and (car a) (append (plist-get (cdr a) :widgets) nil)))))))

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
          (when (kitty-lean-busy-p buffer) (kitty-lean--placeholder buffer))
          (let* ((gen (cl-incf kitty-lean--gen))
                 (session (buffer-local-value 'kitty-lean--rpc-session buffer))
                 (pins (seq-filter (lambda (m) (kitty-lean--pin-live-p m)) kitty-lean--pins))
                 (want (+ 4 (length pins)))
                 (parts (list :tick (nth 2 key)))
                 (failed nil)
                 (done (lambda (key answer)
                         (if (not (car answer)) (setq failed t)
                           (if (eq key :pins)
                               (setq parts (plist-put parts :pins (cons (cdr answer) (plist-get parts :pins))))
                             (setq parts (plist-put parts key (cdr answer)))))
                         (when (zerop (cl-decf want))
                           (if (and (= gen kitty-lean--gen) (not failed)
                                    ;; paused while the answers were on their way
                                    (not kitty-lean--paused))
                               (kitty-lean--render buffer pos parts)
                             ;; not shown: Lean can forget what they hold
                             (kitty-lean--release buffer session (kitty-lean--answer-refs parts)))))))
            (kitty-lean--ask-goals buffer pos (lambda (a) (funcall done :goals a)))
            (kitty-lean--ask-term buffer pos (lambda (a) (funcall done :term a)))
            (kitty-lean--ask-messages buffer pos (lambda (a) (funcall done :messages a)))
            (kitty-lean--ask-widgets buffer pos (lambda (a) (funcall done :widgets a)))
            (dolist (m pins)
              (let* ((there (marker-buffer m))
                     (where (with-current-buffer there
                              (save-excursion
                                (goto-char m)
                                (format "%s%d:%d" (if (eq there buffer) "" (concat (buffer-name there) ":"))
                                        (line-number-at-pos nil t) (current-column)))))
                     (answer (lambda (a) (funcall done :pins
                                                  (cons (car a) (cl-list* m where (if (eq (cdr a) :none) nil (cdr a))))))))
                (if (eq there buffer)
                    (kitty-lean--ask-goals buffer (marker-position m) answer)
                  ;; another file's: plain goals, its references would
                  ;; belong to that file's session
                  (kitty-lean--request :$/lean/plainGoal there (marker-position m)
                                       (lambda (p) (funcall answer
                                                            (cons (car p) (if (cdr p) (append (plist-get (cdr p) :goals) nil) :none))))))))))))))

(defun kitty-lean--pin-live-p (m)
  "Whether the pin M is in a Lean file that is open and has its server."
  (when-let* ((b (marker-buffer m)))
    (with-current-buffer b (and (derived-mode-p 'nael-mode) (fboundp 'eglot-managed-p) (eglot-managed-p)))))

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

(defvar kitty-lean-diagnostics-delay 0.3
  "Seconds new diagnostics wait to refresh the infoview, gathering the next.
Lean publishes them line by line as it checks: a refresh for each would
queue hundreds of goal requests behind the check and slow Lean down.")
(defvar kitty-lean--diagnostics-timer nil)

(defun kitty-lean--after-diagnostics (&rest _)
  "New diagnostics: the infoview's messages may have changed."
  (when (and (derived-mode-p 'nael-mode) (kitty-lean--followed-p (current-buffer))
             (not (timerp kitty-lean--diagnostics-timer)))
    (setq kitty-lean--diagnostics-timer
          (run-at-time kitty-lean-diagnostics-delay nil
                       (lambda (buffer)
                         (setq kitty-lean--diagnostics-timer nil)
                         (when (and (buffer-live-p buffer) (kitty-lean--followed-p buffer))
                           (kitty-lean-infoview-refresh buffer t)))
                       (current-buffer)))))

(defun kitty--lean-managed ()
  "eglot took this Lean buffer: the infoview follows it."
  (when (derived-mode-p 'nael-mode)
    (setq kitty-lean--rpc-session nil)
    (if (not (eglot-managed-p))
        (remove-hook 'eldoc-documentation-functions #'kitty-lean--eldoc-refresh t)
      (add-hook 'eldoc-documentation-functions #'kitty-lean--eldoc-refresh nil t)
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
    (kbd "TAB") #'kitty-lean-infoview-toggle-fold
    (kbd "<tab>") #'kitty-lean-infoview-toggle-fold
    (kbd "za") #'kitty-lean-infoview-toggle-fold
    (kbd "K") #'kitty-lean-infoview-hover
    (kbd "gd") #'kitty-lean-infoview-goto
    (kbd "p") #'kitty-lean-infoview-toggle-pause
    (kbd "c") #'kitty-lean-infoview-clear-pins
    (kbd "u") #'kitty-lean-infoview-unpin
    (kbd "q") #'quit-window))

;;;; Commands

(defun kitty-lean--need-server ()
  "A `user-error' that says why, unless this buffer has a Lean server."
  (unless (and (fboundp 'eglot-managed-p) (eglot-managed-p))
    (user-error (cond ((not (executable-find "lake"))
                       "Lean: `lake' is not on PATH; install elan (https://github.com/leanprover/elan)")
                      ((kitty-lean--starting (kitty-lean--project-key))
                       "Lean: the server is still starting")
                      (t "Lean: no server for this buffer (\\R starts one)")))))

;; Opening a file does not build its imports, as in VS Code (its
;; lean4.automaticallyBuildDependencies is off): one file of a Mathlib
;; project without the cache would build Mathlib from source.  Lean says
;; the imports are out of date, and \r rebuilds them.
(defcustom kitty-lean-build-dependencies nil
  "Non-nil: opening a Lean file builds its out-of-date imports first."
  :type 'boolean
  :group 'kittymax)

(defvar kitty-lean--build-mode nil "dependencyBuildMode for the next didOpen, if not the default.")

(defun kitty-lean--did-open-params (args)
  "Add Lean's dependencyBuildMode to a didOpen eglot sends from a Lean buffer."
  (pcase args
    (`(,conn :textDocument/didOpen ,params . ,rest)
     (if (and (derived-mode-p 'nael-mode) (not (plist-member params :dependencyBuildMode)))
         `(,conn :textDocument/didOpen
                 ,(append params (list :dependencyBuildMode
                                       (or kitty-lean--build-mode
                                           (if kitty-lean-build-dependencies "always" "never"))))
                 ,@rest)
       args))
    (_ args)))
(with-eval-after-load 'jsonrpc
  (advice-add 'jsonrpc-notify :filter-args #'kitty-lean--did-open-params))

(defun kitty-lean-restart-file ()
  "Check this file again from the start, with freshly built imports (\\r).
VS Code's Restart File: close and reopen the document on the server."
  (interactive)
  (kitty-lean--need-server)
  (eglot--signal-textDocument/didClose)
  (let ((kitty-lean--build-mode "once"))
    (eglot--signal-textDocument/didOpen))
  (message "Lean: checking %s again" (buffer-name)))

(declare-function eglot--guess-contact "eglot")
(declare-function eglot--connect "eglot")
(declare-function jsonrpc-shutdown "jsonrpc")
(defun kitty-lean-restart-server ()
  "Restart the Lean server (VS Code's Restart Server), or a start that hangs."
  (interactive)
  (cond
   ((and (fboundp 'eglot-current-server) (eglot-current-server))
    (call-interactively #'eglot-reconnect))
   ((not (executable-find "lake")) (kitty-lean--need-server))
   (t
    (let* ((key (kitty-lean--project-key))
           (start (gethash key kitty-lean--starts))
           (server (plist-get start :server)))
      (kitty-lean--start-failed key)
      (when (and server (jsonrpc-running-p server)) (jsonrpc-shutdown server))
      (apply #'eglot--connect (eglot--guess-contact))))))

(defun kitty-lean--goals-at (pos)
  "Lean's goals at POS, synchronously (a list of strings)."
  (save-excursion
    (goto-char pos)
    (kitty-lean--need-server)
    (kitty-lean--flush)
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
    (kitty-lean--need-server)
    (kitty-lean--flush)
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

(defvar kitty-lean--abbrev-names nil "Every \\-abbreviation, shortest first, for eager replacement.")

;; VS Code's table has a few that nael's lacks (\\\\ and \\+SPC are handled
;; above, or can't be: an abbrev has no space).
(declare-function nael-abbrev-help "nael-abbrev")
(with-eval-after-load 'nael-abbrev
  (require 'skeleton)
  (define-skeleton kitty-lean--skeleton-h<> "" nil "❰" _ "❱")
  (define-skeleton kitty-lean--skeleton-^ "" nil "⁽" _ "⁾")
  (define-skeleton kitty-lean--skeleton-_ "" nil "₍" _ "₎")
  (dolist (a '(("\\h<" "❰") ("\\h>" "❱") ("\\:t" "⦂") ("\\typecolon" "⦂")
               ("\\^C" "ꟲ") ("\\^F" "ꟳ") ("\\^Q" "ꟴ") ("\\^S" "\ua7f1")
               ("\\_c" "𞁞") ("\\_w" "\u209d") ("\\_y" "\u209e") ("\\_z" "\u209f")))
    (unless (abbrev--symbol (car a) nael-abbrev-singleton-table)
      (define-abbrev nael-abbrev-singleton-table (car a) (cadr a) nil :system t)))
  (dolist (a '(("\\h<>" kitty-lean--skeleton-h<>) ("\\^()" kitty-lean--skeleton-^)
               ("\\_()" kitty-lean--skeleton-_)))
    (unless (abbrev--symbol (car a) nael-abbrev-skeleton-table)
      (define-abbrev nael-abbrev-skeleton-table (car a) "" (cadr a) :system t))))

(defun kitty-lean--abbrev-names ()
  (or kitty-lean--abbrev-names
      (setq kitty-lean--abbrev-names (mapcar #'car (kitty-lean--abbrevs)))))

(defun kitty-lean--finish-abbrev (start end)
  "The abbreviation from START (its \\) to END is finished: its symbol, or the
symbol of the shortest abbreviation it starts (VS Code: \\alp SPC → α)."
  (let* ((typed (buffer-substring-no-properties start end))
         (name (if (member typed (kitty-lean--abbrev-names)) typed
                 (seq-find (lambda (n) (string-prefix-p typed n)) (kitty-lean--abbrev-names)))))
    (when name
      (let ((replace (lambda ()
                       (delete-region start end)
                       (goto-char start)
                       (insert name)
                       (let ((local-abbrev-table nael-abbrev-table)) (expand-abbrev)))))
        ;; at the end (TAB) a skeleton leaves point between its brackets
        (if (= (point) end) (funcall replace) (save-excursion (funcall replace))))
      t)))

(defun kitty-lean--abbrev-start (end)
  "Where the \\-abbreviation ending at END starts, or nil."
  (save-excursion
    (goto-char end)
    (skip-chars-backward "^\\\\ \t\n" (max (line-beginning-position) (- end 40)))
    (and (eq (char-before) ?\\) (< (point) end) (1- (point)))))

(defun kitty-lean--eager-expand ()
  "VS Code's eager replacement, after each character typed.
An abbreviation is replaced as soon as it is complete and no longer one
starts with it (\\forall → ∀ at the l), or once the next character makes
it the start of none (\\<x → ⟨x⟩, \\alp) → α)): an unfinished one becomes
the symbol of the shortest abbreviation it starts, as on SPC (\\alp SPC → α).
\\\\ is a backslash."
  (let* ((sep (memq (char-before) '(?\s ?\t ?\n)))
         (end (if sep (1- (point)) (point))))
    (if (and (not sep) (eq (char-before) ?\\) (eq (char-before (1- (point))) ?\\)
             (not (eq (char-before (- (point) 2)) ?\\)))
        (delete-char -1)
      (when-let* ((start (kitty-lean--abbrev-start end))
                  ((> (- end start) 1)))
        (let* ((typed (buffer-substring-no-properties start end))
               ;; \\alpha is not \\Alpha, whatever completion-ignore-case says
               (done (let ((completion-ignore-case nil)) (try-completion typed (kitty-lean--abbrev-names)))))
          (cond
           (sep (kitty-lean--finish-abbrev start end))
           ((eq done t) (expand-abbrev))
           ((and (null done) (> (length typed) 2))
            (kitty-lean--finish-abbrev start (1- end)))))))))

(defun kitty--lean-eager ()
  (add-hook 'post-self-insert-hook #'kitty-lean--eager-expand 90 t))
(kitty-add-hook 'nael-mode-hook #'kitty--lean-eager)

(defun kitty-lean-tab ()
  "TAB after a \\-abbreviation turns it into its symbol and nothing more,
as in VS Code; elsewhere, TAB as always."
  (interactive)
  (unless (and (bound-and-true-p abbrev-mode)
               (when-let* ((start (kitty-lean--abbrev-start (point))))
                 (kitty-lean--finish-abbrev start (point))))
    (call-interactively #'indent-for-tab-command)))

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
    (with-current-buffer (or (url-retrieve-synchronously (concat kitty-lean-loogle-url (url-hexify-string query)) t t 20)
                             (user-error "Loogle: no answer (offline?)"))
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
    (compile (concat
              ;; as VS Code's Build Project: Mathlib's prebuilt files first
              (if (kitty-lean--uses-mathlib-p default-directory) "lake exe cache get && " "")
              (string-join (delq nil (list "lake build" (and target (shell-quote-argument target)))) " ")))))

(defun kitty-lean--uses-mathlib-p (root)
  "Whether the Lake project at ROOT is Mathlib or depends on it."
  (or (file-directory-p (expand-file-name ".lake/packages/mathlib" root))
      (let ((manifest (expand-file-name "lake-manifest.json" root)))
        (and (file-readable-p manifest)
             (with-temp-buffer
               (insert-file-contents manifest)
               (re-search-forward "\"name\": *\"mathlib\"" nil t))))
      (seq-some (lambda (f)
                  (let ((file (expand-file-name f root)))
                    (and (file-readable-p file)
                         (with-temp-buffer
                           (insert-file-contents file)
                           (re-search-forward "^ *\\(package +«?mathlib»?\\|name *= *\"mathlib\"\\)" nil t)))))
                '("lakefile.lean" "lakefile.toml"))))

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

(defun kitty-lean--new-project-file (dir)
  "The file to start in, in the new project DIR: its library's Basic.lean.
Lake names the library itself (my-proj: MyProj), so it is looked up: the
.lean file next to a directory of the same name."
  (let* ((lib (seq-find (lambda (f) (file-directory-p (file-name-sans-extension f)))
                        (directory-files dir t "\\.lean\\'")))
         (basic (and lib (expand-file-name "Basic.lean" (file-name-sans-extension lib)))))
    (cond ((and basic (file-exists-p basic)) basic)
          (lib)
          (t (or (car (directory-files dir t "\\.lean\\'")) dir)))))

(defun kitty-lean-new-project (name &optional math)
  "A new Lake project NAME in this directory; MATH (C-u): with Mathlib, prebuilt.
my-nvim's :LeanNew name [math]."
  (interactive (list (read-string "New Lean project: ") current-prefix-arg))
  (let* ((cwd default-directory)
         (dir (expand-file-name name cwd)))
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
                        (find-file (kitty-lean--new-project-file dir))))
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
  "\\" '("how to type this" . kitty-lean-describe-symbol)
  "TAB" '("to the infoview" . kitty-lean-infoview-select)
  "v" '("infoview options" . kitty-lean-infoview-options)
  "d d" '("colour goal changes" . kitty-lean-infoview-toggle-diffs)
  "z" '("fold all proofs" . kitty-lean-fold-proofs)
  "Z" '("unfold all proofs" . kitty-lean-unfold-proofs)
  "w" '("VS Code's infoview" . kitty-lean-webview))

(autoload 'kitty-lean-webview "kitty-lean-webview"
  "VS Code's own infoview for the Lean files: in a webview, or a browser." t)

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
    (evil-define-key* 'normal nael-mode-map (kbd "\\") kitty-lean-local-map)
    (evil-define-key* 'insert nael-mode-map (kbd "TAB") #'kitty-lean-tab (kbd "<tab>") #'kitty-lean-tab))
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
             (bound-and-true-p org-src--beg-marker)
             ;; not the hidden edit buffer org makes for a moment to indent
             ;; (TAB) or run a command in the block: only C-c '
             (not (eq (bound-and-true-p org-src-window-setup) 'switch-invisibly)))
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
