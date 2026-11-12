;;; kitty-evil-test.el --- my-nvim's keys, pressed in real evil  -*- lexical-binding: t; -*-

;; Each test types keys into a buffer, as you would, and checks the text.  It
;; needs evil and the packages kitty-vim.el uses; without them it skips.
;;   emacs --batch -L <package dirs> -L lisp -L lisp/lang -l test/kitty-evil-test.el \
;;         -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(defconst kitty-test--have-evil (and (locate-library "evil") t))
(when kitty-test--have-evil
  ;; kitty-evil loads evil itself, after its settings, as init.el does
  (require 'kitty-lib)
  (require 'kitty-evil)
  (require 'kitty-vim)
  (require 'kitty-vc)
  (require 'kitty-org)
  (require 'kitty-markdown)
  (require 'kitty-dired)
  (require 'kitty-sql))

(defun kitty-test--type (text keys &optional mode)
  "Put TEXT (| marks the cursor) in a MODE buffer, type KEYS in normal state.
Return the text afterwards, with | where the cursor ended."
  (with-temp-buffer
    (funcall (or mode #'fundamental-mode))
    (insert (replace-regexp-in-string "|" "" text))
    ;; What a window does as it shows the text (markdown finds list items
    ;; through syntax properties).
    (syntax-propertize (point-max))
    (font-lock-ensure)
    (goto-char (1+ (or (string-search "|" text) 0)))
    (switch-to-buffer (current-buffer))
    (buffer-enable-undo)
    (evil-local-mode 1)
    (evil-normal-state)
    (execute-kbd-macro (kbd keys))
    (let ((pt (point)))
      (concat (buffer-substring-no-properties (point-min) pt) "|"
              (buffer-substring-no-properties pt (point-max))))))

(defun kitty-test--text (text keys &optional mode)
  "As `kitty-test--type', without the cursor."
  (replace-regexp-in-string "|" "" (kitty-test--type text keys mode)))

(defmacro kitty-test--deftest (name doc &rest body)
  (declare (indent 1) (doc-string 2))
  `(ert-deftest ,name () ,doc (skip-unless kitty-test--have-evil) ,@body))

;;;; Vim, with my-nvim's settings

(kitty-test--deftest kitty-evil-vim-basics
  "Verb first, as in Neovim."
  (should (equal "bar" (kitty-test--text "|foo bar" "dw")))
  (should (equal "foo qux baz" (kitty-test--text "foo b|ar baz" "ciwqux <escape>" )))
  (should (equal "two" (kitty-test--text "|one\ntwo" "dd")))
  ;; Y yanks to the end of the line (Neovim's Y)
  (should (equal "a bcbc" (kitty-test--text "a |bc" "Y$p")))
  ;; u undoes, C-r redoes (undo-redo)
  (should (equal "foo bar" (kitty-test--text "|foo bar" "dwu")))
  (should (equal "bar" (kitty-test--text "|foo bar" "dwu C-r"))))

(kitty-test--deftest kitty-evil-increment
  "C-a: Vim's increment."
  (should (equal "x = 42" (kitty-test--text "|x = 41" "C-a")))
  (should (equal "x = 45" (kitty-test--text "|x = 41" "4 C-a"))))

;;;; Operators

(kitty-test--deftest kitty-evil-surround
  "ys / cs / ds and visual gs: vim-surround's keys."
  (should (equal "foo \"bar\"" (kitty-test--text "foo b|ar" "ysiw\"")))
  (should (equal "foo 'bar'" (kitty-test--text "foo \"b|ar\"" "cs\"'")))
  (should (equal "foo bar" (kitty-test--text "foo 'b|ar'" "ds'")))
  (should (equal "foo (bar)" (kitty-test--text "foo b|ar" "viwgs)"))))

(kitty-test--deftest kitty-evil-surround-bold-in-markdown
  "ysiw* makes **bold** in markdown."
  (skip-unless (require 'markdown-mode nil t))
  (should (equal "a **word**" (kitty-test--text "a w|ord" "ysiw*" #'markdown-mode))))

(kitty-test--deftest kitty-evil-comment
  "gcc comments the line, gcc again uncomments it."
  (let ((once (kitty-test--text "|(foo)" "gcc" #'emacs-lisp-mode)))
    (should (string-match-p "\\`;+ (foo)\\'" once))
    (should (equal "(foo)" (kitty-test--text (concat "|" once) "gcc" #'emacs-lisp-mode)))))

(kitty-test--deftest kitty-evil-align
  "ga{motion}{char}: gaip= aligns on =."
  (should (equal "a   = 1\nbbb = 2\n" (kitty-test--text "|a = 1\nbbb = 2\n" "gaip="))))

;;;; Text objects (mini.ai's)

(kitty-test--deftest kitty-evil-any-quote
  "iq / aq: the nearest quotes of any kind, else the next."
  (should (equal "x \"Z\" y" (kitty-test--text "x \"ab|c\" y" "ciqZ <escape>")))
  (should (equal "x 'Z' y" (kitty-test--text "x 'a|b' y" "ciqZ <escape>")))
  ;; not inside any: the next pair on the line
  (should (equal "x 'Z'" (kitty-test--text "|x 'ab'" "ciqZ <escape>"))))

(kitty-test--deftest kitty-evil-any-bracket
  "ib / ab: the nearest brackets of any kind, else the next."
  (should (equal "f(a, [Z])" (kitty-test--text "f(a, [b|c])" "cibZ <escape>")))
  (should (equal "f(a, Z)" (kitty-test--text "f(a, [b|c])" "cabZ <escape>")))
  (should (equal "x {Z}" (kitty-test--text "|x {abc}" "cibZ <escape>"))))

(kitty-test--deftest kitty-evil-next-and-last-pair
  "ciN( / ciL(: the next / last pair of that kind."
  (should (equal "f(a) g(b) h(Z)" (kitty-test--text "f(a) g(|b) h(c)" "ciN(Z <escape>")))
  (should (equal "f(Z) g(b) h(c)" (kitty-test--text "f(a) g(|b) h(c)" "ciL(Z <escape>"))))

(kitty-test--deftest kitty-evil-argument
  "cia: the argument under the cursor."
  (should (equal "f(a, Z, c)" (kitty-test--text "f(a, b|b, c)" "ciaZ <escape>"))))

;;;; Multiple cursors

(kitty-test--deftest kitty-evil-cursors-on-every-match
  "SPC M then c: every match changes."
  (should (equal "qux bar qux baz qux"
                 (kitty-test--text "|foo bar foo baz foo" "SPC M ciwqux <escape> C-l"))))

(kitty-test--deftest kitty-evil-cursors-next-match
  "C-n marks the word and its next matches; c changes those, not the rest."
  (should (equal "qux bar qux baz foo"
                 (kitty-test--text "|foo bar foo baz foo" "C-n C-n ciwqux <escape> C-l"))))

(kitty-test--deftest kitty-evil-cursors-restore
  "C-l clears, gQ brings them back."
  (should (equal "qux bar qux"
                 (kitty-test--text "|foo bar foo" "SPC M C-l gQ ciwqux <escape> C-l"))))

;;;; Modes

(kitty-test--deftest kitty-evil-org
  "nvim-orgmode's cit and << / >> on headings."
  ;; kittymax's keywords: TODO -> NEXT -> WAIT | DONE CANCELLED
  (should (equal "* NEXT task" (kitty-test--text "|* TODO task" "cit" #'org-mode)))
  (should (equal "* TODO task" (kitty-test--text "|* NEXT task" "ciT" #'org-mode)))
  (should (equal "* a" (kitty-test--text "|** a" "<<" #'org-mode)))
  (should (equal "** a" (kitty-test--text "|* a" ">>" #'org-mode)))
  ;; off a heading, << still shifts the line
  (should (equal "text" (kitty-test--text "|    text" "<<" #'org-mode))))

(kitty-test--deftest kitty-evil-sql-statements
  "daq deletes a statement, yaq / iq select one."
  (should (equal "select 2;" (kitty-test--text "select |1;\nselect 2;" "daq" #'sql-mode)))
  (should (equal "select 1;\n\nupdate t"
                 (kitty-test--text "select 1;\n\nupdate |x" "ciqupdate SPC t <escape>" #'sql-mode))))

(kitty-test--deftest kitty-evil-markdown-lists
  "o on a list item continues the list."
  (skip-unless (require 'markdown-mode nil t))
  (should (equal "- item\n- next" (kitty-test--text "- it|em" "onext <escape>" #'markdown-mode))))

;;;; Keys that open things (checked by what they are bound to)

(defun kitty-test--normal-binding (keys &optional mode)
  (with-temp-buffer
    (funcall (or mode #'fundamental-mode))
    (switch-to-buffer (current-buffer))
    (evil-local-mode 1)
    (evil-normal-state)
    (key-binding (kbd keys))))

(kitty-test--deftest kitty-evil-leader-and-motions
  "The leader and my-nvim's single keys, in normal state."
  (should (eq 'kitty-find-files (kitty-test--normal-binding "SPC f f")))
  (should (eq 'kitty-source-file (kitty-test--normal-binding "SPC SPC x")))
  (should (eq 'org-agenda (kitty-test--normal-binding "SPC o a")))
  (should (eq 'kitty-org-refile (kitty-test--normal-binding "SPC o r" #'org-mode)))
  (should (eq 'evil-avy-goto-char-timer (kitty-test--normal-binding "s")))
  (should (eq 'kitty-select-node (kitty-test--normal-binding "S")))
  (should (eq 'flymake-goto-next-error (kitty-test--normal-binding "]d")))
  (should (eq 'diff-hl-next-hunk (kitty-test--normal-binding "]h")))
  (should (eq 'kitty-oil (kitty-test--normal-binding "-")))
  (should (eq 'kitty-terminal-toggle (kitty-test--normal-binding "C-/"))))

(kitty-test--deftest kitty-evil-lsp-keys
  "Neovim 0.12's LSP keys in buffers eglot manages."
  (require 'eglot)
  (let ((aux (evil-get-auxiliary-keymap eglot-mode-map 'normal)))
    (should (eq 'xref-find-references (lookup-key aux (kbd "grr"))))
    (should (eq 'eglot-rename (lookup-key aux (kbd "grn"))))
    (should (eq 'eglot-code-actions (lookup-key aux (kbd "gra"))))
    (should (eq 'eglot-find-implementation (lookup-key aux (kbd "gri"))))))

(kitty-test--deftest kitty-evil-dired-like-oil
  "oil's keys in dired, over evil-collection's."
  (let ((dir (make-temp-file "kitty-dired" t)))
    (with-current-buffer (dired dir)
      (evil-normal-state)
      (should (eq 'dired-up-directory (key-binding (kbd "-"))))
      (should (eq 'kitty-dired-toggle-details (key-binding (kbd "gd"))))
      (should (eq 'kitty-dired-insert (key-binding (kbd "i"))))
      (should (eq 'dired-flag-file-deletion (key-binding (kbd "dd"))))
      (kill-buffer))))

(kitty-test--deftest kitty-evil-dired-rename-with-w
  "Edit a name in the listing, :w renames the file (oil's way)."
  (let* ((dir (make-temp-file "kitty-dired" t))
         (file (expand-file-name "old.txt" dir)))
    (with-temp-file file (insert "x"))
    (with-current-buffer (dired dir)
      (switch-to-buffer (current-buffer))
      (evil-normal-state)
      (goto-char (point-min))
      (search-forward "old.txt")
      (goto-char (match-beginning 0))
      (execute-kbd-macro (kbd "i <delete> <delete> <delete> new <escape>"))
      (evil-ex-execute "w")
      (should (file-exists-p (expand-file-name "new.txt" dir)))
      (should-not (file-exists-p file))
      (kill-buffer))))

(provide 'kitty-evil-test)
;;; kitty-evil-test.el ends here
