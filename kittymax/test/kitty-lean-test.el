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
(require 'kitty-lean-widgets)

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
         (released nil)
         (rendered nil)
         (buf (generate-new-buffer "x.lean")))
    (cl-letf (((symbol-function 'kitty-lean--infoview-window) (lambda () t))
              ((symbol-function 'eglot-managed-p) (lambda () t))
              ((symbol-function 'kitty-lean--refresh-target) (lambda (b) (with-current-buffer b (point))))
              ((symbol-function 'kitty-lean--ask-goals) (lambda (_b pos cb) (push (list :goals pos cb) calls)))
              ((symbol-function 'kitty-lean--ask-term) (lambda (_b pos cb) (push (list :term pos cb) calls)))
              ((symbol-function 'kitty-lean--ask-messages) (lambda (_b pos cb) (push (list :messages pos cb) calls)))
              ((symbol-function 'kitty-lean--ask-widgets) (lambda (_b pos cb) (push (list :widgets pos cb) calls)))
              ((symbol-function 'kitty-lean--release) (lambda (_b _s refs) (setq released (append refs released))))
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
        (should (= 8 (length calls)))
        (cl-flet ((answer (pos &optional fail)
                    (dolist (c calls)
                      (when (= (nth 1 c) pos)
                        (funcall (nth 2 c) (if fail (cons nil nil)
                                             (cons t (list (list :type (list :tag (vector (list :info (list :p (format "%d" pos))) '(:text "x"))))))))))))
          ;; the newer request is answered first, the older one after it
          (answer 20)
          (answer 5))
        (should (equal (mapcar #'car rendered) '(20)))
        ;; the older refresh is not shown: what its answers hold is released
        ;; (four answers, each with the reference (:p "5"))
        (should (equal released (make-list 4 '(:p "5"))))
        ;; forced (Lean finished the file): asked again; this time it fails
        (setq calls nil)
        (kitty-lean-infoview-refresh buf t)
        (should (= 4 (length calls)))
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

(defconst kitty-lean-test--widget-source
  "import Lean
open Lean Widget

-- ProofWidgets' HtmlDisplay, as far as the infoview can tell: its id and props
namespace ProofWidgets
@[widget_module] def HtmlDisplay : Widget.Module where javascript := \"export default function(p) { return null }\"
end ProofWidgets

#widget ProofWidgets.HtmlDisplay with (json% {html: {element: [\"div\", [], [
  {element: [\"h3\", [], [{text: \"A heading\"}]]},
  {element: [\"p\", [], [{text: \"some   \"}, {element: [\"b\", [], [{text: \"bold\"}]]}, {text: \" text\"}]]},
  {element: [\"ul\", [], [{element: [\"li\", [], [{text: \"one\"}]]}, {element: [\"li\", [], [{text: \"two\"}]]}]]},
  {element: [\"details\", [], [{element: [\"summary\", [], [{text: \"More\"}]]}, {text: \"hidden body\"}]]}]]}})

@[widget_module] def Unknown : Widget.Module where javascript := \"export default function(p) { return null }\"
#widget Unknown
"
  "A Lean file with panel widgets: one kittymax draws, one it cannot.")

(defconst kitty-lean-test--fold-source
  "/-- A doc
  comment -/
theorem foo (n : Nat) :
    n + 0 = n := by
  induction n with
  | zero => rfl
  | succ n ih =>
    simp

namespace A
def bar : Nat :=
  let x := 1
  x + 1
end A
"
  "A Lean file with folding ranges: a doc comment, a theorem, a namespace and a def in it.")

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
        (kitty-lean-test--write dir "Marks.lean"
                                "theorem ok (a b : Nat) : a + b = b + a := by\n  omega\n\ntheorem bad (a b : Nat) : a + b = b + a := by\n  skip\n")
        (kitty-lean-test--write dir "Trace.lean"
                                "set_option trace.Meta.synthInstance true in\nexample : Inhabited Nat := inferInstance\n")
        (kitty-lean-test--write dir "Widget.lean" kitty-lean-test--widget-source)
        (kitty-lean-test--write dir "Fold.lean" kitty-lean-test--fold-source)
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

(ert-deftest kitty-lean-booster-leaves-json-to-emacs ()
  "With emacs-lsp-booster in front of the servers (package.nix puts it on PATH),
it only buffers: its bytecode mode turns Lean's ⊢ into raw bytes and leaves
the webview no JSON to pass on.  In kittymax's own Emacs (run.sh) eglot-booster
is there, and the goal tests go through the booster too."
  (unless (and (executable-find "emacs-lsp-booster") (locate-library "eglot-booster"))
    (signal 'ert-test-skipped '("no emacs-lsp-booster or eglot-booster")))
  (kitty-lean-test--boot)
  (require 'eglot)
  (should (bound-and-true-p eglot-booster-mode))
  (should (bound-and-true-p eglot-booster-io-only)))

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
  ;; shutdown handler; batch Emacs dies of the error eglot raises there.
  ;; emacs-lsp-booster in front makes a missing lake one of those: the
  ;; booster starts, then exits, so it stays out of this test)
  (let ((nael-eglot-contact '("kitty-lean-no-such-lake" "serve"))
        (boosted (bound-and-true-p eglot-booster-mode)))
    (when boosted (eglot-booster-mode -1))
    (unwind-protect
        (progn
          (kitty-lean-test--visit "Demo/Good.lean")
          (kitty-lean-test--wait 5 #'ignore)
          (should-not (eglot-managed-p)))
      (when boosted (eglot-booster-mode 1))))
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

;;;; Rendering: widgets, folds, proof marks (VS Code's infoview, as text)

(ert-deftest kitty-lean-tells-lean-what-it-can-show ()
  "Lean gets `hasWidgets' (else every message comes flattened) and silent
diagnostics support (the ✓ marks), as from VS Code; other servers nothing."
  (cl-letf (((symbol-function 'eglot--major-modes) (lambda (s) (if (eq s 'lean) '(nael-mode) '(c-mode)))))
    (should (equal (kitty-lean--initialization-options nil 'lean) '(:hasWidgets t)))
    (should (equal (kitty-lean--initialization-options '(:a 1) 'lean) '(:a 1 :hasWidgets t)))
    (should (equal (kitty-lean--initialization-options '(:a 1) 'c) '(:a 1)))
    (should (equal (plist-get (kitty-lean--client-capabilities '(:workspace nil) 'lean) :lean)
                   '(:silentDiagnosticSupport t :incrementalDiagnosticSupport t)))
    (should-not (plist-member (kitty-lean--client-capabilities '(:workspace nil) 'c) :lean))))

(ert-deftest kitty-lean-silent-diagnostics-become-marks ()
  (pcase-let ((`(,kept ,done ,unsolved)
               (kitty-lean--split-diagnostics
                (vector (list :range '(:start (:line 0 :character 0) :end (:line 1 :character 0))
                              :isSilent t :leanTags [2] :severity 3 :message "Goals accomplished!")
                        (list :range '(:start (:line 3 :character 43) :end (:line 4 :character 0))
                              :fullRange '(:start (:line 3 :character 43) :end (:line 4 :character 6))
                              :leanTags [1] :severity 1 :message "unsolved goals")
                        (list :range '(:start (:line 6 :character 0) :end (:line 6 :character 3))
                              :severity 2 :message "a warning")))))
    (should (equal (mapcar (lambda (d) (plist-get d :message)) kept) '("unsolved goals" "a warning")))
    (should (equal done '(0)))
    (should (equal unsolved '(4)))))

(ert-deftest kitty-lean-proof-marks ()
  "✓ beside a finished proof, 🛠 after one with goals left; \"Goals
accomplished!\" is no flymake note and no infoview message."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Marks.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 60 (lambda () (and (kitty-lean-test--errors buf) (not (kitty-lean-busy-p buf))))))
    (should (kitty-lean-test--wait 10 (lambda () (= 2 (length kitty-lean--mark-overlays)))))
    (let ((marks (mapcar (lambda (o) (list (line-number-at-pos (overlay-start o)) (overlay-get o 'kitty-lean-mark)
                                           (substring-no-properties (overlay-get o 'before-string))))
                         kitty-lean--mark-overlays)))
      ;; a terminal (batch Emacs is one): at the end of the line
      (should (member '(1 done " ✓") marks))
      (should (member '(5 unsolved " 🛠") marks)))
    (should-not (seq-find (lambda (d) (string-match-p "Goals accomplished" (flymake-diagnostic-text d)))
                          (flymake-diagnostics)))
    (kitty-lean-infoview-open)
    (goto-char (point-min)) (forward-line 1) (end-of-line)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 30 "No goals"))
    (should-not (string-match-p "Goals accomplished" (kitty-lean-test--infoview-text)))
    ;; in a graphical Emacs: the right fringe
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t)))
      (kitty-lean--draw-marks))
    (should (seq-find (lambda (o) (equal (get-text-property 0 'display (overlay-get o 'before-string))
                                         '(right-fringe kitty-lean-done kitty-lean-done)))
                      kitty-lean--mark-overlays))
    ;; off
    (let ((kitty-lean-proof-marks nil)) (kitty-lean--draw-marks))
    (should-not kitty-lean--mark-overlays)
    (kitty-lean--draw-marks)))

(defun kitty-lean-test--visible ()
  "The infoview's text as it is seen: without what folds hide."
  (with-current-buffer kitty-lean-infoview-buffer-name
    (let ((out nil) (pos (point-min)))
      (while (< pos (point-max))
        (let ((next (next-single-char-property-change pos 'invisible nil (point-max))))
          (unless (invisible-p pos) (push (buffer-substring-no-properties pos next) out))
          (setq pos next)))
      (apply #'concat (nreverse out)))))

(defun kitty-lean-test--iv-goto (regexp)
  (with-current-buffer kitty-lean-infoview-buffer-name
    (goto-char (point-min))
    (should (re-search-forward regexp nil t))
    (goto-char (match-beginning 0))))

(ert-deftest kitty-lean-messages-are-interactive ()
  "Lean's messages with their terms (K, gd), as VS Code gets them."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Marks.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 60 (lambda () (and (kitty-lean-test--errors buf) (not (kitty-lean-busy-p buf))))))
    (kitty-lean-infoview-open)
    (goto-char (point-min)) (forward-line 4)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 30 "unsolved goals\na b : Nat"))
    ;; the goal inside the message: its terms carry Lean's info
    (kitty-lean-test--iv-goto "unsolved goals")
    (with-current-buffer kitty-lean-infoview-buffer-name
      (should (re-search-forward "⊢ a" nil t))
      (backward-char)
      (should (get-text-property (point) 'kitty-lean-info)))))

(ert-deftest kitty-lean-traces-unfold-as-asked ()
  "A trace is a fold; its children are asked from Lean when it is opened, and
it stays open across refreshes; sections fold with TAB."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (clrhash kitty-lean--folds)
  (let ((buf (kitty-lean-test--visit "Trace.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 60 (lambda () (and (flymake-diagnostics) (not (kitty-lean-busy-p buf))))))
    (kitty-lean-infoview-open)
    (goto-char (point-min)) (forward-line 1)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 30 "▸ \\[Meta.synthInstance\\] ✅️ Inhabited Nat"))
    ;; collapsed, as Lean says: nothing asked yet
    (should-not (string-match-p "new goal" (kitty-lean-test--infoview-text)))
    (kitty-lean-test--iv-goto "\\[Meta.synthInstance\\]")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-toggle-fold))
    (should (kitty-lean-test--wait 30 (lambda () (string-match-p "new goal Inhabited Nat" (kitty-lean-test--visible)))))
    ;; a child under its parent: its class shortened, folded as Lean says
    (should (string-match-p "▾ \\[Meta.synthInstance\\] ✅️ Inhabited Nat\n  ▸ \\[Meta.synthInstance\\] ✅️ new goal Inhabited Nat\n  ▸ \\[apply\\] ✅️ apply instInhabitedNat"
                            (kitty-lean-test--visible)))
    ;; the children's terms are interactive too
    (kitty-lean-test--iv-goto "new goal Inhabited")
    (with-current-buffer kitty-lean-infoview-buffer-name
      (search-forward "Inhabited") (backward-char 2)
      (should (get-text-property (point) 'kitty-lean-info)))
    ;; open a grandchild, refresh: still open, its children asked again
    (kitty-lean-test--iv-goto "new goal")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-toggle-fold))
    (should (kitty-lean-test--wait 30 (lambda () (string-match-p "\\[instances\\] #\\[" (kitty-lean-test--visible)))))
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--wait 30 (lambda () (string-match-p "\\[instances\\] #\\[" (kitty-lean-test--visible)))))
    ;; TAB on a section title folds it away, and it stays so
    (kitty-lean-test--iv-goto "Messages (1)")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-toggle-fold))
    (should (string-match-p "▸ Messages (1)" (kitty-lean-test--visible)))
    (should-not (string-match-p "synthInstance" (kitty-lean-test--visible)))
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--wait 30 (lambda () (string-match-p "▸ Messages (1)" (kitty-lean-test--infoview-text)))))
    (should-not (string-match-p "synthInstance" (kitty-lean-test--visible)))
    ;; All messages: folded, opened on request
    (kitty-lean-test--iv-goto "All messages")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-toggle-fold))
    (should (string-match-p "▾ All messages: 0 errors, 0 warnings, 1 info.*\n2:27 info (trace: unfold it in the infoview" (kitty-lean-test--visible)))
    (clrhash kitty-lean--folds)))

(ert-deftest kitty-lean-a-late-trace-answer-is-dropped-and-released ()
  "Children answered after the infoview moved on are not put in, and Lean is
told it can forget them (test/kitty_lean_folds.tla)."
  (let ((iv (get-buffer-create kitty-lean-infoview-buffer-name))
        (src (generate-new-buffer "x.lean"))
        callback released)
    (cl-letf (((symbol-function 'kitty-lean--rpc-call)
               (lambda (_b _p _m _params cb) (setq callback cb)))
              ((symbol-function 'kitty-lean--release)
               (lambda (_b _s refs) (setq released refs))))
      (let ((kitty-lean--rendered src) (kitty-lean--shown-refs (list src "s" nil)) ov)
        (with-current-buffer iv
          (let ((inhibit-read-only t) (kitty-lean--pending-fills nil))
            (erase-buffer) (delete-all-overlays)
            (setq ov (kitty-lean--fold '(t) nil (lambda () (insert "[c] title"))
                                       nil (lambda (o) (kitty-lean--trace-fetch o '(:p "9") "c"))))
            (kitty-lean--fold-set ov t)
            (should (string-match-p "…" (buffer-string)))
            ;; the cursor moved: a new render
            (cl-incf kitty-lean--render-id)
            (funcall callback (cons t (vector '(:tag [(:trace (:cls "c" :indent 2 :msg (:tag [(:info (:p "10")) (:text "child")])
                                                                :collapsed :json-false :children (:strict [])))
                                                     (:text "")]))))
            (should-not (string-match-p "child" (buffer-string)))
            (should (equal released '((:p "10"))))))))
    (kill-buffer src)))

(defun kitty-lean-test--wait-button (buf label)
  "Wait for the button LABEL in the infoview of BUF.  The first render can
have flymake's plain copy of a message, when Lean's interactive one is not
ready yet: so ask again until it is there."
  (kitty-lean-test--wait
   30 (lambda ()
        (or (with-current-buffer kitty-lean-infoview-buffer-name
              (goto-char (point-min))
              (and (search-forward label nil t) (get-text-property (1- (point)) 'kitty-lean-action)))
            (progn (kitty-lean-infoview-refresh buf t) (kitty-lean-test--wait 1 #'ignore) nil)))))

(ert-deftest kitty-lean-try-this-applies-only-to-its-text ()
  "Try this's [apply] in the infoview puts the suggestion in; after an edit
it refuses (Lean's range is for the old text) and asks again."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--write (kitty-lean-test--project) "Try2.lean"
                          "example (a b : Nat) : a + b = b + a := by\n  exact?\n")
  (let ((buf (kitty-lean-test--visit "Try2.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (kitty-lean-infoview-open)
    (should (kitty-lean-test--wait 120 (lambda () (and (flymake-diagnostics) (not (kitty-lean-busy-p buf))))))
    (goto-char (point-min)) (forward-line 1) (back-to-indentation)
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 60 "Try this:\n  \\[apply\\] exact Nat.add_comm a b"))
    (should (kitty-lean-test--wait-button buf "[apply]"))
    ;; typed something since (and the infoview not asked again yet): refused
    (kitty-lean-test--iv-goto "\\[apply\\]")
    (with-current-buffer buf (goto-char (point-max)) (insert " "))
    (with-current-buffer kitty-lean-infoview-buffer-name
      (should (string-match-p "changed since"
                              (cadr (should-error (kitty-lean-infoview-goto) :type 'user-error)))))
    (should (equal (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))
                   "example (a b : Nat) : a + b = b + a := by\n  exact?\n "))
    (with-current-buffer buf (delete-char -1) (kitty-lean-test--sync)
                         (goto-char (point-min)) (forward-line 1) (back-to-indentation))
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--wait 30 (lambda () (eql kitty-lean--rendered-tick (buffer-chars-modified-tick buf)))))
    (should (kitty-lean-test--wait-button buf "[apply]"))
    (kitty-lean-test--iv-goto "\\[apply\\]")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-goto))
    (should (equal (with-current-buffer buf (buffer-substring-no-properties (point-min) (point-max)))
                   "example (a b : Nat) : a + b = b + a := by\n  exact Nat.add_comm a b\n"))
    (with-current-buffer buf (set-buffer-modified-p nil))))

(ert-deftest kitty-lean-panel-widgets ()
  "A ProofWidgets HtmlDisplay at the cursor is drawn as text; a widget made
of JavaScript only says so."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (clrhash kitty-lean--folds)
  (let ((buf (kitty-lean-test--visit "Widget.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 120 (lambda () (not (kitty-lean-busy-p buf)))))
    (kitty-lean-infoview-open)
    (goto-char (point-min)) (re-search-forward "^#widget ProofWidgets")
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 60 "▾ Widgets\nA heading\nsome bold text\n• one\n• two\n▸ More"))
    (should-not (string-match-p "hidden body" (kitty-lean-test--visible)))
    (with-current-buffer kitty-lean-infoview-buffer-name
      (goto-char (point-min)) (search-forward "bold")
      (should (memq 'bold (ensure-list (get-text-property (1- (point)) 'face)))))
    (kitty-lean-test--iv-goto "More")
    (with-current-buffer kitty-lean-infoview-buffer-name (kitty-lean-infoview-toggle-fold))
    (should (string-match-p "▾ More\nhidden body" (kitty-lean-test--visible)))
    (goto-char (point-min)) (re-search-forward "^#widget Unknown")
    (kitty-lean-infoview-refresh buf t)
    (should (kitty-lean-test--infoview-shows 60 "Unknown  (drawn by JavaScript"))
    (clrhash kitty-lean--folds)))

(ert-deftest kitty-lean-widget-html-as-text ()
  "ProofWidgets' HTML: tables aligned, colours, links, <svg> as XML for an image."
  (with-temp-buffer
    (kitty-lean-widgets--html
     '(:element ["table" [] [(:element ["thead" [] [(:element ["tr" [] [(:element ["th" [] [(:text "n")]])
                                                                       (:element ["th" [] [(:text "square")]])]])]])
                            (:element ["tbody" [] [(:element ["tr" [] [(:element ["td" [] [(:text "10")]])
                                                                       (:element ["td" [] [(:text "100")]])]])]])]]))
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "n  │ square\n───┼───────\n10 │ 100\n")))
  (with-temp-buffer
    (kitty-lean-widgets--html '(:element ["span" [["style" "color: red; font-weight: bold"]] [(:text "x")]]))
    (should (equal (get-text-property 1 'face) '(:foreground "red" :weight bold))))
  ;; React's style objects: fontWeight is font-weight
  (with-temp-buffer
    (kitty-lean-widgets--html '(:element ["span" [["style" (:color "red" :fontWeight "bold")]] [(:text "x")]]))
    (should (equal (get-text-property 1 'face) '(:foreground "red" :weight bold))))
  (with-temp-buffer
    (kitty-lean-widgets--html '(:element ["a" [["href" "https://lean-lang.org"]] [(:text "Lean")]]))
    (should (get-text-property 1 'kitty-lean-action))
    (kitty-lean-widgets--html '(:element ["a" [["href" "javascript:alert(1)"]] [(:text "no")]]))
    (should-not (get-text-property 5 'kitty-lean-action)))
  (should (equal (kitty-lean-widgets--xml '(:element ["svg" [["width" 10]] [(:element ["circle" [["r" 4]] []])]]))
                 "<svg width=\"10\" xmlns=\"http://www.w3.org/2000/svg\"><circle r=\"4\"></circle></svg>"))
  ;; an unknown widget in a message: the message's own text for it
  (should-not (with-temp-buffer (kitty-lean-widgets-insert '(:id "Some.Js.Widget" :props nil) t))))

(ert-deftest kitty-lean-goal-view-options ()
  "Hide let values, target first (reverseTacticState), only the first goal open."
  (let ((g1 '(:userName "h" :hyps [(:names ["x"] :type (:text "Nat") :val (:text "5"))
                                   (:names ["y"] :type (:text "Nat"))]
                        :type (:text "x = y")))
        (g2 '(:hyps [] :type (:text "True"))))
    (cl-flet ((show (&rest goals)
                (with-temp-buffer
                  (let ((kitty-lean--fold-path nil) (kitty-lean--pending-fills nil))
                    (kitty-lean--insert-goals goals 'test))
                  (let (out (pos (point-min)))
                    (while (< pos (point-max))
                      (let ((next (next-single-char-property-change pos 'invisible nil (point-max))))
                        (unless (invisible-p pos) (push (buffer-substring-no-properties pos next) out))
                        (setq pos next)))
                    (apply #'concat (nreverse out))))))
      (clrhash kitty-lean--folds)
      (should (equal (show g1) "case h\nx : Nat := 5\ny : Nat\n⊢ x = y\n\n"))
      (let ((kitty-lean-infoview-hide-let-values t))
        (should (equal (show g1) "case h\nx : Nat\ny : Nat\n⊢ x = y\n\n")))
      (let ((kitty-lean-infoview-reverse t))
        (should (equal (show g1) "case h\n⊢ x = y\ny : Nat\nx : Nat := 5\n\n")))
      ;; several: each folds under its case
      (should (equal (show g1 g2) "▾ case h\nx : Nat := 5\ny : Nat\n⊢ x = y\n\n▾ goal 2 of 2\n⊢ True\n\n"))
      (let ((kitty-lean-infoview-emphasize-first-goal t))
        (should (equal (show g1 g2) "▾ case h\nx : Nat := 5\ny : Nat\n⊢ x = y\n\n▸ Other goals (1)\n"))))))

(ert-deftest kitty-lean-review-fixes ()
  "What the review of the rendering found: references outside a proof,
TAB at the end of a closed title, edits that start at one place."
  ;; outside a proof the goals are :none: the other answers' references count
  (should (= 3 (length (kitty-lean--answer-refs
                        (list :goals :none :term nil
                              :pins (list (cl-list* 'm "1:0" (list '(:type (:tag [(:info (:p "1")) (:text "a")])))))
                              :messages (list (list nil 1 '(:tag [(:info (:p "2")) (:text "b")])))
                              :widgets (list '(:id "w" :props (:x (:p "3")))))))))
  ;; TAB anywhere on a closed fold's line, even past its end, is that fold
  (with-temp-buffer
    (let ((kitty-lean--fold-path nil) (kitty-lean--pending-fills nil) ov)
      (setq ov (kitty-lean--fold '(a) t (lambda () (insert "Expected type")) (lambda () (insert "\n⊢ True"))))
      (insert "\n\n")
      (kitty-lean--fold '(b) t (lambda () (insert "  [c] trace")) nil (lambda (_) nil))
      (kitty-lean--fold-set ov nil)
      (goto-char (overlay-end ov))
      (should (eq (kitty-lean--fold-at-point) ov))
      (goto-char (point-max))
      (should-not (eq (kitty-lean--fold-at-point) ov))
      (should (kitty-lean--fold-at-point))))
  ;; LSP edits all speak of the text before any: in their order
  (with-temp-buffer
    (insert "abc")
    (cl-letf (((symbol-function 'kitty-lean--lsp-point)
               (lambda (_b p) (+ 1 (plist-get p :character))))
              ((symbol-function 'select-window) #'ignore)
              ((symbol-function 'display-buffer) #'ignore))
      (kitty-lean-widgets--apply (current-buffer)
                                 (list '(:range (:start (:line 0 :character 0) :end (:line 0 :character 0)) :newText "X")
                                       '(:range (:start (:line 0 :character 0) :end (:line 0 :character 1)) :newText "Y")
                                       '(:range (:start (:line 0 :character 3) :end (:line 0 :character 3)) :newText "A")
                                       '(:range (:start (:line 0 :character 3) :end (:line 0 :character 3)) :newText "B"))))
    (should (equal (buffer-string) "XYbcAB")))
  ;; two alike traces under one parent are two folds
  (with-temp-buffer
    (let ((kitty-lean--fold-path nil) (kitty-lean--pending-fills nil) (kitty-lean--refs nil))
      (clrhash kitty-lean--folds)
      (kitty-lean--insert-trace-children
       (vector '(:tag [(:trace (:cls "c" :indent 0 :collapsed t :msg (:text "same") :children (:strict [(:text "x")]))) (:text "")])
               '(:tag [(:trace (:cls "c" :indent 0 :collapsed t :msg (:text "same") :children (:strict [(:text "y")]))) (:text "")]))
       "p")
      (goto-char (point-min)) (search-forward "same")
      (kitty-lean-infoview-toggle-fold)
      (should (= 1 (hash-table-count kitty-lean--folds)))
      (clrhash kitty-lean--folds))))

(ert-deftest kitty-lean-marks-are-cheap ()
  "Proof marks for a long file: one pass, not one per mark from the top."
  (with-temp-buffer
    (dotimes (_ 20000) (insert "  simp\n"))
    (setq kitty-lean--marks (cons (number-sequence 0 19990 10) nil))
    (let ((t0 (float-time)))
      (kitty-lean--draw-marks)
      (should (< (- (float-time) t0) 0.3)))
    (should (= 2000 (length kitty-lean--mark-overlays)))
    (should (= 11 (line-number-at-pos (overlay-start (nth 1998 kitty-lean--mark-overlays)))))))

;;;; Diagnostics in pieces

(ert-deftest kitty-lean-diagnostics-add-up-and-arrive ()
  "Lean's incremental reports add up per version, a full one replaces them;
the first is handed on at once, the rest once the interval is over, the
last never left behind."
  (let ((kitty-lean--diagnostics (make-hash-table :test #'equal))
        (kitty-lean-diagnostics-interval 0.05)
        (given nil))
    (cl-letf (((symbol-function 'jsonrpc-running-p) (lambda (_) t))
              ((symbol-function 'eglot-handle-notification)
               (lambda (_s _m &rest args) (push (length (plist-get args :diagnostics)) given)))
              ((symbol-function 'kitty-lean--on-diagnostics) (lambda (_u d) d)))
      (cl-flet ((report (version inc n)
                  (when (kitty-lean--diagnostics-add "u" version inc (make-vector n '(:message "m")))
                    (kitty-lean--diagnostics-deliver 'server "u"))))
        (report 1 nil 1)
        (should (equal given '(1)))       ; at once
        (report 1 t 2) (report 1 t 3)
        (should (equal given '(1)))       ; held for the interval
        (should (kitty-lean-test--wait 2 (lambda () (equal given '(6 1)))))
        (report 2 nil 4)                  ; a new version replaces
        (report 2 t 1)
        (should (kitty-lean-test--wait 2 (lambda () (equal (car given) 5))))
        (report 1 t 7)                    ; a late piece of an old version is dropped
        (kitty-lean-test--wait 0.2 #'ignore)
        (should (equal (car given) 5))
        (should (equal (length (kitty-lean--diagnostics-all "u")) 5))))))

(ert-deftest kitty-lean-many-messages-come-in-pieces ()
  "A file with many messages: Lean sends each once, not the growing list each time."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (kitty-lean-test--fresh)
  (kitty-lean-test--write (kitty-lean-test--project) "Many.lean"
                          (mapconcat (lambda (i) (format "#eval %d\n" i)) (number-sequence 1 300) ""))
  (let* ((bytes 0)
         (count (lambda (_proc string) (setq bytes (+ bytes (length string))))))
    (advice-add 'jsonrpc--process-filter :before count)
    (unwind-protect
        (let ((buf (kitty-lean-test--visit "Many.lean")))
          (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
          (should (kitty-lean-test--wait 120 (lambda () (= 300 (length (with-current-buffer buf (flymake-diagnostics)))))))
          ;; all 300 at once would be ~45 kB; 300 growing lists ~7 MB
          (should (< bytes 1000000)))
      (advice-remove 'jsonrpc--process-filter count))))

;;;; VS Code's infoview, served

(require 'kitty-lean-webview)

(defun kitty-lean-test--http (url path &optional body)
  "A request to the webview server at URL; (STATUS . BODY) of its answer."
  (let* ((u (url-generic-parse-url url))
         (answer "")
         (proc (make-network-process :name "test-http" :host "127.0.0.1" :service (url-port u)
                                     :coding 'binary :noquery t
                                     :filter (lambda (_ s) (setq answer (concat answer s)))))
         (target (concat (url-filename u) path)))
    (process-send-string proc (concat (if body "POST " "GET ") target " HTTP/1.1\r\nHost: x\r\n"
                                      (if body (format "Content-Length: %d\r\n" (string-bytes body)) "")
                                      "\r\n" (or body "")))
    (kitty-lean-test--wait 5 (lambda () (and (string-match "\r\n\r\n" answer)
                                             (string-match "Content-Length: \\([0-9]+\\)" answer)
                                             (>= (- (length answer) (string-search "\r\n\r\n" answer) 4)
                                                 (string-to-number (match-string 1 answer))))))
    (delete-process proc)
    (cons (and (string-match "HTTP/1.1 \\([0-9]+\\)" answer) (string-to-number (match-string 1 answer)))
          (substring answer (min (length answer) (+ 4 (or (string-search "\r\n\r\n" answer) 0)))))))

(defun kitty-lean-test--stream (url page)
  "Open PAGE's event stream at URL: a function returning the events so far, as JSON."
  (let* ((u (url-generic-parse-url url))
         (raw "")
         (proc (make-network-process :name "test-events" :host "127.0.0.1" :service (url-port u)
                                     :coding 'binary :noquery t
                                     :filter (lambda (_ s) (setq raw (concat raw s))))))
    (process-send-string proc (format "GET %sevents?page=%s HTTP/1.1\r\nHost: x\r\n\r\n" (url-filename u) page))
    (lambda (&optional close)
      (if close (delete-process proc)
        (let (events (start 0))
          (while (string-match "^data: \\(.*\\)\n\n" raw start)
            (push (json-parse-string (decode-coding-string (match-string 1 raw) 'utf-8)
                                     :object-type 'plist :null-object nil :false-object nil)
                  events)
            (setq start (match-end 0)))
          (nreverse events))))))

(defun kitty-lean-test--answer (events id)
  (seq-find (lambda (e) (equal (plist-get e :id) id)) (funcall events)))

(ert-deftest kitty-lean-webview-serves-only-with-its-token ()
  (let* ((dist (make-temp-file "dist" t))
         (kitty-lean-webview-dist dist))
    (with-temp-file (expand-file-name "index.css" dist) (insert "body{}"))
    (unwind-protect
        (let ((url (kitty-lean-webview--start)))
          (should (string-match-p "host.js" (cdr (kitty-lean-test--http url ""))))
          (should (equal (kitty-lean-test--http url "dist/index.css") '(200 . "body{}")))
          (should (equal (car (kitty-lean-test--http url "dist/../../etc/passwd")) 404))
          (should (equal (car (kitty-lean-test--http url "dist//etc/passwd")) 404))
          (should (equal (car (kitty-lean-test--http url "dist/~/.bashrc")) 404))
          (should (string-match-p "--vscode-editor-foreground" (cdr (kitty-lean-test--http url "theme.css"))))
          ;; the same port without the token
          (should (equal (car (kitty-lean-test--http (replace-regexp-in-string "/[0-9a-f]+/$" "/x/" url) "")) 404)))
      (kitty-lean-webview-stop))))

(ert-deftest kitty-lean-webview-relays-lean ()
  "A page's calls reach Lean and come back as Lean sent them, to that page only:
a session, the goals at the cursor; the hello first, and once per server."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let* ((buf (kitty-lean-test--bad-with-goal))
         (uri (with-current-buffer buf (kitty-lean--uri)))
         (url (kitty-lean-webview--start))
         (a (kitty-lean-test--stream url "pageA"))
         (b (kitty-lean-test--stream url "pageB")))
    (unwind-protect
        (progn
          (should (kitty-lean-test--wait 5 (lambda () (seq-find (lambda (e) (equal (plist-get e :m) "serverRestarted")) (funcall a)))))
          (should (equal (plist-get (car (funcall a)) :m) "changedCursorLocation"))
          (should (seq-find (lambda (e) (equal (plist-get e :m) "initialize")) (funcall a)))
          (should (seq-find (lambda (e) (equal (plist-get e :n) "textDocument/publishDiagnostics")) (funcall a)))
          (kitty-lean-test--http url "call?page=pageA" (json-encode `((id . 0) (m . "createRpcSession") (a . [,uri]))))
          (should (kitty-lean-test--wait 10 (lambda () (kitty-lean-test--answer a 0))))
          (let ((session (plist-get (kitty-lean-test--answer a 0) :v)))
            (should (stringp session))
            (with-current-buffer buf
              (goto-char (point-min)) (forward-line 3) (back-to-indentation))
            ;; straight to the dispatcher, then at once a synchronous request:
            ;; Lean's answer to the page comes while it waits, and jsonrpc runs
            ;; the page's continuation later, outside the delivery
            (kitty-lean-webview--call
             "pageA"
             (json-encode `((id . 1) (m . "sendClientRequest")
                            (a . [,uri "$/lean/rpc/call"
                                       ((sessionId . ,session) (method . "Lean.Widget.getInteractiveGoals")
                                        (textDocument (uri . ,uri)) (position (line . 3) (character . 2))
                                        (params (textDocument (uri . ,uri)) (position (line . 3) (character . 2))))]))))
            (with-current-buffer buf
              (jsonrpc-request (eglot--current-server-or-lose) :textDocument/hover
                               (list :textDocument (list :uri uri) :position '(:line 2 :character 9))))
            (should (kitty-lean-test--wait 30 (lambda () (kitty-lean-test--answer a 1))))
            (let ((answer (kitty-lean-test--answer a 1)))
              (should (equal (plist-get answer :k) "raw"))
              (should (plist-get (plist-get (plist-get answer :v) :result) :goals))))
          ;; page B called nothing and got nothing
          (should-not (seq-find (lambda (e) (plist-get e :id)) (funcall b)))
          ;; B's id 0 is B's own
          (kitty-lean-test--http url "call?page=pageB" (json-encode '((id . 0) (m . "saveConfig") (a . [nil]))))
          (should (kitty-lean-test--wait 5 (lambda () (kitty-lean-test--answer b 0))))
          (should (stringp (plist-get (kitty-lean-test--answer a 0) :v)))
          ;; another file under the same server, and a buffer leaving eglot:
          ;; no restart for the pages (they would drop their RPC sessions)
          (let ((good (kitty-lean-test--visit "Demo/Good.lean")))
            (should (kitty-lean-test--wait 30 (lambda () (with-current-buffer good (eglot-managed-p)))))
            (with-temp-buffer (eglot--managed-mode -1))
            (kitty-lean-test--wait 1 #'ignore)
            (should (= 1 (seq-count (lambda (e) (equal (plist-get e :m) "serverRestarted")) (funcall a))))))
      (funcall a t) (funcall b t)
      (kitty-lean-webview-stop))))

(ert-deftest kitty-lean-webview-answers-wait-for-the-stream ()
  "An answer for a page whose stream is down waits; it comes when the stream is back."
  (let ((url (kitty-lean-webview--start)))
    (unwind-protect
        (progn
          (kitty-lean-test--http url "call?page=P" (json-encode '((id . 7) (m . "saveConfig") (a . [nil]))))
          (let ((s (kitty-lean-test--stream url "P")))
            (should (kitty-lean-test--wait 5 (lambda () (kitty-lean-test--answer s 7))))
            (funcall s t)))
      (kitty-lean-webview-stop))))

(ert-deftest kitty-lean-webview-pages-come-and-go ()
  "A stream the page closed is down, not an error in Lean's hooks; a page that
never opens its stream is forgotten too; the hello waits for a Lean server,
and comes again only for another server: buffers entering eglot are no
restart (test/kitty_lean_greet.tla)."
  (let ((url (kitty-lean-webview--start))
        (kitty-lean-webview-page-timeout 0)
        (server nil) (hellos nil))
    (unwind-protect
        (cl-letf (((symbol-function 'kitty-lean-webview--hello) (lambda (_p _b s) (push s hellos)))
                  ((symbol-function 'kitty-lean-webview--source) (lambda () (current-buffer)))
                  ((symbol-function 'eglot-current-server) (lambda () server)))
          (let ((s (kitty-lean-test--stream url "A")))
            (should (kitty-lean-test--wait 5 (lambda () (gethash "A" kitty-lean-webview--pages))))
            (let ((page (gethash "A" kitty-lean-webview--pages)))
              (should-not hellos)                    ; no server yet
              (setq server 'lean-1)
              (kitty-lean-webview--on-server)
              (kitty-lean-webview--on-server)        ; another buffer under eglot
              (kitty-lean-webview--on-move)
              (should (equal hellos '(lean-1)))
              (setq server 'lean-2)                  ; the server restarted
              (kitty-lean-webview--on-server)
              (should (equal hellos '(lean-2 lean-1)))
              ;; the page goes; Emacs writes before it has read that (more
              ;; writes would kill a batch Emacs with SIGPIPE; an
              ;; interactive one ignores it, and the write errors instead)
              (funcall s t)
              (kitty-lean-webview--send page "{}")
              (should (kitty-lean-test--wait 5 (lambda () (null (kitty-lean-webview--page-stream page)))))
              (kitty-lean-webview--send page "{}")
              (should (equal (kitty-lean-webview--page-outbox page) '("{}")))
              ;; and a write that fails is a stream down, not an error
              (let ((proc (make-pipe-process :name "dead" :noquery t)))
                (delete-process proc)
                (setf (kitty-lean-webview--page-stream page) proc)
                (cl-letf (((symbol-function 'process-live-p) (lambda (_) t)))
                  (kitty-lean-webview--send page "{}"))
                (should-not (kitty-lean-webview--page-stream page)))))
          ;; a page that only ever POSTed
          (kitty-lean-test--http url "call?page=B" (json-encode '((id . 0) (m . "saveConfig") (a . [nil]))))
          (should (gethash "B" kitty-lean-webview--pages))
          (kitty-lean-test--wait 0.1 #'ignore)
          (kitty-lean-webview--tick)
          (should-not (gethash "A" kitty-lean-webview--pages))
          (should-not (gethash "B" kitty-lean-webview--pages))
          ;; A comes back: its calls are dropped, its stream says reload
          (kitty-lean-test--http url "call?page=A" (json-encode '((id . 3) (m . "saveConfig") (a . [nil]))))
          (should-not (gethash "A" kitty-lean-webview--pages))
          (let ((s (kitty-lean-test--stream url "A")))
            (should (kitty-lean-test--wait 5 (lambda () (equal (funcall s) '((:reload t))))))
            (funcall s t)))
      (kitty-lean-webview-stop))))

(ert-deftest kitty-lean-webview-hears-only-lean ()
  "Other servers' edits stay away from the pages; a call that is no JSON is
no error in the process filter; a terminal's \\w reuses one redirect file,
gone when the webview stops."
  (let ((kitty-lean-webview--pages (make-hash-table :test #'equal))
        (sent nil))
    (cl-letf (((symbol-function 'kitty-lean-webview--send) (lambda (_page e) (push e sent))))
      (let ((page (kitty-lean-webview--page "P")))
        (puthash "textDocument/didChange" 1 (kitty-lean-webview--page-subs page))
        (cl-letf (((symbol-function 'kitty-lean--server-p) (lambda (c) (eq c 'lean))))
          (kitty-lean-webview--on-client-notification-safe
           'python :textDocument/didChange '(:textDocument (:uri "file:///x.py")))
          (should-not sent)
          (kitty-lean-webview--on-client-notification-safe
           'lean :textDocument/didChange '(:textDocument (:uri "file:///x.lean")))
          (should (= (length sent) 1)))))
    ;; (ert sets debug-on-error, which lets errors through with-demoted-errors)
    (should-not (condition-case e
                    (let ((debug-on-error nil) (inhibit-message t))
                      (kitty-lean-webview--call "P" "not json") nil)
                  (error e))))
  (let ((kitty-lean-webview-display 'browser) (kitty-lean-webview-dist temporary-file-directory)
        (opened nil))
    (cl-letf (((symbol-function 'browse-url) (lambda (u) (push u opened))))
      (unwind-protect
          (progn (kitty-lean-webview) (kitty-lean-webview)
                 (should (= (length opened) 2))
                 (should (equal (car opened) (cadr opened)))
                 (should (file-exists-p kitty-lean-webview--redirect))
                 (should (= (file-modes kitty-lean-webview--redirect) #o600)))
        (let ((file kitty-lean-webview--redirect))
          (kitty-lean-webview-stop)
          (should-not (file-exists-p file)))))))

(ert-deftest kitty-lean-webview-answers-are-leans-json ()
  "A page's answer is the JSON Lean sent ({} stays {}), even when jsonrpc runs
its continuation later, outside the delivery (a synchronous request waiting)."
  (let ((kitty-lean-webview--pages (make-hash-table :test #'equal))
        (kitty-lean-webview--wanted (make-hash-table :test #'equal))
        (sent nil) (success nil))
    (cl-letf (((symbol-function 'kitty-lean--buffer-for-uri) (lambda (_) (current-buffer)))
              ((symbol-function 'eglot-current-server) (lambda () 'conn))
              ((symbol-function 'kitty-lean--flush) #'ignore)
              ((symbol-function 'jsonrpc-async-request)
               (lambda (_s _m _p &rest args) (setq success (plist-get args :success-fn)) (list 42 nil)))
              ((symbol-function 'kitty-lean-webview--send) (lambda (_page e) (push e sent))))
      (kitty-lean-webview--call "P" "{\"id\":5,\"m\":\"sendClientRequest\",\"a\":[\"u\",\"m\",{}]}")
      ;; Lean's answer is delivered; the continuation does not run yet
      (kitty-lean-webview--keep-raw #'ignore 'conn '(:id 42 :result nil :jsonrpc-json "{\"id\":42,\"result\":{}}"))
      (funcall success nil)
      (should (equal sent '("{\"id\":5,\"k\":\"raw\",\"v\":{\"id\":42,\"result\":{}}}")))
      (should (zerop (hash-table-count kitty-lean-webview--wanted))))))

;;;; Folding

(defun kitty-lean-test--hidden-lines ()
  "The 1-based lines whose text hideshow hides."
  (let (lines)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (when (and (not (eolp)) (invisible-p (pos-bol)))
          (push (line-number-at-pos) lines))
        (forward-line 1)))
    (nreverse lines)))

(ert-deftest kitty-lean-folds-what-lean-says ()
  "Lean's folding ranges through hideshow and evil: za folds the declaration
on the line, zR opens all, zM folds the top level; the first line stays,
as in VS Code; ranges follow edits."
  (kitty-lean-test--skip-unless-lean)
  (kitty-lean-test--boot)
  (let ((buf (kitty-lean-test--visit "Fold.lean")))
    (should (kitty-lean-test--wait 60 (lambda () (eglot-managed-p))))
    (should (kitty-lean-test--wait 60 (lambda () (> (length kitty-lean--fold-ranges) 0))))
    (should hs-minor-mode)
    (should (equal (mapcar (lambda (r) (list (line-number-at-pos (car r)) (line-number-at-pos (nth 1 r))))
                           kitty-lean--fold-ranges)
                   '((1 2) (3 8) (10 14) (11 13))))
    ;; za on the theorem's first line: lines 4-8 hidden, 3 shown
    (goto-char (point-min)) (forward-line 2) (forward-char 3)
    (execute-kbd-macro "za")
    (should (equal (kitty-lean-test--hidden-lines) '(4 5 6 7 8)))
    (execute-kbd-macro "za")
    (should-not (kitty-lean-test--hidden-lines))
    ;; zc inside the def folds the def, not the namespace
    (goto-char (point-min)) (forward-line 11)
    (execute-kbd-macro "zc")
    (should (equal (kitty-lean-test--hidden-lines) '(12 13)))
    (execute-kbd-macro "zR")
    (should-not (kitty-lean-test--hidden-lines))
    ;; zM: the top level (comment, theorem, namespace)
    (execute-kbd-macro "zM")
    (should (equal (kitty-lean-test--hidden-lines) '(2 4 5 6 7 8 11 12 13 14)))
    (execute-kbd-macro "zR")
    ;; an edit above: the ranges move with the text, then Lean's new answer
    (goto-char (point-min))
    (insert "-- a new first line\n")
    (should (equal (mapcar (lambda (r) (line-number-at-pos (car r))) kitty-lean--fold-ranges) '(2 4 11 12)))
    (should-not (eql kitty-lean--fold-tick (buffer-chars-modified-tick)))
    (kitty-lean-test--sync)
    (should (kitty-lean-test--wait 60 (lambda () (not (kitty-lean-busy-p buf)))))
    (should (kitty-lean-test--wait 10 (lambda () (eql kitty-lean--fold-tick (buffer-chars-modified-tick)))))
    (should (equal (mapcar (lambda (r) (line-number-at-pos (car r))) kitty-lean--fold-ranges) '(2 4 11 12)))
    (set-buffer-modified-p nil)))

(ert-deftest kitty-lean-fold-proofs ()
  "Lean 4.37's proof ranges: fold all proofs, unfold them; an answer for
an older text is dropped."
  (with-temp-buffer
    (insert kitty-lean-test--fold-source)
    (kitty-lean--fold-setup)
    ;; Lean 4.37's answer for this text: the proof from the end of the header
    (let ((answer (vector '(:startLine 0 :endLine 1 :kind "comment")
                          '(:startLine 9 :endLine 13 :kind "region")
                          '(:startLine 10 :endLine 12 :kind "region")
                          '(:startLine 3 :endLine 7 :kind "proof")))
          success)
      (cl-letf (((symbol-function 'eglot-current-server) (lambda () 'server))
                ((symbol-function 'eglot--TextDocumentIdentifier) (lambda () '(:uri "file:///F.lean")))
                ((symbol-function 'kitty-lean--flush) #'ignore)
                ((symbol-function 'jsonrpc-async-request)
                 (lambda (_s method _params &rest args)
                   (should (eq method :textDocument/foldingRange))
                   (setq success (plist-get args :success-fn)))))
        ;; the text changed after the question: the answer is dropped
        (kitty-lean--fold-request)
        (goto-char (point-max)) (insert "\n")
        (funcall success answer)
        (should (equal kitty-lean--fold-ranges []))
        (delete-char -1)
        (kitty-lean--fold-request)
        (funcall success answer)
        (should (equal (mapcar (lambda (r) (list (line-number-at-pos (car r)) (line-number-at-pos (nth 1 r)) (nth 2 r)))
                               kitty-lean--fold-ranges)
                       '((1 2 nil) (4 8 t) (10 14 nil) (11 13 nil))))
        (kitty-lean-fold-proofs)
        (should (equal (kitty-lean-test--hidden-lines) '(5 6 7 8)))
        (kitty-lean-unfold-proofs)
        (should-not (kitty-lean-test--hidden-lines))))))

(ert-deftest kitty-lean-folding-is-cheap ()
  "Taking 6000 ranges and folding the top level of 2000 declarations stay
well under a second (the review measured 6.8 s and 15 s before)."
  (with-temp-buffer
    (dotimes (i 2000) (insert (format "def d%d : Nat :=\n  %d\n\n" i i)))
    (setq-local comment-start "-- " comment-end "")
    (kitty-lean--fold-setup)
    (should hs-minor-mode)
    (let ((answer (vconcat (cl-loop for i below 2000 for l = (* 3 i)
                                    append (list (list :startLine l :endLine (1+ l) :kind "region")
                                                 (list :startLine l :endLine (1+ l) :kind "proof")
                                                 (list :startLine (1+ l) :endLine (+ 2 l) :kind "region")))))
          (start (float-time)))
      (kitty-lean--folding-ranges answer)
      (should (< (- (float-time) start) 0.5))
      (setq start (float-time))
      (hs-hide-all)
      (should (< (- (float-time) start) 1.0))
      (should (= 2000 (length (kitty-lean-test--hidden-lines)))))))

;;;; The webview's right-click menu

(ert-deftest kitty-lean-webview-menu-names-only-what-the-infoview-hears ()
  "Every entry of the page's right-click menu (webview/host.js) is one the
shipped infoview answers to: a renamed entry in a new @leanprover/infoview
would otherwise do nothing when clicked.  Its behaviour in a browser is
recorded by the review's Playwright script."
  (let ((bundle (and kitty-lean-webview-dist
                     (expand-file-name "index.production.min.js" kitty-lean-webview-dist))))
    (unless (and bundle (file-readable-p bundle))
      (signal 'ert-test-skipped '("no @leanprover/infoview (KITTYMAX_LEAN_INFOVIEW)")))
    (let ((js (with-temp-buffer (insert-file-contents bundle) (buffer-string)))
          (entries nil))
      (with-temp-buffer
        (insert-file-contents (expand-file-name "lisp/lang/webview/host.js" kitty-lean-test--root))
        (while (re-search-forward "item('\\([A-Za-z]+\\)'" nil t)
          (push (match-string 1) entries)))
      (should (> (length entries) 30))
      (should-not (seq-remove (lambda (e) (or (string-search (format "\"%s\"" e) js)
                                               (string-search (format "`%s:${" e) js)))
                              entries)))))
