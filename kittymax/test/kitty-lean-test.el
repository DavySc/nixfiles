;;; kitty-lean-test.el --- Lean 4, through the whole configuration and a real server  -*- lexical-binding: t; -*-

;;   kittymax/test/run.sh, or:
;;   emacs --batch -q -L lisp -L lisp/lang -l test/kitty-lean-test.el -f ert-run-tests-batch-and-exit
;;
;; The first tests need nothing.  The rest boot kittymax and open a small Lake
;; project in a real Lean server (`lake serve'): they need nael, and `lean' and
;; `lake' on PATH (elan, or nixpkgs' lean4), and are skipped without them.  As
;; my-nvim's tests/lean_test.lua does for lean.nvim.

(require 'ert)
(require 'cl-lib)

(defvar kitty-lean-test--root
  (file-name-directory (directory-file-name (file-name-directory (or load-file-name buffer-file-name)))))

;;;; Without a server

(defvar kitty-cache-dir)
(defvar kitty-data-dir)
(defvar kitty-config-dir)
(unless (boundp 'kitty-cache-dir)
  (setq kitty-cache-dir (make-temp-file "kitty-cache" t)
        kitty-data-dir kitty-cache-dir
        kitty-config-dir kitty-lean-test--root))
(require 'kitty-lib)
(require 'kitty-lean)

;; `lake build''s own output (Lean 4.35)
(defconst kitty-lean-test--lake-output "✖ [2/4] Building Demo.Bad (252ms)
trace: .> LEAN_PATH=/p/.lake/build/lib/lean lean /p/Demo/Bad.lean -o x --json
error: Demo/Bad.lean:1:15: Type mismatch
  \"s\"
has type
  String
error: Demo/Bad.lean:3:41: unsolved goals
a b : Nat
⊢ a + b = b + a
warning: ./Demo/Other.lean:6:8: declaration uses `sorry`
info: Demo/Bad.lean:6:0: 2
Some required targets logged failures:
- Demo.Bad
error: build failed
")

(ert-deftest kitty-lean-lake-messages-are-jumps ()
  "Lake's errors, warnings and infos: file, line, 1-based column, severity."
  (with-temp-buffer
    (insert kitty-lean-test--lake-output)
    (goto-char (point-min))
    (let (found)
      (while (re-search-forward kitty-lean-lake-error-regexp nil t)
        (push (list (match-string 1) (match-string 2) (kitty-lean--column)
                    (cond ((match-beginning 4) 'warning) ((match-beginning 5) 'info) (t 'error)))
              found))
      (should (equal (nreverse found)
                     '(("Demo/Bad.lean" "1" 16 error)
                       ("Demo/Bad.lean" "3" 42 error)
                       ("Demo/Other.lean" "6" 9 warning)
                       ("Demo/Bad.lean" "6" 1 info)))))))

(ert-deftest kitty-lean-dependencies-are-read-only ()
  (should (kitty-lean-read-only-p "/p/.lake/packages/mathlib/Mathlib/Data/Nat.lean"))
  (should (kitty-lean-read-only-p "/home/d/.elan/toolchains/leanprover--lean4---v4.35.0/src/lean/Init.lean"))
  (should-not (kitty-lean-read-only-p "/p/Demo/Basic.lean"))
  (should-not (kitty-lean-read-only-p nil)))

(ert-deftest kitty-lean-babel-output-loses-the-temporary-file-name ()
  (should (equal (kitty-lean--strip-locations "/t/Block1.lean:1:0: error: oops\n2\n" "/t/Block1.lean")
                 "1:0: error: oops\n2\n")))

(ert-deftest kitty-lean-infoview-drops-stale-answers ()
  "Answers for an older request never overwrite a newer one, whatever their order;
a failed answer leaves the infoview as it was."
  (let* ((calls nil)
         (rendered nil)
         (buf (generate-new-buffer "x.lean")))
    (cl-letf (((symbol-function 'kitty-lean--infoview-window) (lambda () t))
              ((symbol-function 'eglot-managed-p) (lambda () t))
              ((symbol-function 'kitty-lean--refresh-target) (lambda (b) (with-current-buffer b (point))))
              ((symbol-function 'kitty-lean--ask-goals) (lambda (_b pos cb) (push (list :goals pos cb) calls)))
              ((symbol-function 'kitty-lean--ask-term) (lambda (_b pos cb) (push (list :term pos cb) calls)))
              ((symbol-function 'kitty-lean--ask-messages) (lambda (_b pos cb) (push (list :messages pos cb) calls)))
              ((symbol-function 'kitty-lean--render)
               (lambda (_b pos parts) (push (cons pos (plist-get parts :goals)) rendered))))
      (with-current-buffer buf
        (insert "theorem t : True := by\n  trivial\n")
        (setq major-mode 'nael-mode)
        (put 'nael-mode 'derived-mode-parent 'prog-mode)
        (goto-char 5)
        (kitty-lean-infoview-refresh buf)
        (goto-char 20)
        (kitty-lean-infoview-refresh buf)
        ;; the same place again: no new request
        (kitty-lean-infoview-refresh buf)
        (should (= 6 (length calls)))
        (cl-flet ((answer (pos &optional fail)
                    (dolist (c calls)
                      (when (= (nth 1 c) pos)
                        (funcall (nth 2 c) (if fail (cons nil nil) (cons t (list (format "goal at %d" pos)))))))))
          ;; the newer request is answered first, the older one after it
          (answer 20)
          (answer 5))
        (should (equal rendered '((20 "goal at 20"))))
        ;; forced (Lean finished the file): asked again; this time it fails
        (setq calls nil)
        (kitty-lean-infoview-refresh buf t)
        (should (= 3 (length calls)))
        (dolist (c calls) (funcall (nth 2 c) (cons nil nil)))
        (should (= 1 (length rendered)))))
    (kill-buffer buf)))

;;;; Through the whole configuration and a real Lean server

(defvar kitty-lean-test--booted nil)

(defun kitty-lean-test--boot ()
  (unless kitty-lean-test--booted
    (setq kitty-lean-test--booted t)
    (let ((home (make-temp-file "kitty-home" t)))
      (setenv "KITTYMAX_PACKAGES" "none")
      (setenv "XDG_DATA_HOME" (expand-file-name "data" home))
      (setenv "XDG_CACHE_HOME" (expand-file-name "cache" home))
      (setq treesit-auto-install-grammar 'never)
      (setq user-emacs-directory (file-name-as-directory kitty-lean-test--root))
      (load (expand-file-name "early-init.el" kitty-lean-test--root) nil t)
      (load (expand-file-name "init.el" kitty-lean-test--root) nil t)
      (run-hooks 'after-init-hook 'emacs-startup-hook 'window-setup-hook)
      (when (fboundp 'kitty--evil-setup) (unless (featurep 'evil) (kitty--evil-setup)))
      (setq kitty-lean-infoview-auto-open t))))

(defun kitty-lean-test--skip-unless-lean ()
  "Skip the test without nael or a Lean toolchain."
  (unless (and (executable-find "lake") (executable-find "lean") (locate-library "nael"))
    (signal 'ert-test-skipped '("no nael, lean or lake"))))

(defun kitty-lean-test--write (dir file text)
  (let ((path (expand-file-name file dir)))
    (make-directory (file-name-directory path) t)
    (with-temp-file path (insert text))
    path))

(defvar kitty-lean-test--project nil)

(defun kitty-lean-test--project ()
  "A Lake project: a library with an error and an unfinished proof, a good module, main."
  (or kitty-lean-test--project
      (let ((dir (file-name-as-directory (file-truename (make-temp-file "kitty-lean" t)))))
        (kitty-lean-test--write dir "lakefile.toml" "name = \"demo\"\n\n[[lean_lib]]\nname = \"Demo\"\n")
        (kitty-lean-test--write dir "Demo.lean" "import Demo.Bad\n")
        (kitty-lean-test--write dir "Demo/Bad.lean"
                                "def x : Nat := \"s\"\n\ntheorem t (a b : Nat) : a + b = b + a := by\n  skip\n\n#eval 1 + 1\n")
        (kitty-lean-test--write dir "Demo/Good.lean" "def good : Nat := 42\n")
        (kitty-lean-test--write dir "Main.lean" "def main : IO Unit := IO.println \"hello from lean\"\n")
        (kitty-lean-test--write dir "Try.lean" "example (a b : Nat) : a + b = b + a := by\n  exact?\n")
        (kitty-lean-test--write dir "Use.lean" "import Demo.Good\n#check good\ntheorem t (a b : Nat) : a + b = b + a := Nat.add_c\n")
        (let ((default-directory dir))
          (call-process "git" nil nil nil "init" "-q")
          ;; Demo.Good's .olean, for `import Demo.Good' from org
          (call-process "lake" nil nil nil "build" "Demo.Good"))
        (setq kitty-lean-test--project dir))))

(defun kitty-lean-test--wait (seconds pred)
  "Wait up to SECONDS for PRED, letting timers and the server run."
  (let ((end (+ (float-time) seconds)))
    (while (and (not (funcall pred)) (< (float-time) end))
      (accept-process-output nil 0.1)
      (when (input-pending-p) (discard-input)))
    (funcall pred)))

(defun kitty-lean-test--sync ()
  "Send the edits to the server now (eglot waits for an idle time, which batch Emacs never has)."
  (when (eglot-managed-p) (eglot--signal-textDocument/didChange)))

(defun kitty-lean-test--infoview-text ()
  (with-current-buffer (get-buffer-create kitty-lean-infoview-buffer-name)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun kitty-lean-test--infoview-shows (seconds regexp)
  "Wait up to SECONDS for the infoview to match REGEXP; say what it shows if not."
  (or (kitty-lean-test--wait seconds (lambda () (string-match-p regexp (kitty-lean-test--infoview-text))))
      (progn (message "infoview, not matching %S (gen %s, paused %s):\n%s"
                      regexp kitty-lean--gen kitty-lean--paused (kitty-lean-test--infoview-text))
             nil)))

(defun kitty-lean-test--misc-info (buffer)
  "What BUFFER's mode-line-misc-info shows of Lean (doom-modeline's misc-info).
format-mode-line says nothing in batch Emacs: so, its rules for a list
(one that starts with a symbol is a conditional, not a list of elements)."
  (with-current-buffer buffer
    (should (consp (car mode-line-misc-info)))
    (let ((el (seq-find (lambda (e) (eq e kitty-lean--mode-line-element)) mode-line-misc-info)))
      (should el)
      (or (eval (cadr el) t) ""))))

(defun kitty-lean-test--visit (file)
  (let ((buf (find-file-noselect (expand-file-name file (kitty-lean-test--project)))))
    (switch-to-buffer buf)
    (delete-other-windows)
    (when (fboundp 'evil-normal-state) (evil-normal-state))
    ;; eglot-ensure connects after the next command
    (run-hooks 'post-command-hook)
    ;; flymake starts once the buffer is on display, which batch Emacs,
    ;; without redisplay, never says
    (run-hooks 'window-configuration-change-hook)
    buf))

(defun kitty-lean-test--fresh ()
  "No Lean buffer and no infoview left from an earlier test."
  (dolist (b (buffer-list))
    (when (and (buffer-live-p b) (with-current-buffer b (derived-mode-p 'nael-mode)))
      (with-current-buffer b (set-buffer-modified-p nil))
      (kill-buffer b)))
  (when-let* ((w (kitty-lean--infoview-window))) (delete-window w)))

(defun kitty-lean-test--errors (buf)
  (with-current-buffer buf
    (and (bound-and-true-p flymake-mode)
         (cl-remove-if-not (lambda (d) (memq (flymake-diagnostic-type d) '(:error eglot-error)))
                           (flymake-diagnostics)))))

(ert-deftest kitty-lean-server-diagnostics-and-infoview ()
  "A Lean file: the server, its diagnostics, the infoview following the cursor."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (eq major-mode 'nael-mode))
    (should abbrev-mode)
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (string-match-p "lake" (format "%s" (process-command (jsonrpc--process (eglot-current-server))))))
    (should (equal (file-truename (project-root (eglot--project (eglot-current-server))))
                   (kitty-lean-test--project)))
    ;; the type error and the unsolved goal
    (should (kitty-lean-test--wait 120 (lambda () (>= (length (kitty-lean-test--errors buf)) 2))))
    (should (kitty-lean-test--wait 60 (lambda () (not (kitty-lean-busy-p buf)))))
    (should-not (kitty-lean--mode-line))
    ;; the infoview opened by itself and follows the cursor
    (should (kitty-lean--infoview-window))
    (goto-char (point-min)) (forward-line 3) (back-to-indentation)
    (kitty-lean-infoview-refresh buf)
    (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
    (should (string-match-p "Tactic state" (kitty-lean-test--infoview-text)))
    ;; messages of the cursor's line, whole
    (goto-char (point-min)) (forward-char 16)
    (kitty-lean-infoview-refresh buf)
    (should (kitty-lean-test--infoview-shows 30 "Type mismatch\\(.\\|\n\\)*has type"))
    (should (string-match-p "Messages (1)\n1:15 error" (kitty-lean-test--infoview-text)))
    ;; a message spanning lines shows on each of them, as in VS Code
    (goto-char (point-min)) (forward-line 3) (back-to-indentation)
    (kitty-lean-infoview-refresh buf)
    (should (kitty-lean-test--infoview-shows 30 "3:41 error\nunsolved goals"))
    (should (string-match-p "All messages: 2 errors, 0 warnings, 1 info" (kitty-lean-test--infoview-text)))
    ;; #eval's output is a message, as in VS Code's infoview
    (goto-char (point-min)) (forward-line 5)
    (kitty-lean-infoview-refresh buf)
    (should (kitty-lean-test--infoview-shows 30 "6:0 info\n2$"))
    ;; eldoc's idle timer moves it, nothing on each key
    (goto-char (point-min)) (forward-line 3) (end-of-line)
    (let ((gen kitty-lean--gen))
      (eldoc-print-current-symbol-info)
      (should (> kitty-lean--gen gen)))
    (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
    ;; \i closes it, \i opens it
    (kitty-lean-infoview-toggle)
    (should-not (kitty-lean--infoview-window))
    (kitty-lean-infoview-toggle)
    (should (kitty-lean--infoview-window))))

(ert-deftest kitty-lean-progress-while-checking ()
  "Lean's file progress: the mode line and the fringe while checking, nothing after."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (kitty-lean-infoview-open)
    ;; a report as Lean sends it, then the one that says it is done
    (kitty-lean--on-progress (plist-get (eglot--TextDocumentIdentifier) :uri)
                             (vector (list :range (list :start (list :line 2 :character 0) :end (list :line 5 :character 0)) :kind 1)))
    (should (kitty-lean-busy-p buf))
    (should (string-match-p "⧗" (kitty-lean--mode-line)))
    ;; what doom-modeline's misc-info segment shows
    (should (string-match-p "⧗ [0-9]+%%" (kitty-lean-test--misc-info buf)))
    (should (kitty-lean-test--wait 2 (lambda () (= 1 (length kitty-lean--progress-overlays)))))
    (let ((gen kitty-lean--gen))
      (kitty-lean--on-progress (plist-get (eglot--TextDocumentIdentifier) :uri) [])
      (should-not (kitty-lean-busy-p buf))
      ;; done: the infoview asks again
      (should (> kitty-lean--gen gen)))
    (should (kitty-lean-test--wait 2 (lambda () (null kitty-lean--progress-overlays))))))

(ert-deftest kitty-lean-background-files-leave-the-infoview-alone ()
  "A file Lean checks out of sight (a definition you looked at) does not take
the infoview from the one you are in, as in VS Code."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((other (kitty-lean-test--visit "Demo/Good.lean"))
        (buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (with-current-buffer other (eglot-managed-p)))))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (kitty-lean-infoview-open)
    (goto-char (point-min)) (forward-line 3) (back-to-indentation)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
    ;; Bad.lean's own check is over (its diagnostics refresh, rightly)
    (should (kitty-lean-test--wait 60 (lambda () (not (kitty-lean-busy-p buf)))))
    (kitty-lean-test--wait 1 #'ignore)
    (let ((gen kitty-lean--gen))
      ;; both opened before the server was up: one server for the two
      (should (with-current-buffer other (eglot-managed-p)))
      (should (eq (with-current-buffer other (eglot-current-server)) (eglot-current-server)))
      ;; Good.lean finishes checking and gets diagnostics, out of sight
      (with-current-buffer other
        (let ((uri (plist-get (eglot--TextDocumentIdentifier) :uri)))
          (kitty-lean--on-progress uri (vector (list :range (list :start (list :line 0 :character 0) :end (list :line 1 :character 0)) :kind 1)))
          (kitty-lean--on-progress uri []))
        (kitty-lean--after-diagnostics))
      ;; (diagnostics refresh after a moment, gathered: see the next test)
      (kitty-lean-test--wait 1 #'ignore)
      (should (eq kitty-lean--source buf))
      (should (= gen kitty-lean--gen))
      ;; the one in the selected window still does
      (kitty-lean--after-diagnostics)
      (should (kitty-lean-test--wait 2 (lambda () (> kitty-lean--gen gen)))))))

(ert-deftest kitty-lean-unicode-input ()
  "\\a then a space → α, \\N then Escape → ℕ, \\<> → ⟨⟩ with the cursor inside, \\forall at once."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (goto-char (point-max))
    (execute-kbd-macro (kbd "o - - SPC \\ a SPC x SPC \\ N <escape>"))
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "-- α x ℕ"))
    ;; \\<> puts the cursor between ⟨ and ⟩; \\< alone is ⟨, once x shows it is not \\<=
    (execute-kbd-macro (kbd "o \\ < > x <escape> o \\ < x"))
    (should (equal (buffer-substring-no-properties (line-beginning-position 0) (line-end-position)) "⟨x⟩\n⟨x"))
    (execute-kbd-macro (kbd "<escape>"))
    ;; complete and the start of nothing longer: at once, as VS Code
    (let ((completion-ignore-case t))   ; as kittymax has it: \\alpha is still not \\Alpha
      (execute-kbd-macro (kbd "<escape> o \\ a l p h a"))
      (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "α")))
    (execute-kbd-macro (kbd "<escape> o \\ N TAB"))
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "ℕ"))
    (execute-kbd-macro (kbd "<escape>"))
    (execute-kbd-macro (kbd "o \\ f o r a l l"))
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "∀"))
    (execute-kbd-macro (kbd "<escape>"))
    (with-current-buffer buf (set-buffer-modified-p nil) (revert-buffer t t))))

(ert-deftest kitty-lean-keys ()
  "my-nvim's Lean keys: lean.nvim's on \\, SPC m m / r / c, :Lake and :LeanNew."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--visit "Demo/Bad.lean")
  (dolist (k '(("i" . kitty-lean-infoview-toggle) ("r" . kitty-lean-restart-file)
               ("s" . kitty-lean-accept-suggestion) ("S" . kitty-lean-sorry-fill)
               ("u" . kitty-lean-insert-symbol) ("l" . kitty-lean-loogle)
               ("/" . kitty-lean-grep-library) ("f" . kitty-lean-find-library-file)
               ("\\" . kitty-lean-describe-symbol)))
    (let ((b (lookup-key (evil-get-auxiliary-keymap nael-mode-map 'normal) (kbd (concat "\\ " (car k))))))
      (should (eq (cdr k) (if (consp b) (cdr b) b)))))
  (dolist (k '(("m" . kitty-lean-build) ("r" . kitty-lean-run-file) ("c" . kitty-lean-cache-get)))
    (let ((b (lookup-key (kitty--local-leader-map) (kbd (car k)))))
      (should (eq (cdr k) (if (consp b) (cdr b) b)))))
  (should (evil-ex-binding "Lake"))
  (should (evil-ex-binding "LeanNew")))

(ert-deftest kitty-lean-sorry-fill-and-suggestions ()
  "\\S fills each goal with a sorry; \\s takes Lean's `Try this'."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (>= (length (kitty-lean-test--errors buf)) 2))))
    (goto-char (point-min)) (forward-line 3)
    (kitty-lean-sorry-fill)
    (kitty-lean-test--sync)
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "  sorry"))
    ;; the unsolved goal is gone, only the type error is left
    (should (kitty-lean-test--wait 120 (lambda () (= 1 (length (kitty-lean-test--errors buf))))))
    (with-current-buffer buf (revert-buffer t t)))
  (let ((buf (kitty-lean-test--visit "Try.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (and (not (kitty-lean-busy-p buf)) (flymake-diagnostics)))))
    (goto-char (point-min)) (forward-line 1) (back-to-indentation)
    (kitty-lean-accept-suggestion)
    (should (kitty-lean-test--wait 10 (lambda () (not (string-match-p "exact\\?" (buffer-string))))))
    (should (string-match-p "exact Nat.add_comm a b\\|exact Nat.add_comm" (buffer-string)))
    (set-buffer-modified-p nil)
    (kill-buffer buf)))

(ert-deftest kitty-lean-language-server-basics ()
  "What eglot gives from Lean's server: completion, definitions across modules
and into Lean's own library (read-only), hovers, semantic highlighting."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Use.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (and (not (kitty-lean-busy-p buf)) (flymake-diagnostics)))))
    ;; completion at `Nat.add_c|'
    (goto-char (point-min)) (forward-line 2) (end-of-line)
    (let* ((capf (eglot-completion-at-point))
           (cands (all-completions (buffer-substring-no-properties (nth 0 capf) (nth 1 capf)) (nth 2 capf))))
      (should (member "add_comm" (mapcar (lambda (c) (car (last (split-string c "\\.")))) cands))))
    ;; hover on `good': its type
    (goto-char (point-min)) (forward-line 1) (search-forward "goo")
    (let ((hover (jsonrpc-request (eglot-current-server) :textDocument/hover (eglot--TextDocumentPositionParams))))
      (should (string-match-p "Nat" (format "%S" hover))))
    (require 'consult-xref nil t)      ; what kittymax shows xrefs with (package autoloads)
    ;; go to definition: another module of the project
    (xref-find-definitions "good")
    (should (string-suffix-p "Demo/Good.lean" buffer-file-name))
    (should (looking-at "good\\|def good"))
    (kill-buffer)
    ;; and Lean's own library, which is not for editing
    (switch-to-buffer buf)
    (goto-char (point-min)) (forward-line 2) (search-forward ": Nat") (backward-char 1)
    (call-interactively #'xref-find-definitions)
    (should (string-match-p "Prelude\\.lean\\'\\|/Init/" buffer-file-name))
    (should buffer-read-only)
    (switch-to-buffer buf)
    (should (bound-and-true-p eglot-semantic-tokens-mode))))

(ert-deftest kitty-lean-closing-the-last-file-is-quiet ()
  "Closing the last Lean file stops its server, without an error (Lean exits
before eglot's `exit' reaches it, some of the time: so, ten times)."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (dotimes (_ 10)
    (let* ((buf (kitty-lean-test--visit "Demo/Good.lean"))
           (server (and (kitty-lean-test--wait 60 (lambda () (eglot-managed-p)))
                        (eglot-current-server))))
      (should server)
      (kill-buffer buf)
      (should-not (buffer-live-p buf))
      (should (kitty-lean-test--wait 10 (lambda () (not (jsonrpc-running-p server))))))))

(defun kitty-lean-test--bad-with-goal ()
  "Bad.lean checked, the infoview on its unsolved goal."
  (kitty-lean-test--fresh)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (>= (length (kitty-lean-test--errors buf)) 2))))
    (should (kitty-lean-test--wait 60 (lambda () (not (kitty-lean-busy-p buf)))))
    (unless (kitty-lean--infoview-window) (kitty-lean-infoview-open))
    (goto-char (point-min)) (forward-line 3) (back-to-indentation)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
    buf))

(defun kitty-lean-test--hover-a ()
  "K on the goal's `a' in the infoview: what it says."
  (with-current-buffer kitty-lean-infoview-buffer-name
    (goto-char (point-min)) (search-forward "⊢ a") (backward-char 1)
    (kitty-lean-infoview-hover)
    (with-current-buffer "*Lean term*" (buffer-substring-no-properties (point-min) (point-max)))))

(ert-deftest kitty-lean-infoview-terms-are-the-ones-under-the-cursor ()
  "K on `a' in `a + b = b + a' is about `a', not the whole equation."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--bad-with-goal)
  (with-current-buffer kitty-lean-infoview-buffer-name
    (goto-char (point-min)) (search-forward "⊢ ")
    (let ((line (buffer-substring (point) (line-end-position))))
      (should (> (length (delete-dups (mapcar (lambda (i) (get-text-property i 'kitty-lean-info line))
                                              (number-sequence 0 (1- (length line))))))
                 3))))
  (should (string-match-p "\\`a : Nat" (kitty-lean-test--hover-a))))

(ert-deftest kitty-lean-a-lost-session-is-found-again ()
  "Lean forgets an RPC session nobody kept alive (a laptop asleep): the
infoview connects once more, and K works on what it shows."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)) (connects 0))
    (cl-letf* ((orig (symbol-function 'jsonrpc-request))
               ((symbol-function 'jsonrpc-request)
                (lambda (c m &rest r) (when (eq m :$/lean/rpc/connect) (cl-incf connects)) (apply orig c m r))))
      ;; K right away, on references of a session Lean no longer has
      (with-current-buffer buf (setq kitty-lean--rpc-session "12345"))
      (should (string-match-p "out of date" (condition-case e (kitty-lean-test--hover-a) (user-error (cadr e)))))
      (should (kitty-lean-test--wait 30 (lambda () (= connects 1))))
      (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
      (should (string-match-p "\\`a : Nat" (kitty-lean-test--hover-a)))
      ;; the infoview's own refresh on a lost session: one new session, not one per call
      (setq connects 0)
      (with-current-buffer buf (setq kitty-lean--rpc-session "12345"))
      (kitty-lean-infoview-refresh buf t)
      (kitty-lean-test--wait 3 #'ignore)
      (should (kitty-lean-test--infoview-shows 30 "⊢ a \\+ b = b \\+ a"))
      (should (= connects 1))
      (should (string-match-p "\\`a : Nat" (kitty-lean-test--hover-a))))))

(ert-deftest kitty-lean-paused-means-paused ()
  "An answer on its way when you pause does not change the infoview."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)))
    (goto-char (point-min)) (forward-char 16)
    (kitty-lean-infoview-refresh buf t)
    (let ((before (kitty-lean-test--infoview-text)))
      (kitty-lean-infoview-toggle-pause)
      (kitty-lean-test--wait 3 #'ignore)
      (should (equal before (kitty-lean-test--infoview-text)))
      (kitty-lean-infoview-toggle-pause))))

(ert-deftest kitty-lean-edits-reach-lean-before-questions ()
  "\\S right after typing a tactic sees the new text (eglot sends edits only
when idle; the question would otherwise be about the old text)."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--write (kitty-lean-test--project) "Two.lean" "example : True ∧ True := by\n  skip\n")
  (let ((buf (kitty-lean-test--visit "Two.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 60 (lambda () (flymake-diagnostics))))
    (goto-char (point-min)) (forward-line 1) (back-to-indentation)
    (delete-region (point) (line-end-position)) (insert "constructor")
    (kitty-lean-sorry-fill)
    (should (string-match-p "· sorry\n +· sorry" (buffer-string)))
    (with-current-buffer buf (set-buffer-modified-p nil) (kill-buffer))))

(ert-deftest kitty-lean-revert-leaves-no-progress-marks ()
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)))
    (kitty-lean--on-progress (plist-get (eglot--TextDocumentIdentifier) :uri)
                             (vector (list :range (list :start (list :line 2 :character 0) :end (list :line 5 :character 0)) :kind 1)))
    (should (kitty-lean-test--wait 2 (lambda () (= 1 (length kitty-lean--progress-overlays)))))
    (revert-buffer t t)
    (kitty-lean-test--wait 20 (lambda () (and (eglot-managed-p) (not (kitty-lean-busy-p buf)))))
    (should-not (seq-filter (lambda (o) (overlay-get o 'kitty-lean-progress)) (overlays-in (point-min) (point-max))))))

(ert-deftest kitty-lean-checking-says-so ()
  "Before Lean has an answer (imports building), the infoview says it is checking."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)))
    (with-current-buffer kitty-lean-infoview-buffer-name (let ((inhibit-read-only t)) (erase-buffer)))
    (setq kitty-lean--rendered nil)
    (cl-letf (((symbol-function 'kitty-lean--ask-goals) #'ignore))
      (kitty-lean--on-progress (plist-get (eglot--TextDocumentIdentifier) :uri)
                               (vector (list :range (list :start (list :line 0 :character 0) :end (list :line 5 :character 0)) :kind 1)))
      (kitty-lean-infoview-refresh buf t)
      (should (string-match-p "Lean is checking the file" (kitty-lean-test--infoview-text))))
    (kitty-lean--on-progress (plist-get (eglot--TextDocumentIdentifier) :uri) [])))

(ert-deftest kitty-lean-new-project-opens-its-library ()
  "Lake names the library itself: my-proj's is MyProj."
  (let ((dir (make-temp-file "kitty-new" t)))
    (make-directory (expand-file-name "MyProj" dir))
    (dolist (f '("Main.lean" "MyProj.lean" "MyProj/Basic.lean"))
      (kitty-lean-test--write dir f "\n"))
    (should (equal (kitty-lean--new-project-file dir) (expand-file-name "MyProj/Basic.lean" dir)))))

(ert-deftest kitty-lean-org-tab-is-only-indentation ()
  "TAB in a lean block of an org file (org edits the block in a hidden buffer
for it): no scratch file, no server."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (require 'org)
  (clrhash kitty-lean--starts)
  (let ((scratch (expand-file-name ".lake/kittymax-org/" (kitty-lean-test--project)))
        (org-src-tab-acts-natively t))
    (with-current-buffer (find-file-noselect (expand-file-name "t.org" (make-temp-file "kitty-org" t)))
      (switch-to-buffer (current-buffer))
      (insert (format "#+begin_src lean :project %s\ntheorem g : 1 = 1 := by\nskip\n#+end_src\n" (kitty-lean-test--project)))
      (goto-char (point-min)) (forward-line 2)
      (dotimes (_ 3) (org-indent-line))
      (should-not (and (file-directory-p scratch) (directory-files scratch nil "\\.lean\\'")))
      (should (zerop (hash-table-count kitty-lean--starts)))
      (set-buffer-modified-p nil) (kill-buffer))))

(ert-deftest kitty-lean-open-infoview-does-not-slow-lean ()
  "Lean sends diagnostics line by line as it checks; the infoview asks again
after a pause in them, not on each (each question waits for the check:
hundreds of them made Lean 40 times slower)."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--write (kitty-lean-test--project) "Many.lean"
                          (mapconcat (lambda (i) (format "theorem t%d (a b : Nat) : a + b = b + a := by\n  skip\n  omega\n#eval %d\n" i i))
                                     (number-sequence 1 100) ""))
  (let ((seen nil)
        (buf (kitty-lean-test--visit "Many.lean"))
        (t0 (float-time)))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (unless (kitty-lean--infoview-window) (kitty-lean-infoview-open))
    (goto-char (point-max)) (forward-line -2)
    (should (kitty-lean-test--wait 120 (lambda ()
                                         (when (kitty-lean-busy-p buf) (setq seen t))
                                         (and seen (>= (length (flymake-diagnostics)) 100)
                                              (not (kitty-lean-busy-p buf))))))
    (message "100 theorems, infoview open: checked in %.1fs" (- (float-time) t0))
    ;; 2 s here, gathered; 32 s with a refresh per report
    (should (< (- (float-time) t0) 15))
    (set-buffer-modified-p nil) (kill-buffer buf)))

(defvar nael-eglot-contact)

(ert-deftest kitty-lean-a-failed-start-is-not-waited-for ()
  "The project's server does not start (lake exits): the next file starts it
again instead of waiting for nothing.  test/kitty_lean_start.tla's Fix."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--wait 3 #'ignore)
  (clrhash kitty-lean--starts)
  ;; (a server that starts and exits is the same hand-over, from eglot's
  ;; shutdown handler; batch Emacs dies of the error eglot raises there)
  (let ((nael-eglot-contact '("kitty-lean-no-such-lake" "serve")))
    (kitty-lean-test--visit "Demo/Good.lean")
    (kitty-lean-test--wait 5 #'ignore)
    (should-not (eglot-managed-p)))
  ;; lake works again (the toolchain is there now)
  (should (with-current-buffer (kitty-lean-test--visit "Demo/Bad.lean")
            (kitty-lean-test--wait 30 (lambda () (eglot-managed-p))))))

(ert-deftest kitty-lean-a-file-opened-while-starting-is-served ()
  "Two files open while the server starts and the one starting it is closed
before it did: the other still gets the server.  test/kitty_lean_start.tla."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--wait 3 #'ignore)
  (clrhash kitty-lean--starts)
  (let* ((a (find-file-noselect (expand-file-name "Demo/Good.lean" (kitty-lean-test--project))))
         (b (kitty-lean-test--visit "Demo/Bad.lean")))
    ;; a never had a command (no post-command-hook): its start never ran
    (kill-buffer a)
    (should (kitty-lean-test--wait 30 (lambda () (with-current-buffer b (eglot-managed-p)))))))

(ert-deftest kitty-lean-restart-file-checks-again ()
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (>= (length (kitty-lean-test--errors buf)) 2))))
    (kitty-lean-restart-file)
    (should (kitty-lean-test--wait 120 (lambda () (>= (length (kitty-lean-test--errors buf)) 2))))))

(ert-deftest kitty-lean-lake-build-and-run ()
  "SPC m m: lake build, its errors as jumps; SPC m r: main's output."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--visit "Demo/Bad.lean")
  (let ((done nil))
    (let ((compilation-finish-functions (list (lambda (&rest _) (setq done t))))
          (compilation-ask-about-save nil))
      (kitty-lean-build "Demo")
      (should (kitty-lean-test--wait 180 (lambda () done))))
    (with-current-buffer "*compilation*"
      (goto-char (point-min))
      (let ((msg (compilation-next-error 1)))
        (should msg)
        (should (string-suffix-p "Demo/Bad.lean" (caar (compilation--loc->file-struct (compilation--message->loc msg)))))
        (should (= 1 (compilation--loc->line (compilation--message->loc msg)))))
      ;; RET lands where Lean points: column 15 (0-based), on "s"
      (compile-goto-error)
      (should (string-suffix-p "Demo/Bad.lean" buffer-file-name))
      (should (= 1 (line-number-at-pos)))
      (should (= 15 (current-column)))))
  (kitty-lean-test--visit "Main.lean")
  (let ((done nil))
    (let ((compilation-finish-functions (list (lambda (&rest _) (setq done t))))
          (compilation-ask-about-save nil))
      (kitty-lean-run-file)
      (should (kitty-lean-test--wait 120 (lambda () done))))
    (should (string-match-p "hello from lean"
                            (with-current-buffer (seq-find (lambda (b) (string-match-p "compilation" (buffer-name b))) (buffer-list))
                              (buffer-string))))))

(ert-deftest kitty-lean-org-babel ()
  "A lean block in org: #eval and #check come back; :project brings the project's modules."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (require 'org)
  (require 'ob-core)
  (let ((org-file (expand-file-name "notes.org" (make-temp-file "kitty-org" t))))
    (with-current-buffer (find-file-noselect org-file)
      (insert "#+begin_src lean\n#eval 1 + 1\n#check Nat.add_comm\n#+end_src\n\n"
              (format "#+begin_src lean :project %s\nimport Demo.Good\n#eval good\n#+end_src\n" (kitty-lean-test--project)))
      (goto-char (point-min))
      (should (equal (org-babel-execute-src-block nil nil '((:results . "output silent")))
                     "2\nNat.add_comm (n m : Nat) : n + m = m + n"))
      (re-search-forward "import Demo.Good")
      (should (equal (org-babel-execute-src-block nil nil '((:results . "output silent"))) "42"))
      ;; the scratch files are gone again
      (should-not (directory-files (expand-file-name ".lake/kittymax-org" (kitty-lean-test--project)) nil "\\.lean\\'"))
      (set-buffer-modified-p nil)
      (kill-buffer))))

(ert-deftest kitty-lean-org-edit-has-the-server ()
  "C-c ' on a lean block: nael, the server, goals in the infoview; back without questions."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (require 'org)
  (let ((org-file (expand-file-name "notes.org" (make-temp-file "kitty-org" t)))
        (project-server (with-current-buffer (kitty-lean-test--visit "Demo/Good.lean")
                          (and (kitty-lean-test--wait 60 (lambda () (eglot-managed-p)))
                               (eglot-current-server)))))
    (should project-server)
    (with-current-buffer (find-file-noselect org-file)
      (switch-to-buffer (current-buffer))
      (insert (format "* Proof\n#+begin_src lean :project %s\nimport Demo.Good\ntheorem g : good = 42 := by\n  skip\n#+end_src\n"
                      (kitty-lean-test--project)))
      (goto-char (point-min))
      (re-search-forward "  skip")
      (org-edit-special)
      (run-hooks 'post-command-hook)
      (let ((edit (current-buffer)))
        (should (eq major-mode 'nael-mode))
        (should (string-prefix-p (expand-file-name ".lake/kittymax-org/" (kitty-lean-test--project)) buffer-file-name))
        (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
        (should (equal (file-truename (project-root (eglot--project (eglot-current-server))))
                       (kitty-lean-test--project)))
        ;; the project's server, not a second one, when it is running already
        (when project-server (should (eq project-server (eglot-current-server))))
        (should (kitty-lean-test--wait 120 (lambda () (kitty-lean-test--errors edit))))
        (goto-char (point-min)) (forward-line 2) (back-to-indentation)
        (unless (kitty-lean--infoview-window) (kitty-lean-infoview-open))
        (kitty-lean-infoview-refresh edit t)
        (should (kitty-lean-test--infoview-shows 30 "⊢ good = 42"))
        (let ((file buffer-file-name)
              (server (eglot-current-server)))
          (goto-char (point-max))
          (insert "-- edited")
          ;; no question, the block takes the edit, the scratch file goes
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "asked")))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "asked"))))
            (org-edit-src-exit))
          (should-not (buffer-live-p edit))
          (should-not (file-exists-p file))
          (should (string-match-p "-- edited" (buffer-string)))
          ;; Good.lean still has the server
          (should (jsonrpc-running-p server))
          ;; with nothing else open, the block's server stops after C-c '
          (dolist (b (buffer-list))
            (when (and (buffer-live-p b) (with-current-buffer b (derived-mode-p 'nael-mode)))
              (kill-buffer b)))
          (goto-char (point-min)) (re-search-forward "  skip")
          (org-edit-special)
          (run-hooks 'post-command-hook)
          (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
          (let ((alone (eglot-current-server)))
            (should-not (eq alone server))
            (org-edit-src-exit)
            (should (kitty-lean-test--wait 10 (lambda () (not (jsonrpc-running-p alone)))))))
        (set-buffer-modified-p nil)
        (kill-buffer)))))

(ert-deftest kitty-lean-org-blocks-take-abbreviations ()
  "\\to in a lean block of an org file is →; in the prose it stays LaTeX."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (with-current-buffer (find-file-noselect (expand-file-name "n.org" (make-temp-file "kitty-org" t)))
    (switch-to-buffer (current-buffer))
    (insert "#+begin_src lean\n\n#+end_src\n")
    (goto-char (point-min)) (forward-line 1)
    (evil-insert-state)
    (execute-kbd-macro (kbd "a SPC \\ t o SPC b"))
    (evil-normal-state)
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "a → b"))
    (goto-char (point-max))
    (evil-insert-state)
    (execute-kbd-macro (kbd "f SPC \\ t o SPC g"))
    (evil-normal-state)
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "f \\to g"))
    (set-buffer-modified-p nil)
    (kill-buffer)))

(provide 'kitty-lean-test)
;;; kitty-lean-test.el ends here

;;;; The second review (Fable 5.2)

(defvar eglot-sync-connect)
(defvar eglot-connect-timeout)

(ert-deftest kitty-lean-a-file-opened-out-of-sight-strands-nobody ()
  "`kittymax A.lean B.lean': A is opened without being shown, B is where you
work.  B gets the server, A with it, and it is the project's only one.
test/kitty_lean_start.tla, with the selected buffer."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--wait 3 #'ignore)
  (clrhash kitty-lean--starts)
  (let* ((a (find-file-noselect (expand-file-name "Demo/Good.lean" (kitty-lean-test--project))))
         (b (kitty-lean-test--visit "Demo/Bad.lean")))
    (should (kitty-lean-test--wait 30 (lambda () (with-current-buffer b (eglot-managed-p)))))
    (should (with-current-buffer a (eglot-managed-p)))
    ;; A's own eglot-ensure, after a command there, finds the server
    (with-current-buffer a (run-hooks 'post-command-hook))
    (should (= 1 (length (gethash (with-current-buffer b (eglot--project (eglot-current-server)))
                                  eglot--servers-by-project))))))

(ert-deftest kitty-lean-two-files-at-once-get-one-server ()
  "Both files have their command before the server answers: one launch."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--wait 3 #'ignore)
  (clrhash kitty-lean--starts)
  (let ((launches 0)
        (eglot-sync-connect nil))        ; the connect returns before Lean answers
    (advice-add 'jsonrpc-async-request :before
                (lambda (_c m &rest _) (when (eq m :initialize) (cl-incf launches)))
                '((name . kitty-lean-test-launches)))
    (unwind-protect
        (let ((a (kitty-lean-test--visit "Demo/Good.lean"))
              (b (kitty-lean-test--visit "Demo/Bad.lean")))
          (should (kitty-lean-test--wait 30 (lambda () (and (with-current-buffer a (eglot-managed-p))
                                                            (with-current-buffer b (eglot-managed-p))))))
          (should (= launches 1)))
      (advice-remove 'jsonrpc-async-request 'kitty-lean-test-launches))))

(ert-deftest kitty-lean-a-slow-start-is-waited-for-and-shown ()
  "elan fetching a toolchain takes minutes; eglot gives up after
eglot-connect-timeout (30 s; 2 s here).  Lean is waited for, and the mode
line says what lake prints meanwhile."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--wait 3 #'ignore)
  (clrhash kitty-lean--starts)
  (let ((eglot-connect-timeout 2)
        (eglot-sync-connect nil)
        (seen nil)
        (nael-eglot-contact '("sh" "-c" "echo 'info: downloading toolchain' >&2; sleep 5; exec lake serve")))
    (let ((b (kitty-lean-test--visit "Demo/Bad.lean")))
      (should (kitty-lean-test--wait 30 (lambda ()
                                          (when (string-match-p "Lean starting: info: downloading toolchain"
                                                                (kitty-lean-test--misc-info b))
                                            (setq seen t))
                                          (with-current-buffer b (eglot-managed-p)))))
      (should seen)
      (should-not (string-match-p "Lean starting" (kitty-lean-test--misc-info b))))))

(ert-deftest kitty-lean-no-lake-says-so ()
  "Without lake (no elan yet): one message, and the commands say why they can't."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--project)
  (let ((exec-path '("/nonexistent"))
        (kitty-lean--told-no-lake nil)
        (shown nil))
    (cl-letf* ((orig (symbol-function 'message))
               ((symbol-function 'message)
                (lambda (fmt &rest args) (when fmt (push (apply #'format fmt args) shown)) (apply orig fmt args))))
      (let ((b (kitty-lean-test--visit "Demo/Good.lean")))
        (should (seq-find (lambda (m) (string-match-p "lake.? is not on PATH" m)) shown))
        (should-not (buffer-local-value 'eglot--managed-mode b))
        (dolist (cmd '(kitty-lean-restart-file kitty-lean-restart-server kitty-lean-sorry-fill kitty-lean-accept-suggestion))
          (should (string-match-p "lake.? is not on PATH"
                                  (condition-case e (progn (funcall cmd) "no error")
                                    (user-error (cadr e)) (error (format "%S" e))))))))))

(ert-deftest kitty-lean-narrowed-buffers-show-the-right-line ()
  "Narrowed: the header and the messages are those of the line in the file."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)))
    (unwind-protect
        (progn
          (goto-char (point-min)) (forward-line 2)
          (narrow-to-region (point) (point-max))
          (forward-line 1) (back-to-indentation)
          (with-current-buffer kitty-lean-infoview-buffer-name (let ((inhibit-read-only t)) (erase-buffer)))
          (kitty-lean-infoview-refresh buf t)
          (should (kitty-lean-test--infoview-shows 30 "Bad.lean:4:2"))
          (should (kitty-lean-test--infoview-shows 30 "3:41 error\nunsolved goals")))
      (with-current-buffer buf (widen)))))

(ert-deftest kitty-lean-wide-characters-are-where-lean-says ()
  "Lean counts columns in UTF-16, where 𝕜 is two: the infoview's columns
and jumps are the buffer's."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--write (kitty-lean-test--project) "Wide.lean"
                          "def 𝔸𝔹 : Nat := 1\ntheorem 𝕜𝕜 (a b : Nat) : a + b = b + a := by skip\n")
  (let ((buf (kitty-lean-test--visit "Wide.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (kitty-lean-test--errors buf))))
    (should (kitty-lean-test--wait 60 (lambda () (not (kitty-lean-busy-p buf)))))
    (unless (kitty-lean--infoview-window) (kitty-lean-infoview-open))
    (let ((err (flymake-diagnostic-beg (car (kitty-lean-test--errors buf)))))
      (goto-char err)
      (kitty-lean-infoview-refresh buf t)
      (should (kitty-lean-test--infoview-shows 30 (format "2:%d error" (save-excursion (goto-char err) (current-column)))))
      (goto-char (point-min))
      (with-current-buffer kitty-lean-infoview-buffer-name
        (goto-char (point-min)) (search-forward " error") (backward-char 2)
        (kitty-lean-infoview-goto))
      (should (eq (window-buffer (selected-window)) buf))
      (should (= (window-point) err)))
    (set-buffer-modified-p nil)))

(ert-deftest kitty-lean-closing-the-file-clears-the-infoview ()
  "The infoview's file is closed: it says so, and K and RET say why they can't."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--bad-with-goal)))
    (with-current-buffer buf (set-buffer-modified-p nil))
    (kill-buffer buf)
    (should (string-match-p "\\`No Lean file" (kitty-lean-test--infoview-text)))
    (kitty-lean-test--wait 2 #'ignore)
    (should (string-match-p "\\`No Lean file" (kitty-lean-test--infoview-text)))
    (with-current-buffer kitty-lean-infoview-buffer-name
      (goto-char (point-min))
      (should-error (kitty-lean-infoview-hover) :type 'user-error)
      (should-error (kitty-lean-infoview-goto) :type 'user-error))))

(ert-deftest kitty-lean-opening-a-file-builds-nothing ()
  "As VS Code: opening a file does not build its imports (one file of a
Mathlib project without the cache would build Mathlib); Lean says so,
and \\r builds them."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (let* ((root (kitty-lean-test--project))
         (olean (expand-file-name ".lake/build/lib/lean/Demo/Dep.olean" root)))
    (kitty-lean-test--write root "Demo/Dep.lean" "def dep : Nat := 7\n")
    (kitty-lean-test--write root "UseDep.lean" "import Demo.Dep\n#eval dep\n")
    (when (file-exists-p olean) (delete-file olean))
    (let ((buf (kitty-lean-test--visit "UseDep.lean")))
      (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
      (should (kitty-lean-test--wait 60 (lambda () (kitty-lean-test--errors buf))))
      (should (string-match-p "Restart File\\|rebuilt\\|not built\\|out of date"
                              (flymake-diagnostic-text (car (kitty-lean-test--errors buf)))))
      (should-not (file-exists-p olean))
      (kitty-lean-restart-file)
      (should (kitty-lean-test--wait 120 (lambda () (file-exists-p olean))))
      (should (kitty-lean-test--wait 60 (lambda () (and (not (kitty-lean-test--errors buf))
                                                        (seq-find (lambda (d) (string-match-p "7" (flymake-diagnostic-text d)))
                                                                  (flymake-diagnostics)))))))))

(ert-deftest kitty-lean-build-gets-the-mathlib-cache-first ()
  (let ((dir (make-temp-file "kitty-mathlib" t)))
    (should-not (kitty-lean--uses-mathlib-p dir))
    (kitty-lean-test--write dir "lakefile.toml" "name = \"m\"\n\n[[require]]\nname = \"mathlib\"\nscope = \"leanprover-community\"\n")
    (should (kitty-lean--uses-mathlib-p dir))
    (let (command)
      (cl-letf (((symbol-function 'compile) (lambda (c &rest _) (setq command c)))
                ((symbol-function 'kitty-lean--project-or-lose) (lambda () dir)))
        (kitty-lean-build))
      (should (equal command "lake exe cache get && lake build")))))

(ert-deftest kitty-lean-unfinished-abbreviations ()
  "As VS Code: an abbreviation ended before it is complete becomes the
symbol of the shortest one it starts; \\\\ is \; VS Code's \\h<>."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Demo/Bad.lean")))
    (goto-char (point-max))
    (dolist (c '(("o \\ a l p SPC x" "α x")
                 ("o ( \\ a l p )" "(α)")
                 ("o \\ a l p TAB" "α")
                 ("o a \\ \\ n" "a\\n")
                 ("o \\ : t" "⦂")))
      (execute-kbd-macro (kbd (concat (car c) " <escape>")))
      (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) (cadr c))))
    (execute-kbd-macro (kbd "o \\ h < > x <escape>"))
    (should (equal (buffer-substring-no-properties (line-beginning-position) (line-end-position)) "❰x❱"))
    (with-current-buffer buf (set-buffer-modified-p nil) (revert-buffer t t))))

(ert-deftest kitty-lean-pins-follow-you-to-other-files ()
  "A pin stays in the infoview in another file; RET on it goes there, u unpins it."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((bad (kitty-lean-test--bad-with-goal)))
    (setq kitty-lean--pins nil)
    (kitty-lean-infoview-pin)
    (let ((pinned (point))
          (good (kitty-lean-test--visit "Demo/Good.lean")))
      (should (kitty-lean-test--wait 30 (lambda () (eglot-managed-p))))
      (kitty-lean-infoview-refresh good t)
      (should (kitty-lean-test--infoview-shows 30 "Pinned at Bad.lean:4:2\n\\(.\\|\n\\)*⊢ a \\+ b = b \\+ a"))
      (with-current-buffer kitty-lean-infoview-buffer-name
        (goto-char (point-min)) (search-forward "Pinned at")
        (kitty-lean-infoview-goto))
      (should (eq (window-buffer (selected-window)) bad))
      (should (= (window-point) pinned))
      (switch-to-buffer good)
      (with-current-buffer kitty-lean-infoview-buffer-name
        (goto-char (point-min)) (search-forward "Pinned at")
        (kitty-lean-infoview-unpin))
      (should-not kitty-lean--pins)
      (should (kitty-lean-test--wait 30 (lambda () (not (string-match-p "Pinned" (kitty-lean-test--infoview-text)))))))))
