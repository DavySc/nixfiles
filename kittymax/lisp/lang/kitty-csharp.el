;;; kitty-csharp.el --- C# on modern .NET, in place of Visual Studio  -*- lexical-binding: t; -*-

;;; Commentary:

;; csharp-ts-mode (tree-sitter), csharp-ls as the language server (go to
;; definition, references, rename, code actions, diagnostics, formatting on
;; save), and the dotnet CLI from SPC m.  What Visual Studio's windows did:
;;
;;   SPC m m  build           the solution (or project) the buffer belongs to;
;;                             errors and warnings are jumps (]d / M-g n)
;;   SPC m r  run             the buffer's project (C-u: pick another one)
;;   SPC m t  test at point   the test method under the cursor (Test Explorer)
;;   SPC m T  test file       the class under the cursor;  SPC m A all tests
;;   SPC m l  test again      the last test run
;;   SPC m d  debug           build, then start under netcoredbg (dape)
;;   SPC m w  watch           dotnet watch run (hot reload)
;;   SPC m p  add package     NuGet;   SPC m R restore
;;   SPC m s  projects        open a project of the solution (Solution Explorer)
;;   SPC m o  organize usings;  SPC m f format
;;
;; netcoredbg comes from PATH or kittymax's debug-adapters directory
;; (windows/install.ps1 puts it there).

;;; Code:

