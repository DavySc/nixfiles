;;; kitty-c.el --- C and C++  -*- lexical-binding: t; -*-

;;; Commentary:

;; tree-sitter modes, clangd (indexing in the background, clang-tidy
;; diagnostics), clang-format on save when the project has a .clang-format.
;; SPC m builds whatever the project is, as Visual Studio would:
;;
;;   CMake         CMakeLists.txt; with CMakePresets.json, a preset (asked once)
;;   MSBuild       a .sln / .vcxproj from Visual Studio (kitty-msvc.el)
;;   Make          a Makefile
;;   one file      no project: this file alone, with gcc, clang or cl
;;                 (the first one found, as my-nvim's ftplugin/cpp.lua does)
;;
;; On Windows the MSVC compiler's environment is read from Visual Studio
;; before anything is built, so cl.exe, Ninja and nmake work in Emacs as in a
;; Developer Command Prompt.  Debugging: dape with CodeLLDB on Windows (it
;; reads the PDBs MSVC writes), gdb elsewhere.

;;; Code:

(require 'kitty-lib)
(require 'subr-x)
(require 'seq)
(require 'kitty-msvc)

(declare-function dape "dape")
(declare-function kitty-debug-adapter "kitty-csharp")

(setq c-ts-mode-indent-offset 4
      c-ts-mode-indent-style 'k&r
      c-basic-offset 4
      c-default-style '((c-mode . "k&r") (c++-mode . "stroustrup") (other . "gnu")))

(dolist (hook '(c-mode-hook c-ts-mode-hook c++-mode-hook c++-ts-mode-hook))
  (kitty-add-hook hook (lambda () (kitty-eglot-ensure-for "clangd"))))

;; clang-format has an opinion even without a style file; only format when
;; the project pinned one.
(defun kitty--c-format-on-save-p ()
  (and buffer-file-name
       (locate-dominating-file buffer-file-name ".clang-format")))
(defun kitty--c-setup ()
  (unless (kitty--c-format-on-save-p)
    (when (fboundp 'apheleia-mode) (apheleia-mode -1))))
(dolist (hook '(c-mode-hook c-ts-mode-hook c++-mode-hook c++-ts-mode-hook))
  (kitty-add-hook hook #'kitty--c-setup))

;;;; Which build

(defun kitty-c--root ()
  (kitty-project-root))

(defun kitty-c--build-system ()
  "How the project is built: `cmake', `msbuild', `make' or nil (this file alone)."
  (let ((root (kitty-c--root)))
    (cond ((file-exists-p (expand-file-name "CMakeLists.txt" root)) 'cmake)
          ((kitty-msvc-solution) 'msbuild)
          ((seq-some (lambda (f) (file-exists-p (expand-file-name f root))) '("Makefile" "makefile" "GNUmakefile"))
           'make))))

(defun kitty-c--compile (command &optional comint)
  "Run COMMAND at the project root, in the MSVC environment on Windows."
  (kitty-msvc-ensure-env)
  (let ((default-directory (kitty-c--root)))
    (compile command comint)))

;;;; CMake, with or without presets

(defvar kitty-c--presets (make-hash-table :test #'equal) "Project root -> the configure preset chosen.")

(defun kitty-c--presets-file ()
  (seq-find #'file-exists-p (mapcar (lambda (f) (expand-file-name f (kitty-c--root)))
                                    '("CMakeUserPresets.json" "CMakePresets.json"))))

(defun kitty-c--read-presets (file)
  "Configure and build presets of FILE and the files it includes."
  (let* ((json (json-parse-string (with-temp-buffer (insert-file-contents file) (buffer-string))
                                  :object-type 'plist :null-object nil :false-object nil))
         (configure (append (plist-get json :configurePresets) nil))
         (build (append (plist-get json :buildPresets) nil)))
    (seq-doseq (inc (plist-get json :include))
      (let ((more (kitty-c--read-presets (expand-file-name inc (file-name-directory file)))))
        (setq configure (append configure (car more)) build (append build (cdr more)))))
    (when (string-suffix-p "CMakeUserPresets.json" file)
      (let ((main (expand-file-name "CMakePresets.json" (file-name-directory file))))
        (when (file-exists-p main)
          (let ((more (kitty-c--read-presets main)))
            (setq configure (append configure (car more)) build (append build (cdr more)))))))
    (cons configure build)))

(defun kitty-c-preset-binary-dir (name presets root)
  "The build directory of configure preset NAME (inherited, macros expanded)."
  (let* ((find (lambda (n) (seq-find (lambda (p) (equal (plist-get p :name) n)) presets)))
         (dir nil) (todo (list name)))
    (while (and todo (not dir))
      (let ((p (funcall find (pop todo))))
        (setq dir (plist-get p :binaryDir))
        (let ((inh (plist-get p :inherits)))
          (setq todo (append todo (if (stringp inh) (list inh) (append inh nil)))))))
    (when dir
      (let ((root (directory-file-name root)))
        (dolist (m `(("${sourceDir}" . ,root) ("${presetName}" . ,name)
                     ("${sourceParentDir}" . ,(directory-file-name (file-name-directory root)))
                     ("${sourceDirName}" . ,(file-name-nondirectory root))))
          (setq dir (string-replace (car m) (cdr m) dir)))
        (setq dir (replace-regexp-in-string "\\$env{\\([^}]+\\)}" (lambda (m) (or (getenv (match-string 1 m)) "")) dir t t))
        (expand-file-name dir root)))))

(defun kitty-c--preset (&optional ask)
  "The configure preset of this project: the one chosen before, else ASK."
  (let ((root (kitty-c--root)))
    (or (and (not ask) (gethash root kitty-c--presets))
        (let* ((presets (car (kitty-c--read-presets (kitty-c--presets-file))))
               (names (mapcar (lambda (p) (plist-get p :name))
                              (seq-remove (lambda (p) (eq (plist-get p :hidden) t)) presets))))
          (puthash root (completing-read "CMake preset: " names nil t) kitty-c--presets)))))

(defun kitty-c--build-dir ()
  "Where CMake builds: the preset's directory, else build/."
  (or (and (kitty-c--presets-file)
           (kitty-c-preset-binary-dir (kitty-c--preset) (car (kitty-c--read-presets (kitty-c--presets-file)))
                                      (kitty-c--root)))
      (expand-file-name "build" (kitty-c--root))))

(defun kitty-c--copy-compile-commands (buffer status)
  "After a configure: put compile_commands.json where clangd looks (the root)."
  (when (string-prefix-p "finished" status)
    (with-current-buffer buffer
      (let ((from (expand-file-name "compile_commands.json" (kitty-c--build-dir)))
            (to (expand-file-name "compile_commands.json" (kitty-c--root))))
        (when (and (file-exists-p from) (not (file-equal-p from to))
                   (not (equal (file-name-directory from) (expand-file-name "build/" (kitty-c--root)))))
          (copy-file from to t))))))

(defun kitty-c-configure (&optional ask)
  "Configure: CMake (a preset when the project has them; ASK: choose again), or
compile_commands.json from MSBuild for a Visual Studio solution."
  (interactive "P")
  (pcase (kitty-c--build-system)
    ('msbuild (kitty-msvc-write-compile-commands))
    (_
     (let ((buf (kitty-c--compile
                 (if (kitty-c--presets-file)
                     (format "cmake --preset %s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
                             (shell-quote-argument (kitty-c--preset ask)))
                   (concat "cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug "
                           "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON")))))
       (with-current-buffer buf
         (add-hook 'compilation-finish-functions #'kitty-c--copy-compile-commands nil t))))))

;;;; Build, run, test

(defun kitty-c-build ()
  "Build the project; a lone file without a build system is compiled directly."
  (interactive)
  (pcase (kitty-c--build-system)
    ('cmake (kitty-c--compile (format "cmake --build %s" (shell-quote-argument (kitty-c--build-dir)))))
    ('msbuild (kitty-msvc-ensure-env) (kitty-msvc-build))
    ('make (kitty-c--compile "make -k"))
    (_ (kitty-c-compile-file))))

(defun kitty-c-compiler (&optional cxx)
  "The first compiler on PATH: gcc, clang, then MSVC's cl (CXX: g++, clang++, cl)."
  (or (seq-find #'executable-find (if cxx '("g++" "clang++" "cl") '("gcc" "clang" "cl")))
      (and (eq system-type 'windows-nt) (kitty-msvc-ensure-env) (executable-find "cl") "cl")
      (if cxx "g++" "gcc")))

(defun kitty-c--scratch-binary (file)
  "Where FILE alone compiles to: the cache, keyed by its full path."
  (let ((dir (expand-file-name "c-bin" kitty-cache-dir)))
    (make-directory dir t)
    (expand-file-name (concat (file-name-base file) "-" (substring (md5 file) 0 8)
                              (if (eq system-type 'windows-nt) ".exe" ""))
                      dir)))

(defun kitty-c-compile-file-command (file &optional cxx compiler)
  "The command line that compiles FILE alone (with my-nvim's flags)."
  (let* ((compiler (or compiler (kitty-c-compiler cxx)))
         (out (kitty-c--scratch-binary file)))
    (mapconcat #'shell-quote-argument
               (if (member (file-name-base compiler) '("cl"))
                   (list compiler "/nologo" (if cxx "/std:c++latest" "/std:clatest") "/W4" "/Zi" "/EHsc" file
                         (concat "/Fe:" out) (concat "/Fo:" out ".obj") (concat "/Fd:" out ".pdb"))
                 (list compiler (if cxx "-std=c++23" "-std=c23") "-Wall" "-Wextra" "-g" file "-o" out))
               " ")))

(defun kitty-c-compile-file ()
  "Compile just this file to an executable (in the cache)."
  (interactive)
  (let ((file (or buffer-file-name (user-error "Save the buffer first"))))
    (kitty-msvc-ensure-env)
    (compile (kitty-c-compile-file-command file (derived-mode-p 'c++-mode 'c++-ts-mode)))))

(defun kitty-c-executable ()
  "The program to run or debug: the solution's, the CMake build's, or this file's."
  (pcase (kitty-c--build-system)
    ('msbuild (kitty-msvc-executable))
    ('cmake
     (let* ((dir (kitty-c--build-dir))
            (candidates (and (file-directory-p dir)
                             (seq-filter (lambda (f) (and (file-executable-p f) (not (file-directory-p f))
                                                          (or (not (eq system-type 'windows-nt))
                                                              (string-suffix-p ".exe" f))))
                                         (directory-files-recursively
                                          dir "" nil (lambda (d) (not (string-match-p "CMakeFiles" d))))))))
       (cond ((null candidates) (user-error "Nothing built in %s yet (SPC m m)" dir))
             ((null (cdr candidates)) (car candidates))
             (t (completing-read "Program: " candidates nil t)))))
    (_ (if buffer-file-name (kitty-c--scratch-binary buffer-file-name) (user-error "Nothing to run")))))

(defun kitty-c-run ()
  "Run the built program."
  (interactive)
  (let ((exe (kitty-c-executable)))
    (let ((default-directory (file-name-directory exe)))
      (compile (shell-quote-argument exe) t))))

(defun kitty-c-test ()
  "Run ctest."
  (interactive)
  (kitty-c--compile (format "ctest --test-dir %s --output-on-failure" (shell-quote-argument (kitty-c--build-dir)))))

;;;; Debugging

(defun kitty-c-debug ()
  "Debug the program: CodeLLDB through dape on Windows (MSVC's PDBs), gdb elsewhere."
  (interactive)
  (if-let* ((adapter (and (eq system-type 'windows-nt)
                          (fboundp 'kitty-debug-adapter)
                          (kitty-debug-adapter "codelldb" "codelldb" "extension" "adapter" "codelldb"))))
      (let ((exe (kitty-c-executable)))
        (require 'dape)
        (dape `(command ,adapter
                        command-args ("--port" :autoport)
                        port :autoport
                        :type "lldb" :request "launch"
                        :program ,exe :cwd ,(file-name-directory exe) :args [])))
    (call-interactively #'gdb)))

(dolist (mode '(c-mode c-ts-mode c++-mode c++-ts-mode))
  ;; my-nvim's <leader>m keys (ftplugin/cpp.lua): mm build, mr run, md debug,
  ;; mg configure, ma source / header.  The rest are extras on free keys.
  (kitty-local-leader mode
    "m" '("build" . kitty-c-build)
    "r" '("run" . kitty-c-run)
    "d" '("debug" . kitty-c-debug)
    "g" '("configure / compile_commands" . kitty-c-configure)
    "a" '("source / header" . ff-find-other-file)
    "B" '("compile this file" . kitty-c-compile-file)
    "T" '("ctest" . kitty-c-test)
    "f" '("format" . kitty-format)))

(provide 'kitty-c)
;;; kitty-c.el ends here
