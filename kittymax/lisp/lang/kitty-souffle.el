;;; kitty-souffle.el --- Soufflé (Datalog)  -*- lexical-binding: t; -*-

;;; Commentary:

;; souffle-mode for .dl programs, as my-nvim has them (syntax/souffle.vim,
;; ftplugin/souffle.lua):
;;
;;   SPC m m   souffle checks and runs the program; errors and warnings are
;;             jumps to their line and column (]d / M-g n)
;;   SPC m r   run it in an interactive buffer: facts from the file's
;;             directory (-F), output relations printed (-D -); C-u asks for
;;             more arguments (my-nvim's :SouffleRun [args])
;;
;; .facts files (souffle-facts-mode) are Tab-separated: a typed Tab stays a
;; Tab, Tabs are shown, and trailing whitespace is kept (a trailing Tab is an
;; empty last column).
;;
;; souffle prints only the file's name in its messages ("in file path.dl"),
;; so it runs in the file's directory, where that name resolves.

;;; Code:

(require 'kitty-lib)
(require 'compile)

(add-to-list 'auto-mode-alist '("\\.\\(dl\\|souffle\\)\\'" . souffle-mode))
(add-to-list 'auto-mode-alist '("\\.facts\\'" . souffle-facts-mode))

;;;; Highlighting, as syntax/souffle.vim

(defconst souffle-font-lock-keywords
  `((,(concat "^[ \t]*\\(\\.\\(?:decl\\|type\\|comp\\|init\\|input\\|output\\|printsize\\|limitsize"
              "\\|pragma\\|functor\\|plan\\|override\\)\\)\\_>")
     1 font-lock-keyword-face)
    ("^[ \t]*\\.\\(?:decl\\|type\\|comp\\|init\\|functor\\)[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)"
     1 font-lock-function-name-face)
    ("^[ \t]*#\\(?:include\\|define\\|ifdef\\|ifndef\\|if\\|else\\|endif\\|undef\\)\\_>.*"
     0 font-lock-preprocessor-face)
    (,(regexp-opt '("choice-domain" "inline" "no_inline" "magic" "no_magic" "brie" "btree" "btree_delete" "eqrel"
                    "cat" "ord" "strlen" "substr" "to_number" "to_string" "to_float" "to_unsigned"
                    "match" "contains" "min" "max" "sum" "count" "mean" "range" "as" "nil")
                  'symbols)
     . font-lock-keyword-face)
    (,(regexp-opt '("band" "bor" "bxor" "bnot" "bshl" "bshr" "bshru" "land" "lor" "lxor" "lnot") 'symbols)
     . font-lock-builtin-face)
    (,(regexp-opt '("number" "unsigned" "float" "symbol") 'symbols) . font-lock-type-face)
    (,(regexp-opt '("true" "false") 'symbols) . font-lock-constant-face)
    ("\\_<\\(?:0x[[:xdigit:]]+\\|0b[01]+\\|[0-9]+\\(?:\\.[0-9]+\\)?\\)\\_>" . font-lock-constant-face)
    ("\\_<_\\_>" . font-lock-builtin-face)
    (":-\\|!=\\|<=\\|>=\\|[=<>!]" . font-lock-keyword-face))
  "souffle-mode's highlighting: syntax/souffle.vim's groups.")

(defvar souffle-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?/ ". 124b" st)
    (modify-syntax-entry ?* ". 23" st)
    (modify-syntax-entry ?\n "> b" st)
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?_ "_" st)
    (modify-syntax-entry ?. "." st)
    st)
  "// and /* */ comments, \"strings\".")

;;;; Indentation: a rule's body is indented under its head

(defvar souffle-indent-offset 4 "Indentation of a rule's body lines.")

(defun souffle-indent-line ()
  "Indent a line: 0 for a statement, `souffle-indent-offset' inside a rule.
A rule goes on until the line that ends with a full stop."
  (interactive)
  (let ((indent
         (save-excursion
           (beginning-of-line)
           (if (or (bobp) (looking-at-p "[ \t]*[.#]")) 0
             (forward-line -1)
             (while (and (not (bobp)) (looking-at-p "[ \t]*\\(?://.*\\)?$")) (forward-line -1))
             ;; a directive (.decl ...) or #include is a whole statement
             (if (looking-at-p "[ \t]*[.#]") 0
             (end-of-line)
             (skip-chars-backward " \t")
             ;; a comment at the end of the line does not end it
             (let ((code-end (save-excursion
                               (beginning-of-line)
                               (if (re-search-forward "//" (line-end-position) t) (match-beginning 0) (line-end-position)))))
               (goto-char code-end)
               (skip-chars-backward " \t"))
             (if (or (bobp) (memq (char-before) '(?. ?\n))) 0 souffle-indent-offset))))))
    (if (<= (current-column) (current-indentation))
        (indent-line-to indent)
      (save-excursion (indent-line-to indent)))))

;;;###autoload
(define-derived-mode souffle-mode prog-mode "Soufflé"
  "Soufflé Datalog programs."
  (setq-local font-lock-defaults '(souffle-font-lock-keywords))
  (setq-local comment-start "// "
              comment-end ""
              comment-start-skip "\\(?://+\\|/\\*+\\)[ \t]*"
              indent-line-function #'souffle-indent-line
              tab-width 4
              indent-tabs-mode nil))

;;;; .facts

(defvar-keymap souffle-facts-mode-map
  "TAB" #'souffle-facts-tab)

(defun souffle-facts-tab ()
  "Insert a Tab: the column separator."
  (interactive)
  (insert "\t"))

;;;###autoload
(define-derived-mode souffle-facts-mode text-mode "Facts"
  "Soufflé input facts: one per line, columns separated by Tabs."
  (setq-local indent-tabs-mode t
              tab-width 16
              indent-line-function #'souffle-facts-tab
              whitespace-style '(face tabs tab-mark trailing)
              whitespace-display-mappings '((tab-mark ?\t [?→ ?\t])))
  (electric-indent-local-mode -1)
  (whitespace-mode 1))

;; A trailing Tab is an empty last column, not whitespace to clean up on save.
(defun kitty--souffle-facts-keep-trailing (orig &rest args)
  "`delete-trailing-whitespace' (on save) leaves .facts files alone."
  (unless (derived-mode-p 'souffle-facts-mode)
    (apply orig args)))
(advice-add 'delete-trailing-whitespace :around #'kitty--souffle-facts-keep-trailing)

;;;; Check and run

(defconst kitty-souffle-error-regexp
  "^\\(?:Error\\|\\(?4:Warning\\)\\): .* in file \\(?1:.+?\\) at line \\(?2:[0-9]+\\)"
  "Error: <msg> in file <f> at line <l>, as souffle 2.5 prints it.")

(defun kitty-souffle--column ()
  "The column (1-based) of the ^ two lines below the message, or nil.
souffle prints the source line, then ---^ under the column."
  (save-match-data
    (save-excursion
      (goto-char (match-end 0))
      (forward-line 2)
      (and (looking-at "\\(-*\\)\\^") (1+ (length (match-string 1)))))))

(with-eval-after-load 'compile
  (setf (alist-get 'kitty-souffle compilation-error-regexp-alist-alist)
        (list kitty-souffle-error-regexp 1 2 #'kitty-souffle--column '(4)))
  (add-to-list 'compilation-error-regexp-alist 'kitty-souffle))

(defun kitty-souffle-command (file &optional args)
  "souffle's command line for FILE: facts from its directory, output to stdout."
  (mapconcat #'shell-quote-argument
             (append (list "souffle" "-F" (directory-file-name (file-name-directory file)) "-D" "-")
                     args (list (file-name-nondirectory file)))
             " "))

(defun kitty-souffle--file ()
  (let ((file (or buffer-file-name (user-error "souffle: this buffer is not a file"))))
    (when (buffer-modified-p) (save-buffer))
    file))

(defun kitty-souffle-make ()
  "Check and run the program; errors go to *compilation* (my-nvim's :make)."
  (interactive)
  (let* ((file (kitty-souffle--file))
         (default-directory (file-name-directory file)))
    (compile (kitty-souffle-command file))))

(defun kitty-souffle-run (&optional args)
  "Run the program in an interactive buffer; C-u asks for ARGS (my-nvim's :SouffleRun)."
  (interactive (list (and current-prefix-arg (split-string-and-unquote (read-string "souffle args: ")))))
  (let* ((file (kitty-souffle--file))
         (default-directory (file-name-directory file)))
    (compile (kitty-souffle-command file args) t)))

(kitty-local-leader 'souffle-mode
  "m" '("check and run" . kitty-souffle-make)
  "r" '("run" . kitty-souffle-run))

(with-eval-after-load 'evil
  (declare-function evil-ex-define-cmd "evil-ex")
  (evil-ex-define-cmd "SouffleRun" #'kitty-souffle-run))

(provide 'kitty-souffle)
;;; kitty-souffle.el ends here