(require 'kitty-lib)
(require 'compile)
(require 'subr-x)
(require 'seq)

(declare-function treesit-node-parent "treesit")
(declare-function treesit-node-type "treesit")
(declare-function treesit-node-at "treesit")
(declare-function treesit-node-child-by-field-name "treesit")
(declare-function treesit-node-text "treesit")
(declare-function treesit-parser-list "treesit")
(declare-function dape "dape")
(defvar dape-configs)

(setq csharp-ts-mode-indent-offset 4)

(add-to-list 'auto-mode-alist '("\\.\\(csproj\\|fsproj\\|vcxproj\\|props\\|targets\\|slnx\\)\\'" . nxml-mode))
(add-to-list 'auto-mode-alist '("\\.cs\\'" . csharp-ts-mode))

(defun kitty--csharp-setup ()
  (kitty-eglot-ensure-for "csharp-ls")
  (setq-local fill-column 120
              tab-width 4
              indent-tabs-mode nil)
  ;; Format through the language server before saving.
  (add-hook 'before-save-hook
            (lambda ()
              (when (and (fboundp 'eglot-managed-p) (eglot-managed-p))
                (ignore-errors (eglot-format-buffer))))
            nil t))
(kitty-add-hook 'csharp-ts-mode-hook #'kitty--csharp-setup)
(kitty-add-hook 'csharp-mode-hook #'kitty--csharp-setup)

;;;; Errors from MSBuild (dotnet, msbuild, cl.exe, csc)
;;
;;   C:\src\App\Program.cs(5,27): warning CS8602: Dereference ... [C:\src\App\App.csproj]
;;   2>C:\src\lib\util.c(10): error C2143: syntax error: missing ';' before '}'
;;   at App.Tests.MathTests.Adds() in C:\src\App.Tests\MathTests.cs:line 14

(defconst kitty-msbuild-error-regexp
  (concat "^[ \t]*\\(?:[0-9]+>\\)?"
          "\\(?1:\\(?:[A-Za-z]:\\)?[^ \t\n:(][^:(\n]*?\\)"
          "(\\(?2:[0-9]+\\)\\(?:,\\(?3:[0-9]+\\)\\(?:,[0-9]+,[0-9]+\\)?\\)?)"
          " ?: \\(?:\\(?:fatal \\)?error\\|\\(?4:warning\\)\\|\\(?5:info\\|message\\|note\\)\\)"
          " \\(?:[A-Z]+[0-9]+\\)?")
  "file(line[,col]): error|warning|info CODE: as MSBuild, csc and cl print them.")

(defconst kitty-dotnet-test-trace-regexp
  "^[ \t]+at .+ in \\(?1:.+\\):line \\(?2:[0-9]+\\)$"
  "A stack frame in a failed test: at Ns.Class.Method() in FILE:line N.")

(with-eval-after-load 'compile
  (setf (alist-get 'kitty-msbuild compilation-error-regexp-alist-alist)
        (list kitty-msbuild-error-regexp 1 2 3 '(4 . 5)))
  (setf (alist-get 'kitty-dotnet-test compilation-error-regexp-alist-alist)
        (list kitty-dotnet-test-trace-regexp 1 2 nil 2))
  (add-to-list 'compilation-error-regexp-alist 'kitty-msbuild)
  (add-to-list 'compilation-error-regexp-alist 'kitty-dotnet-test))

;;;; Solutions and projects

(defun kitty-csharp--files-here (dir regexp)
  (and (file-directory-p dir) (directory-files dir t regexp)))

(defun kitty-csharp-solution (&optional dir)
  "The solution (.sln, .slnx) above DIR, else the project (.csproj) above it.
When a directory holds several, the first in name order."
  (let ((dir (expand-file-name (or dir default-directory))))
    (or (when-let* ((d (locate-dominating-file dir (lambda (d) (kitty-csharp--files-here d "\\.slnx?\\'")))))
          (car (kitty-csharp--files-here d "\\.slnx?\\'")))
        (kitty-csharp-project dir))))

(defun kitty-csharp-project (&optional dir)
  "The .csproj (or .fsproj) of the code in DIR: the nearest one above it."
  (let ((dir (expand-file-name (or dir default-directory))))
    (when-let* ((d (locate-dominating-file dir (lambda (d) (kitty-csharp--files-here d "\\.[cf]sproj\\'")))))
      (car (kitty-csharp--files-here d "\\.[cf]sproj\\'")))))

(defun kitty-csharp-solution-projects (solution)
  "The projects of SOLUTION (a .sln, .slnx or a project file itself), absolute."
  (kitty-solution-projects solution))

(defun kitty-csharp--read-project (prompt solution)
  (let* ((projects (seq-filter (lambda (p) (string-match-p "\\.[cf]sproj\\'" p))
                               (kitty-csharp-solution-projects solution)))
         (root (file-name-directory solution)))
    (unless projects (user-error "No projects in %s" solution))
    (expand-file-name (completing-read prompt (mapcar (lambda (p) (file-relative-name p root)) projects) nil t)
                      root)))

;;;; dotnet

(defvar kitty-csharp-configuration "Debug" "The configuration dotnet builds and runs.")

(defun kitty-csharp-dotnet (args &optional comint dir)
  "Run `dotnet ARGS' (a list) in DIR (the solution's directory) as a compilation.
COMINT: an interactive buffer (for run and watch)."
  (let* ((solution (kitty-csharp-solution))
         (default-directory (or dir (and solution (file-name-directory solution)) (kitty-project-root)))
         ;; Plain lines, not .NET 9's live terminal output.
         (compilation-environment (cons "MSBUILDTERMINALLOGGER=off" compilation-environment)))
    (compile (mapconcat #'shell-quote-argument (cons "dotnet" args) " ") comint)))

(defun kitty-csharp--target ()
  (or (kitty-csharp-solution) (user-error "No .sln, .slnx or .csproj above this file")))

(defun kitty-csharp-build ()
  "Build the solution (or the project) this buffer belongs to."
  (interactive)
  (kitty-csharp-dotnet (list "build" (kitty-csharp--target) "-nologo" "-clp:NoSummary"
                             "-c" kitty-csharp-configuration)))

(defun kitty-csharp-run (&optional pick)
  "Run this buffer's project (PICK, with C-u: choose one of the solution's)."
  (interactive "P")
  (let ((project (if (or pick (not (kitty-csharp-project)))
                     (kitty-csharp--read-project "Run project: " (kitty-csharp--target))
                   (kitty-csharp-project))))
    (kitty-csharp-dotnet (list "run" "--project" project "-c" kitty-csharp-configuration) t)))

(defun kitty-csharp-watch ()
  "dotnet watch run: rebuilds and hot-reloads on save."
  (interactive)
  (kitty-csharp-dotnet (list "watch" "--project" (or (kitty-csharp-project) (kitty-csharp--target)) "run") t))

(defun kitty-csharp-restore () "Restore packages." (interactive)
       (kitty-csharp-dotnet (list "restore" (kitty-csharp--target))))

(defun kitty-csharp-add-package (name)
  "Add NuGet package NAME to this buffer's project."
  (interactive "sNuGet package: ")
  (kitty-csharp-dotnet (list "add" (or (kitty-csharp-project) (user-error "No project here")) "package" name)))

(defun kitty-csharp-open-project ()
  "Open one of the solution's projects (Visual Studio's Solution Explorer)."
  (interactive)
  (let ((project (kitty-csharp--read-project "Project: " (kitty-csharp--target))))
    (dired (file-name-directory project))))

;;;; Tests (Visual Studio's Test Explorer)

(defvar kitty-csharp--last-test nil "(DIR . ARGS) of the last dotnet test run.")

(defun kitty-csharp--enclosing (types)
  "Names of the enclosing tree-sitter nodes of TYPES, innermost first."
  (when (and (fboundp 'treesit-parser-list) (treesit-parser-list))
    (let ((node (treesit-node-at (point))) names)
      (while node
        (when (member (treesit-node-type node) types)
          (when-let* ((name (treesit-node-child-by-field-name node "name")))
            (push (cons (treesit-node-type node) (treesit-node-text name t)) names)))
        (setq node (treesit-node-parent node)))
      (nreverse names))))

(defun kitty-csharp-test-name (&optional class-only)
  "Namespace.Class.Method of the test under the cursor (CLASS-ONLY: Namespace.Class)."
  (let* ((found (kitty-csharp--enclosing '("method_declaration" "class_declaration" "record_declaration"
                                            "namespace_declaration")))
         (method (cdr (assoc "method_declaration" found)))
         (classes (mapcar #'cdr (seq-filter (lambda (f) (member (car f) '("class_declaration" "record_declaration")))
                                            found)))
         (ns (or (cdr (assoc "namespace_declaration" found))
                 (save-excursion
                   (goto-char (point-min))
                   (and (re-search-forward "^[ \t]*namespace[ \t]+\\([[:alnum:]_.]+\\)[ \t]*;" nil t)
                        (match-string-no-properties 1))))))
    (unless classes
      ;; Without tree-sitter: the nearest class and method above.
      (save-excursion
        (when (and (not class-only)
                   (re-search-backward "^[ \t]*\\(?:public\\|internal\\|private\\|protected\\)[^=;\n(]*[ \t]\\([[:alpha:]_][[:alnum:]_]*\\)[ \t]*(" nil t))
          (setq method (match-string-no-properties 1)))
        (when (re-search-backward "\\_<\\(?:class\\|record\\)[ \t]+\\([[:alpha:]_][[:alnum:]_]*\\)" nil t)
          (setq classes (list (match-string-no-properties 1))))))
    (unless classes (user-error "No test class here"))
    (string-join (delq nil (append (list ns) (reverse classes) (list (and (not class-only) method)))) ".")))

(defun kitty-csharp--test (filter)
  (let* ((project (or (kitty-csharp-project) (kitty-csharp--target)))
         (args (append (list "test" project "-nologo" "-c" kitty-csharp-configuration)
                       (and filter (list "--filter" (concat "FullyQualifiedName~" filter))))))
    (setq kitty-csharp--last-test (cons (file-name-directory project) args))
    (kitty-csharp-dotnet args nil (file-name-directory project))))

(defun kitty-csharp-test-at-point ()
  "Run the test method under the cursor."
  (interactive)
  (kitty-csharp--test (kitty-csharp-test-name)))

(defun kitty-csharp-test-class ()
  "Run the tests of the class under the cursor."
  (interactive)
  (kitty-csharp--test (kitty-csharp-test-name t)))

(defun kitty-csharp-test-all ()
  "Run every test of the solution."
  (interactive)
  (setq kitty-csharp--last-test nil)
  (kitty-csharp-dotnet (list "test" (kitty-csharp--target) "-nologo" "-c" kitty-csharp-configuration)))

(defun kitty-csharp-test-last ()
  "Run the last tests again."
  (interactive)
  (if kitty-csharp--last-test
      (kitty-csharp-dotnet (cdr kitty-csharp--last-test) nil (car kitty-csharp--last-test))
    (kitty-csharp-test-all)))

;;;; Debugging: netcoredbg through dape

(defun kitty-debug-adapter (name &rest parts)
  "Debug adapter NAME: on PATH, else under kittymax's debug-adapters/PARTS."
  (or (executable-find name)
      (let ((f (apply #'file-name-concat kitty-data-dir "debug-adapters" parts)))
        (seq-find #'file-executable-p (list f (concat f ".exe"))))))

(defun kitty-csharp-target-path (project)
  "The assembly PROJECT builds (bin/Debug/net10.0/App.dll), as MSBuild says."
  (with-temp-buffer
    (let ((process-environment (cons "MSBUILDTERMINALLOGGER=off" process-environment)))
      (unless (zerop (call-process "dotnet" nil t nil "msbuild" project "-nologo"
                                   "-getProperty:TargetPath" (concat "-p:Configuration=" kitty-csharp-configuration)))
        (user-error "dotnet msbuild failed: %s" (string-trim (buffer-string)))))
    (string-trim (buffer-string))))

(defun kitty-csharp-debug (&optional pick)
  "Build this buffer's project (PICK: choose one), then debug it with netcoredbg."
  (interactive "P")
  (require 'dape)
  (let* ((project (if (or pick (not (kitty-csharp-project)))
                      (kitty-csharp--read-project "Debug project: " (kitty-csharp--target))
                    (kitty-csharp-project)))
         (adapter (or (kitty-debug-adapter "netcoredbg" "netcoredbg" "netcoredbg")
                      (user-error "netcoredbg not found (windows/install.ps1 installs it)")))
         (program (kitty-csharp-target-path project))
         (dir (file-name-directory project)))
    (dape `(modes (csharp-mode csharp-ts-mode)
                  command ,adapter
                  command-args ["--interpreter=vscode"]
                  compile ,(format "dotnet build %s -nologo -c %s" (shell-quote-argument project)
                                   kitty-csharp-configuration)
                  command-cwd ,dir
                  :type "coreclr" :request "launch"
                  :cwd ,dir :program ,program :stopAtEntry nil))))

;;;; Keys

(dolist (mode '(csharp-mode csharp-ts-mode))
  (kitty-local-leader mode
    "m" '("build" . kitty-csharp-build)
    "r" '("run" . kitty-csharp-run)
    "d" '("debug (netcoredbg)" . kitty-csharp-debug)
    "t" '("test at point" . kitty-csharp-test-at-point)
    "T" '("test class" . kitty-csharp-test-class)
    "A" '("all tests" . kitty-csharp-test-all)
    "l" '("last test again" . kitty-csharp-test-last)
    "w" '("watch (hot reload)" . kitty-csharp-watch)
    "R" '("restore" . kitty-csharp-restore)
    "p" '("add package" . kitty-csharp-add-package)
    "s" '("open project" . kitty-csharp-open-project)
    "f" '("format" . kitty-format)
    "o" '("organize usings" . eglot-code-action-organize-imports)))

(provide 'kitty-csharp)
;;; kitty-csharp.el ends here
