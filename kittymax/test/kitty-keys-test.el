;;; kitty-keys-test.el --- my-nvim's keys in kittymax  -*- lexical-binding: t; -*-

;; my-nvim (Neovim) is the source of truth for kittymax's keys.  This checks
;; that every <leader> key my-nvim defines runs the matching command here, that
;; mode-only leader keys (nvim-orgmode's <leader>o..., markdown's <leader>ce)
;; sit over the global ones without hiding them, that every kittymax command a
;; key names exists, and the editing logic that does not need evil.

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-evil)
(require 'kitty-vim)
(require 'kitty-org)
(require 'kitty-markdown)
(require 'kitty-vc)
(require 'kitty-dired)
(require 'kitty-sql)
;; Everything a key can name, for `kitty-keys-commands-exist'.
(dolist (m '(kitty-core kitty-ui kitty-splash kitty-cat kitty-completion kitty-prog kitty-rss
             kitty-c kitty-csharp kitty-nix kitty-verilog kitty-sqldiff))
  (require m))

(defun kitty-test--command (map keys)
  (let ((b (lookup-key map (kbd keys))))
    (if (and (consp b) (stringp (car b))) (cdr b) b)))

;;;; my-nvim's <leader> keys (lua/config/core/*.lua, lua/lang/*.lua, init.lua)

(defconst kitty-test--nvim-leader
  '(;; ui.lua
    ("f f" . kitty-find-files) ("f g" . consult-ripgrep) ("," . consult-buffer)
    ("e" . kitty-explorer) ("f r" . kitty-registers) ("f t" . kitty-terminal-toggle)
    ("u z" . kitty-zen) ("u u" . kitty-undo-tree)
    ("x x" . flymake-show-project-diagnostics) ("x X" . flymake-show-buffer-diagnostics)
    ("x L" . flymake-show-buffer-diagnostics) ("x Q" . kitty-quickfix)
    ("c s" . consult-imenu) ("c l" . xref-find-references)
    ;; lsp.lua
    ("c a" . eglot-code-actions) ("r n" . eglot-rename) ("u h" . kitty-toggle-inlay-hints)
    ;; git.lua
    ("g g" . magit-status) ("g h" . magit-log-buffer-file) ("g H" . magit-log-current)
    ("g s" . magit-status) ("g l" . magit-log-current) ("g L" . magit-log-buffer-file)
    ("g d" . magit-diff-unstaged) ("g b" . magit-branch-checkout) ("g B" . kitty-git-browse)
    ("h s" . kitty-hunk-stage) ("h r" . diff-hl-revert-hunk) ("h S" . magit-stage-buffer-file)
    ("h u" . magit-unstage-buffer-file) ("h p" . diff-hl-show-hunk) ("h b" . magit-blame-addition)
    ("h d" . magit-diff-buffer-file) ("h t" . magit-blame-echo)
    ;; dap.lua
    ("d b" . dape-breakpoint-toggle) ("d B" . dape-breakpoint-expression)
    ("d c" . kitty-debug-continue) ("d s" . dape-next) ("d i" . dape-step-in)
    ("d o" . dape-step-out) ("d u" . dape-info) ("d l" . dape-restart)
    ("d q" . dape-quit) ("d e" . dape-evaluate-expression)
    ;; ai.lua
    ("a c" . kitty-claude) ("a f" . kitty-claude) ("a C" . kitty-claude-continue)
    ("a b" . kitty-claude-add-buffer) ("a s" . kitty-claude-send)
    ("a e" . kitty-claude-explain) ("a r" . kitty-claude-refactor) ("a t" . kitty-claude-teach)
    ;; files.lua, org.lua, kitten.lua, multicursor.lua, reload.lua, init.lua
    ("p v" . kitty-oil) ("o a" . org-agenda) ("o c" . org-capture)
    ("u k" . kitty-cat-mode) ("u p" . kitty-org-toggle-pretty)
    ("M" . kitty-mc-all) ("R" . kitty-reload) ("X" . kitty-eval-line-or-region)
    ("SPC x" . kitty-source-file))
  "my-nvim's <leader> key -> the kittymax command it runs.")

(ert-deftest kitty-keys-every-nvim-leader-key ()
  (dolist (entry kitty-test--nvim-leader)
    (should (equal (cons (car entry) (cdr entry))
                   (cons (car entry) (kitty-test--command kitty-leader-map (car entry)))))))

(defun kitty-test--raw (key)
  "The leader's own entry for single-character KEY, label and all."
  (cdr (assq (string-to-char key) (cdr kitty-leader-map))))

(ert-deftest kitty-keys-leader-has-which-key-labels ()
  "Prefixes carry a name, as my-nvim's which-key groups do."
  (dolist (p '("f" "g" "h" "x" "c" "d" "a" "u" "o"))
    (let ((b (kitty-test--raw p)))
      (should (and (consp b) (stringp (car b)) (keymapp (cdr b)))))))

(ert-deftest kitty-keys-local-leader-on-m ()
  (should (equal kitty-local-leader-binding (kitty-test--raw "m"))))

(ert-deftest kitty-keys-commands-exist ()
  "Every kittymax command a key runs is defined (the rest come from packages)."
  (let (missing)
    (cl-labels ((walk (map)
                  (map-keymap
                   (lambda (_ev b)
                     (let ((cmd (if (and (consp b) (stringp (car b))) (cdr b) b)))
                       (cond ((keymapp cmd) (walk cmd))
                             ((and (symbolp cmd) (string-prefix-p "kitty-" (symbol-name cmd))
                                   (not (fboundp cmd)))
                              (push cmd missing)))))
                   map)))
      (walk kitty-leader-map)
      (maphash (lambda (_m map) (walk map)) kitty--mode-leaders)
      (maphash (lambda (_m map) (walk map)) kitty--local-leaders))
    (should-not missing)))

;;;; Mode-only leader keys

(defun kitty-test--leader-in (mode keys)
  (with-temp-buffer
    (setq major-mode mode)
    (kitty-test--command (kitty-leader-keymap) keys)))

(ert-deftest kitty-keys-org-buffers-have-nvim-orgmode-keys ()
  (dolist (probe '(("o r" . kitty-org-refile) ("o t" . org-set-tags-command)
                   ("o $" . org-archive-subtree) ("o i d" . org-deadline)
                   ("o i s" . org-schedule) ("o l i" . org-insert-link)
                   ("o x i" . org-clock-in) ("RET" . org-meta-return)
                   ;; the global ones under the same prefix are still there
                   ("o a" . org-agenda) ("o c" . org-capture) ("g g" . magit-status)))
    (should (equal probe (cons (car probe) (kitty-test--leader-in 'org-mode (car probe)))))))

(ert-deftest kitty-keys-org-keys-stay-in-org ()
  (should-not (kitty-test--leader-in 'text-mode "o r"))
  (should (eq 'org-agenda (kitty-test--leader-in 'text-mode "o a"))))

(ert-deftest kitty-keys-markdown-edits-code-blocks ()
  (should (eq 'markdown-edit-code-block (kitty-test--leader-in 'markdown-mode "c e")))
  (should (eq 'eglot-code-actions (kitty-test--leader-in 'markdown-mode "c a")))
  (should-not (kitty-test--leader-in 'text-mode "c e")))

(ert-deftest kitty-keys-derived-modes-inherit ()
  (put 'kitty-test-org-derived 'derived-mode-parent 'org-mode)
  (should (eq 'kitty-org-refile (kitty-test--leader-in 'kitty-test-org-derived "o r"))))

;;;; Vim's C-a

(defun kitty-test--inc (text pos count)
  (with-temp-buffer
    (insert text)
    (goto-char pos)
    (kitty-increment count)
    (cons (buffer-string) (point))))

(ert-deftest kitty-keys-increment ()
  ;; under the cursor, after it, negative, across zero; the cursor ends on the last digit
  (should (equal '("x = 42;" . 6) (kitty-test--inc "x = 41;" 6 1)))
  (should (equal '("x = 46;" . 6) (kitty-test--inc "x = 41;" 1 5)))
  (should (equal '("a -2 b" . 4) (kitty-test--inc "a -3 b" 4 1)))
  (should (equal '("a 1 b" . 3) (kitty-test--inc "a -1 b" 1 2)))
  (should (equal '("v10" . 3) (kitty-test--inc "v9" 1 1)))
  (should-error (kitty-test--inc "no digits" 1 1) :type 'user-error))

;;;; SQL statements (iq / aq, ]] [[)

(defconst kitty-test--sql
  "select 1;\nselect ';' as semi, 2 -- ; in a comment\nfrom t;\n\nupdate t\nset x = 1\n\nGO\ndelete from t\n")

(defun kitty-test--stmt (needle &optional nth)
  "The statement around the NTH occurrence of NEEDLE: (inner-text . outer-text)."
  (with-temp-buffer
    (sql-mode)
    (insert kitty-test--sql)
    (goto-char (point-min))
    (dotimes (_ (or nth 1)) (search-forward needle))
    (goto-char (match-beginning 0))
    (let ((b (kitty-sql-statement-bounds)))
      (cons (buffer-substring-no-properties (nth 0 b) (nth 1 b))
            (buffer-substring-no-properties (nth 0 b) (nth 2 b))))))

(ert-deftest kitty-keys-sql-statements ()
  (should (equal '("select 1" . "select 1;\n") (kitty-test--stmt "select 1")))
  ;; ; inside a string or a comment does not end a statement
  (should (equal "select ';' as semi, 2 -- ; in a comment\nfrom t"
                 (car (kitty-test--stmt "as semi"))))
  ;; a blank line ends one, and GO lines do (T-SQL)
  (should (equal "update t\nset x = 1" (car (kitty-test--stmt "set x"))))
  (should (equal "delete from t" (car (kitty-test--stmt "delete")))))

(ert-deftest kitty-keys-sql-blank-line-has-no-statement ()
  (with-temp-buffer
    (sql-mode)
    (insert kitty-test--sql)
    (goto-char (point-min))
    (search-forward "from t;\n")
    (should-not (kitty-sql-statement-bounds))))

(ert-deftest kitty-keys-sql-next-and-previous ()
  (with-temp-buffer
    (sql-mode)
    (insert kitty-test--sql)
    (goto-char (point-min))
    (kitty-sql-next-statement 1)
    (should (looking-at-p "select ';'"))
    (kitty-sql-next-statement 1)
    (should (looking-at-p "update t"))
    (kitty-sql-previous-statement 1)
    (should (looking-at-p "select ';'"))))

(provide 'kitty-keys-test)
;;; kitty-keys-test.el ends here
