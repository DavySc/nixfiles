;;; kitty-ob-csharp.el --- org babel for C#, through .NET 10's file-based apps  -*- lexical-binding: t; -*-

;;; Commentary:

;; #+begin_src csharp
;;   var xs = new[] { 1, 2, 3 };
;;   Console.WriteLine(string.Join(", ", xs.Select(x => x * x)));
;; #+end_src
;;
;; The block is top-level C# (statements, local functions, types after
;; them, or a class with Main), run with `dotnet run --file' (the .NET 10
;; SDK): no project.  Implicit usings are on (System, System.Linq, ...).
;;
;; Org 9.8 has its own ob-csharp, which writes and builds a new project for
;; every run (seconds each time).  This one replaces its execute function:
;; each distinct block is compiled once and kept in the cache, so running it
;; again takes a fraction of a second.  Header arguments (org's forms work):
;;
;;   :usings "System.Text.Json System.Net.Http"   (or a list) extra usings
;;   :package "Humanizer@2.14.1 Dapper@2.1.35"   NuGet packages (#:package)
;;   :framework net10.0                          the target framework
;;   :cmdline "a b"                              the program's arguments
;;   :var n=5 :var t=some-table   variables (numbers, strings, lists, tables)
;;
;; The result is what the block prints; :results table reads Tab-separated
;; lines as a table.

;;; Code:

(require 'ob)
(require 'subr-x)
;; org's own first, so that the definitions below are the ones that stay
(require 'ob-csharp nil t)

(defvar kitty-cache-dir)
(defvar org-babel-default-header-args:csharp)
(defvar org-babel-header-args:csharp)
(setq org-babel-default-header-args:csharp '((:results . "output"))
      org-babel-header-args:csharp '((usings . :any) (package . :any) (framework . :any) (cmdline . :any)))

(add-to-list 'org-babel-tangle-lang-exts '("csharp" . "cs"))
(add-to-list 'org-src-lang-modes '("csharp" . csharp))

(defun kitty-ob-csharp--value (v)
  "V (a babel value) as a C# expression."
  (cond ((integerp v) (number-to-string v))
        ((floatp v) (format "%sd" v))
        ((stringp v)
         (concat "\""
                 (mapconcat (lambda (c)
                              (pcase c
                                (?\" "\\\"") (?\\ "\\\\") (?\n "\\n") (?\r "\\r") (?\t "\\t")
                                (_ (string c))))
                            v "")
                 "\""))
        ((null v) "null")
        ((symbolp v) (kitty-ob-csharp--value (symbol-name v)))
        ((and (listp v) (seq-every-p #'listp (remq 'hline v)))
         ;; a table: rows of cells, as object[][]
         (concat "new object[][] {"
                 (mapconcat (lambda (row) (concat "new object[] {" (mapconcat #'kitty-ob-csharp--value row ", ") "}"))
                            (remq 'hline v) ", ")
                 "}"))
        ((listp v)
         (let ((type (cond ((seq-every-p #'integerp v) "long")
                           ((seq-every-p #'numberp v) "double")
                           ((seq-every-p #'stringp v) "string")
                           (t "object"))))
           (format "new %s[] {%s}" type (mapconcat #'kitty-ob-csharp--value v ", "))))
        (t (kitty-ob-csharp--value (format "%s" v)))))

(defun kitty-ob-csharp--words (v)
  "V, a header argument: a string of words or a list (org's form), as strings."
  (cond ((null v) nil)
        ((stringp v) (split-string v nil t))
        ((listp v) (mapcar (lambda (x) (format "%s" x)) v))
        (t (list (format "%s" v)))))

(defun org-babel-expand-body:csharp (body params)
  "BODY with the directives, usings and variables PARAMS ask for."
  (when (cdr (assq :references params))
    (user-error "C# blocks take :package (NuGet), not :references"))
  (let ((packages (kitty-ob-csharp--words (cdr (assq :package params))))
        (usings (kitty-ob-csharp--words (cdr (assq :usings params))))
        (framework (cdr (assq :framework params)))
        (vars (org-babel--get-vars params)))
    (concat
     ;; #: directives come first in a file-based app
     (if framework (format "#:property TargetFramework=%s\n" framework) "")
     (mapconcat (lambda (p) (format "#:package %s\n" p)) packages "")
     (mapconcat (lambda (u) (format "using %s;\n" (string-remove-suffix ";" u))) usings "")
     (mapconcat (lambda (v) (format "var %s = %s;\n" (car v) (kitty-ob-csharp--value (cdr v)))) vars "")
     body
     "\n")))

(defun kitty-ob-csharp--file (code)
  "A file holding CODE, named by its contents (so a rerun is not rebuilt)."
  (let* ((dir (expand-file-name "ob-csharp" (if (boundp 'kitty-cache-dir) kitty-cache-dir temporary-file-directory)))
         (file (expand-file-name (format "block_%s.cs" (substring (secure-hash 'sha1 code) 0 16)) dir)))
    (make-directory dir t)
    (unless (file-exists-p file)
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file file (insert code))))
    file))

(defun org-babel-execute:csharp (body params)
  "Run C# BODY with `dotnet run --file' and return what it prints."
  (unless (executable-find "dotnet")
    (user-error "C# blocks need the .NET 10 SDK (dotnet) on PATH"))
  (let* ((code (org-babel-expand-body:csharp body params))
         (file (kitty-ob-csharp--file code))
         ;; Not in a project's directory: `dotnet run' would pick its project.
         (default-directory (file-name-directory file))
         (process-environment (append '("DOTNET_NOLOGO=1" "DOTNET_CLI_TELEMETRY_OPTOUT=1") process-environment))
         (cmdline (cdr (assq :cmdline params)))
         (out (org-babel-eval (concat "dotnet run --file " (shell-quote-argument file)
                                      (if cmdline (concat " -- " cmdline) ""))
                              "")))
    (org-babel-reassemble-table
     (org-babel-result-cond (cdr (assq :result-params params))
       out
       (let ((tmp (org-babel-temp-file "csharp-")))
         (with-temp-file tmp (insert out))
         (org-babel-import-elisp-from-file tmp)))
     (org-babel-pick-name (cdr (assq :colname-names params)) (cdr (assq :colnames params)))
     (org-babel-pick-name (cdr (assq :rowname-names params)) (cdr (assq :rownames params))))))

(defun org-babel-prep-session:csharp (_session _params)
  "C# blocks have no sessions."
  (user-error "C# blocks have no sessions"))

(provide 'kitty-ob-csharp)
;;; kitty-ob-csharp.el ends here
