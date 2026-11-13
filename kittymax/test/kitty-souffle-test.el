;;; kitty-souffle-test.el --- Soufflé, as my-nvim has it  -*- lexical-binding: t; -*-

;;   emacs --batch -L lisp -L lisp/lang -l test/kitty-souffle-test.el -f ert-run-tests-batch-and-exit

(require 'ert)
(require 'cl-lib)
(defvar kitty-cache-dir (make-temp-file "kitty-cache" t))
(defvar kitty-data-dir kitty-cache-dir)
(defvar kitty-config-dir default-directory)
(require 'kitty-lib)
(require 'kitty-souffle)

(defconst kst--program ".decl edge(x: number, y: number)
.input edge
.decl path(x: number, y: number)
.output path
path(x, y) :- edge(x, y).
path(x, z) :- path(x, y) edge(y, z).
")

;; souffle 2.5's own output for the program above (line 6 lacks a comma)
(defconst kst--output "Error: syntax error, unexpected identifier, expecting . in file path.dl at line 6
path(x, z) :- path(x, y) edge(y, z).
-------------------------^-----------
Warning: Variable y only occurs once in file path.dl at line 6
path(x, z) :- path(x, y) edge(y, z).
---------------------^---------------
1 errors generated, evaluation aborted
")

(defun kst--dir (files)
  (let ((dir (file-name-as-directory (make-temp-file "kst" t))))
    (dolist (f files) (with-temp-file (expand-file-name (car f) dir) (insert (cdr f))))
    dir))

(ert-deftest kitty-souffle-modes-by-extension ()
  ".dl and .souffle are programs, .facts are facts."
  (should (eq 'souffle-mode (assoc-default "x/path.dl" auto-mode-alist #'string-match)))
  (should (eq 'souffle-facts-mode (assoc-default "x/edge.facts" auto-mode-alist #'string-match))))

(ert-deftest kitty-souffle-errors-jump-to-line-and-column ()
  "souffle's message: RET lands on the line, and on the column its ^ points at."
  (let* ((dir (kst--dir `(("path.dl" . ,kst--program))))
         (file (expand-file-name "path.dl" dir)))
    (with-current-buffer (get-buffer-create "*kst compilation*")
      (let ((inhibit-read-only t)) (erase-buffer) (insert kst--output))
      (setq default-directory dir)
      (compilation-mode)
      (goto-char (point-min))
      (compile-goto-error)
      (should (equal file (buffer-file-name)))
      (should (= 6 (line-number-at-pos)))
      (should (= 25 (current-column)))     ; the e of "edge", under the ^
      (kill-buffer))
    (with-current-buffer "*kst compilation*"
      (goto-char (point-min))
      (forward-line 3)
      (let ((msg (progn (compilation--ensure-parse (point-max))
                        (get-text-property (point) 'compilation-message))))
        (should (= 1 (compilation--message->type msg))))     ; a warning
      (kill-buffer))))

(ert-deftest kitty-souffle-command-line ()
  "my-nvim's makeprg: souffle -F <dir> -D - <file>, run in the file's directory."
  (should (equal (mapconcat #'shell-quote-argument (list "souffle" "-F" "/w/my dir" "-D" "-" "path.dl") " ")
                 (kitty-souffle-command "/w/my dir/path.dl")))
  (should (string-match-p "-D - -j 4 path.dl\\'" (kitty-souffle-command "/w/path.dl" '("-j" "4")))))

(ert-deftest kitty-souffle-real-run ()
  "With souffle installed: SPC m m's command really runs the program."
  (skip-unless (executable-find "souffle"))
  (let* ((dir (kst--dir '(("path.dl" . ".decl edge(x: number, y: number)\n.input edge\n.decl path(x: number, y: number)\n.output path\npath(x, y) :- edge(x, y).\npath(x, z) :- path(x, y), edge(y, z).\n")
                          ("edge.facts" . "1\t2\n2\t3\n"))))
         (default-directory dir))
    (let ((out (shell-command-to-string (kitty-souffle-command (expand-file-name "path.dl" dir)))))
      (should (string-match-p "^1\t3$" out)))))

(ert-deftest kitty-souffle-indent ()
  "A rule's body is indented under its head; a full stop ends the rule."
  (with-temp-buffer
    (souffle-mode)
    (insert ".decl a(x: number)\nb(x) :-\na(x),\nc(x).\nd(1).\n")
    (indent-region (point-min) (point-max))
    (should (equal ".decl a(x: number)\nb(x) :-\n    a(x),\n    c(x).\nd(1).\n" (buffer-string)))))

(ert-deftest kitty-souffle-facts-keep-tabs ()
  "In .facts a Tab is a Tab, and a trailing one (an empty column) survives saving."
  (let* ((dir (kst--dir '(("e.facts" . ""))))
         (file (expand-file-name "e.facts" dir)))
    (with-current-buffer (find-file-noselect file)
      (should (eq major-mode 'souffle-facts-mode))
      (insert "a")
      (call-interactively #'souffle-facts-tab)
      (insert "b")
      (indent-for-tab-command)
      (insert "\n")
      (add-hook 'before-save-hook #'delete-trailing-whitespace)
      (unwind-protect (save-buffer)
        (remove-hook 'before-save-hook #'delete-trailing-whitespace))
      (kill-buffer))
    (should (equal "a\tb\t\n" (with-temp-buffer (insert-file-contents file) (buffer-string))))))

(ert-deftest kitty-souffle-comments ()
  "// comments, for gcc."
  (with-temp-buffer
    (souffle-mode)
    (insert "a(1).")
    (comment-region (point-min) (point-max))
    (should (equal "// a(1)." (buffer-string)))))

(provide 'kitty-souffle-test)
;;; kitty-souffle-test.el ends here
