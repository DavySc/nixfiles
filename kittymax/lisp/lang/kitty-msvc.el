;;; kitty-msvc.el --- Visual Studio's C toolchain, without the IDE  -*- lexical-binding: t; -*-

;;; Commentary:

;; C projects that Visual Studio made (.sln + .vcxproj) build and index
;; without Visual Studio running: only its compiler and MSBuild are used
;; (the "Build Tools for Visual Studio" are enough).
;;
;; - The compiler's environment (cl.exe, INCLUDE, LIB: what the "Developer
;;   Command Prompt" sets) is read once from vcvarsall.bat and kept in the
;;   cache, so CMake with Ninja and `make' find cl.exe too.
;; - MSBuild builds the solution; its errors are jumps (kitty-csharp.el's
;;   regexp covers cl.exe's file(line,col): error C2143).
;; - compile_commands.json for clangd comes from MSBuild's own evaluation of
;;   each .vcxproj (msbuild -getItem:ClCompile): the include paths, defines,
;;   C standard and forced includes per file, property sheets included,
;;   with nothing built.  Run it again (SPC m g) after changing them.
;;
;; Visual Studio itself is found with vswhere, which its installer puts in a
;; fixed place.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)
(require 'seq)
(require 'cl-lib)
(require 'json)

(declare-function eglot-current-server "eglot")
(declare-function eglot-reconnect "eglot")

(defvar kitty-msvc-arch (if (string-match-p "\\`\\(aarch64\\|arm64\\)" system-configuration) "arm64" "x64")
  "The target architecture vcvarsall.bat sets the environment up for.")

(defvar kitty-msvc-configuration "Debug" "The configuration MSBuild builds.")

(defvar kitty-msvc-platform "x64"
  "The solution platform MSBuild builds (x64, x86 ...); a project's own is
Win32 where the solution says x86.")

;;;; Finding Visual Studio

(defun kitty-msvc-vswhere ()
  "vswhere.exe, which the Visual Studio installer keeps in a fixed place."
  (or (executable-find "vswhere")
      (let ((f (expand-file-name "Microsoft Visual Studio/Installer/vswhere.exe"
                                 (or (getenv "ProgramFiles(x86)") "C:/Program Files (x86)"))))
        (and (file-exists-p f) f))))

(defun kitty-msvc--vswhere (&rest args)
  "The first line vswhere prints for ARGS, or nil."
  (when-let* ((vswhere (kitty-msvc-vswhere)))
    (with-temp-buffer
      (when (zerop (apply #'call-process vswhere nil t nil
                          "-latest" "-prerelease" "-products" "*" "-utf8" args))
        (let ((line (car (split-string (buffer-string) "[\r\n]+" t))))
          (and line (not (string-empty-p line)) line))))))

(defun kitty-msvc-installation ()
  "Where the newest Visual Studio (or Build Tools) with the C compiler is."
  (kitty-msvc--vswhere "-requires" "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
                       "-property" "installationPath"))

(defun kitty-msvc-msbuild ()
  "MSBuild.exe: on PATH, else Visual Studio's."
  (or (executable-find "msbuild")
      (kitty-msvc--vswhere "-requires" "Microsoft.Component.MSBuild"
                           "-find" "MSBuild\\**\\Bin\\MSBuild.exe")
      (user-error "MSBuild not found: install Visual Studio or its Build Tools (with the C++ workload)")))

;;;; The compiler's environment

(defun kitty-msvc-parse-env (text)
  "The NAME=VALUE lines of TEXT (the output of `set') as an alist."
  (let (env)
    (dolist (line (split-string text "[\r\n]+" t))
      (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" line)
        (push (cons (match-string 1 line) (match-string 2 line)) env)))
    (nreverse env)))

(defun kitty-msvc--env-cache (installation)
  (expand-file-name (format "msvc-env-%s-%s.eld" kitty-msvc-arch (md5 installation)) kitty-cache-dir))

(defun kitty-msvc-read-env (installation)
  "The environment vcvarsall.bat sets up in INSTALLATION (cached)."
  (let ((cache (kitty-msvc--env-cache installation)))
    (if (file-exists-p cache)
        (with-temp-buffer (insert-file-contents cache) (read (current-buffer)))
      (let* ((bat (expand-file-name "VC/Auxiliary/Build/vcvarsall.bat" installation))
             (env (with-temp-buffer
                    (message "kittymax: reading the MSVC environment (once) ...")
                    ;; Through the shell (cmd), whose quoting this is: call-process would
                    ;; escape the quotes for a C program, which cmd does not read.
                    (unless (zerop (call-process-shell-command
                                    (format "call \"%s\" %s >nul 2>&1 && set"
                                            (subst-char-in-string ?/ ?\\ bat) kitty-msvc-arch)
                                    nil t))
                      (user-error "vcvarsall.bat failed: %s" (buffer-string)))
                    (kitty-msvc-parse-env (buffer-string)))))
        (unless (assoc-string "INCLUDE" env t)
          (user-error "vcvarsall.bat set no INCLUDE: is the C++ workload installed?"))
        (with-temp-file cache (prin1 env (current-buffer)))
        env))))

(defun kitty-msvc-apply-env (env)
  "Make Emacs and the programs it starts use ENV (from `kitty-msvc-read-env')."
  (dolist (pair env)
    (setenv (car pair) (cdr pair)))
  (when-let* ((path (cdr (assoc-string "PATH" env t))))
    (setq exec-path (append (parse-colon-path path) (list exec-directory)))))

(defun kitty-msvc-ensure-env ()
  "On Windows, give Emacs the MSVC environment unless cl.exe is already found."
  (when (and (eq system-type 'windows-nt) (not (executable-find "cl")))
    (if-let* ((installation (kitty-msvc-installation)))
        (progn (kitty-msvc-apply-env (kitty-msvc-read-env installation)) t)
      (message "kittymax: no Visual Studio with the C compiler found (vswhere)")
      nil)))

(defun kitty-msvc-refresh-env ()
  "Read the MSVC environment again (after a Visual Studio update)."
  (interactive)
  (when-let* ((installation (kitty-msvc-installation)))
    (ignore-errors (delete-file (kitty-msvc--env-cache installation)))
    (kitty-msvc-apply-env (kitty-msvc-read-env installation))
    (message "kittymax: MSVC environment read again")))

;;;; Solutions and projects

(defun kitty-msvc-solution (&optional dir)
  "The .sln / .slnx holding C++ projects above DIR, else the .vcxproj above it."
  (let ((dir (expand-file-name (or dir default-directory))))
    (or (when-let* ((d (locate-dominating-file
                        dir (lambda (d) (and (file-directory-p d) (directory-files d nil "\\.slnx?\\'"))))))
          (seq-find (lambda (sln) (seq-some (lambda (p) (string-suffix-p ".vcxproj" p)) (kitty-solution-projects sln)))
                    (directory-files d t "\\.slnx?\\'")))
        (when-let* ((d (locate-dominating-file
                        dir (lambda (d) (and (file-directory-p d) (directory-files d nil "\\.vcxproj\\'"))))))
          (car (directory-files d t "\\.vcxproj\\'"))))))

(defun kitty-msvc-projects (solution)
  "The .vcxproj files of SOLUTION."
  (seq-filter (lambda (p) (string-suffix-p ".vcxproj" p)) (kitty-solution-projects solution)))

(defun kitty-msvc-project-platform (platform)
  "A solution PLATFORM as a C++ project names it (x86 is Win32)."
  (if (equal (downcase platform) "x86") "Win32" platform))

(defun kitty-msvc-evaluate (vcxproj &optional properties)
  "MSBuild's evaluation of VCXPROJ: its ClCompile items and PROPERTIES.
A plist (:Properties (...) :Items (:ClCompile [...])); nothing is built."
  (with-temp-buffer
    (let ((status (call-process (kitty-msvc-msbuild) nil t nil vcxproj "-nologo"
                                "-getItem:ClCompile"
                                (concat "-getProperty:" (string-join (or properties '("IncludePath" "ExternalIncludePath"
                                                                                       "TargetPath" "ConfigurationType"))
                                                                     ","))
                                (concat "-p:Configuration=" kitty-msvc-configuration)
                                (concat "-p:Platform=" (kitty-msvc-project-platform kitty-msvc-platform)))))
      (goto-char (point-min))
      (unless (and (zerop status) (re-search-forward "^{" nil t))
        (user-error "msbuild could not evaluate %s: %s" (file-name-nondirectory vcxproj)
                    (string-trim (buffer-string))))
      (goto-char (match-beginning 0))
      (json-parse-buffer :object-type 'plist :null-object nil :false-object nil))))

;;;; compile_commands.json from the evaluation

(defun kitty-msvc--list (value)
  "A ;-separated MSBuild list, without empty and %(...) entries."
  (seq-remove (lambda (s) (or (string-empty-p s) (string-prefix-p "%(" s)))
              (mapcar #'string-trim (split-string (or value "") ";"))))

(defconst kitty-msvc--standards
  '(("stdc11" . "/std:c11") ("stdc17" . "/std:c17") ("stdclatest" . "/std:clatest")
    ("stdcpp14" . "/std:c++14") ("stdcpp17" . "/std:c++17") ("stdcpp20" . "/std:c++20")
    ("stdcpplatest" . "/std:c++latest"))
  "MSBuild's LanguageStandard values and cl.exe's flags for them.")

(defun kitty-msvc-compile-command (item properties directory)
  "The compile_commands.json entry of ClCompile ITEM (a plist).
PROPERTIES are the project's evaluated properties; DIRECTORY its folder."
  (let* ((file (plist-get item :FullPath))
         (c-file (string-match-p "\\.c\\'" file))
         (compile-as (plist-get item :CompileAs))
         (std (cdr (assoc (if (or (equal compile-as "CompileAsC") (and c-file (not (equal compile-as "CompileAsCpp"))))
                              (plist-get item :LanguageStandard_C)
                            (plist-get item :LanguageStandard))
                          kitty-msvc--standards))))
    (list :directory directory
          :file file
          :arguments
          (vconcat
           (list "cl.exe" "/nologo" "/c")
           (pcase compile-as ("CompileAsC" '("/TC")) ("CompileAsCpp" '("/TP")))
           (and std (list std))
           (mapcar (lambda (d) (concat "/D" d)) (kitty-msvc--list (plist-get item :PreprocessorDefinitions)))
           (mapcar (lambda (d) (concat "/I" d)) (kitty-msvc--list (plist-get item :AdditionalIncludeDirectories)))
           (mapcar (lambda (d) (concat "/imsvc" d))
                   (append (kitty-msvc--list (plist-get properties :IncludePath))
                           (kitty-msvc--list (plist-get properties :ExternalIncludePath))))
           (mapcar (lambda (f) (concat "/FI" f)) (kitty-msvc--list (plist-get item :ForcedIncludeFiles)))
           (split-string (or (plist-get item :AdditionalOptions) "") "[ \t]+" t)
           (list file)))))

(defun kitty-msvc-compile-commands (evaluation vcxproj)
  "The compile_commands.json entries of VCXPROJ from its EVALUATION."
  (let ((properties (plist-get evaluation :Properties))
        (dir (directory-file-name (file-name-directory vcxproj))))
    (delq nil
          (mapcar (lambda (item)
                    (unless (equal (downcase (or (plist-get item :ExcludedFromBuild) "")) "true")
                      (kitty-msvc-compile-command item properties dir)))
                  (plist-get (plist-get evaluation :Items) :ClCompile)))))

(defun kitty-msvc-write-compile-commands (&optional solution)
  "Write compile_commands.json next to SOLUTION, from MSBuild's evaluation of each project.
clangd reads it; the language servers of open C buffers are restarted."
  (interactive)
  (let* ((solution (or solution (kitty-msvc-solution) (user-error "No .sln or .vcxproj above this file")))
         (projects (kitty-msvc-projects solution))
         (out (expand-file-name "compile_commands.json" (file-name-directory solution)))
         entries (i 0))
    (dolist (p projects)
      (setq i (1+ i))
      (message "kittymax: evaluating %s (%d/%d) ..." (file-name-nondirectory p) i (length projects))
      (setq entries (append entries (kitty-msvc-compile-commands (kitty-msvc-evaluate p) p))))
    (with-temp-file out
      (insert (json-serialize (vconcat entries)))
      (json-pretty-print-buffer))
    (dolist (b (buffer-list))
      (with-current-buffer b
        (when (and (derived-mode-p 'c-mode 'c-ts-mode 'c++-mode 'c++-ts-mode)
                   (fboundp 'eglot-current-server) (eglot-current-server))
          (ignore-errors (eglot-reconnect (eglot-current-server))))))
    (message "kittymax: %s: %d files from %d project(s)" out (length entries) (length projects))
    out))

;;;; Building, running

(defun kitty-msvc-build-command (solution)
  "The MSBuild command line that builds SOLUTION (a .sln or .vcxproj)."
  (mapconcat #'shell-quote-argument
             (list (kitty-msvc-msbuild) solution "-m" "-nologo" "-v:minimal" "-clp:NoSummary"
                   (concat "-p:Configuration=" kitty-msvc-configuration)
                   (concat "-p:Platform=" (if (string-suffix-p ".vcxproj" solution)
                                              (kitty-msvc-project-platform kitty-msvc-platform)
                                            kitty-msvc-platform)))
             " "))

(defun kitty-msvc-build (&optional solution)
  "Build SOLUTION (default: the one above this file) with MSBuild."
  (interactive)
  (let* ((solution (or solution (kitty-msvc-solution) (user-error "No .sln or .vcxproj above this file")))
         (default-directory (file-name-directory solution)))
    (compile (kitty-msvc-build-command solution))))

(defun kitty-msvc-executable (&optional solution)
  "The program a project of SOLUTION builds (asks when several build one)."
  (let* ((solution (or solution (kitty-msvc-solution) (user-error "No .sln or .vcxproj above this file")))
         (apps (delq nil (mapcar (lambda (p)
                                   (let ((props (plist-get (kitty-msvc-evaluate p '("TargetPath" "ConfigurationType"))
                                                           :Properties)))
                                     (when (equal (plist-get props :ConfigurationType) "Application")
                                       (cons (file-name-base p) (plist-get props :TargetPath)))))
                                 (kitty-msvc-projects solution)))))
    (cond ((null apps) (user-error "No project of %s builds a program" (file-name-nondirectory solution)))
          ((null (cdr apps)) (cdar apps))
          (t (cdr (assoc (completing-read "Program: " apps nil t) apps))))))

(provide 'kitty-msvc)
;;; kitty-msvc.el ends here
